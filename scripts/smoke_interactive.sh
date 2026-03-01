#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME/ed_launcher" "$HOME/.local/share/Steam/steamapps/compatdata/359320/pfx" "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton/files/bin"

cat > "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton/proton" <<'EOF'
#!/usr/bin/env bash
echo proton "$@"
EOF
chmod +x "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton/proton"
cat > "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton/files/bin/wine" <<'EOF'
#!/usr/bin/env bash
echo wine "$@"
EOF
chmod +x "$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton/files/bin/wine"

CFG="$XDG_CONFIG_HOME/ed_launcher/default.ini"
cat > "$CFG" <<EOF
[interactive]
ui=wizard
[paths]
edcopilot_exe=$ROOT/scripts/dummy_tool.sh
mined_exe=$ROOT/scripts/dummy_tool.sh
[instances]
mode=split
EOF

cat > "$ROOT/scripts/dummy_tool.sh" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$ROOT/scripts/dummy_tool.sh"

echo "[1] unset-variable safety"
"$ROOT/ed_pfx_launcher.sh" --help >/dev/null

echo "[2] non-TTY wizard fallback + save keys"
"$ROOT/ed_pfx_launcher.sh" --interactive --no-game --no-edcopilot >/dev/null 2>&1 || true
grep -q '^prefix_dir=' "$CFG"
grep -q '^dir=' "$CFG"

echo "[3] wizard cancel path does not modify config (simulated with direct UI output)"
BEFORE="$(cat "$CFG")"
python3 "$ROOT/scripts/interactive_ui.py" --prefixes '/a|/b|' --protons '/p|' </dev/null > "$TMP/ui.json"
AFTER="$(cat "$CFG")"
[[ "$BEFORE" == "$AFTER" ]]

echo "[4] tools-only default leaves tools running"
"$ROOT/ed_pfx_launcher.sh" --no-game --tool "$ROOT/scripts/dummy_tool.sh" --no-edcopilot >/dev/null 2>&1 || true
pgrep -f dummy_tool.sh >/dev/null
pkill -f dummy_tool.sh || true

echo "[5] tools-only wait-tools cleans on Ctrl+C"
"$ROOT/ed_pfx_launcher.sh" --no-game --wait-tools --tool "$ROOT/scripts/dummy_tool.sh" --no-edcopilot >/dev/null 2>&1 &
PID=$!
sleep 1
kill -TERM "$PID" || true
sleep 2
! pgrep -f dummy_tool.sh >/dev/null || (pkill -f dummy_tool.sh; false)

echo "[6] auto mode fallback when runtime missing + perf knobs in plan"
OUT="$TMP/out.log"
"$ROOT/ed_pfx_launcher.sh" --no-game --edcopilot-mode auto --edcopilot-delay 0 --edcopilot-timeout 1 --pulse 80 --gpu 'GPUX' --cap 70 --tool "$ROOT/scripts/dummy_tool.sh" >"$OUT" 2>&1 || true
grep -q 'edcopilot_mode=auto' "$OUT"
grep -q 'PULSE_LATENCY_MSEC=80' "$OUT"
grep -q 'DXVK_FILTER_DEVICE_NAME=GPUX' "$OUT"
grep -q 'DXVK_FRAME_RATE=70' "$OUT"
pkill -f dummy_tool.sh || true

echo "Smoke checks passed"
