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

launch_wine_child() {
  local label="$1"; shift
  local log_file="$LOG_DIR/${label}.log"
  [[ "$DRY_RUN" -eq 1 ]] && { log "DRY-RUN child[$label]: $*"; return 0; }
  "$@" >>"$log_file" 2>&1 &
  register_child "$!"
}

launch_edcopilot() {
  local mode="$1"
  if [[ "$mode" == "runtime" || ( "$mode" == "auto" && -n "$RUNTIME_CLIENT" ) ]]; then
    if [[ -x "${RUNTIME_CLIENT:-}" ]]; then
      launch_wine_child "edcopilot" "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$EDCOPILOT_EXE"
      return 0
    fi
  fi
  launch_wine_child "edcopilot" "$PROTON_BIN" run "$EDCOPILOT_EXE"
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
EDCOPILOT_EXE_REL="$(cfg_get 'edcopilot.exe_rel' 'drive_c/EDCoPilot/LaunchEDCoPilot.exe')"
EDCOPTER_ENABLED="$(cfg_bool 'edcopter.enabled' 'false')"
EDCOPTER_EXE_REL="$(cfg_get 'edcopter.exe_rel' '')"
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
        local_wait=0
        until is_elite_running || (( local_wait >= 120 )); do sleep 2; local_wait=$((local_wait+2)); done
        is_elite_running && log "Elite process detected" || warn "Elite process not detected within timeout; continuing"
      fi
      CURRENT_STATE="STATE_LAUNCH_EDCOPILOT"
      phase_end "STATE_WAIT_GAME"
      ;;
    STATE_LAUNCH_EDCOPILOT)
      phase_start "STATE_LAUNCH_EDCOPILOT"
      if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
        [[ "$EDCOPILOT_DELAY" -gt 0 ]] && sleep "$EDCOPILOT_DELAY"
        launch_edcopilot "$EDCOPILOT_MODE"
      else
        warn "EDCoPilot disabled or missing exe: $EDCOPILOT_EXE"
      fi
      CURRENT_STATE="STATE_WAIT_EDCOPILOT_GUI"
      phase_end "STATE_LAUNCH_EDCOPILOT"
      ;;
    STATE_WAIT_EDCOPILOT_GUI)
      phase_start "STATE_WAIT_EDCOPILOT_GUI"
      if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" && "$DRY_RUN" -eq 0 ]]; then
        if wait_for_process_any "$EDCOPILOT_INIT_TIMEOUT" 'EDCoPilotGUI2\.exe' 'EDCoPilotGUI\.exe' 'LaunchEDCoPilot\.exe'; then
          log "EDCoPilot GUI detected"
        else
          phase_fail "STATE_WAIT_EDCOPILOT_GUI" "GUI not detected in timeout"
          warn "EDCoPilot GUI not detected after ${EDCOPILOT_INIT_TIMEOUT}s"
        fi
      fi
      CURRENT_STATE="STATE_LAUNCH_AUX"
      phase_end "STATE_WAIT_EDCOPILOT_GUI"
      ;;
    STATE_LAUNCH_AUX)
      phase_start "STATE_LAUNCH_AUX"
      if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
        launch_wine_child "edcopter" "$PROTON_BIN" run "$EDCOPTER_EXE"
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
        if [[ -n "$GAME_PID" ]]; then
          while kill -0 "$GAME_PID" >/dev/null 2>&1; do sleep 5; done
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
      cleanup_children
      if [[ -x "$(dirname "$PROTON_BIN")/files/bin/wineserver" ]]; then
        "$(dirname "$PROTON_BIN")/files/bin/wineserver" -k >/dev/null 2>&1 || true
      fi
      phase_end "STATE_SHUTDOWN"
      break
      ;;
    *) die "Unknown state: $CURRENT_STATE" ;;
  esac
done

log "Coordinator finished"
