#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCRIPT="$ROOT_DIR/ed_pfx_launcher.sh"
CFG="$TMP/test.ini"
LOGROOT="$TMP/state"
mkdir -p "$TMP/steam/steamapps/compatdata/359320/pfx" "$TMP/proton/Proton-9"
touch "$TMP/proton/Proton-9/proton"
chmod +x "$TMP/proton/Proton-9/proton"

pass(){ echo "PASS: $*"; }
fail(){ echo "FAIL: $*"; exit 1; }

# 1) unset-variable safety + bootstrap
XDG_STATE_HOME="$LOGROOT" "$SCRIPT" --help >/dev/null
pass "help path works with strict mode"

# 2) wizard cancel path does not modify config (simulate via non-tty fallback path by invoking python directly)
set +e
python3 "$ROOT_DIR/scripts/interactive_ui.py" "$CFG" "$TMP/steam/steamapps/compatdata/359320/pfx" "$TMP/proton/Proton-9" </dev/null >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "wizard should not run without tty"
[[ ! -f "$CFG" ]] || fail "config should remain unchanged on cancelled/non-tty wizard"
pass "wizard cancel/non-tty path leaves config untouched"

# 3) wizard save writes both keys (direct function simulation)
python3 - "$CFG" "$TMP/steam/steamapps/compatdata/359320/pfx" "$TMP/proton/Proton-9" <<'PY'
import scripts.interactive_ui as ui, sys
ui.save_config(sys.argv[1], sys.argv[2], sys.argv[3])
PY
rg -q '^prefix_dir\s*=\s*' "$CFG" || fail "prefix_dir missing"
rg -q '^dir\s*=\s*' "$CFG" || fail "proton dir missing"
pass "wizard save path writes both steam/proton keys"

# 4) non-TTY wizard fallback logs and legacy auto-select behavior
set +e
XDG_STATE_HOME="$LOGROOT" "$SCRIPT" --interactive --interactive-ui wizard --prefix-dir "$TMP/steam" --proton-dir "$TMP/proton" --no-game --tool "dummy.exe" >"$TMP/out.log" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "launcher fallback run failed"
rg -q 'Wizard fallback' "$TMP/out.log" || fail "expected wizard fallback log"
pass "non-tty wizard fallback logged"

# 5) tools-only default exits without cleanup kill
rg -q 'Tools-only mode launched; exiting without cleanup' "$TMP/out.log" || fail "tools-only message missing"
pass "tools-only default no cleanup verified"

# 6) auto runtime fallback to proton when runtime client absent
rg -q 'fallback to proton' "$TMP/out.log" || fail "auto fallback message missing"
pass "auto runtime fallback in non-runtime env"

# 7) plan includes perf knobs
rg -q 'PULSE_LATENCY_MSEC=' "$TMP/out.log" || fail "pulse missing"
rg -q 'DXVK_FILTER_DEVICE_NAME=' "$TMP/out.log" || fail "gpu missing"
rg -q 'DXVK_FRAME_RATE=' "$TMP/out.log" || fail "cap missing"
pass "plan summary includes perf knobs"

echo "Smoke checks complete"
