# ed_pfx_launcher

`ed_pfx_launcher.sh` can run in two launch contexts:

- **Steam mode**: Steam has expanded `%command%` and forwarded tokens to the script.
- **Terminal mode**: the script was started directly from a shell and no `%command%` argv is available.

## Steam mode vs terminal mode

- In **Steam mode**, forwarded command tokens may be prepended when launching MinEd.
- In **terminal mode**, no forwarded `%command%` sequence exists, so the launcher builds a direct runtime/Proton command.

## Why native `MinEdLauncher` is Steam-mode only

The native Linux `MinEdLauncher` path is only selected for Steam mode because its intended contract depends on Steam-expanded `%command%` token forwarding. In terminal mode this forwarding does not exist, so the script uses `MinEdLauncher.exe` under runtime/Proton.

## Why launcher exit is not treated as an immediate failure

`MinEdLauncher` can behave like a short-lived wrapper and exit after spawning the game process. For that reason, early launcher exit is recorded as a warning, but detection keeps polling for `EliteDangerous64.exe` until the configured game timeout.


## Prefix/Proton detection and selection

You can override or tune detection for the Wine prefix and Proton install:

- CLI flags:
  - `--prefix-dir <path>`: prefix search root or explicit compatdata dir (supports ending in `/pfx`).
  - `--prefix-select <first|newest>`: selection mode when multiple prefix candidates are found.
  - `--proton-dir <path>`: Proton search root or explicit Proton directory containing `proton`.
  - `--proton-select <first|newest>`: selection mode when multiple Proton candidates are found.
  - `--interactive`: run interactive prefix/Proton setup. Defaults to the wizard UI when terminal capabilities are sufficient, otherwise falls back safely to legacy mode.
  - `--interactive-ui <legacy|wizard>`: temporary rollout toggle. CLI overrides config.
- Config keys:
  - `[steam] prefix_dir`, `prefix_select`
  - `[proton] dir`, `select`
  - `[interactive] ui` (`wizard` default, or `legacy`)

When `steam.compatdata_dir` is still present, it is treated as a compatibility alias for `steam.prefix_dir`.

When `--interactive` is used, the script scans for all detectable prefix and Proton locations, routes to the selected interactive UI path, and writes `[steam] prefix_dir` and `[proton] dir` into the active config file before continuing.

`wizard` now uses a dedicated backend (`scripts/interactive_ui.py`) built on `prompt_toolkit`, with step-by-step candidate selection, review, and explicit save/cancel confirmations. If stdin/stdout are not TTYs (or the wizard backend is unavailable), the backend emits a legacy-compatible auto-select fallback so behavior remains stable in non-interactive sessions. Logs include which UI path was selected and whether wizard used fallback behavior.

`legacy` keeps the previous shell-driven prompt flow for a transition window and remains available through `--interactive-ui legacy`.

## Shared data bridge across prefixes

When you split Elite/game/tools into separate prefixes (`[instances]`), the launcher can map selected Windows user-data directories from one canonical prefix into every other tool prefix before launch. This keeps journals, settings, and companion app state consistent.

Config keys in `[shared_data]`:

- `enabled=true|false`: turn bridge setup on/off.
- `source_prefix=game|edcopilot|edcopter|tool`: canonical source prefix for shared data (`game` is recommended).
- `strategy=symlink|bind|copy`: `symlink` is implemented and preferred; `bind`/`copy` are accepted for forward compatibility and currently fall back to symlink.

Mapped Windows paths (relative to `drive_c/` in each prefix):

- `users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous`
- `users/steamuser/AppData/Local/EDCoPilot`
- `users/steamuser/Documents/Frontier Developments/Elite Dangerous`

Behavior notes:

- Bridge setup runs before EDCoPilot/EDCoPTER/CLI tool launch.
- Mapping is idempotent: existing correct symlinks are kept; mismatches are logged and corrected; non-empty unmanaged destination directories are left untouched with a warning.
- Link targets are validated and mismatch warnings are written to the coordinator log.

## Smoke harness

Run `scripts/smoke_interactive.sh` for a deterministic local smoke pass/fail summary. The harness is non-network and uses temporary local config files to verify:

- unset-variable safety in bootstrap token expansion,
- interactive wizard cancel path does not modify config,
- interactive save path writes both `[steam] prefix_dir` and `[proton] dir`,
- non-TTY wizard backend fallback logs and legacy-compatible auto-select behavior.
