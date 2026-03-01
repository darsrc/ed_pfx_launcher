#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ed_pfx_launcher"
DEFAULT_APPID="359320"
DEFAULT_TIMEOUT=180
DEFAULT_STABLE_SECONDS=6
DEFAULT_EDCOPILOT_DELAY=5
DEFAULT_EDCOPILOT_BUS_WAIT=30
DEFAULT_EDCOPILOT_TIMEOUT=45
DEFAULT_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
DEFAULT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/ed_launcher/config.ini"
DEFAULT_PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ed_launcher"
DEFAULT_INTERACTIVE_UI="wizard"
DEFAULT_PULSE=90
DEFAULT_GPU_FILTER="RTX 3060"
DEFAULT_CAP=60
DEFAULT_PREFIX_SELECT="newest"
DEFAULT_PROTON_SELECT="newest"

STEAM_ROOT_CANDIDATES=(
  "${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
  "$HOME/.steam/steam"
  "$HOME/.local/share/Steam"
)
COMPATTOOLS_CANDIDATES=(
  "$HOME/.steam/steam/compatibilitytools.d"
  "$HOME/.local/share/Steam/compatibilitytools.d"
  "/usr/share/steam/compatibilitytools.d"
  "/usr/local/share/steam/compatibilitytools.d"
)
RUNTIME_CLIENT_RELATIVE=(
  "ubuntu12_64/steam-runtime-launch-client"
  "steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client"
  "steamapps/common/SteamLinuxRuntime_sniper/steam-runtime-launch-client"
)

CONFIG_FILE="$DEFAULT_CONFIG"
PROFILE_NAME=""
MODE="terminal"
FORWARDED_CMD=()
DEBUG=0
NO_EDCOPILOT=0
NO_MINED=0
NO_GAME=0
WAIT_TOOLS=0
NO_MONITOR=0
TIMEOUT="$DEFAULT_TIMEOUT"
STABLE_SECONDS="$DEFAULT_STABLE_SECONDS"
PREFIX_DIR=""
PREFIX_SELECT="$DEFAULT_PREFIX_SELECT"
PROTON_DIR=""
PROTON_SELECT="$DEFAULT_PROTON_SELECT"
INTERACTIVE=0
INTERACTIVE_UI="$DEFAULT_INTERACTIVE_UI"
EDCOPILOT_MODE="auto"
EDCOPILOT_DELAY="$DEFAULT_EDCOPILOT_DELAY"
EDCOPILOT_BUS_WAIT="$DEFAULT_EDCOPILOT_BUS_WAIT"
EDCOPILOT_TIMEOUT="$DEFAULT_EDCOPILOT_TIMEOUT"
TOOL_EXES=()
PULSE_LATENCY_MSEC="$DEFAULT_PULSE"
DXVK_FILTER_DEVICE_NAME="$DEFAULT_GPU_FILTER"
DXVK_FRAME_RATE="$DEFAULT_CAP"
VK_ICD_FILENAMES_OVERRIDE=""
MONITOR_GAME=1

INSTANCE_MODE="split"
GAME_PREFIX=""
EDCOPILOT_PREFIX=""
TOOL_PREFIX=""
SHARED_ENABLED="true"
SHARED_SOURCE_PREFIX="game"
SHARED_STRATEGY="symlink"

MINED_ARGS=("/autorun" "/autoquit" "/edo" "/frontier")
MINED_PATH_NATIVE=""
MINED_PATH_EXE=""
EDCOPILOT_EXE=""
GAME_EXE="EliteDangerous64.exe"

COORD_LOG=""
DEBUG_LOG=""
TOOLS_PGIDS=()
TOOLS_PIDS=()
TOOLS_LOGS=()
CLEANUP_ON_EXIT=1

log() {
  local msg="$*"
  echo "[$(date '+%F %T')] $msg" | tee -a "$COORD_LOG" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ed_pfx_launcher.sh [options] [-- %command%]

Core:
  --profile <name>                 Load ~/.config/ed_launcher/<name>.ini
  --config <path>                  Explicit config file
  --debug                          Enable Wine debug categories and debug logs
  --timeout <sec>                  Game wait timeout (default 180)
  --stable-seconds <sec>           Required stability time for EliteDangerous64.exe
  --no-monitor                     Disable long-lived game monitoring

Game/tools toggles:
  --no-game                        Tools-only mode
  --no-mined                       Skip MinEd and launch game directly
  --no-edcopilot                   Skip EDCoPilot
  --wait-tools                     In tools-only mode, wait and cleanup on Ctrl+C
  --tool <path/to/app.exe>         Repeatable additional tool executable path

Prefix/proton:
  --prefix-dir <path>              Prefix search root or explicit compatdata(/pfx)
  --prefix-select <first|newest>
  --proton-dir <path>              Proton search root or explicit Proton dir
  --proton-select <first|newest>
  --interactive                    Run prefix/proton interactive setup
  --interactive-ui <legacy|wizard>

EDCoPilot:
  --edcopilot-mode <auto|runtime|proton>
  --edcopilot-delay <sec>
  --edcopilot-bus-wait <sec>
  --edcopilot-timeout <sec>

Performance knobs:
  --pulse <ms>                     PULSE_LATENCY_MSEC
  --gpu <substring>                DXVK_FILTER_DEVICE_NAME
  --cap <fps>                      DXVK_FRAME_RATE
  --vk-icd <path>                  Override VK_ICD_FILENAMES

Instances/shared data:
  --instance-mode <split|single>
  --game-prefix <path>
  --edcopilot-prefix <path>
  --tool-prefix <path>

Compatibility aliases:
  --compatdata-dir <path>          Alias for --prefix-dir
  --help                           Show this help
EOF
}

trim() { sed -e 's/^\s*//' -e 's/\s*$//'; }

get_ini_value() {
  local file="$1" section="$2" key="$3"
  awk -F'=' -v s="[$section]" -v k="$key" '
    $0 ~ /^\s*;/ {next}
    /^\s*\[/ {in=($0==s)}
    in==1 {
      gsub(/^[ \t]+|[ \t]+$/, "", $1)
      if ($1==k) {
        $1=""; sub(/^=/,"",$0); gsub(/^[ \t]+|[ \t]+$/, "", $0); print $0; exit
      }
    }
  ' "$file" 2>/dev/null || true
}

write_ini_value() {
  local file="$1" section="$2" key="$3" value="$4"
  python3 - "$file" "$section" "$key" "$value" <<'PY'
import configparser, os, sys
p, s, k, v = sys.argv[1:]
cp = configparser.ConfigParser()
if os.path.exists(p):
    cp.read(p)
if not cp.has_section(s): cp.add_section(s)
cp.set(s, k, v)
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, 'w') as f: cp.write(f)
PY
}

parse_args() {
  while (($#)); do
    case "$1" in
      --help) usage; exit 0 ;;
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --profile) PROFILE_NAME="$2"; shift 2 ;;
      --debug) DEBUG=1; shift ;;
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --stable-seconds) STABLE_SECONDS="$2"; shift 2 ;;
      --no-monitor) NO_MONITOR=1; shift ;;
      --no-edcopilot) NO_EDCOPILOT=1; shift ;;
      --no-mined) NO_MINED=1; shift ;;
      --no-game) NO_GAME=1; shift ;;
      --wait-tools) WAIT_TOOLS=1; shift ;;
      --tool) TOOL_EXES+=("$2"); shift 2 ;;
      --prefix-dir|--compatdata-dir) PREFIX_DIR="$2"; shift 2 ;;
      --prefix-select) PREFIX_SELECT="$2"; shift 2 ;;
      --proton-dir) PROTON_DIR="$2"; shift 2 ;;
      --proton-select) PROTON_SELECT="$2"; shift 2 ;;
      --interactive) INTERACTIVE=1; shift ;;
      --interactive-ui) INTERACTIVE_UI="$2"; shift 2 ;;
      --edcopilot-mode) EDCOPILOT_MODE="$2"; shift 2 ;;
      --edcopilot-delay) EDCOPILOT_DELAY="$2"; shift 2 ;;
      --edcopilot-bus-wait) EDCOPILOT_BUS_WAIT="$2"; shift 2 ;;
      --edcopilot-timeout) EDCOPILOT_TIMEOUT="$2"; shift 2 ;;
      --pulse) PULSE_LATENCY_MSEC="$2"; shift 2 ;;
      --gpu) DXVK_FILTER_DEVICE_NAME="$2"; shift 2 ;;
      --cap) DXVK_FRAME_RATE="$2"; shift 2 ;;
      --vk-icd) VK_ICD_FILENAMES_OVERRIDE="$2"; shift 2 ;;
      --instance-mode) INSTANCE_MODE="$2"; shift 2 ;;
      --game-prefix) GAME_PREFIX="$2"; shift 2 ;;
      --edcopilot-prefix) EDCOPILOT_PREFIX="$2"; shift 2 ;;
      --tool-prefix) TOOL_PREFIX="$2"; shift 2 ;;
      --) shift; FORWARDED_CMD=("$@"); break ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

load_profile_and_config() {
  if [[ -n "$PROFILE_NAME" ]]; then
    CONFIG_FILE="$DEFAULT_PROFILE_DIR/${PROFILE_NAME}.ini"
    [[ -f "$CONFIG_FILE" ]] || die "Profile not found: $CONFIG_FILE"
  fi
  [[ -f "$CONFIG_FILE" ]] || return 0

  local v
  v="$(get_ini_value "$CONFIG_FILE" steam prefix_dir)"; [[ -n "$v" ]] && PREFIX_DIR="$v"
  v="$(get_ini_value "$CONFIG_FILE" steam compatdata_dir)"; [[ -n "$v" && -z "${PREFIX_DIR}" ]] && PREFIX_DIR="$v"
  v="$(get_ini_value "$CONFIG_FILE" steam prefix_select)"; [[ -n "$v" ]] && PREFIX_SELECT="$v"
  v="$(get_ini_value "$CONFIG_FILE" proton dir)"; [[ -n "$v" ]] && PROTON_DIR="$v"
  v="$(get_ini_value "$CONFIG_FILE" proton select)"; [[ -n "$v" ]] && PROTON_SELECT="$v"
  v="$(get_ini_value "$CONFIG_FILE" interactive ui)"; [[ -n "$v" ]] && INTERACTIVE_UI="$v"

  v="$(get_ini_value "$CONFIG_FILE" shared_data enabled)"; [[ -n "$v" ]] && SHARED_ENABLED="$v"
  v="$(get_ini_value "$CONFIG_FILE" shared_data source_prefix)"; [[ -n "$v" ]] && SHARED_SOURCE_PREFIX="$v"
  v="$(get_ini_value "$CONFIG_FILE" shared_data strategy)"; [[ -n "$v" ]] && SHARED_STRATEGY="$v"

  v="$(get_ini_value "$CONFIG_FILE" launch instance_mode)"; [[ -n "$v" ]] && INSTANCE_MODE="$v"
  v="$(get_ini_value "$CONFIG_FILE" launch mined_native)"; [[ -n "$v" ]] && MINED_PATH_NATIVE="$v"
  v="$(get_ini_value "$CONFIG_FILE" launch mined_exe)"; [[ -n "$v" ]] && MINED_PATH_EXE="$v"
  v="$(get_ini_value "$CONFIG_FILE" launch edcopilot_exe)"; [[ -n "$v" ]] && EDCOPILOT_EXE="$v"
  v="$(get_ini_value "$CONFIG_FILE" launch appid)"; [[ -n "$v" ]] && DEFAULT_APPID="$v"

  v="$(get_ini_value "$CONFIG_FILE" performance pulse_latency_msec)"; [[ -n "$v" ]] && PULSE_LATENCY_MSEC="$v"
  v="$(get_ini_value "$CONFIG_FILE" performance dxvk_filter_device_name)"; [[ -n "$v" ]] && DXVK_FILTER_DEVICE_NAME="$v"
  v="$(get_ini_value "$CONFIG_FILE" performance dxvk_frame_rate)"; [[ -n "$v" ]] && DXVK_FRAME_RATE="$v"
}

ensure_log_dir() {
  mkdir -p "$DEFAULT_LOG_DIR"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  COORD_LOG="$DEFAULT_LOG_DIR/coordinator_${ts}.log"
  touch "$COORD_LOG"
  if ((DEBUG)); then
    DEBUG_LOG="$DEFAULT_LOG_DIR/debug_${ts}.log"
  fi
}

detect_mode() {
  if ((${#FORWARDED_CMD[@]} > 0)); then
    local literal=0
    for tok in "${FORWARDED_CMD[@]}"; do
      [[ "$tok" == "%command%" ]] && literal=1
    done
    if ((literal)); then
      log "WARN: Literal %command% seen outside Steam expansion. Staying terminal mode."
      MODE="terminal"
      FORWARDED_CMD=()
    else
      MODE="steam"
    fi
  fi
}

choose_by_select() {
  local select="$1"; shift
  local items=("$@")
  ((${#items[@]})) || return 1
  if [[ "$select" == "first" ]]; then
    printf '%s\n' "${items[0]}"
    return 0
  fi
  local best="" best_m=0 m
  for i in "${items[@]}"; do
    m=$(stat -c '%Y' "$i" 2>/dev/null || echo 0)
    if (( m >= best_m )); then
      best_m=$m
      best="$i"
    fi
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

find_compatdata_candidates() {
  local out=()
  if [[ -n "$PREFIX_DIR" ]]; then
    if [[ -d "$PREFIX_DIR/pfx" ]]; then out+=("$PREFIX_DIR/pfx")
    elif [[ -d "$PREFIX_DIR" && "$(basename "$PREFIX_DIR")" == "pfx" ]]; then out+=("$PREFIX_DIR")
    elif [[ -d "$PREFIX_DIR" ]]; then
      while IFS= read -r d; do out+=("$d"); done < <(find "$PREFIX_DIR" -maxdepth 8 -type d -path '*/compatdata/*/pfx' 2>/dev/null)
    fi
  fi
  for root in "${STEAM_ROOT_CANDIDATES[@]}"; do
    [[ -n "$root" && -d "$root/steamapps/compatdata" ]] || continue
    while IFS= read -r d; do out+=("$d"); done < <(find "$root/steamapps/compatdata" -maxdepth 2 -type d -name pfx 2>/dev/null)
  done
  printf '%s\n' "${out[@]}" | awk 'NF' | sort -u
}

find_proton_candidates() {
  local out=()
  if [[ -n "$PROTON_DIR" ]]; then
    if [[ -x "$PROTON_DIR/proton" ]]; then out+=("$PROTON_DIR")
    elif [[ -d "$PROTON_DIR" ]]; then
      while IFS= read -r d; do out+=("$d"); done < <(find "$PROTON_DIR" -maxdepth 2 -type f -name proton -printf '%h\n' 2>/dev/null)
    fi
  fi
  for root in "${STEAM_ROOT_CANDIDATES[@]}"; do
    [[ -n "$root" ]] || continue
    while IFS= read -r d; do out+=("$d"); done < <(find "$root/steamapps/common" -maxdepth 1 -type d -name 'Proton*' 2>/dev/null)
  done
  for root in "${COMPATTOOLS_CANDIDATES[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r d; do out+=("$d"); done < <(find "$root" -maxdepth 2 -type f -name proton -printf '%h\n' 2>/dev/null)
  done
  printf '%s\n' "${out[@]}" | awk 'NF' | sort -u
}

run_interactive_selection() {
  log "Interactive UI selected: $INTERACTIVE_UI"
  local prefixes protons sel_prefix sel_proton
  mapfile -t prefixes < <(find_compatdata_candidates)
  mapfile -t protons < <(find_proton_candidates)
  if [[ "$INTERACTIVE_UI" == "wizard" && -t 0 && -t 1 && -x "$(command -v python3)" && -f "scripts/interactive_ui.py" ]]; then
    if python3 scripts/interactive_ui.py "$CONFIG_FILE" "$(printf '%s\n' "${prefixes[@]}")" "$(printf '%s\n' "${protons[@]}")"; then
      PREFIX_DIR="$(get_ini_value "$CONFIG_FILE" steam prefix_dir)"
      PROTON_DIR="$(get_ini_value "$CONFIG_FILE" proton dir)"
      log "Wizard saved selection to active config."
      return
    else
      log "Wizard unavailable/cancelled; falling back to legacy auto-select."
    fi
  else
    log "Wizard fallback: non-tty/backend missing, using legacy auto-select."
  fi
  sel_prefix="$(choose_by_select "$PREFIX_SELECT" "${prefixes[@]}")"
  sel_proton="$(choose_by_select "$PROTON_SELECT" "${protons[@]}")"
  [[ -n "$sel_prefix" && -n "$sel_proton" ]] || die "Interactive fallback could not auto-select prefix/proton"
  PREFIX_DIR="$sel_prefix"
  PROTON_DIR="$sel_proton"
  write_ini_value "$CONFIG_FILE" steam prefix_dir "$PREFIX_DIR"
  write_ini_value "$CONFIG_FILE" proton dir "$PROTON_DIR"
}

resolve_paths() {
  local prefix_candidates proton_candidates
  mapfile -t prefix_candidates < <(find_compatdata_candidates)
  mapfile -t proton_candidates < <(find_proton_candidates)
  [[ -n "$PREFIX_DIR" ]] || PREFIX_DIR="$(choose_by_select "$PREFIX_SELECT" "${prefix_candidates[@]}")"
  [[ -n "$PROTON_DIR" ]] || PROTON_DIR="$(choose_by_select "$PROTON_SELECT" "${proton_candidates[@]}")"
  [[ -n "$PREFIX_DIR" ]] || die "No prefix found. Use --prefix-dir or --interactive"
  [[ -n "$PROTON_DIR" ]] || die "No proton found. Use --proton-dir or --interactive"
  [[ -d "$PREFIX_DIR" ]] || die "Prefix dir not found: $PREFIX_DIR"
  [[ -x "$PROTON_DIR/proton" ]] || die "Proton executable not found: $PROTON_DIR/proton"

  local install_default="${PREFIX_DIR%/pfx}/pfx/drive_c/Program Files (x86)/Steam/steamapps/common/Elite Dangerous"
  [[ -n "$MINED_PATH_EXE" ]] || MINED_PATH_EXE="$install_default/MinEdLauncher/MinEdLauncher.exe"
  [[ -n "$MINED_PATH_NATIVE" ]] || MINED_PATH_NATIVE="$install_default/MinEdLauncher/MinEdLauncher"
  [[ -n "$EDCOPILOT_EXE" ]] || EDCOPILOT_EXE="$install_default/EDCoPilot/LaunchEDCoPilot.exe"

  if [[ "$INSTANCE_MODE" == "split" ]]; then
    GAME_PREFIX="${GAME_PREFIX:-$PREFIX_DIR}"
    EDCOPILOT_PREFIX="${EDCOPILOT_PREFIX:-${PREFIX_DIR%/pfx}_edcopilot/pfx}"
    TOOL_PREFIX="${TOOL_PREFIX:-${PREFIX_DIR%/pfx}_tools/pfx}"
    mkdir -p "$EDCOPILOT_PREFIX" "$TOOL_PREFIX"
  else
    GAME_PREFIX="${GAME_PREFIX:-$PREFIX_DIR}"
    EDCOPILOT_PREFIX="${EDCOPILOT_PREFIX:-$PREFIX_DIR}"
    TOOL_PREFIX="${TOOL_PREFIX:-$PREFIX_DIR}"
  fi
}

build_base_env() {
  export WINEFSYNC="${WINEFSYNC:-1}"
  export WINEESYNC="${WINEESYNC:-1}"
  export SDL_JOYSTICK_DISABLE="${SDL_JOYSTICK_DISABLE:-1}"
  export SDL_GAMECONTROLLER_DISABLE="${SDL_GAMECONTROLLER_DISABLE:-1}"
  export PYGAME_FORCE_JOYSTICK="${PYGAME_FORCE_JOYSTICK:-0}"
  export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-dinput=n;dinput8=n;hid=n;hidraw=n}"
  export PULSE_LATENCY_MSEC="$PULSE_LATENCY_MSEC"
  export DXVK_FILTER_DEVICE_NAME="$DXVK_FILTER_DEVICE_NAME"
  export DXVK_FRAME_RATE="$DXVK_FRAME_RATE"
  if ((DEBUG)); then
    export WINEDEBUG="-all,+seh,+err,+mscoree,+loaddll"
  else
    export WINEDEBUG="-all"
  fi
  if [[ -n "$VK_ICD_FILENAMES_OVERRIDE" ]]; then
    export VK_ICD_FILENAMES="$VK_ICD_FILENAMES_OVERRIDE"
  elif [[ -f "/usr/share/vulkan/icd.d/nvidia_icd.json" ]]; then
    export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.json"
  fi
  if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${PROTON_ENABLE_WAYLAND:-}" ]]; then
    export PROTON_ENABLE_WAYLAND=1
  fi
  unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus || true
}

shared_paths=(
"users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous"
"users/steamuser/AppData/Local/EDCoPilot"
"users/steamuser/Documents/Frontier Developments/Elite Dangerous"
)

apply_shared_bridge() {
  [[ "$SHARED_ENABLED" == "true" ]] || { log "Shared bridge disabled"; return; }
  local src_prefix="$GAME_PREFIX"
  case "$SHARED_SOURCE_PREFIX" in
    game) src_prefix="$GAME_PREFIX" ;;
    edcopilot) src_prefix="$EDCOPILOT_PREFIX" ;;
    tool|edcopter) src_prefix="$TOOL_PREFIX" ;;
  esac
  [[ "$SHARED_STRATEGY" == "symlink" ]] || log "Shared strategy $SHARED_STRATEGY currently falling back to symlink"

  local dst_prefix rel src dst
  for dst_prefix in "$EDCOPILOT_PREFIX" "$TOOL_PREFIX"; do
    [[ "$dst_prefix" == "$src_prefix" ]] && continue
    for rel in "${shared_paths[@]}"; do
      src="$src_prefix/drive_c/$rel"
      dst="$dst_prefix/drive_c/$rel"
      mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
      [[ -e "$src" ]] || mkdir -p "$src"
      if [[ -L "$dst" ]]; then
        if [[ "$(readlink -f "$dst")" == "$(readlink -f "$src")" ]]; then
          continue
        else
          rm -f "$dst"
        fi
      elif [[ -d "$dst" ]] && [[ -n "$(find "$dst" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]]; then
        log "WARN: unmanaged non-empty dir left untouched: $dst"
        continue
      else
        rm -rf "$dst"
      fi
      ln -s "$src" "$dst"
      log "Shared bridge linked: $dst -> $src"
    done
  done
}

wait_for_process_stable() {
  local pattern="$1" timeout="$2" stable="$3"
  local elapsed=0 stable_seen=0
  while ((elapsed < timeout)); do
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      ((stable_seen++))
      if ((stable_seen >= stable)); then return 0; fi
    else
      stable_seen=0
    fi
    sleep 1
    ((elapsed++))
  done
  return 1
}

launch_with_proton_detached() {
  local prefix="$1" logfile="$2"; shift 2
  env STEAM_COMPAT_DATA_PATH="${prefix%/pfx}" setsid -f "$PROTON_DIR/proton" run "$@" >>"$logfile" 2>&1 || true
}

find_runtime_client() {
  local root rel
  for root in "${STEAM_ROOT_CANDIDATES[@]}"; do
    [[ -n "$root" ]] || continue
    for rel in "${RUNTIME_CLIENT_RELATIVE[@]}"; do
      if [[ -x "$root/$rel" ]]; then printf '%s\n' "$root/$rel"; return 0; fi
    done
  done
  return 1
}

derive_appid() {
  local appid="${SteamGameId:-${SteamAppId:-$DEFAULT_APPID}}"
  if [[ "$appid" == "$DEFAULT_APPID" ]]; then
    local maybe
    maybe="$(basename "${GAME_PREFIX%/pfx}")"
    [[ "$maybe" =~ ^[0-9]+$ ]] && appid="$maybe"
  fi
  echo "$appid"
}

launch_edcopilot() {
  local appid bus_name tool_log runtime_client
  appid="$(derive_appid)"
  bus_name="com.steampowered.App${appid}"
  tool_log="$DEFAULT_LOG_DIR/edcopilot_$(date +%Y%m%d_%H%M%S).log"
  TOOLS_LOGS+=("$tool_log")
  sleep "$EDCOPILOT_DELAY"
  local mode="$EDCOPILOT_MODE"
  if [[ "$mode" == "auto" ]]; then
    if runtime_client="$(find_runtime_client)" && command -v busctl >/dev/null 2>&1; then
      mode="runtime"
    else
      mode="proton"
      log "EDCoPilot auto mode fallback to proton (runtime prerequisites missing)."
    fi
  fi
  if [[ "$mode" == "runtime" ]]; then
    runtime_client="$(find_runtime_client || true)"
    [[ -n "$runtime_client" ]] || { [[ "$EDCOPILOT_MODE" == "auto" ]] && mode="proton" || die "runtime mode requested but runtime client missing"; }
    if [[ "$mode" == "runtime" ]]; then
      command -v busctl >/dev/null 2>&1 || { [[ "$EDCOPILOT_MODE" == "auto" ]] && mode="proton" || die "runtime mode requested but busctl missing"; }
    fi
    if [[ "$mode" == "runtime" ]]; then
      local waited=0
      until busctl --user list 2>/dev/null | awk '{print $1}' | grep -qx "$bus_name"; do
        sleep 1; ((waited++)); ((waited >= EDCOPILOT_BUS_WAIT)) && break
      done
      if ((waited >= EDCOPILOT_BUS_WAIT)); then
        [[ "$EDCOPILOT_MODE" == "auto" ]] && { log "Runtime bus wait timeout; fallback to proton."; mode="proton"; } || die "runtime mode bus-name $bus_name not available"
      fi
    fi
    if [[ "$mode" == "runtime" ]]; then
      local wine_loader="$PROTON_DIR/files/bin/wine"
      [[ -x "$wine_loader" ]] || die "runtime mode requires Proton wine loader: $wine_loader"
      env SteamGameId="$appid" STEAM_COMPAT_DATA_PATH="${EDCOPILOT_PREFIX%/pfx}" setsid -f "$runtime_client" "--bus-name=$bus_name" -- "$wine_loader" "$EDCOPILOT_EXE" >>"$tool_log" 2>&1 || true
      log "EDCoPilot launched in runtime mode"
    fi
  fi
  if [[ "$mode" == "proton" ]]; then
    launch_with_proton_detached "$EDCOPILOT_PREFIX" "$tool_log" "$EDCOPILOT_EXE"
    log "EDCoPilot launched in proton mode"
  fi
  if wait_for_process_stable "EDCoPilotGUI2.exe" "$EDCOPILOT_TIMEOUT" 3; then
    log "EDCoPilot process detected stable"
  else
    log "WARN: EDCoPilot process not detected within timeout; recent log tail:"
    tail -n 30 "$tool_log" | tee -a "$COORD_LOG" >&2 || true
  fi
}

launch_tools() {
  local tool idx=0
  for tool in "${TOOL_EXES[@]}"; do
    local logf="$DEFAULT_LOG_DIR/tool_${idx}_$(date +%Y%m%d_%H%M%S).log"
    TOOLS_LOGS+=("$logf")
    launch_with_proton_detached "$TOOL_PREFIX" "$logf" "$tool"
    idx=$((idx+1))
    log "Tool launched: $tool"
  done
}

launch_game() {
  local game_log="$DEFAULT_LOG_DIR/game_$(date +%Y%m%d_%H%M%S).log"
  if ((NO_MINED)); then
    launch_with_proton_detached "$GAME_PREFIX" "$game_log" "$GAME_EXE"
    log "Game launched directly (no-mined)"
  else
    if [[ "$MODE" == "steam" && -x "$MINED_PATH_NATIVE" ]]; then
      setsid -f "${FORWARDED_CMD[@]}" "$MINED_PATH_NATIVE" "${MINED_ARGS[@]}" "$PROFILE_NAME" >>"$game_log" 2>&1 || true
      log "MinEd native steam-mode launch invoked"
    else
      launch_with_proton_detached "$GAME_PREFIX" "$game_log" "$MINED_PATH_EXE" "${MINED_ARGS[@]}" "$PROFILE_NAME"
      log "MinEd exe proton launch invoked"
    fi
  fi

  if wait_for_process_stable "EliteDangerous64.exe" "$TIMEOUT" "$STABLE_SECONDS"; then
    log "EliteDangerous64.exe reached stable running state"
  else
    if pgrep -f "EDLaunch.exe" >/dev/null 2>&1; then
      log "EDLaunch.exe observed but EliteDangerous64.exe did not stabilize"
    fi
    die "Game did not reach stable running state within timeout"
  fi
}

cleanup() {
  if ((CLEANUP_ON_EXIT==0)); then
    log "Cleanup skipped by policy"
    return
  fi
  log "Cleanup policy active (tools launched detached; no group tracking in detached mode)."
}

print_plan() {
  cat <<EOF | tee -a "$COORD_LOG"
--- Launch plan ---
APPID: $(derive_appid)
Profile: ${PROFILE_NAME:-default}
Mode: $MODE
Prefix(game/edcopilot/tool): $GAME_PREFIX | $EDCOPILOT_PREFIX | $TOOL_PREFIX
Instance mode: $INSTANCE_MODE
Proton: $PROTON_DIR
MinEd native: $MINED_PATH_NATIVE
MinEd exe: $MINED_PATH_EXE
EDCoPilot exe: $EDCOPILOT_EXE
Debug: $DEBUG ${DEBUG_LOG:+(debug log: $DEBUG_LOG)}
Tools-only: $NO_GAME wait-tools: $WAIT_TOOLS cleanup_on_exit: $CLEANUP_ON_EXIT
EDCoPilot mode: $EDCOPILOT_MODE delay/buswait/timeout: $EDCOPILOT_DELAY/$EDCOPILOT_BUS_WAIT/$EDCOPILOT_TIMEOUT
Perf: PULSE_LATENCY_MSEC=$PULSE_LATENCY_MSEC DXVK_FILTER_DEVICE_NAME=$DXVK_FILTER_DEVICE_NAME DXVK_FRAME_RATE=$DXVK_FRAME_RATE PROTON_ENABLE_WAYLAND=${PROTON_ENABLE_WAYLAND:-0} VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-unset}
-------------------
EOF
}

main() {
  parse_args "$@"
  load_profile_and_config
  ensure_log_dir
  detect_mode
  ((NO_MONITOR)) && MONITOR_GAME=0
  ((INTERACTIVE)) && run_interactive_selection
  resolve_paths
  build_base_env
  apply_shared_bridge

  if ((NO_GAME)); then
    CLEANUP_ON_EXIT=0
    ((WAIT_TOOLS)) && CLEANUP_ON_EXIT=1
  fi

  trap cleanup EXIT INT TERM
  print_plan

  ((NO_EDCOPILOT)) || launch_edcopilot
  launch_tools

  if ((NO_GAME)); then
    if ((WAIT_TOOLS)); then
      log "Tools-only wait mode active; press Ctrl+C to cleanup and exit"
      while true; do sleep 2; done
    else
      log "Tools-only mode launched; exiting without cleanup"
      exit 0
    fi
  fi

  launch_game
  if ((MONITOR_GAME)); then
    log "Monitoring game process..."
    while pgrep -f "EliteDangerous64.exe" >/dev/null 2>&1; do sleep 5; done
    log "Game process ended"
  fi
}

main "$@"
