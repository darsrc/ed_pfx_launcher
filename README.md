# ed_pfx_launcher

Bash launcher for **Elite Dangerous + MinEdLauncher + EDCoPilot + extra tools** on Linux/Steam/Proton with explicit concurrency controls.

## Why this exists

Running multiple Proton launches against the same compatdata can serialize/lock. This project defaults to an **instance split model** (`game`, `edcopilot`, `tool` prefixes) to avoid lock contention, then applies a **shared data bridge** (symlink strategy) so key user data paths stay consistent.

## Files

- `ed_pfx_launcher.sh` - main launcher.
- `scripts/interactive_ui.py` - prompt_toolkit wizard (`NAME - DIR` selections, review/save/cancel).
- `scripts/smoke_interactive.sh` - deterministic local smoke checks.
- `config/example.ini` - sample config.

## Steam mode vs terminal mode

- **Steam mode**: pass forwarded tokens after `--`, e.g. `... -- %command%`.
  - If tokens are real expanded command tokens, launcher uses `steam` mode.
  - If literal `%command%` is seen in terminal, launcher warns and stays terminal mode.
- **Terminal mode**: launcher builds explicit Proton/runtime commands.

## Native MinEdLauncher is Steam-only

Native Linux MinEd is only selected in steam mode (and only when executable exists), because contract depends on Steam-expanded command forwarding.
In terminal mode, launcher uses `MinEdLauncher.exe` via Proton.

## Early MinEd exit is not immediate failure

Launcher does **not** treat MinEd early exit as failure. It polls for stable `EliteDangerous64.exe` and requires stability (`--stable-seconds`) before success.

## Prefix + Proton detection

CLI:
- `--prefix-dir <path>` / `--compatdata-dir <path>` alias
- `--prefix-select <first|newest>`
- `--proton-dir <path>`
- `--proton-select <first|newest>`
- `--interactive`
- `--interactive-ui <legacy|wizard>`

Config keys:
- `[steam] prefix_dir`, `prefix_select`
- `[steam] compatdata_dir` alias supported
- `[proton] dir`, `select`
- `[interactive] ui`

Discovery roots:
- Steam roots: `~/.steam/steam`, `~/.local/share/Steam`, `STEAM_COMPAT_CLIENT_INSTALL_PATH`
- Proton: `steamapps/common/Proton*` and compatibilitytools.d (user + system, including `/usr/share/steam/compatibilitytools.d`)

Assumptions for library discovery: common Steam layouts under known roots are scanned directly for `steamapps/compatdata` and Proton directories; parser avoids brittle VDF parsing by directory probing.

## Interactive behavior + fallback order

When `--interactive` is set:
1. Wizard (`prompt_toolkit`) if TTY + dependency available.
2. Legacy auto-select fallback otherwise.

Wizard writes active config with:
- `[steam] prefix_dir=...`
- `[proton] dir=...`

Cancel/non-TTY wizard does not save changes.

## Shared data bridge

Config section `[shared_data]`:
- `enabled=true|false`
- `source_prefix=game|edcopilot|edcopter|tool`
- `strategy=symlink|bind|copy` (`bind/copy` currently logged and treated as `symlink`)

Mapped paths under `drive_c/`:
- `users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous`
- `users/steamuser/AppData/Local/EDCoPilot`
- `users/steamuser/Documents/Frontier Developments/Elite Dangerous`

Idempotent behavior:
- correct link unchanged
- mismatched link corrected
- non-empty unmanaged dirs left untouched with warning

## Multi-tool and tools-only

- Repeatable tool launch: `--tool "C:/.../tool.exe"`
- tools-only: `--no-game`
- tools-only wait/cleanup: `--wait-tools`
  - without `--wait-tools`, launcher exits and leaves tools running
  - with `--wait-tools`, launcher waits until Ctrl+C and performs configured cleanup path

## EDCoPilot launch modes

- `--edcopilot-mode auto|runtime|proton`
- `--edcopilot-delay <sec>`
- `--edcopilot-bus-wait <sec>`
- `--edcopilot-timeout <sec>`

Bus-name: `com.steampowered.App${APPID}` where APPID derives from `SteamGameId`/`SteamAppId`, compatdata basename, or default `359320`.

Runtime client detection order (first hit wins):
1. `<steam_root>/ubuntu12_64/steam-runtime-launch-client`
2. `<steam_root>/steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client`
3. `<steam_root>/steamapps/common/SteamLinuxRuntime_sniper/steam-runtime-launch-client`

`auto` mode attempts runtime then falls back to proton with explicit logging.

## Performance knobs (CLI + env export)

- `--pulse <ms>` -> `PULSE_LATENCY_MSEC`
- `--gpu "<substring>"` -> `DXVK_FILTER_DEVICE_NAME`
- `--cap <fps>` -> `DXVK_FRAME_RATE`
- `--vk-icd <path>` -> `VK_ICD_FILENAMES`
- if NVIDIA ICD file exists and no override: prefers `/usr/share/vulkan/icd.d/nvidia_icd.json`
- if `WAYLAND_DISPLAY` exists and user did not override: sets `PROTON_ENABLE_WAYLAND=1`
- unsets PRIME offload vars to avoid mixed GPU routing

## Back-compat features

- `--debug` sets `WINEDEBUG=-all,+seh,+err,+mscoree,+loaddll`
- default quiet mode uses `WINEDEBUG=-all`
- profile loading: `--profile <name>` -> `~/.config/ed_launcher/<name>.ini`
- `--no-edcopilot`, `--no-mined`, `--timeout`

## Smoke harness

Run:

```bash
scripts/smoke_interactive.sh
```

Validates:
- strict mode bootstrap and unset safety
- wizard cancel/non-tty path does not modify config
- wizard save writes both steam/proton keys
- non-tty wizard fallback logging + legacy selection
- tools-only default exits without cleanup
- auto runtime fallback when runtime client absent
- plan summary includes perf knobs

## Steam Launch Options example

```bash
/workspace/ed_pfx_launcher/ed_pfx_launcher.sh --profile darvix --interactive-ui wizard -- %command%
```

## Terminal examples

Game + EDCoPilot concurrent split prefixes:

```bash
./ed_pfx_launcher.sh --instance-mode split --edcopilot-mode auto
```

Tools-only (detach and exit):

```bash
./ed_pfx_launcher.sh --no-game --tool "Z:/path/ToolA.exe" --tool "Z:/path/ToolB.exe"
```

Tools-only wait + cleanup on Ctrl+C:

```bash
./ed_pfx_launcher.sh --no-game --wait-tools --tool "Z:/path/ToolA.exe"
```

Force EDCoPilot runtime mode:

```bash
./ed_pfx_launcher.sh --edcopilot-mode runtime --edcopilot-bus-wait 45
```

Set pulse/gpu/cap:

```bash
./ed_pfx_launcher.sh --pulse 90 --gpu "RTX 3060" --cap 60
```
