#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT_DIR/ed_pfx_launcher.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

run_cmd() {
  local out_file="$1"
  shift
  if "$@" >"$out_file" 2>&1; then
    return 0
  fi
  return 1
}

assert_file_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq "$needle" "$file"; then
    pass "$label"
  else
    fail "$label"
    echo "  expected to find: $needle"
    echo "  in: $file"
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq "$needle" "$file"; then
    fail "$label"
    echo "  did not expect to find: $needle"
    echo "  in: $file"
  else
    pass "$label"
  fi
}

assert_files_equal() {
  local a="$1" b="$2" label="$3"
  if cmp -s "$a" "$b"; then
    pass "$label"
  else
    fail "$label"
    echo "  files differ: $a vs $b"
  fi
}

assert_cmd_ok() {
  local label="$1" out_file="$2"
  shift 2
  if run_cmd "$out_file" "$@"; then
    pass "$label"
  else
    fail "$label"
    sed -n '1,120p' "$out_file"
  fi
}

make_fake_steam_tree() {
  local base="$1"
  local appid="$2"

  mkdir -p "$base/steamapps/compatdata/$appid/pfx"
  mkdir -p "$base/steamapps/common/ProtonTest/files/bin"
  cat > "$base/steamapps/common/ProtonTest/proton" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$base/steamapps/common/ProtonTest/proton"
  cat > "$base/steamapps/common/ProtonTest/files/bin/wine" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$base/steamapps/common/ProtonTest/files/bin/wine"
}

write_base_config() {
  local cfg="$1" steam_root="$2" appid="$3"
  cat > "$cfg" <<EOF_CFG
[steam]
appid=$appid
steam_root=$steam_root

[interactive]
ui=wizard

[elite]
platform=steam
profile=
EOF_CFG
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APPID="359320"
STEAM_ROOT="$TMP_DIR/steam"
make_fake_steam_tree "$STEAM_ROOT" "$APPID"

# 1) Unset-variable safety in bootstrap token expansion.
CFG_UNSET="$TMP_DIR/unset_token.ini"
cat > "$CFG_UNSET" <<EOF_CFG
[steam]
appid=$APPID
steam_root={compatdata}
prefix_dir=$STEAM_ROOT/steamapps/compatdata/$APPID

[proton]
dir=$STEAM_ROOT/steamapps/common/ProtonTest

[elite]
platform=steam
profile=
EOF_CFG

OUT_UNSET="$TMP_DIR/out_unset.log"
assert_cmd_ok \
  "bootstrap token expansion tolerates unset variables" \
  "$OUT_UNSET" \
  env -u COMPATDATA_DIR STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" "$LAUNCHER" --config "$CFG_UNSET" --no-game --dry-run --debug
assert_file_not_contains "$OUT_UNSET" "unbound variable" "no unbound variable crash during bootstrap expansion"

# 2) Cancel path does not write config (wizard backend test hook).
CFG_CANCEL="$TMP_DIR/cancel.ini"
write_base_config "$CFG_CANCEL" "$STEAM_ROOT" "$APPID"
cp "$CFG_CANCEL" "$CFG_CANCEL.before"
OUT_CANCEL="$TMP_DIR/out_cancel.log"
if ED_PFX_UI_TEST_ACTION=cancel "$LAUNCHER" --config "$CFG_CANCEL" --interactive --interactive-ui wizard --no-game --dry-run --debug >"$OUT_CANCEL" 2>&1; then
  fail "wizard cancel exits non-zero to signal cancellation"
  sed -n '1,120p' "$OUT_CANCEL"
else
  pass "wizard cancel exits non-zero to signal cancellation"
fi
assert_file_contains "$OUT_CANCEL" "Interactive wizard cancelled; config unchanged" "wizard cancel is reported"
assert_files_equal "$CFG_CANCEL.before" "$CFG_CANCEL" "cancel path keeps config unchanged"

# 3 + 4) Save path writes both keys and non-TTY wizard fallback behavior.
CFG_SAVE="$TMP_DIR/save.ini"
write_base_config "$CFG_SAVE" "$STEAM_ROOT" "$APPID"
OUT_SAVE="$TMP_DIR/out_save.log"
assert_cmd_ok \
  "non-TTY interactive run succeeds" \
  "$OUT_SAVE" \
  "$LAUNCHER" --config "$CFG_SAVE" --interactive --interactive-ui wizard --no-game --dry-run --debug
assert_file_contains "$OUT_SAVE" "Interactive UI route selected: ui=wizard requested=wizard" "wizard route selected"
assert_file_contains "$OUT_SAVE" "Interactive wizard backend used non-TTY fallback behavior" "non-TTY fallback behavior logged"
assert_file_contains "$CFG_SAVE" "prefix_dir=$STEAM_ROOT/steamapps/compatdata/$APPID" "save writes steam.prefix_dir"
assert_file_contains "$CFG_SAVE" "dir=$STEAM_ROOT/steamapps/common/ProtonTest" "save writes proton.dir"

if (( FAIL_COUNT > 0 )); then
  echo "SMOKE RESULT: FAIL ($FAIL_COUNT failed, $PASS_COUNT passed)"
  exit 1
fi

echo "SMOKE RESULT: PASS ($PASS_COUNT checks)"
