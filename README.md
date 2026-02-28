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
  - `--interactive`: show detected prefix/Proton candidates, prompt for selection, and persist choices to config.
- Config keys:
  - `[steam] prefix_dir`, `prefix_select`
  - `[proton] dir`, `select`

When `steam.compatdata_dir` is still present, it is treated as a compatibility alias for `steam.prefix_dir`.

When `--interactive` is used, the script scans for all detectable prefix and Proton locations, asks you to choose each one, then writes `[steam] prefix_dir` and `[proton] dir` into the active config file before continuing.
