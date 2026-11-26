-- Multi-profile fork/enhancement of github.com/d87/mpv-persist-properties
-- Persists selected mpv properties across sessions, scoped per profile.

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")
local options = require("mp.options")

local opts = {
    -- Default comma-separated list of mpv properties to persist
    properties = "",
    -- Active profile name (can be changed at runtime or via mpv.conf profiles)
    profile = "default",
    -- Optional comma-separated list of profiles for cycling (e.g. "default,headphones,speakers")
    profiles = "",
    -- Optional per-profile property overrides: "anime:volume,sub-scale;music:volume,speed"
    profile_properties = "",
    -- Storage path (supports mpv path expansion like ~~/)
    config_path = "~~/persistent_config.json",
    -- Save changes automatically (debounced). If false, saves on profile switch and shutdown.
    save_on_change = true,
    -- Show OSD notification when switching/saving/resetting profiles
    osd_messages = true,
}

local active_profile = "default"
local profile_values = {}
local pending_changes = {}
local initialized_props = {}
local save_timer = nil

-- Helpers --------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function parse_csv(str)
    local result = {}
    if not str or str == "" then
        return result
    end
    for item in str:gmatch("[^,]+") do
        local cleaned = trim(item)
        if cleaned ~= "" then
            table.insert(result, cleaned)
        end
    end
    return result
end

local function parse_profile_properties(str)
    local map = {}
    if not str or str == "" then
        return map
    end
    for entry in str:gmatch("[^;]+") do
        local name, props = entry:match("^%s*([^:]+):(.*)$")
        if name and props then
            local trimmed_name = trim(name)
            if trimmed_name ~= "" then
                map[trimmed_name] = parse_csv(props)
            end
        end
    end
    return map
end

local function deep_copy(val)
    if type(val) ~= "table" then
        return val
    end
    local copy = {}
    for k, v in pairs(val) do
        copy[k] = deep_copy(v)
    end
    return copy
end

local function deep_equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function notify(text)
    if opts.osd_messages then
        mp.osd_message(text)
    end
    msg.info(text)
end

local function get_config_path()
    return mp.command_native({ "expand-path", opts.config_path })
end

local function get_properties_for_profile(profile_name)
    local overrides = parse_profile_properties(opts.profile_properties)
    if overrides[profile_name] and #overrides[profile_name] > 0 then
        return overrides[profile_name]
    end
    return parse_csv(opts.properties)
end

-- Persistence ----------------------------------------------------------------

local function normalize_store(data)
    if type(data) ~= "table" then
        return { _version = 2, profiles = {} }
    end
    if data._version == 2 and type(data.profiles) == "table" then
        return data
    end
    -- Migrate legacy flat format into the "default" profile
    local migrated = { _version = 2, profiles = { default = {} } }
    for k, v in pairs(data) do
        if type(k) == "string" then
            migrated.profiles.default[k] = v
        end
    end
    msg.info("Migrated legacy persistent_config.json into 'default' profile.")
    return migrated
end

local function read_store_from_disk()
    local path = get_config_path()
    local f = io.open(path, "r")
    if not f then
        return { _version = 2, profiles = {} }
    end
    local content = f:read("*a")
    f:close()

    if not content or trim(content) == "" then
        return { _version = 2, profiles = {} }
    end

    local parsed, err = utils.parse_json(content)
    if err or type(parsed) ~= "table" then
        msg.warn("Could not parse " .. path .. "; starting with empty config.")
        return { _version = 2, profiles = {} }
    end
    return normalize_store(parsed)
end

local function write_store_to_disk(store)
    local path = get_config_path()
    local encoded, err = utils.format_json(store)
    if err or not encoded then
        msg.error("Failed to serialize persistent config: " .. tostring(err))
        return false
    end
    local f, open_err = io.open(path, "w")
    if not f then
        msg.error("Failed to open " .. path .. " for writing: " .. tostring(open_err))
        return false
    end
    f:write(encoded)
    f:close()
    return true
end

local function flush_save()
    if save_timer then
        save_timer:kill()
        save_timer = nil
    end
    if next(pending_changes) == nil then
        return
    end

    -- Re-read disk first so concurrent mpv instances on other profiles aren't clobbered
    local store = read_store_from_disk()
    if type(store.profiles[active_profile]) ~= "table" then
        store.profiles[active_profile] = {}
    end

    for k, v in pairs(pending_changes) do
        store.profiles[active_profile][k] = v
    end

    if write_store_to_disk(store) then
        pending_changes = {}
    end
end

local function schedule_save()
    if save_timer then
        save_timer:kill()
    end
    save_timer = mp.add_timeout(0.5, function()
        save_timer = nil
        flush_save()
    end)
end

-- Property Observation & Profile Switching -----------------------------------

local function on_property_change(name, val)
    -- Skip the initial callback fired immediately upon mp.observe_property
    if not initialized_props[name] then
        initialized_props[name] = true
        return
    end
    if val == nil then
        return
    end
    if deep_equal(profile_values[name], val) then
        return
    end

    profile_values[name] = deep_copy(val)
    pending_changes[name] = deep_copy(val)

    if opts.save_on_change then
        schedule_save()
    end
end

local function apply_profile(target_profile, show_osd)
    target_profile = trim(target_profile or "")
    if target_profile == "" then
        target_profile = "default"
    end

    -- Save any pending edits for the outgoing profile before switching
    flush_save()
    mp.unobserve_property(on_property_change)

    active_profile = target_profile
    local store = read_store_from_disk()
    profile_values = deep_copy(store.profiles[active_profile] or {})
    pending_changes = {}
    initialized_props = {}

    local props = get_properties_for_profile(active_profile)

    -- Apply stored values first so observers pick up the restored state
    for _, prop in ipairs(props) do
        if profile_values[prop] ~= nil then
            local ok, err = mp.set_property_native(prop, profile_values[prop])
            if not ok then
                msg.warn(string.format(
                    "Failed to restore '%s' for profile '%s': %s",
                    prop, active_profile, tostring(err)
                ))
            end
        end
    end

    for _, prop in ipairs(props) do
        mp.observe_property(prop, "native", on_property_change)
    end

    if show_osd then
        notify("Persist profile: " .. active_profile)
    end
end

local function get_available_profiles()
    local list = {}
    local seen = {}

    local function add(name)
        if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(list, name)
        end
    end

    -- 1. User-configured order from `profiles=`
    for _, name in ipairs(parse_csv(opts.profiles)) do
        add(name)
    end
    -- 2. Any profiles referenced in `profile_properties=`
    for name in pairs(parse_profile_properties(opts.profile_properties)) do
        add(name)
    end
    -- 3. Any profiles already saved on disk
    local store = read_store_from_disk()
    local disk_names = {}
    for name in pairs(store.profiles) do
        table.insert(disk_names, name)
    end
    table.sort(disk_names)
    for _, name in ipairs(disk_names) do
        add(name)
    end
    -- 4. Current active profile & fallback
    add(active_profile)
    if #list == 0 then
        add("default")
    end

    return list
end

-- Script Messages (for input.conf keybindings) -------------------------------

mp.register_script_message("persist-profile-set", function(name)
    if not name or trim(name) == "" then
        msg.warn("persist-profile-set requires a profile name.")
        return
    end
    apply_profile(name, true)
end)

mp.register_script_message("persist-profile-cycle", function(direction)
    local list = get_available_profiles()
    if #list == 0 then
        return
    end
    local idx = 1
    for i, name in ipairs(list) do
        if name == active_profile then
            idx = i
            break
        end
    end
    local step = (direction == "prev" or direction == "down") and -1 or 1
    local next_idx = ((idx - 1 + step) % #list) + 1
    apply_profile(list[next_idx], true)
end)

mp.register_script_message("persist-profile-save", function()
    local props = get_properties_for_profile(active_profile)
    for _, prop in ipairs(props) do
        local val = mp.get_property_native(prop)
        if val ~= nil then
            profile_values[prop] = deep_copy(val)
            pending_changes[prop] = deep_copy(val)
        end
    end
    flush_save()
    notify("Saved persist profile: " .. active_profile)
end)

mp.register_script_message("persist-profile-reset", function(target)
    local name = (target and trim(target) ~= "") and trim(target) or active_profile
    if name == active_profile then
        if save_timer then
            save_timer:kill()
            save_timer = nil
        end
        pending_changes = {}
        profile_values = {}
    end
    local store = read_store_from_disk()
    store.profiles[name] = nil
    write_store_to_disk(store)
    notify("Reset persist profile: " .. name)
end)

-- Init & Lifecycle -----------------------------------------------------------

local function on_opts_update(changed)
    if changed.profile or changed.properties or changed.profile_properties or changed.config_path then
        apply_profile(opts.profile, changed.profile == true)
    end
end

options.read_options(opts, "persist_properties", on_opts_update)
apply_profile(opts.profile, false)

mp.register_event("shutdown", function()
    flush_save()
end)
