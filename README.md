# mpv-persist-properties
Forked from https://github.com/d87/mpv-persist-properties

Lua script for mpv to keep selected values like volume between player sessions. Supports separate values for separate profiles.

## Features:

* Versioned multi-profile storage: Saves properties under ```profiles.<name>``` in ```persistent_config.json``` while auto-migrating legacy flat JSON files into ```profiles.default```.

* Native ```mpv.conf``` & auto-profile support: Listens for live ```script-opts``` updates via ```mp.options.read_options```'s ```on_update callback```, so static profiles, CLI flags, and conditional auto-profiles switch persistence profiles automatically.

* Per-profile property lists: Optionally override which properties are tracked for specific profiles using ```profile_properties```.

* Runtime switching via ```input.conf```: Adds ```script-message``` commands to set, cycle, snapshot, or reset profiles without restarting mpv.

* Safe writes & concurrency: Debounces disk writes, flushes on profile switch and ```shutdown```, ignores initial ```observe_property``` callbacks to prevent cross-profile clobbering, and merges against disk before saving so concurrent mpv instances using different profiles do not overwrite each other.

## Configuration & Usage:
### 1. ```script-opts/persist_properties.conf```
```
# Default properties persisted for all profiles
properties=volume,sub-scale,speed

# Default starting profile
profile=default

# Optional ordered list for cycling with persist-profile-cycle
# profiles=default,headphones,anime

# Optional per-profile property overrides (semicolon-separated)
# profile_properties=anime:volume,sub-scale,sub-pos;music:volume,speed
```
### 2. Integrating with ```mpv.conf``` Profiles (Static & Auto-Profiles)
```
# Static profile
[headphones]
script-opts-append=persist_properties-profile=headphones

# Auto profile based on path
[anime]
profile-cond=path:match("Anime") ~= nil
profile-restore=copy
script-opts-append=persist_properties-profile=anime
```
```profile-cond=path:match("Anime") ~= nil```

* Defines the trigger condition using a Lua expression. path is the full file path of the current video, and :match("Anime") ~= nil checks whether the word "Anime" appears anywhere in that path (case-sensitive). Whenever that evaluates to true, mpv automatically applies every setting under that ```[profile]``` section.

```profile-restore=copy```

* Tells mpv to revert the profile's settings as soon as the condition is no longer true (for example, when a regular movie is opened or a non-matching file in a playlist is played). Before applying the profile, mpv copies the previous values of any options the profile changes, then restores them once the condition becomes false. Without it, the profile's settings (including the ```persist_properties-profile``` switch) would stay stuck on for the rest of the mpv session even after watching anime is stopped.
### 3. Launching via CLI
```
mpv --script-opts=persist_properties-profile=headphones video.mkv
# Or via an mpv.conf profile defined above:
mpv --profile=headphones video.mkv
```
### 4. Runtime Switching in input.conf
```
Ctrl+p      script-message persist-profile-cycle
Ctrl+P      script-message persist-profile-cycle prev
Ctrl+1      script-message persist-profile-set default
Ctrl+2      script-message persist-profile-set headphones
Ctrl+s      script-message persist-profile-save
Ctrl+Alt+r  script-message persist-profile-reset
```
## _Generated using Gemini Neon_
