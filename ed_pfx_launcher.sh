#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG_DIR="$STATE_HOME/ed_pfx_launcher/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/coordinator.log"
: > "$LOG_FILE" || true

_ts() { date +'%H:%M:%S'; }
log() { echo "[$(_ts)] $*" | tee -a "$LOG_FILE" >/dev/null; }
warn() { echo "[$(_ts)] WARN: $*" | tee -a "$LOG_FILE" >/dev/null; }
die() { echo "[$(_ts)] ERROR: $*" | tee -a "$LOG_FILE" >/dev/null; exit 1; }

phase_start() { log "[PHASE:$1] START"; }
phase_end() { log "[PHASE:$1] END"; }
phase_fail() { log "[PHASE:$1] FAIL: $2"; }

have() { command -v "$1" >/dev/null 2>&1; }

CONFIG_PATH="$SCRIPT_DIR/ed_pfx_launcher.ini"
NO_GAME=0
WAIT_TOOLS=0
DRY_RUN=0
declare -a CLI_TOOLS=()
declare -a FORWARDED_CMD=()

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME [--config <ini>] [--no-game] [--wait-tools] [--tool <exe>]... [--dry-run] [--] %command%
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    --tool) CLI_TOOLS+=("${2:-}"); shift 2;;
    --no-game) NO_GAME=1; shift;;
    --wait-tools) WAIT_TOOLS=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; FORWARDED_CMD=("$@"); break;;
    *) FORWARDED_CMD+=("$1"); shift;;
  esac
done

# INI parsing
declare -A CFG=()
_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
_unquote() { local s="$1"; [[ "$s" =~ ^".*"$ ]] && s="${s:1:${#s}-2}"; [[ "$s" =~ ^'.*'$ ]] && s="${s:1:${#s}-2}"; printf '%s' "$s"; }

ini_load() {
  local file="$1" section="" raw line key val
  [[ -f "$file" ]] || die "Config not found: $file"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(_trim "$raw")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue
    if [[ "$line" =~ ^\[[^\]]+\]$ ]]; then
      section="${line:1:${#line}-2}"
      section="${section,,}"
      continue
    fi
    if [[ "$line" == *"="* ]]; then
      key="$(_trim "${line%%=*}")"
      val="$(_trim "${line#*=}")"
      key="${key,,}"
      val="$(_unquote "$val")"
      [[ -n "$section" && -n "$key" ]] && CFG["$section.$key"]="$val"
    fi
  done < "$file"
}

cfg_get() { printf '%s' "${CFG[$1]:-${2:-}}"; }
cfg_bool() {
  local v="$(cfg_get "$1" "${2:-false}")"
  case "${v,,}" in true|false) printf '%s' "${v,,}" ;; *) printf '%s' "${2:-false}" ;; esac
}
cfg_int() {
  local raw="$(cfg_get "$1" "$2")"
  [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= $3 )) && { printf '%s' "$raw"; return; }
  printf '%s' "$2"
}

expand_tokens() {
  local s="$1"
  s="${s//\{home\}/$HOME}"
  s="${s//\{appid\}/$APPID}"
  s="${s//\{steam_root\}/$STEAM_ROOT}"
  s="${s//\{compatdata\}/$COMPATDATA_DIR}"
  s="${s//\{prefix\}/$WINEPREFIX}"
  printf '%s' "$s"
}

detect_steam_root() {
  local c="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
  [[ -n "$c" && -d "$c" ]] && { printf '%s' "$c"; return 0; }
  for c in "$HOME/.local/share/Steam" "$HOME/.steam/debian-installation" "$HOME/.steam/steam"; do
    [[ -d "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

detect_runtime_client() {
  local steam_root="$1" p
  p="$steam_root/steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client"
  [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  for p in "$steam_root"/steamapps/common/SteamLinuxRuntime_*/pressure-vessel/bin/steam-runtime-launch-client; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

resolve_runtime_client_from_processes() {
  local process_line candidate

  process_line="$(pgrep -fa 'SteamLinuxRuntime_.*/pressure-vessel.*/EliteDangerous64\.exe' 2>/dev/null | head -n1 || true)"
  [[ -z "$process_line" ]] && process_line="$(pgrep -fa 'SteamLinuxRuntime_.*pressure-vessel.*/EDLaunch\.exe' 2>/dev/null | head -n1 || true)"
  [[ -z "$process_line" ]] && return 1

  candidate="$(printf '%s\n' "$process_line" | sed -n 's#.*\(/[^[:space:]]*SteamLinuxRuntime_[^[:space:]]*/pressure-vessel\).*#\1/bin/steam-runtime-launch-client#p')"
  [[ -z "$candidate" ]] && return 1

  if [[ ! -e "$candidate" ]]; then
    warn "Resolved runtime client candidate does not exist: $candidate"
    return 1
  fi
  if [[ ! -x "$candidate" ]]; then
    warn "Resolved runtime client candidate is not executable: $candidate"
    return 1
  fi

  printf '%s' "$candidate"
}

find_proton() {
  local steam_root="$1" p
  p="$(ls -1d "$steam_root"/steamapps/common/Proton*/proton 2>/dev/null | head -n1 || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  p="$(ls -1d "$HOME"/.steam/steam/compatibilitytools.d/*/proton 2>/dev/null | head -n1 || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

wait_for_process_any() {
  local timeout="$1"; shift
  local i=0 p
  while (( i < timeout )); do
    for p in "$@"; do pgrep -f "$p" >/dev/null 2>&1 && return 0; done
    sleep 1; i=$((i+1))
  done
  return 1
}

first_pid_for_pattern() {
  local pattern="$1"
  pgrep -f "$pattern" 2>/dev/null | head -n1 || true
}

wait_for_game_window() {
  local timeout="$1"
  local elapsed=0
  local game_pid=""

  while (( elapsed < timeout )); do
    game_pid="$(first_pid_for_pattern 'EliteDangerous64\.exe')"
    if [[ -n "$game_pid" ]]; then
      DETECTED_KIND="mined"
      DETECTED_PID="$game_pid"
      log "Detected game process (EliteDangerous64.exe) pid=$DETECTED_PID"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

wait_for_launcher() {
  local timeout="$1"
  local elapsed=0
  local mined_pid=""
  local edlaunch_pid=""

  while (( elapsed < timeout )); do
    mined_pid="$(first_pid_for_pattern 'MinEdLauncher')"
    if [[ -n "$mined_pid" ]]; then
      log "Detected MinEdLauncher pid=$mined_pid; waiting for EliteDangerous64.exe"
      if wait_for_game_window "$GAME_DETECT_TIMEOUT"; then
        return 0
      fi
      return 1
    fi

    edlaunch_pid="$(first_pid_for_pattern '[ZX]:.*steamapps.common.Elite Dangerous.EDLaunch\.exe.*')"
    if [[ -n "$edlaunch_pid" ]]; then
      DETECTED_KIND="edlaunch"
      DETECTED_PID="$edlaunch_pid"
      log "Detected EDLaunch process pid=$DETECTED_PID"
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

is_elite_running() { pgrep -f 'EliteDangerous64\.exe|EDLaunch\.exe' >/dev/null 2>&1; }

# state enum via functions
STATE_WAIT_LAUNCHER() { :; }
STATE_WAIT_GAME() { :; }
STATE_LAUNCH_EDCOPILOT() { :; }
STATE_WAIT_EDCOPILOT_GUI() { :; }
STATE_LAUNCH_AUX() { :; }
STATE_MONITOR() { :; }
STATE_SHUTDOWN() { :; }

CURRENT_STATE="STATE_WAIT_LAUNCHER"

declare -a CHILD_PIDS=()
register_child() { CHILD_PIDS+=("$1"); }

cleanup_children() {
  local pid
  for pid in "${CHILD_PIDS[@]:-}"; do kill -TERM "$pid" >/dev/null 2>&1 || true; done
  sleep 1
  for pid in "${CHILD_PIDS[@]:-}"; do kill -KILL "$pid" >/dev/null 2>&1 || true; done
}

collect_pids_for_patterns() {
  local -a patterns=("$@")
  local pattern pid
  local -A uniq=()

  for pattern in "${patterns[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && uniq["$pid"]=1
    done < <(pgrep -f "$pattern" 2>/dev/null || true)
  done

  for pid in "${!uniq[@]}"; do
    printf '%s\n' "$pid"
  done
}

wait_for_patterns_to_exit() {
  local timeout="$1"; shift
  local elapsed=0

  while (( elapsed < timeout )); do
    if ! collect_pids_for_patterns "$@" | grep -q .; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  ! collect_pids_for_patterns "$@" | grep -q .
}

signal_patterns() {
  local signal="$1"; shift
  local pid

  while IFS= read -r pid; do
    kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done < <(collect_pids_for_patterns "$@")
}

shutdown_edcopilot() {
  local edcopilot_dir request_file gui_exe
  local -a patterns=('EDCoPilotGUI2\.exe' 'LaunchEDCoPilot\.exe' 'EDCoPilot\.exe')

  edcopilot_dir="$(dirname "$EDCOPILOT_EXE")"
  gui_exe="$edcopilot_dir/EDCoPilotGUI2.exe"
  request_file="$edcopilot_dir/EDCoPilot.request.txt"

  if [[ ! -f "$gui_exe" ]]; then
    log "EDCoPilotGUI2.exe not found; skipping EDCoPilot native shutdown signaling"
    return 0
  fi

  if collect_pids_for_patterns "${patterns[@]}" | grep -q .; then
    printf 'Shutdown\n' > "$request_file"
    log "Wrote EDCoPilot shutdown request: $request_file"
  else
    log "No EDCoPilot process found at shutdown; skipping request signaling"
  fi

  if wait_for_patterns_to_exit "$EDCOPILOT_SHUTDOWN_TIMEOUT" "${patterns[@]}"; then
    log "EDCoPilot processes exited after native shutdown signaling"
  else
    warn "EDCoPilot still running after ${EDCOPILOT_SHUTDOWN_TIMEOUT}s; sending SIGTERM"
    signal_patterns TERM "${patterns[@]}"
    if ! wait_for_patterns_to_exit "$EDCOPILOT_FORCE_KILL_TIMEOUT" "${patterns[@]}"; then
      warn "EDCoPilot still running after SIGTERM grace; sending SIGKILL"
      signal_patterns KILL "${patterns[@]}"
      wait_for_patterns_to_exit 2 "${patterns[@]}" || true
    fi
  fi

  rm -f "$request_file"
  log "Removed EDCoPilot shutdown request file (if present): $request_file"
}

shutdown_edcopter() {
  local -a patterns=('EDCoPTER\.exe')

  if ! collect_pids_for_patterns "${patterns[@]}" | grep -q .; then
    return 0
  fi

  log "Stopping EDCoPTER processes"
  signal_patterns TERM "${patterns[@]}"
  if ! wait_for_patterns_to_exit "$EDCOPTER_SHUTDOWN_TIMEOUT" "${patterns[@]}"; then
    warn "EDCoPTER still running after ${EDCOPTER_SHUTDOWN_TIMEOUT}s; sending SIGKILL"
    signal_patterns KILL "${patterns[@]}"
  fi
}

launch_wine_child() {
  local label="$1"; shift
  local log_file="$LOG_DIR/${label}.log"
  [[ "$DRY_RUN" -eq 1 ]] && { log "DRY-RUN child[$label]: $*"; return 0; }
  "$@" >>"$log_file" 2>&1 &
  register_child "$!"
}

log_edcopilot_tail() {
  local log_file="$LOG_DIR/edcopilot.log"
  if [[ -f "$log_file" ]]; then
    warn "Last 60 lines from $log_file"
    tail -n 60 "$log_file" | while IFS= read -r line; do
      warn "[edcopilot.log] $line"
    done
  else
    warn "EDCoPilot log not found at $log_file"
  fi
}

prepare_edcopilot_config() {
  local force_linux_flag="$1"
  local edcopilot_dir target

  if [[ "$force_linux_flag" != "true" ]]; then
    log "EDCoPilot RunningOnLinux patch disabled by config"
    return 0
  fi

  edcopilot_dir="$(dirname "$EDCOPILOT_EXE")"
  if [[ ! -d "$edcopilot_dir" ]]; then
    warn "EDCoPilot directory not found, skipping RunningOnLinux patch: $edcopilot_dir"
    return 0
  fi

  for target in "EDCoPilot.ini" "edcopilotgui.ini"; do
    local target_path="$edcopilot_dir/$target"
    if [[ ! -f "$target_path" ]]; then
      log "Skipping missing EDCoPilot config: $target_path"
      continue
    fi

    if result="$(python3 - "$target_path" <<'PY'
from pathlib import Path
import re
import sys

file_path = Path(sys.argv[1])
raw = file_path.read_bytes()

def default_eol(data: bytes) -> bytes:
    if b"\r\n" in data:
        return b"\r\n"
    if b"\n" in data:
        return b"\n"
    if b"\r" in data:
        return b"\r"
    return b"\n"

line_ending = default_eol(raw)

lines = raw.splitlines(keepends=True)
updated = False
found = False

for idx, line in enumerate(lines):
    text = line.decode("utf-8", errors="surrogateescape")
    if re.match(r"^\s*RunningOnLinux\s*=", text, flags=re.IGNORECASE):
        found = True
        if line.endswith(b"\r\n"):
            eol = b"\r\n"
        elif line.endswith(b"\n"):
            eol = b"\n"
        elif line.endswith(b"\r"):
            eol = b"\r"
        else:
            eol = line_ending
        new_line = b'RunningOnLinux="1"' + eol
        if line != new_line:
            lines[idx] = new_line
            updated = True

if not found:
    if lines and not lines[-1].endswith((b"\r\n", b"\n", b"\r")):
        lines[-1] = lines[-1] + line_ending
    lines.append(b'RunningOnLinux="1"' + line_ending)
    updated = True

if updated:
    file_path.write_bytes(b"".join(lines))

print("patched" if updated else "unchanged")
PY
)"; then
      log "Prepared EDCoPilot config ($result): $target_path"
    else
      warn "Failed to patch EDCoPilot config: $target_path"
    fi
  done
}

launch_edcopilot_runtime() {
  local runtime_client="$1"
  local log_file="$LOG_DIR/edcopilot.log"
  local pid=""
  local elapsed=0

  [[ "$DRY_RUN" -eq 1 ]] && {
    log "DRY-RUN child[edcopilot]: $runtime_client --bus-name=\"com.steampowered.App${APPID}\" --pass-env-matching=\"WINE*\" --pass-env-matching=\"STEAM*\" --pass-env-matching=\"PROTON*\" --env=\"SteamGameId=${APPID}\" -- \"$WINELOADER\" \"$EDCOPILOT_EXE\""
    return 0
  }

  "$runtime_client" \
    --bus-name="com.steampowered.App${APPID}" \
    --pass-env-matching="WINE*" \
    --pass-env-matching="STEAM*" \
    --pass-env-matching="PROTON*" \
    --env="SteamGameId=${APPID}" \
    -- "$WINELOADER" "$EDCOPILOT_EXE" >>"$log_file" 2>&1 &
  pid="$!"
  register_child "$pid"
  log "Started EDCoPilot runtime launch pid=$pid"

  sleep 4
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    warn "EDCoPilot runtime process exited during grace period (pid=$pid)"
    log_edcopilot_tail
    return 1
  fi

  while (( elapsed < EDCOPILOT_INIT_TIMEOUT )); do
    if pgrep -f 'EDCoPilotGUI2\.exe' >/dev/null 2>&1; then
      log "EDCoPilot GUI detected via EDCoPilotGUI2.exe"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  warn "EDCoPilot GUI not detected after ${EDCOPILOT_INIT_TIMEOUT}s"
  log_edcopilot_tail
  return 1
}

launch_edcopilot() {
  local mode="$1" runtime_client=""

  runtime_client="$(resolve_runtime_client_from_processes || true)"
  if [[ -n "$runtime_client" ]]; then
    RUNTIME_CLIENT="$runtime_client"
    log "Resolved runtime client from running process: $RUNTIME_CLIENT"
  elif [[ -n "${RUNTIME_CLIENT:-}" && -x "$RUNTIME_CLIENT" ]]; then
    log "Falling back to static runtime client: $RUNTIME_CLIENT"
  fi

  if [[ "$mode" == "runtime" || ( "$mode" == "auto" && -n "$RUNTIME_CLIENT" ) ]]; then
    if [[ -x "${RUNTIME_CLIENT:-}" ]]; then
      launch_edcopilot_runtime "$RUNTIME_CLIENT"
      return $?
    fi
  fi

  if [[ "$EDCOPILOT_ALLOW_PROTON_FALLBACK" == "true" ]]; then
    log "Launching EDCoPilot via Proton fallback"
    launch_wine_child "edcopilot" "$PROTON_BIN" run "$EDCOPILOT_EXE"
    return 0
  fi

  warn "No runtime launch path available and Proton fallback is disabled"
  return 1
}

build_game_command() {
  GAME_CMD_KIND=""
  GAME_WORKDIR=""
  GAME_CMD_ARR=()

  if (( ${#FORWARDED_CMD[@]} > 0 )) && [[ "${FORWARDED_CMD[0]}" != "%command%" ]]; then
    GAME_CMD_KIND="steam"
    GAME_CMD_ARR=("${FORWARDED_CMD[@]}")
    return 0
  fi

  local mined_exe
  mined_exe="$(cfg_get 'elite.mined_exe' '')"
  [[ -z "$mined_exe" ]] && mined_exe="$STEAM_ROOT/steamapps/common/Elite Dangerous/MinEdLauncher.exe"
  if [[ -f "$mined_exe" ]]; then
    GAME_CMD_KIND="mined"
    GAME_WORKDIR="$(dirname "$mined_exe")"
    GAME_CMD_ARR=("$PROTON_BIN" run "$mined_exe")
    return 0
  fi

  die "Unable to build game command. Pass Steam %command% or set elite.mined_exe"
}

ini_load "$CONFIG_PATH"

phase_start "bootstrap"
APPID="$(cfg_get 'steam.appid' "${SteamGameId:-359320}")"
BUS_NAME="com.steampowered.App$APPID"
EDCOPILOT_ENABLED="$(cfg_bool 'edcopilot.enabled' 'true')"
EDCOPILOT_MODE="$(cfg_get 'edcopilot.mode' 'auto')"
EDCOPILOT_DELAY="$(cfg_int 'edcopilot.delay' '30' '0')"
EDCOPILOT_INIT_TIMEOUT="$(cfg_int 'edcopilot.init_timeout' '45' '1')"
EDCOPILOT_SHUTDOWN_TIMEOUT="$(cfg_int 'edcopilot.shutdown_timeout' '15' '1')"
EDCOPILOT_FORCE_KILL_TIMEOUT="$(cfg_int 'edcopilot.force_kill_timeout' '5' '1')"
EDCOPILOT_ALLOW_PROTON_FALLBACK="$(cfg_bool 'edcopilot.allow_proton_fallback' 'false')"
EDCOPILOT_FORCE_LINUX_FLAG="$(cfg_bool 'edcopilot.force_linux_flag' 'true')"
LAUNCHER_DETECT_TIMEOUT="$(cfg_int 'elite.launcher_detect_timeout' '120' '1')"
GAME_DETECT_TIMEOUT="$(cfg_int 'elite.game_detect_timeout' '120' '1')"
EDCOPILOT_EXE_REL="$(cfg_get 'edcopilot.exe_rel' 'drive_c/EDCoPilot/LaunchEDCoPilot.exe')"
EDCOPTER_ENABLED="$(cfg_bool 'edcopter.enabled' 'false')"
EDCOPTER_SHUTDOWN_TIMEOUT="$(cfg_int 'edcopter.shutdown_timeout' '5' '1')"
EDCOPTER_EXE_REL="$(cfg_get 'edcopter.exe_rel' '')"
WINESERVER_KILL_ON_SHUTDOWN="$(cfg_bool 'wine.wineserver_kill_on_shutdown' 'false')"
WINESERVER_WAIT_ON_SHUTDOWN="$(cfg_bool 'wine.wineserver_wait_on_shutdown' 'false')"
phase_end "bootstrap"

phase_start "detect steam/prefix/runtime"
STEAM_ROOT="$(cfg_get 'steam.steam_root' '')"
[[ -z "$STEAM_ROOT" ]] && STEAM_ROOT="$(detect_steam_root || true)"
[[ -n "$STEAM_ROOT" && -d "$STEAM_ROOT" ]] || { phase_fail "detect steam/prefix/runtime" "steam root not found"; die "steam root not found"; }
COMPATDATA_DIR="$(cfg_get 'steam.compatdata_dir' "${STEAM_COMPAT_DATA_PATH:-$STEAM_ROOT/steamapps/compatdata/$APPID}")"
WINEPREFIX="$COMPATDATA_DIR/pfx"
[[ -d "$WINEPREFIX" ]] || { phase_fail "detect steam/prefix/runtime" "wineprefix not found"; die "WINEPREFIX not found: $WINEPREFIX"; }
RUNTIME_CLIENT="$(cfg_get 'steam.runtime_client' '')"
[[ -z "$RUNTIME_CLIENT" ]] && RUNTIME_CLIENT="$(detect_runtime_client "$STEAM_ROOT" || true)"
PROTON_BIN="$(cfg_get 'proton.proton' '')"
[[ -z "$PROTON_BIN" ]] && PROTON_BIN="$(find_proton "$STEAM_ROOT" || true)"
[[ -n "$PROTON_BIN" && -x "$PROTON_BIN" ]] || { phase_fail "detect steam/prefix/runtime" "proton not found"; die "proton not found"; }
WINELOADER="$(dirname "$PROTON_BIN")/files/bin/wine"
EDCOPILOT_EXE="$(cfg_get 'edcopilot.exe' '')"
[[ -z "$EDCOPILOT_EXE" ]] && EDCOPILOT_EXE="$WINEPREFIX/$EDCOPILOT_EXE_REL"
prepare_edcopilot_config "$EDCOPILOT_FORCE_LINUX_FLAG"
EDCOPTER_EXE=""
[[ -n "$EDCOPTER_EXE_REL" ]] && EDCOPTER_EXE="$WINEPREFIX/$EDCOPTER_EXE_REL"
export WINEPREFIX STEAM_COMPAT_DATA_PATH="$COMPATDATA_DIR" STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" SteamGameId="$APPID" WINEDEBUG="-all"
phase_end "detect steam/prefix/runtime"

phase_start "detect launcher/game"
if [[ "$NO_GAME" -eq 0 ]]; then
  build_game_command
  log "Game launch kind=$GAME_CMD_KIND"
  log "Game command=$(printf '%q ' "${GAME_CMD_ARR[@]}")"
else
  log "No-game mode enabled"
fi
phase_end "detect launcher/game"

GAME_PID=""
DETECTED_KIND=""
DETECTED_PID=""
MONITOR_PID=""

while true; do
  case "$CURRENT_STATE" in
    STATE_WAIT_LAUNCHER)
      phase_start "STATE_WAIT_LAUNCHER"
      if [[ "$NO_GAME" -eq 0 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "DRY-RUN would launch game command"
        else
          [[ -n "$GAME_WORKDIR" ]] && cd "$GAME_WORKDIR"
          "${GAME_CMD_ARR[@]}" &
          GAME_PID="$!"
          register_child "$GAME_PID"
          log "Game process started pid=$GAME_PID"
        fi
      fi
      CURRENT_STATE="STATE_WAIT_GAME"
      phase_end "STATE_WAIT_LAUNCHER"
      ;;
    STATE_WAIT_GAME)
      phase_start "STATE_WAIT_GAME"
      if [[ "$NO_GAME" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
        log "Skipping wait for game in no-game/dry-run"
      else
        if ! wait_for_launcher "$LAUNCHER_DETECT_TIMEOUT"; then
          phase_fail "STATE_WAIT_GAME" "launcher/game detection timeout"
          die "Launcher detection timed out after ${LAUNCHER_DETECT_TIMEOUT}s or game detection timed out after ${GAME_DETECT_TIMEOUT}s"
        fi

        if [[ "$DETECTED_KIND" == "mined" ]]; then
          MONITOR_PID="$DETECTED_PID"
          log "Monitor lifecycle token=game pid=$MONITOR_PID"
        elif [[ "$DETECTED_KIND" == "edlaunch" ]]; then
          MONITOR_PID="$DETECTED_PID"
          log "Monitor lifecycle token=launcher pid=$MONITOR_PID"
        else
          phase_fail "STATE_WAIT_GAME" "unexpected detection kind"
          die "Unexpected launcher detection result"
        fi
      fi
      CURRENT_STATE="STATE_LAUNCH_EDCOPILOT"
      phase_end "STATE_WAIT_GAME"
      ;;
    STATE_LAUNCH_EDCOPILOT)
      phase_start "STATE_LAUNCH_EDCOPILOT"
      if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
        [[ "$EDCOPILOT_DELAY" -gt 0 ]] && sleep "$EDCOPILOT_DELAY"
        if ! launch_edcopilot "$EDCOPILOT_MODE"; then
          phase_fail "STATE_LAUNCH_EDCOPILOT" "EDCoPilot launch/verification failed"
          die "EDCoPilot failed to launch or EDCoPilotGUI2.exe was not detected"
        fi
      else
        warn "EDCoPilot disabled or missing exe: $EDCOPILOT_EXE"
      fi
      CURRENT_STATE="STATE_WAIT_EDCOPILOT_GUI"
      phase_end "STATE_LAUNCH_EDCOPILOT"
      ;;
    STATE_WAIT_EDCOPILOT_GUI)
      phase_start "STATE_WAIT_EDCOPILOT_GUI"
      log "EDCoPilot GUI verification completed in launch phase"
      CURRENT_STATE="STATE_LAUNCH_AUX"
      phase_end "STATE_WAIT_EDCOPILOT_GUI"
      ;;
    STATE_LAUNCH_AUX)
      phase_start "STATE_LAUNCH_AUX"
      if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
        runtime_client="$(resolve_runtime_client_from_processes || true)"
        if [[ -n "$runtime_client" ]]; then
          RUNTIME_CLIENT="$runtime_client"
          log "Resolved runtime client from running process: $RUNTIME_CLIENT"
        elif [[ -n "${RUNTIME_CLIENT:-}" && -x "$RUNTIME_CLIENT" ]]; then
          log "Falling back to static runtime client: $RUNTIME_CLIENT"
        fi

        if [[ -x "${RUNTIME_CLIENT:-}" ]]; then
          launch_wine_child "edcopter" "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$EDCOPTER_EXE"
        else
          launch_wine_child "edcopter" "$PROTON_BIN" run "$EDCOPTER_EXE"
        fi
      fi
      for t in "${CLI_TOOLS[@]}"; do
        [[ -f "$t" ]] || { warn "tool not found: $t"; continue; }
        launch_wine_child "tool_$(basename "$t")" "$PROTON_BIN" run "$t"
      done
      CURRENT_STATE="STATE_MONITOR"
      phase_end "STATE_LAUNCH_AUX"
      ;;
    STATE_MONITOR)
      phase_start "STATE_MONITOR"
      if [[ "$NO_GAME" -eq 1 ]]; then
        if [[ "$WAIT_TOOLS" -eq 1 ]]; then
          log "No-game monitor active (--wait-tools); Ctrl+C to exit"
          while true; do sleep 5; done
        fi
      elif [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ -n "$MONITOR_PID" ]]; then
          while kill -0 "$MONITOR_PID" >/dev/null 2>&1; do sleep 5; done
        else
          while is_elite_running; do sleep 5; done
        fi
        log "Game ended; transitioning to shutdown"
      fi
      CURRENT_STATE="STATE_SHUTDOWN"
      phase_end "STATE_MONITOR"
      ;;
    STATE_SHUTDOWN)
      phase_start "STATE_SHUTDOWN"
      if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
        shutdown_edcopilot
      fi
      if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
        shutdown_edcopter
      fi
      cleanup_children
      if [[ -x "$(dirname "$PROTON_BIN")/files/bin/wineserver" ]]; then
        if [[ "$WINESERVER_KILL_ON_SHUTDOWN" == "true" ]]; then
          "$(dirname "$PROTON_BIN")/files/bin/wineserver" -k >/dev/null 2>&1 || true
          log "Ran wineserver -k"
        fi
        if [[ "$WINESERVER_WAIT_ON_SHUTDOWN" == "true" ]]; then
          "$(dirname "$PROTON_BIN")/files/bin/wineserver" -w >/dev/null 2>&1 || true
          log "Ran wineserver -w"
        fi
      fi
      phase_end "STATE_SHUTDOWN"
      break
      ;;
    *) die "Unknown state: $CURRENT_STATE" ;;
  esac
done

log "Coordinator finished"
