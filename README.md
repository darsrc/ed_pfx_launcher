# ed_pfx_launcher

`ed_pfx_launcher.sh` coordinates Elite Dangerous (AppID 359320), MinEdLauncher, EDCoPilot, and additional Windows tools on Linux with Proton and strong fallback behavior.

## Why this exists (core bug fix)
Launching multiple Proton wrappers against the same `compatdata` can serialize/lock. This launcher prevents that by defaulting to **split instance mode** (`game` prefix + separate `tools` prefix) and then bridging important Windows user-data directories with symlinks.

## Steam mode vs terminal mode
- **Steam mode**: pass forwarded `%command%` tokens after `--`. Example shown below.
- **Terminal mode**: launcher builds explicit Proton commands.
- If literal `%command%` is passed from terminal accidentally, launcher logs warning and stays terminal mode.

## Native MinEdLauncher is Steam-only
Native MinEdLauncher is only used in Steam mode where forwarded token contract exists. In terminal mode launcher uses `MinEdLauncher.exe` under Proton.

## Early launcher exit is not immediate failure
MinEd can exit quickly after spawning game. The launcher waits for a **stable** `EliteDangerous64.exe` (default stable window: 6s) up to `--timeout`.

## Features
- Prefix/proton detection + selection:
  - `--prefix-dir`, `--prefix-select`
  - `--proton-dir`, `--proton-select`
  - `--interactive`, `--interactive-ui <wizard|legacy>`
- Config keys:
  - `[steam] prefix_dir`, `prefix_select`
  - `[proton] dir`, `select`
  - `[interactive] ui`
  - compatibility alias: `steam.compatdata_dir`
- Wizard UI with `prompt_toolkit`, save/cancel flow, fallback to legacy auto-select on non-TTY/missing backend.
- Shared data bridge (`[shared_data]`) over mapped paths:
  - `users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous`
  - `users/steamuser/AppData/Local/EDCoPilot`
  - `users/steamuser/Documents/Frontier Developments/Elite Dangerous`
- Strategy `symlink` implemented fully; `bind`/`copy` accepted and logged fallback to symlink.
- Multi-tool repeatable launch: `--tool <path.exe>` (repeatable), per-tool logs, detached process groups.
- Tools-only mode:
  - `--no-game` default leaves tools running on launcher exit.
  - `--no-game --wait-tools` waits and then cleanup on Ctrl+C/exit.
- EDCoPilot modes:
  - `--edcopilot-mode <auto|runtime|proton>`
  - `--edcopilot-delay`, `--edcopilot-bus-wait`, `--edcopilot-timeout`
  - runtime uses `steam-runtime-launch-client` + `busctl` contract (`com.steampowered.App${APPID}`) when available.
  - auto mode falls back to Proton with explicit log reason.
- Wayland/performance knobs (config + CLI):
  - `--pulse` => `PULSE_LATENCY_MSEC`
  - `--gpu` => `DXVK_FILTER_DEVICE_NAME`
  - `--cap` => `DXVK_FRAME_RATE`
  - auto NVIDIA ICD preference with `/usr/share/vulkan/icd.d/nvidia_icd.json`
  - Wayland hint (`PROTON_ENABLE_WAYLAND=1` if `WAYLAND_DISPLAY` present)
  - PRIME variable cleanup (`__NV_PRIME_RENDER_OFFLOAD`, `__GLX_VENDOR_LIBRARY_NAME`, `__VK_LAYER_NV_optimus`)
- Back-compat:
  - `--debug` (Wine categories: `-all,+seh,+err,+mscoree,+loaddll`)
  - `--profile <name>` loads `~/.config/ed_launcher/<name>.ini`
  - `--no-edcopilot`, `--no-mined`, `--timeout`
- Proton discovery includes:
  - `steamapps/common/Proton*`
  - compatibilitytools.d in user + system dirs (`/usr/share/steam/compatibilitytools.d`, `/usr/local/share/steam/compatibilitytools.d`)

## Logging
Default log root:
`$XDG_STATE_HOME/ed_pfx_launcher` (or `~/.local/state/ed_pfx_launcher`).

Logs include:
- Coordinator log with full launch plan and selected decisions.
- Per-tool logs (`tool_N.log`), plus MinEd/game/EDCoPilot logs.
- Debug mode includes extended Wine debug level and `/tmp/ed_launcher_debug_*.log` marker.

## Config model
See `config/example.ini`.
CLI overrides config values.

## VDF parsing assumptions
This launcher avoids brittle `libraryfolders.vdf` parsing by discovering under known Steam roots and compatibilitytools directories directly. It handles common layouts without strict dependency on exact VDF formatting.

## Smoke harness
Run:
```bash
scripts/smoke_interactive.sh
```
Checks:
- unset-variable safety bootstrap
- wizard cancel does not modify config
- wizard save path emits both selected paths
- non-TTY wizard fallback logging + legacy auto-select
- auto runtime fallback behavior
- tools-only behavior
- plan summary contains perf knobs

## Steam launch options example
```bash
/path/to/ed_pfx_launcher.sh --profile darvix -- -- %command%
```
(Use Steam mode forwarding by placing `%command%` after `--`.)

## Terminal examples
Game + EDCoPilot concurrently (split prefixes default):
```bash
./ed_pfx_launcher.sh --profile darvix --edcopilot-mode auto
```

Tools-only detached:
```bash
./ed_pfx_launcher.sh --no-game --tool "Z:\\path\\ToolA.exe" --tool "Z:\\path\\ToolB.exe"
```

Tools-only wait + cleanup:
```bash
./ed_pfx_launcher.sh --no-game --wait-tools --tool "Z:\\path\\ToolA.exe"
```

Force EDCoPilot runtime mode:
```bash
./ed_pfx_launcher.sh --edcopilot-mode runtime
```

Tune pulse/gpu/cap:
```bash
./ed_pfx_launcher.sh --pulse 80 --gpu "RTX 3060" --cap 60
```
