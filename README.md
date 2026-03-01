# ed_pfx_launcher

`ed_pfx_launcher.sh` launches Elite Dangerous + MinEdLauncher + EDCoPilot + arbitrary tools on Linux with robust logging, fallbacks, and a concurrency-safe default (split prefixes).

## Why this exists
Proton wrapper launches against the same compatdata can serialize/lock. This launcher defaults to **split instance mode** (`instances.mode=split`) so game and tools use separate prefixes, then bridges shared Windows user folders with symlinks.

## Contexts
- **Steam mode:** `ed_pfx_launcher.sh [opts] -- <expanded %command% tokens>`.
- **Terminal mode:** invoke directly; launcher builds Proton/runtime command lines itself.
- Literal `%command%` in terminal is detected and ignored with a warning.

## MinEd native vs Windows
- Native MinEd is used only in Steam mode and only if configured executable exists.
- Terminal mode always runs `MinEdLauncher.exe` via Proton.

## Early MinEd exit behavior
MinEd can exit after spawning the game. This is not treated as failure. Launcher polls for `EliteDangerous64.exe` and requires stability (`--stable-seconds`) before success.

## Key CLI flags
- Prefix/Proton detection: `--prefix-dir`, `--prefix-select`, `--proton-dir`, `--proton-select`
- Interactive: `--interactive`, `--interactive-ui wizard|legacy`
- Modes: `--no-game`, `--wait-tools`, `--no-mined`, `--no-edcopilot`, `--no-monitor`
- Tools: repeatable `--tool /path/app.exe`
- EDCoPilot: `--edcopilot-mode auto|runtime|proton`, `--edcopilot-delay`, `--edcopilot-bus-wait`, `--edcopilot-timeout`
- Perf knobs: `--pulse`, `--gpu`, `--cap`
- Debug: `--debug` (Wine debug categories + timestamped logs)

## Config
Profile files: `~/.config/ed_launcher/<name>.ini` loaded by `--profile <name>`.

Supported keys:
- `[steam] prefix_dir`, `prefix_select`, alias `compatdata_dir`
- `[proton] dir`, `select`
- `[interactive] ui`
- `[shared_data] enabled`, `source_prefix`, `strategy`
- `[instances] mode`, `game_prefix`, `edcopilot_prefix`, `tool_prefix_base`
- `[paths] mined_native`, `mined_exe`, `edcopilot_exe`
- `[performance] pulse_latency_msec`, `dxvk_filter_device_name`, `dxvk_frame_rate`, `prefer_nvidia_icd`

## Shared Data Bridge
Before tool launch, these folders are bridged between prefixes (symlink strategy):
- `drive_c/users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous`
- `drive_c/users/steamuser/AppData/Local/EDCoPilot`
- `drive_c/users/steamuser/Documents/Frontier Developments/Elite Dangerous`

Idempotent behavior:
- correct symlink: kept
- mismatched symlink: corrected
- unmanaged non-empty real dirs: left untouched with warning

## Steam runtime client detection order
Checks common Steam roots for:
1. `ubuntu12_64/steam-runtime-launch-client`
2. `steamapps/common/SteamLinuxRuntime_sniper/steam-runtime-launch-client`
3. `steamapps/common/SteamLinuxRuntime_sniper/run`

`--edcopilot-mode auto` tries runtime path first when dependencies are available (`busctl`, runtime client, Proton wine), otherwise falls back to Proton mode.

## Smoke harness
Run:
```bash
scripts/smoke_interactive.sh
```
Validates:
- bootstrap unset-variable safety
- wizard non-TTY fallback + config save keys
- wizard cancel path does not alter config
- tools-only default leaves tools running
- tools-only `--wait-tools` waits and cleanup on Ctrl+C
- auto runtime fallback behavior and perf knobs in plan summary

## VDF parsing note
This implementation intentionally avoids brittle VDF parsing; it scans known Steam roots and common Proton/prefix locations instead.

## Usage examples
Steam launch options example:
```bash
/workspace/ed_pfx_launcher/ed_pfx_launcher.sh --profile darvix --interactive-ui wizard -- %command%
```

Terminal examples:
```bash
# game + EDCoPilot concurrently (split prefixes default)
./ed_pfx_launcher.sh --profile darvix

# tools-only (detach)
./ed_pfx_launcher.sh --no-game --tool "/path/ToolA.exe" --tool "/path/ToolB.exe"

# tools-only with wait and cleanup
./ed_pfx_launcher.sh --no-game --wait-tools --tool "/path/ToolA.exe"

# force EDCoPilot runtime mode
./ed_pfx_launcher.sh --edcopilot-mode runtime

# perf knobs
./ed_pfx_launcher.sh --pulse 80 --gpu "RTX 3060" --cap 72
```
