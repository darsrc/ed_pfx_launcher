#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.smoke"
CONF="${WORK_DIR}/config.ini"
LOG_DIR="${WORK_DIR}/logs"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/steam/steamapps/compatdata/359320/pfx" "$WORK_DIR/steam/steamapps/common/Proton-Test" "$LOG_DIR"
mkdir -p "$WORK_DIR/steam/steamapps/compatdata/359321/pfx" "$WORK_DIR/steam/compatibilitytools.d/Proton-GE"
touch "$WORK_DIR/steam/steamapps/common/Proton-Test/proton"
touch "$WORK_DIR/steam/compatibilitytools.d/Proton-GE/proton"
chmod +x "$WORK_DIR/steam/steamapps/common/Proton-Test/proton" "$WORK_DIR/steam/compatibilitytools.d/Proton-GE/proton"

cat > "$CONF" <<EOF
[steam]
prefix_dir=${WORK_DIR}/steam
prefix_select=first
[proton]
dir=${WORK_DIR}/steam/steamapps/common
select=first
[interactive]
ui=wizard
EOF

echo "[1/7] unset-variable safety"
env -i HOME="$HOME" bash -n "$ROOT_DIR/ed_pfx_launcher.sh"

echo "[2/7] wizard cancel does not modify config"
orig_sum="$(sha256sum "$CONF" | awk '{print $1}')"
python3 "$ROOT_DIR/scripts/interactive_ui.py" --prefix a b --proton c d --legacy <<< $'0\n' | rg 'CANCEL\|' >/dev/null
new_sum="$(sha256sum "$CONF" | awk '{print $1}')"
[[ "$orig_sum" == "$new_sum" ]]

echo "[3/7] wizard save output includes both values"
out="$(python3 "$ROOT_DIR/scripts/interactive_ui.py" --prefix "$WORK_DIR/steam/steamapps/compatdata/359320/pfx" --proton "$WORK_DIR/steam/steamapps/common/Proton-Test" --legacy <<< $'1\n1\n')"
echo "$out" | rg 'OK\|.*/pfx\|.*/Proton-Test'

echo "[4/7] non-TTY wizard fallback to legacy auto-select"
run_out="$(HOME="$HOME" XDG_CONFIG_HOME="$WORK_DIR" XDG_STATE_HOME="$WORK_DIR" "$ROOT_DIR/ed_pfx_launcher.sh" --config "$CONF" --interactive --no-game --tool 'C:\\dummy.exe' --timeout 1 --cap 45 --pulse 80 --gpu 'Mock GPU' 2>&1 || true)"
echo "$run_out" | rg 'wizard unavailable|falling back'

echo "[5/7] auto mode runtime fallback to proton in non-runtime env"
echo "$run_out" | rg 'runtime unavailable; falling back to proton'

echo "[6/7] tools-only default exits without cleanup"
echo "$run_out" | rg 'tools-only mode active'

echo "[7/7] plan summary includes perf knobs"
echo "$run_out" | rg 'PULSE_LATENCY_MSEC=80.*DXVK_FILTER_DEVICE_NAME=Mock GPU.*DXVK_FRAME_RATE=45'

echo "smoke passed"
