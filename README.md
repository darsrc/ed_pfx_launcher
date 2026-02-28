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

## Prefix and Proton directory selection

Both the Wine prefix and Proton install now support dynamic detection, config overrides, and CLI overrides:

- Prefix dir precedence: `--prefix-dir` → `[prefix] dir` → auto-detected compatdata `pfx` path.
- Proton dir precedence: `--proton-dir` → `[proton] dir` → deprecated `[proton] proton` compatibility key → auto-detected Proton directory.

When detected automatically, the script scans common Steam locations under `steamapps/compatdata` and `compatibilitytools.d`.
