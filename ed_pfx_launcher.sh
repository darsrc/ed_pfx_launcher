#!/usr/bin/env bash
set -euo pipefail

APP_ID_DEFAULT="359320"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DEFAULT_LOG_DIR="$XDG_STATE_HOME/ed_pfx_launcher"
DEFAULT_PROFILE_DIR="$XDG_CONFIG_HOME/ed_launcher"
DEFAULT_CONFIG="$DEFAULT_PROFILE_DIR/default.ini"
DEFAULT_TIMEOUT=180
DEFAULT_STABLE_SECONDS=6
DEFAULT_EDCOPILOT_DELAY=5
DEFAULT_EDCOPILOT_BUS_WAIT=30
DEFAULT_EDCOPILOT_TIMEOUT=45
DEFAULT_PULSE=90
DEFAULT_GPU_FILTER="RTX 3060"
DEFAULT_FRAME_CAP=60

STEAM_ROOT_OVERRIDE="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
COMPAT_DATA_OVERRIDE="${STEAM_COMPAT_DATA_PATH:-}"
PROTON_DIR_OVERRIDE=""
PREFIX_DIR_OVERRIDE=""
PREFIX_SELECT="newest"
PROTON_SELECT="newest"
INTERACTIVE=0
INTERACTIVE_UI="wizard"
DEBUG=0
TIMEOUT="$DEFAULT_TIMEOUT"
STABLE_SECONDS="$DEFAULT_STABLE_SECONDS"
MODE="terminal"
NO_GAME=0
WAIT_TOOLS=0
NO_MONITOR=0
NO_MINED=0
NO_EDCOPILOT=0
EDCOPILOT_MODE="auto"
EDCOPILOT_DELAY="$DEFAULT_EDCOPILOT_DELAY"
EDCOPILOT_BUS_WAIT="$DEFAULT_EDCOPILOT_BUS_WAIT"
EDCOPILOT_TIMEOUT="$DEFAULT_EDCOPILOT_TIMEOUT"
PROFILE_NAME="default"
PULSE_LATENCY_MSEC="$DEFAULT_PULSE"
DXVK_FILTER_DEVICE_NAME="$DEFAULT_GPU_FILTER"
DXVK_FRAME_RATE="$DEFAULT_FRAME_CAP"
PREFER_NVIDIA_ICD="auto"
LOG_DIR="$DEFAULT_LOG_DIR"
FORWARDED_CMD=()
CUSTOM_TOOLS=()
MINED_EXTRA_ARGS=()

# env knobs defaults
WINEFSYNC="${WINEFSYNC:-1}"
WINEESYNC="${WINEESYNC:-1}"
SDL_JOYSTICK_DISABLE="${SDL_JOYSTICK_DISABLE:-1}"
SDL_GAMECONTROLLER_DISABLE="${SDL_GAMECONTROLLER_DISABLE:-1}"
PYGAME_FORCE_JOYSTICK="${PYGAME_FORCE_JOYSTICK:-0}"
WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-dinput=n;dinput8=n;hid=n;hidraw=n}"

# instance/shared defaults
INSTANCE_MODE="split"
SHARED_ENABLED="true"
SHARED_SOURCE="game"
SHARED_STRATEGY="symlink"
GAME_PREFIX=""
EDCOPILOT_PREFIX=""
TOOL_PREFIX_BASE=""

MINED_NATIVE=""
MINED_EXE=""
EDCOPILOT_EXE=""
GAME_EXE="EliteDangerous64.exe"

COORD_LOG=""
COMBINED_LOG=""
RUNTIME_CLIENT=""
PROTON_DIR=""
PROTON_BIN=""
PROTON_WINE=""
APP_ID="${SteamGameId:-${SteamAppId:-$APP_ID_DEFAULT}}"
BUS_NAME=""
SELECTED_PREFIX=""

TOOL_PIDS=()
TOOL_PGIDS=()
cleanup_tools_on_exit=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- forwarded %command% tokens]

Core options:
  --prefix-dir <path>         Prefix search root or explicit compatdata(/pfx)
  --prefix-select <first|newest>
  --proton-dir <path>         Proton search root or explicit dir containing proton
  --proton-select <first|newest>
  --interactive               Run interactive setup and save config
  --interactive-ui <legacy|wizard>
  --profile <name>            Load $DEFAULT_PROFILE_DIR/<name>.ini
  --timeout <sec>             Game detection timeout (default: $DEFAULT_TIMEOUT)
  --stable-seconds <sec>      Stable game process window (default: $DEFAULT_STABLE_SECONDS)
  --debug                     Enable verbose wine logs
  --no-edcopilot              Skip EDCoPilot launch
  --no-mined                  Skip MinEd and launch game directly
  --no-game                   Tools-only mode
  --wait-tools                With tools-only, wait and cleanup on exit/Ctrl+C
  --no-monitor                Do not long-monitor game lifetime
  --tool <path>               Additional tool executable (repeatable)

EDCoPilot:
  --edcopilot-mode <auto|runtime|proton>
  --edcopilot-delay <sec>
  --edcopilot-bus-wait <sec>
  --edcopilot-timeout <sec>

Performance knobs:
  --pulse <ms>                Set PULSE_LATENCY_MSEC
  --gpu <substring>           Set DXVK_FILTER_DEVICE_NAME
  --cap <fps>                 Set DXVK_FRAME_RATE

Other:
  --help
EOF
}

log() { echo "[$(date '+%F %T')] $*" | tee -a "$COORD_LOG" >&2; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

trim() { sed -e 's/^\s*//' -e 's/\s*$//' ; }

load_config_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Config/profile not found: $file"
  local section=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line="$(printf '%s' "$raw" | sed 's/[;#].*$//' | trim)"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      local key="$(printf '%s' "${BASH_REMATCH[1]}" | trim)"
      local val="$(printf '%s' "${BASH_REMATCH[2]}" | trim)"
      case "$section.$key" in
        steam.prefix_dir|steam.compatdata_dir) PREFIX_DIR_OVERRIDE="$val" ;;
        steam.prefix_select) PREFIX_SELECT="$val" ;;
        proton.dir) PROTON_DIR_OVERRIDE="$val" ;;
        proton.select) PROTON_SELECT="$val" ;;
        interactive.ui) INTERACTIVE_UI="$val" ;;
        shared_data.enabled) SHARED_ENABLED="$val" ;;
        shared_data.source_prefix) SHARED_SOURCE="$val" ;;
        shared_data.strategy) SHARED_STRATEGY="$val" ;;
        instances.mode) INSTANCE_MODE="$val" ;;
        instances.game_prefix) GAME_PREFIX="$val" ;;
        instances.edcopilot_prefix) EDCOPILOT_PREFIX="$val" ;;
        instances.tool_prefix_base) TOOL_PREFIX_BASE="$val" ;;
        paths.mined_native) MINED_NATIVE="$val" ;;
        paths.mined_exe) MINED_EXE="$val" ;;
        paths.edcopilot_exe) EDCOPILOT_EXE="$val" ;;
        performance.pulse_latency_msec) PULSE_LATENCY_MSEC="$val" ;;
        performance.dxvk_filter_device_name) DXVK_FILTER_DEVICE_NAME="$val" ;;
        performance.dxvk_frame_rate) DXVK_FRAME_RATE="$val" ;;
        performance.prefer_nvidia_icd) PREFER_NVIDIA_ICD="$val" ;;
      esac
    fi
  done < "$file"
}

save_active_config() {
  mkdir -p "$DEFAULT_PROFILE_DIR"
  local out="$DEFAULT_PROFILE_DIR/${PROFILE_NAME}.ini"
  cat > "$out" <<EOF
[steam]
prefix_dir=$PREFIX_DIR_OVERRIDE
prefix_select=$PREFIX_SELECT

[proton]
dir=$PROTON_DIR_OVERRIDE
select=$PROTON_SELECT

[interactive]
ui=$INTERACTIVE_UI
EOF
  log "Saved interactive selections to $out"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --) shift; FORWARDED_CMD=("$@"); break ;;
      --help) usage; exit 0 ;;
      --prefix-dir) PREFIX_DIR_OVERRIDE="$2"; shift 2 ;;
      --prefix-select) PREFIX_SELECT="$2"; shift 2 ;;
      --proton-dir) PROTON_DIR_OVERRIDE="$2"; shift 2 ;;
      --proton-select) PROTON_SELECT="$2"; shift 2 ;;
      --interactive) INTERACTIVE=1; shift ;;
      --interactive-ui) INTERACTIVE_UI="$2"; shift 2 ;;
      --debug) DEBUG=1; shift ;;
      --profile) PROFILE_NAME="$2"; shift 2 ;;
      --no-edcopilot) NO_EDCOPILOT=1; shift ;;
      --no-mined) NO_MINED=1; shift ;;
      --no-game) NO_GAME=1; shift ;;
      --wait-tools) WAIT_TOOLS=1; shift ;;
      --no-monitor) NO_MONITOR=1; shift ;;
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --stable-seconds) STABLE_SECONDS="$2"; shift 2 ;;
      --tool) CUSTOM_TOOLS+=("$2"); shift 2 ;;
      --edcopilot-mode) EDCOPILOT_MODE="$2"; shift 2 ;;
      --edcopilot-delay) EDCOPILOT_DELAY="$2"; shift 2 ;;
      --edcopilot-bus-wait) EDCOPILOT_BUS_WAIT="$2"; shift 2 ;;
      --edcopilot-timeout) EDCOPILOT_TIMEOUT="$2"; shift 2 ;;
      --pulse) PULSE_LATENCY_MSEC="$2"; shift 2 ;;
      --gpu) DXVK_FILTER_DEVICE_NAME="$2"; shift 2 ;;
      --cap) DXVK_FRAME_RATE="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

detect_mode() {
  MODE="terminal"
  if [[ ${#FORWARDED_CMD[@]} -gt 0 ]]; then
    local literal=0 tok
    for tok in "${FORWARDED_CMD[@]}"; do
      [[ "$tok" == "%command%" ]] && literal=1
    done
    if [[ $literal -eq 1 ]]; then
      warn "Literal %command% seen in terminal invocation; ignoring forwarded command tokens"
      FORWARDED_CMD=()
    else
      MODE="steam"
    fi
  fi
}

setup_logs() {
  mkdir -p "$LOG_DIR"
  COORD_LOG="$LOG_DIR/coordinator-$(date +%Y%m%d-%H%M%S).log"
  touch "$COORD_LOG"
  if [[ $DEBUG -eq 1 ]]; then
    COMBINED_LOG="/tmp/ed_pfx_launcher-debug-$(date +%Y%m%d-%H%M%S).log"
    touch "$COMBINED_LOG"
  fi
}

find_steam_roots() {
  local roots=()
  [[ -n "$STEAM_ROOT_OVERRIDE" && -d "$STEAM_ROOT_OVERRIDE" ]] && roots+=("$STEAM_ROOT_OVERRIDE")
  [[ -d "$HOME/.steam/steam" ]] && roots+=("$HOME/.steam/steam")
  [[ -d "$HOME/.local/share/Steam" ]] && roots+=("$HOME/.local/share/Steam")
  printf '%s\n' "${roots[@]}" | awk 'NF&&!seen[$0]++'
}

scan_prefix_candidates() {
  local roots=()
  [[ -n "$PREFIX_DIR_OVERRIDE" ]] && roots+=("$PREFIX_DIR_OVERRIDE")
  if [[ -n "$COMPAT_DATA_OVERRIDE" ]]; then roots+=("$COMPAT_DATA_OVERRIDE"); fi
  while IFS= read -r r; do roots+=("$r/steamapps/compatdata"); done < <(find_steam_roots)
  local candidates=()
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    if [[ "$root" == */pfx ]]; then candidates+=("$root"); continue; fi
    if [[ -d "$root/pfx" ]]; then candidates+=("$root/pfx"); continue; fi
    while IFS= read -r p; do candidates+=("$p"); done < <(find "$root" -maxdepth 3 -type d -name pfx 2>/dev/null)
  done
  printf '%s\n' "${candidates[@]}" | awk 'NF&&!seen[$0]++'
}

scan_proton_candidates() {
  local roots=()
  [[ -n "$PROTON_DIR_OVERRIDE" ]] && roots+=("$PROTON_DIR_OVERRIDE")
  while IFS= read -r r; do
    roots+=("$r/steamapps/common" "$r/compatibilitytools.d")
  done < <(find_steam_roots)
  roots+=("/usr/share/steam/compatibilitytools.d" "/usr/local/share/steam/compatibilitytools.d")
  local candidates=()
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    if [[ -x "$root/proton" ]]; then candidates+=("$root"); continue; fi
    while IFS= read -r p; do
      [[ -x "$p/proton" ]] && candidates+=("$p")
    done < <(find "$root" -maxdepth 2 -type d \( -name 'Proton*' -o -name 'GE-Proton*' -o -name 'proton*' \) 2>/dev/null)
  done
  printf '%s\n' "${candidates[@]}" | awk 'NF&&!seen[$0]++'
}

select_candidate() {
  local mode="$1"; shift
  local list=("$@")
  [[ ${#list[@]} -gt 0 ]] || return 1
  if [[ "$mode" == "first" ]]; then printf '%s\n' "${list[0]}"; return 0; fi
  local newest="${list[0]}" latest=0
  local item
  for item in "${list[@]}"; do
    local mt
    mt=$(stat -c %Y "$item" 2>/dev/null || echo 0)
    if (( mt >= latest )); then latest=$mt; newest="$item"; fi
  done
  printf '%s\n' "$newest"
}

run_interactive_if_requested() {
  [[ $INTERACTIVE -eq 1 ]] || return 0
  mapfile -t pfxs < <(scan_prefix_candidates)
  mapfile -t prots < <(scan_proton_candidates)
  log "Interactive path selected: $INTERACTIVE_UI"
  if [[ "$INTERACTIVE_UI" == "wizard" && -t 0 && -t 1 && -f "$SCRIPT_DIR/scripts/interactive_ui.py" ]]; then
    if python3 "$SCRIPT_DIR/scripts/interactive_ui.py" --prefixes "$(printf '%s|' "${pfxs[@]}")" --protons "$(printf '%s|' "${prots[@]}")" >"$LOG_DIR/wizard.json"; then
      if jq -e '.saved == true' "$LOG_DIR/wizard.json" >/dev/null 2>&1; then
        PREFIX_DIR_OVERRIDE="$(jq -r '.prefix_dir' "$LOG_DIR/wizard.json")"
        PROTON_DIR_OVERRIDE="$(jq -r '.proton_dir' "$LOG_DIR/wizard.json")"
        save_active_config
      else
        log "Wizard canceled; config unchanged"
      fi
      return 0
    fi
    warn "Wizard backend unavailable/failed; falling back to legacy auto-select"
  else
    warn "Wizard fallback triggered (non-TTY or missing script)"
  fi
  local selp selr
  selp=$(select_candidate "$PREFIX_SELECT" "${pfxs[@]}") || die "No prefix candidates found"
  selr=$(select_candidate "$PROTON_SELECT" "${prots[@]}") || die "No proton candidates found"
  PREFIX_DIR_OVERRIDE="$selp"
  PROTON_DIR_OVERRIDE="$selr"
  save_active_config
}

setup_selected_paths() {
  mapfile -t pfxs < <(scan_prefix_candidates)
  mapfile -t prots < <(scan_proton_candidates)
  if [[ -z "$PREFIX_DIR_OVERRIDE" ]]; then PREFIX_DIR_OVERRIDE=$(select_candidate "$PREFIX_SELECT" "${pfxs[@]}"); fi
  if [[ -z "$PROTON_DIR_OVERRIDE" ]]; then PROTON_DIR_OVERRIDE=$(select_candidate "$PROTON_SELECT" "${prots[@]}"); fi
  [[ -n "$PREFIX_DIR_OVERRIDE" ]] || die "Unable to select prefix"
  [[ -n "$PROTON_DIR_OVERRIDE" ]] || die "Unable to select Proton"
  if [[ "$PREFIX_DIR_OVERRIDE" == */pfx ]]; then
    SELECTED_PREFIX="$PREFIX_DIR_OVERRIDE"
  else
    SELECTED_PREFIX="$PREFIX_DIR_OVERRIDE/pfx"
  fi
  PROTON_DIR="$PROTON_DIR_OVERRIDE"
  PROTON_BIN="$PROTON_DIR/proton"
  PROTON_WINE="$PROTON_DIR/files/bin/wine"
  [[ -x "$PROTON_BIN" ]] || die "Proton binary missing at $PROTON_BIN"
  [[ -x "$PROTON_WINE" ]] || warn "Proton wine loader missing at $PROTON_WINE"
  [[ -n "${SteamGameId:-}" ]] || [[ -n "${SteamAppId:-}" ]] || {
    local app_from_path
    app_from_path=$(basename "$(dirname "$SELECTED_PREFIX")")
    [[ "$app_from_path" =~ ^[0-9]+$ ]] && APP_ID="$app_from_path"
  }
  BUS_NAME="com.steampowered.App${APP_ID}"
}

setup_instances() {
  local compat_root="$(dirname "$SELECTED_PREFIX")"
  GAME_PREFIX="${GAME_PREFIX:-$SELECTED_PREFIX}"
  EDCOPILOT_PREFIX="${EDCOPILOT_PREFIX:-$SELECTED_PREFIX}"
  TOOL_PREFIX_BASE="${TOOL_PREFIX_BASE:-$compat_root/ed_pfx_instances}"
  if [[ "$INSTANCE_MODE" == "split" ]]; then
    mkdir -p "$TOOL_PREFIX_BASE/game/pfx" "$TOOL_PREFIX_BASE/edcopilot/pfx" "$TOOL_PREFIX_BASE/tools/pfx"
    GAME_PREFIX="$TOOL_PREFIX_BASE/game/pfx"
    EDCOPILOT_PREFIX="$TOOL_PREFIX_BASE/edcopilot/pfx"
  fi
}

bridge_one_path() {
  local srcp="$1" dstp="$2"
  mkdir -p "$(dirname "$srcp")" "$(dirname "$dstp")"
  [[ -e "$srcp" ]] || mkdir -p "$srcp"
  if [[ -L "$dstp" ]]; then
    local t; t=$(readlink -f "$dstp" || true)
    if [[ "$t" == "$(readlink -f "$srcp")" ]]; then return 0; fi
    warn "Fixing mismatched symlink: $dstp"
    rm -f "$dstp"
  elif [[ -d "$dstp" ]] && [[ -n "$(find "$dstp" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]]; then
    warn "Unmanaged non-empty directory left untouched: $dstp"
    return 0
  elif [[ -e "$dstp" ]]; then
    rm -rf "$dstp"
  fi
  ln -s "$srcp" "$dstp"
}

run_shared_bridge() {
  [[ "$SHARED_ENABLED" == "true" ]] || return 0
  [[ "$SHARED_STRATEGY" == "symlink" ]] || warn "Strategy $SHARED_STRATEGY not fully implemented; using symlink"
  local src="$GAME_PREFIX"
  case "$SHARED_SOURCE" in
    game) src="$GAME_PREFIX" ;;
    edcopilot) src="$EDCOPILOT_PREFIX" ;;
    tool) src="$TOOL_PREFIX_BASE/tools/pfx" ;;
  esac
  local rels=(
    "users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous"
    "users/steamuser/AppData/Local/EDCoPilot"
    "users/steamuser/Documents/Frontier Developments/Elite Dangerous"
  )
  local targets=("$GAME_PREFIX" "$EDCOPILOT_PREFIX" "$TOOL_PREFIX_BASE/tools/pfx")
  local r t
  for t in "${targets[@]}"; do
    for r in "${rels[@]}"; do
      [[ "$t" == "$src" ]] && continue
      bridge_one_path "$src/drive_c/$r" "$t/drive_c/$r"
    done
  done
}

find_runtime_client() {
  local candidates=()
  while IFS= read -r s; do
    candidates+=(
      "$s/ubuntu12_64/steam-runtime-launch-client"
      "$s/steamapps/common/SteamLinuxRuntime_sniper/steam-runtime-launch-client"
      "$s/steamapps/common/SteamLinuxRuntime_sniper/run"
    )
  done < <(find_steam_roots)
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then RUNTIME_CLIENT="$c"; return 0; fi
  done
  return 1
}

build_env_base() {
  export WINEFSYNC WINEESYNC SDL_JOYSTICK_DISABLE SDL_GAMECONTROLLER_DISABLE PYGAME_FORCE_JOYSTICK WINEDLLOVERRIDES
  export PULSE_LATENCY_MSEC DXVK_FILTER_DEVICE_NAME DXVK_FRAME_RATE
  unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus
  if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${PROTON_ENABLE_WAYLAND:-}" ]]; then
    export PROTON_ENABLE_WAYLAND=1
  fi
  if [[ "$PREFER_NVIDIA_ICD" != "false" && -f "/usr/share/vulkan/icd.d/nvidia_icd.json" && -z "${VK_ICD_FILENAMES:-}" ]]; then
    export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.json"
  fi
  if [[ $DEBUG -eq 1 ]]; then
    export WINEDEBUG="-all,+seh,+err,+mscoree,+loaddll"
  else
    export WINEDEBUG="-all"
  fi
}

launch_detached() {
  local logf="$1"; shift
  setsid "$@" >>"$logf" 2>&1 &
  local pid=$!
  local pgid
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  TOOL_PIDS+=("$pid")
  TOOL_PGIDS+=("$pgid")
  echo "$pid"
}

launch_tool() {
  local label="$1" exe="$2" pfx="$3" mode="${4:-auto}"
  local logf="$LOG_DIR/${label// /_}-$(date +%Y%m%d-%H%M%S).log"
  local cmd=()
  if [[ "$exe" == *.exe || "$mode" == "windows" ]]; then
    cmd=(env STEAM_COMPAT_DATA_PATH="$(dirname "$pfx")" "$PROTON_BIN" run "$exe")
  else
    cmd=("$exe")
  fi
  log "Launching tool '$label' in prefix '$pfx' log=$logf"
  launch_detached "$logf" "${cmd[@]}" >/dev/null
}

is_process_stable() {
  local pname="$1" stable="$2"
  local start now
  start=$(date +%s)
  while true; do
    pgrep -f "$pname" >/dev/null || return 1
    now=$(date +%s)
    (( now - start >= stable )) && return 0
    sleep 1
  done
}

wait_for_elite() {
  local timeout="$1" stable="$2"
  local start now
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    (( now - start > timeout )) && return 1
    if pgrep -f "EDLaunch.exe" >/dev/null; then log "EDLaunch.exe detected (early indicator)"; fi
    if is_process_stable "EliteDangerous64.exe" "$stable"; then
      log "EliteDangerous64.exe detected as stable"
      return 0
    fi
    sleep 2
  done
}

launch_game() {
  local game_log="$LOG_DIR/game-$(date +%Y%m%d-%H%M%S).log"
  if [[ $NO_MINED -eq 1 ]]; then
    log "Launching game directly (no MinEd)"
    env STEAM_COMPAT_DATA_PATH="$(dirname "$GAME_PREFIX")" "$PROTON_BIN" run "$GAME_EXE" >>"$game_log" 2>&1 &
  else
    local args=(/autorun /autoquit /edo /frontier "$PROFILE_NAME")
    if [[ "$MODE" == "steam" && -n "$MINED_NATIVE" && -x "$MINED_NATIVE" ]]; then
      log "Steam mode: launching native MinEd contract"
      ("${FORWARDED_CMD[@]}" "$MINED_NATIVE" "${args[@]}") >>"$game_log" 2>&1 &
    else
      [[ -n "$MINED_EXE" ]] || MINED_EXE="MinEdLauncher.exe"
      log "Launching MinEdLauncher.exe via Proton"
      env STEAM_COMPAT_DATA_PATH="$(dirname "$GAME_PREFIX")" "$PROTON_BIN" run "$MINED_EXE" "${args[@]}" >>"$game_log" 2>&1 &
    fi
  fi
}

wait_for_bus_name() {
  local timeout="$1" start now
  command -v busctl >/dev/null || return 2
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    (( now - start > timeout )) && return 1
    busctl --user list 2>/dev/null | awk '{print $1}' | grep -qx "$BUS_NAME" && return 0
    sleep 1
  done
}

launch_edcopilot() {
  [[ $NO_EDCOPILOT -eq 1 ]] && return 0
  sleep "$EDCOPILOT_DELAY"
  local logf="$LOG_DIR/edcopilot-$(date +%Y%m%d-%H%M%S).log"
  local mode="$EDCOPILOT_MODE"
  if [[ "$mode" == "auto" ]]; then
    if find_runtime_client && command -v busctl >/dev/null && [[ -x "$PROTON_WINE" ]]; then mode="runtime"; else mode="proton"; fi
  fi
  if [[ "$mode" == "runtime" ]]; then
    find_runtime_client || { [[ "$EDCOPILOT_MODE" == "auto" ]] && { warn "runtime unavailable, fallback proton"; mode="proton"; } || die "runtime mode requested but client missing"; }
    if [[ "$mode" == "runtime" ]]; then
      wait_for_bus_name "$EDCOPILOT_BUS_WAIT" || { [[ "$EDCOPILOT_MODE" == "auto" ]] && { warn "bus wait timeout, fallback proton"; mode="proton"; } || die "runtime mode bus name not ready"; }
    fi
    if [[ "$mode" == "runtime" ]]; then
      log "Launching EDCoPilot in runtime mode via $RUNTIME_CLIENT"
      launch_detached "$logf" env SteamGameId="$APP_ID" STEAM_COMPAT_DATA_PATH="$(dirname "$EDCOPILOT_PREFIX")" "$RUNTIME_CLIENT" "--bus-name=$BUS_NAME" -- "$PROTON_WINE" "$EDCOPILOT_EXE" >/dev/null
    fi
  fi
  if [[ "$mode" == "proton" ]]; then
    log "Launching EDCoPilot in proton mode"
    launch_detached "$logf" env STEAM_COMPAT_DATA_PATH="$(dirname "$EDCOPILOT_PREFIX")" "$PROTON_BIN" run "$EDCOPILOT_EXE" >/dev/null
  fi
  local start now
  start=$(date +%s)
  while true; do
    pgrep -f "EDCoPilotGUI2.exe" >/dev/null && { log "EDCoPilot detected"; return 0; }
    now=$(date +%s)
    (( now - start > EDCOPILOT_TIMEOUT )) && { warn "EDCoPilot not detected within timeout"; tail -n 20 "$logf" >> "$COORD_LOG" || true; return 0; }
    sleep 2
  done
}

cleanup() {
  local code=$?
  if [[ $cleanup_tools_on_exit -eq 1 && ( ${#TOOL_PGIDS[@]} -gt 0 || ${#TOOL_PIDS[@]} -gt 0 ) ]]; then
    log "Cleanup: terminating tool process groups"
    local g p
    for g in "${TOOL_PGIDS[@]}"; do kill -TERM -- "-$g" 2>/dev/null || true; done
    for p in "${TOOL_PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  fi
  exit $code
}
trap cleanup EXIT INT TERM

print_plan() {
  cat <<EOF | tee -a "$COORD_LOG"
Plan Summary:
  APPID=$APP_ID profile=$PROFILE_NAME mode=$MODE
  prefix(base)=$SELECTED_PREFIX instance_mode=$INSTANCE_MODE
  game_prefix=$GAME_PREFIX edcopilot_prefix=$EDCOPILOT_PREFIX tool_prefix=$TOOL_PREFIX_BASE/tools/pfx
  proton=$PROTON_DIR
  mined_native=${MINED_NATIVE:-<none>} mined_exe=${MINED_EXE:-MinEdLauncher.exe}
  edcopilot_exe=${EDCOPILOT_EXE:-LaunchEDCoPilot.exe}
  debug=$DEBUG combined_log=${COMBINED_LOG:-<none>}
  no_game=$NO_GAME wait_tools=$WAIT_TOOLS no_mined=$NO_MINED no_edcopilot=$NO_EDCOPILOT
  edcopilot_mode=$EDCOPILOT_MODE bus_name=$BUS_NAME
  PULSE_LATENCY_MSEC=$PULSE_LATENCY_MSEC DXVK_FILTER_DEVICE_NAME=$DXVK_FILTER_DEVICE_NAME DXVK_FRAME_RATE=$DXVK_FRAME_RATE
  PROTON_ENABLE_WAYLAND=${PROTON_ENABLE_WAYLAND:-0} VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-<default>}
EOF
}

main() {
  parse_args "$@"
  mkdir -p "$DEFAULT_PROFILE_DIR"
  [[ "$PROFILE_NAME" == "default" && ! -f "$DEFAULT_CONFIG" ]] || load_config_file "$DEFAULT_PROFILE_DIR/${PROFILE_NAME}.ini"
  setup_logs
  detect_mode
  run_interactive_if_requested
  setup_selected_paths
  setup_instances
  run_shared_bridge
  build_env_base
  MINED_EXE="${MINED_EXE:-MinEdLauncher.exe}"
  EDCOPILOT_EXE="${EDCOPILOT_EXE:-LaunchEDCoPilot.exe}"
  print_plan

  if [[ $NO_GAME -eq 1 ]]; then
    cleanup_tools_on_exit=0
    [[ $WAIT_TOOLS -eq 1 ]] && cleanup_tools_on_exit=1
    [[ $NO_EDCOPILOT -eq 0 ]] && launch_edcopilot
    local idx=1 t
    for t in "${CUSTOM_TOOLS[@]}"; do launch_tool "tool$idx" "$t" "$TOOL_PREFIX_BASE/tools/pfx" "auto"; ((idx++)); done
    if [[ $WAIT_TOOLS -eq 1 ]]; then
      log "tools-only wait mode active; waiting for child tools"
      wait || true
    else
      log "tools-only mode: leaving tools running and exiting"
    fi
    return 0
  fi

  launch_game
  wait_for_elite "$TIMEOUT" "$STABLE_SECONDS" || die "EliteDangerous64.exe did not become stable within timeout"
  launch_edcopilot
  local idx=1 t
  for t in "${CUSTOM_TOOLS[@]}"; do launch_tool "tool$idx" "$t" "$TOOL_PREFIX_BASE/tools/pfx" "auto"; ((idx++)); done

  if [[ $NO_MONITOR -eq 1 ]]; then
    log "No-monitor requested; exiting while tools may keep running"
    return 0
  fi
  log "Monitoring game process; ctrl+c to stop and cleanup"
  while pgrep -f "EliteDangerous64.exe" >/dev/null; do sleep 5; done
  log "Game exited"
}

main "$@"
