#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ed_pfx_launcher"
DEFAULT_APPID="359320"
DEFAULT_TIMEOUT=180
DEFAULT_STABLE_SECS=6
DEFAULT_EDCOPILOT_DELAY=5
DEFAULT_EDCOPILOT_BUS_WAIT=30
DEFAULT_EDCOPILOT_TIMEOUT=45
DEFAULT_INTERACTIVE_UI="wizard"
DEFAULT_PULSE_LATENCY=90
DEFAULT_GPU_FILTER="RTX 3060"
DEFAULT_DXVK_CAP=60
DEFAULT_LOG_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ed_launcher/config.ini"
DEFAULT_STEAM_ROOT_HINT="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.local/share/Steam}"
DEFAULT_COMPATDATA_HINT="${STEAM_COMPAT_DATA_PATH:-}"
DEFAULT_PROFILE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ed_launcher"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="terminal"
DEBUG=0
NO_MINED=0
NO_EDCOPILOT=0
NO_GAME=0
WAIT_TOOLS=0
NO_MONITOR=0
INTERACTIVE=0
INTERACTIVE_UI=""
EDCOPILOT_MODE="auto"
PROFILE_NAME=""
TIMEOUT="$DEFAULT_TIMEOUT"
STABLE_SECS="$DEFAULT_STABLE_SECS"
EDCOPILOT_DELAY="$DEFAULT_EDCOPILOT_DELAY"
EDCOPILOT_BUS_WAIT="$DEFAULT_EDCOPILOT_BUS_WAIT"
EDCOPILOT_TIMEOUT="$DEFAULT_EDCOPILOT_TIMEOUT"
PREFIX_DIR=""
PREFIX_SELECT=""
PROTON_DIR=""
PROTON_SELECT=""
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
LOG_DIR="$DEFAULT_LOG_ROOT"
PULSE_LATENCY="$DEFAULT_PULSE_LATENCY"
GPU_FILTER="$DEFAULT_GPU_FILTER"
DXVK_CAP="$DEFAULT_DXVK_CAP"
VK_ICD_MODE="auto"
INSTANCE_MODE="split"
SOURCE_PREFIX="game"
SHARED_ENABLED="true"
SHARED_STRATEGY="symlink"
PROFILE_INSTALL_MAP="darvix:darnielle,darmod:darmod"

FORWARDED_CMD=()
TOOLS=()
TOOL_PGIDS=()
LOG_FILE=""
COORD_LOG=""
CLEANUP_ON_EXIT=1
RUNTIME_CLIENT=""

declare -A CFG

ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() {
  local lvl="$1"; shift
  local msg="[$(ts)] [$lvl] $*"
  echo "$msg"
  if [[ -n "${COORD_LOG:-}" ]]; then
    echo "$msg" >> "$COORD_LOG"
  fi
}
warn() { log WARN "$*"; }
err() { log ERROR "$*"; }

die() {
  err "$*"
  exit 1
}

trim() {
  local s="$*"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

load_ini_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local section=""
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    local line
    line="$(trim "$raw")"
    [[ -z "$line" || "$line" == ";"* || "$line" == "#"* ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" == *=* ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      key="$(trim "$key")"
      val="$(trim "$val")"
      CFG["$section.$key"]="$val"
    fi
  done < "$file"
}

cfg_get() {
  local key="$1" default="${2:-}"
  if [[ -n "${CFG[$key]:-}" ]]; then
    printf '%s' "${CFG[$key]}"
  else
    printf '%s' "$default"
  fi
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  local after_sep=0
  while (($#)); do
    local arg="$1"
    shift || true
    if [[ "$after_sep" -eq 1 ]]; then
      FORWARDED_CMD+=("$arg")
      continue
    fi
    case "$arg" in
      --) after_sep=1 ;;
      --debug) DEBUG=1 ;;
      --no-edcopilot) NO_EDCOPILOT=1 ;;
      --no-mined) NO_MINED=1 ;;
      --no-game) NO_GAME=1 ;;
      --wait-tools) WAIT_TOOLS=1 ;;
      --no-monitor) NO_MONITOR=1 ;;
      --interactive) INTERACTIVE=1 ;;
      --interactive-ui) INTERACTIVE_UI="${1:-}"; shift || die "missing value for --interactive-ui" ;;
      --prefix-dir) PREFIX_DIR="${1:-}"; shift || die "missing value for --prefix-dir" ;;
      --prefix-select) PREFIX_SELECT="${1:-}"; shift || die "missing value for --prefix-select" ;;
      --proton-dir) PROTON_DIR="${1:-}"; shift || die "missing value for --proton-dir" ;;
      --proton-select) PROTON_SELECT="${1:-}"; shift || die "missing value for --proton-select" ;;
      --profile) PROFILE_NAME="${1:-}"; shift || die "missing value for --profile" ;;
      --timeout) TIMEOUT="${1:-}"; shift || die "missing value for --timeout" ;;
      --stable-secs) STABLE_SECS="${1:-}"; shift || die "missing value for --stable-secs" ;;
      --tool) TOOLS+=("${1:-}"); shift || die "missing value for --tool" ;;
      --edcopilot-mode) EDCOPILOT_MODE="${1:-}"; shift || die "missing value for --edcopilot-mode" ;;
      --edcopilot-delay) EDCOPILOT_DELAY="${1:-}"; shift || die "missing value for --edcopilot-delay" ;;
      --edcopilot-bus-wait) EDCOPILOT_BUS_WAIT="${1:-}"; shift || die "missing value for --edcopilot-bus-wait" ;;
      --edcopilot-timeout) EDCOPILOT_TIMEOUT="${1:-}"; shift || die "missing value for --edcopilot-timeout" ;;
      --pulse) PULSE_LATENCY="${1:-}"; shift || die "missing value for --pulse" ;;
      --gpu) GPU_FILTER="${1:-}"; shift || die "missing value for --gpu" ;;
      --cap) DXVK_CAP="${1:-}"; shift || die "missing value for --cap" ;;
      --log-dir) LOG_DIR="${1:-}"; shift || die "missing value for --log-dir" ;;
      --config) CONFIG_FILE="${1:-}"; shift || die "missing value for --config" ;;
      --instance-mode) INSTANCE_MODE="${1:-}"; shift || die "missing value for --instance-mode" ;;
      --help|-h) show_help; exit 0 ;;
      *) die "unknown argument: $arg" ;;
    esac
  done
}

show_help() {
  cat <<'EOF'
Usage: ed_pfx_launcher.sh [options] [-- %command% ...]

Core:
  --profile <name>              Load ~/.config/ed_launcher/<name>.ini
  --config <path>               Config path
  --debug                       Enable detailed Wine logs
  --timeout <sec>               Game wait timeout (default 180)
  --stable-secs <sec>           Stable game PID window
  --interactive                 Run prefix/proton selection flow
  --interactive-ui <wizard|legacy>

Steam/Proton selection:
  --prefix-dir <path>           Prefix search root or explicit compatdata(/pfx)
  --prefix-select <first|newest>
  --proton-dir <path>           Proton search root or explicit proton dir
  --proton-select <first|newest>
  --instance-mode <split|single>

Launch toggles:
  --no-game                     Tools-only mode
  --wait-tools                  In tools-only mode wait and cleanup on Ctrl+C
  --no-mined                    Skip MinEd; launch game directly
  --no-edcopilot                Skip EDCoPilot
  --tool <exe path>             Repeatable extra tool exe
  --no-monitor                  Do not monitor game lifetime after launch

EDCoPilot:
  --edcopilot-mode <auto|runtime|proton>
  --edcopilot-delay <sec>
  --edcopilot-bus-wait <sec>
  --edcopilot-timeout <sec>

Performance knobs:
  --pulse <ms>                  PULSE_LATENCY_MSEC
  --gpu <substring>             DXVK_FILTER_DEVICE_NAME
  --cap <fps>                   DXVK_FRAME_RATE

Compatibility:
  steam.compatdata_dir aliases steam.prefix_dir in config.
EOF
}

discover_steam_roots() {
  local roots=()
  [[ -d "$HOME/.steam/steam" ]] && roots+=("$HOME/.steam/steam")
  [[ -d "$HOME/.local/share/Steam" ]] && roots+=("$HOME/.local/share/Steam")
  [[ -d "$DEFAULT_STEAM_ROOT_HINT" ]] && roots+=("$DEFAULT_STEAM_ROOT_HINT")
  printf '%s\n' "${roots[@]}" | awk 'NF && !seen[$0]++'
}

scan_prefix_candidates() {
  local root="$1"
  if [[ -d "$root/pfx" ]]; then
    echo "$root/pfx"
  elif [[ -d "$root/compatdata" ]]; then
    find "$root/compatdata" -mindepth 2 -maxdepth 2 -type d -name pfx 2>/dev/null || true
  elif [[ -d "$root/steamapps/compatdata" ]]; then
    find "$root/steamapps/compatdata" -mindepth 2 -maxdepth 2 -type d -name pfx 2>/dev/null || true
  fi
}

scan_proton_candidates() {
  local roots=()
  while IFS= read -r s; do
    roots+=("$s")
    roots+=("$s/steamapps/common")
    roots+=("$s/compatibilitytools.d")
    roots+=("$s/steamapps/compatibilitytools.d")
  done < <(discover_steam_roots)
  roots+=("/usr/share/steam/compatibilitytools.d" "/usr/local/share/steam/compatibilitytools.d")

  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    find "$r" -mindepth 1 -maxdepth 2 -type f -name proton -printf '%h\n' 2>/dev/null || true
  done | awk 'NF && !seen[$0]++'
}

pick_candidate() {
  local mode="$1"; shift
  local arr=("$@")
  [[ ${#arr[@]} -gt 0 ]] || return 1
  if [[ "$mode" == "newest" ]]; then
    local newest="${arr[0]}" t=0
    local p
    for p in "${arr[@]}"; do
      local mt
      mt=$(stat -c %Y "$p" 2>/dev/null || echo 0)
      if (( mt > t )); then t=$mt; newest="$p"; fi
    done
    echo "$newest"
  else
    echo "${arr[0]}"
  fi
}

launch_detached_logged() {
  local logfile="$1"; shift
  setsid "$@" >>"$logfile" 2>&1 < /dev/null &
  local pid=$!
  local pgid
  pgid=$(ps -o pgid= -p "$pid" | tr -d ' ' || true)
  [[ -n "$pgid" ]] && TOOL_PGIDS+=("$pgid")
  echo "$pid"
}

pid_exists() { kill -0 "$1" 2>/dev/null; }

wait_stable_proc() {
  local pattern="$1" timeout="$2" stable="$3"
  local start now pid stable_start=0
  start=$(date +%s)
  while true; do
    now=$(date +%s)
    (( now - start > timeout )) && return 1
    pid=$(pgrep -f "$pattern" | head -n1 || true)
    if [[ -n "$pid" ]] && pid_exists "$pid"; then
      if (( stable_start == 0 )); then stable_start="$now"; fi
      if (( now - stable_start >= stable )); then
        echo "$pid"
        return 0
      fi
    else
      stable_start=0
    fi
    sleep 1
  done
}

runtime_client_detect() {
  local paths=(
    "$STEAM_ROOT/ubuntu12_64/steam-runtime-launch-client"
    "$STEAM_ROOT/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point"
    "$STEAM_ROOT/steamapps/common/SteamLinuxRuntime_sniper/steam-runtime-launch-client"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -x "$p" ]]; then
      RUNTIME_CLIENT="$p"
      return 0
    fi
  done
  return 1
}

ensure_shared_path() {
  local src_root="$1" dst_root="$2" rel="$3"
  local src="$src_root/drive_c/$rel"
  local dst="$dst_root/drive_c/$rel"
  mkdir -p "$(dirname "$src")" "$(dirname "$dst")"
  [[ -e "$src" ]] || mkdir -p "$src"

  if [[ -L "$dst" ]]; then
    local target
    target=$(readlink -f "$dst" || true)
    local src_real
    src_real=$(readlink -f "$src")
    if [[ "$target" == "$src_real" ]]; then
      log INFO "shared_data ok: $dst -> $target"
      return 0
    fi
    warn "shared_data relinking mismatched symlink: $dst"
    rm -f "$dst"
  elif [[ -d "$dst" ]] && [[ -n "$(find "$dst" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    warn "shared_data unmanaged non-empty dir left untouched: $dst"
    return 0
  elif [[ -e "$dst" ]]; then
    rm -rf "$dst"
  fi

  ln -s "$src" "$dst"
  log INFO "shared_data linked: $dst -> $src"
}

apply_shared_bridge() {
  is_true "$SHARED_ENABLED" || { log INFO "shared_data disabled"; return 0; }
  local strategy="${SHARED_STRATEGY,,}"
  if [[ "$strategy" != "symlink" ]]; then
    warn "shared_data strategy '$strategy' not fully implemented; falling back to symlink"
  fi

  local src
  case "$SOURCE_PREFIX" in
    game) src="$GAME_PFX" ;;
    edcopilot|tool) src="$TOOL_PFX" ;;
    *) src="$GAME_PFX" ;;
  esac

  local rels=(
    "users/steamuser/AppData/Local/Frontier Developments/Elite Dangerous"
    "users/steamuser/AppData/Local/EDCoPilot"
    "users/steamuser/Documents/Frontier Developments/Elite Dangerous"
  )

  local target_pfxs=("$TOOL_PFX")
  [[ "$INSTANCE_MODE" == "single" ]] && target_pfxs=()
  local tp rel
  for tp in "${target_pfxs[@]}"; do
    for rel in "${rels[@]}"; do
      ensure_shared_path "$src" "$tp" "$rel"
    done
  done
}

write_ini_key() {
  local file="$1" section="$2" key="$3" val="$4"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! awk -v sec="$section" -v key="$key" -v val="$val" '
    BEGIN{insec=0; wrote=0}
    $0 ~ "^\\["sec"\\]$" {print; insec=1; next}
    $0 ~ /^\[/ {if(insec&&!wrote){print key"="val; wrote=1} insec=0}
    {if(insec && $0 ~ "^"key"="){if(!wrote){print key"="val; wrote=1}; next} print}
    END{if(!wrote){if(!insec) print "["sec"]"; print key"="val}}
  ' "$file" > "$file.tmp"; then
    return 1
  fi
  mv "$file.tmp" "$file"
}

run_interactive() {
  local ui="$1"
  local prefixes=("${PREFIX_CANDIDATES[@]}")
  local protons=("${PROTON_CANDIDATES[@]}")
  if [[ ${#prefixes[@]} -eq 0 || ${#protons[@]} -eq 0 ]]; then
    die "interactive mode requested but no prefix/proton candidates found"
  fi

  if [[ "$ui" == "wizard" && -t 0 && -t 1 && -x "$(command -v python3)" ]]; then
    log INFO "interactive path: wizard"
    local out
    if out=$(python3 "$SCRIPT_DIR/scripts/interactive_ui.py" --prefix "${prefixes[@]}" --proton "${protons[@]}" 2>>"$COORD_LOG"); then
      if [[ "$out" == CANCEL* ]]; then
        warn "wizard cancelled; no config written"
        return 0
      fi
      local sel_prefix sel_proton
      sel_prefix="$(echo "$out" | awk -F'|' '/^OK\|/ {print $2}')"
      sel_proton="$(echo "$out" | awk -F'|' '/^OK\|/ {print $3}')"
      [[ -n "$sel_prefix" && -n "$sel_proton" ]] || die "wizard output malformed"
      write_ini_key "$CONFIG_FILE" steam prefix_dir "$sel_prefix"
      write_ini_key "$CONFIG_FILE" proton dir "$sel_proton"
      PREFIX_DIR="$sel_prefix"
      PROTON_DIR="$sel_proton"
      log INFO "wizard saved selections to $CONFIG_FILE"
      return 0
    else
      warn "wizard backend unavailable/failed; falling back to legacy auto-select"
    fi
  else
    warn "wizard unavailable (non-tty or python3 missing); falling back to legacy auto-select"
  fi

  PREFIX_DIR="$(pick_candidate "${PREFIX_SELECT:-first}" "${prefixes[@]}")"
  PROTON_DIR="$(pick_candidate "${PROTON_SELECT:-newest}" "${protons[@]}")"
  log INFO "legacy interactive fallback selected prefix=$PREFIX_DIR proton=$PROTON_DIR"
}

cleanup_tools() {
  [[ ${#TOOL_PGIDS[@]} -eq 0 ]] && return 0
  local pg
  for pg in "${TOOL_PGIDS[@]}"; do
    kill -TERM "-$pg" 2>/dev/null || true
  done
}

on_exit() {
  if (( CLEANUP_ON_EXIT == 1 )); then
    cleanup_tools
  fi
}
trap on_exit EXIT INT TERM

load_config_and_profile() {
  load_ini_file "$CONFIG_FILE"
  if [[ -n "$PROFILE_NAME" ]]; then
    local pfile="$DEFAULT_PROFILE_DIR/$PROFILE_NAME.ini"
    [[ -f "$pfile" ]] || die "profile not found: $pfile"
    load_ini_file "$pfile"
  fi

  PREFIX_DIR="${PREFIX_DIR:-$(cfg_get steam.prefix_dir "")}"
  [[ -z "$PREFIX_DIR" ]] && PREFIX_DIR="$(cfg_get steam.compatdata_dir "")"
  PREFIX_SELECT="${PREFIX_SELECT:-$(cfg_get steam.prefix_select first)}"
  PROTON_DIR="${PROTON_DIR:-$(cfg_get proton.dir "")}"
  PROTON_SELECT="${PROTON_SELECT:-$(cfg_get proton.select newest)}"
  INTERACTIVE_UI="${INTERACTIVE_UI:-$(cfg_get interactive.ui "$DEFAULT_INTERACTIVE_UI")}"

  SHARED_ENABLED="$(cfg_get shared_data.enabled "$SHARED_ENABLED")"
  SOURCE_PREFIX="$(cfg_get shared_data.source_prefix "$SOURCE_PREFIX")"
  SHARED_STRATEGY="$(cfg_get shared_data.strategy "$SHARED_STRATEGY")"

  EDCOPILOT_MODE="${EDCOPILOT_MODE:-$(cfg_get edcopilot.mode auto)}"
  EDCOPILOT_DELAY="${EDCOPILOT_DELAY:-$(cfg_get edcopilot.delay $DEFAULT_EDCOPILOT_DELAY)}"
  EDCOPILOT_BUS_WAIT="${EDCOPILOT_BUS_WAIT:-$(cfg_get edcopilot.bus_wait $DEFAULT_EDCOPILOT_BUS_WAIT)}"
  EDCOPILOT_TIMEOUT="${EDCOPILOT_TIMEOUT:-$(cfg_get edcopilot.timeout $DEFAULT_EDCOPILOT_TIMEOUT)}"

  PULSE_LATENCY="${PULSE_LATENCY:-$(cfg_get perf.pulse_latency_msec "$DEFAULT_PULSE_LATENCY") }"
  GPU_FILTER="${GPU_FILTER:-$(cfg_get perf.dxvk_filter_device_name "$DEFAULT_GPU_FILTER") }"
  DXVK_CAP="${DXVK_CAP:-$(cfg_get perf.dxvk_frame_rate "$DEFAULT_DXVK_CAP") }"
  INSTANCE_MODE="${INSTANCE_MODE:-$(cfg_get instances.mode split)}"
}

select_paths() {
  STEAM_ROOT=""
  while IFS= read -r s; do
    STEAM_ROOT="$s"; break
  done < <(discover_steam_roots)
  [[ -z "$STEAM_ROOT" ]] && STEAM_ROOT="$DEFAULT_STEAM_ROOT_HINT"

  PREFIX_CANDIDATES=()
  if [[ -n "$PREFIX_DIR" ]]; then
    if [[ -d "$PREFIX_DIR/pfx" ]]; then PREFIX_CANDIDATES+=("$PREFIX_DIR/pfx")
    elif [[ -d "$PREFIX_DIR" && "$(basename "$PREFIX_DIR")" == "pfx" ]]; then PREFIX_CANDIDATES+=("$PREFIX_DIR")
    else
      while IFS= read -r c; do [[ -n "$c" ]] && PREFIX_CANDIDATES+=("$c"); done < <(scan_prefix_candidates "$PREFIX_DIR")
    fi
  else
    local sr
    while IFS= read -r sr; do
      while IFS= read -r c; do [[ -n "$c" ]] && PREFIX_CANDIDATES+=("$c"); done < <(scan_prefix_candidates "$sr")
    done < <(discover_steam_roots)
    [[ -n "$DEFAULT_COMPATDATA_HINT" && -d "$DEFAULT_COMPATDATA_HINT/pfx" ]] && PREFIX_CANDIDATES+=("$DEFAULT_COMPATDATA_HINT/pfx")
  fi

  PROTON_CANDIDATES=()
  if [[ -n "$PROTON_DIR" ]]; then
    if [[ -x "$PROTON_DIR/proton" ]]; then PROTON_CANDIDATES+=("$PROTON_DIR")
    else
      while IFS= read -r c; do [[ -n "$c" ]] && PROTON_CANDIDATES+=("$c"); done < <(find "$PROTON_DIR" -mindepth 1 -maxdepth 2 -type f -name proton -printf '%h\n' 2>/dev/null || true)
    fi
  else
    while IFS= read -r c; do [[ -n "$c" ]] && PROTON_CANDIDATES+=("$c"); done < <(scan_proton_candidates)
  fi

  mapfile -t PREFIX_CANDIDATES < <(printf '%s\n' "${PREFIX_CANDIDATES[@]}" | awk 'NF && !seen[$0]++')
  mapfile -t PROTON_CANDIDATES < <(printf '%s\n' "${PROTON_CANDIDATES[@]}" | awk 'NF && !seen[$0]++')

  if (( INTERACTIVE == 1 )); then
    run_interactive "$INTERACTIVE_UI"
  fi

  if [[ -z "$PREFIX_DIR" ]]; then
    PREFIX_DIR="$(pick_candidate "$PREFIX_SELECT" "${PREFIX_CANDIDATES[@]}")"
  fi
  if [[ -z "$PROTON_DIR" ]]; then
    PROTON_DIR="$(pick_candidate "$PROTON_SELECT" "${PROTON_CANDIDATES[@]}")"
  fi

  [[ -d "$PREFIX_DIR" ]] || die "no valid prefix selected"
  [[ -x "$PROTON_DIR/proton" ]] || die "no valid proton selected"

  PROTON="$PROTON_DIR/proton"
  PROTON_WINE="$PROTON_DIR/files/bin/wine"
  APPID="${SteamGameId:-${SteamAppId:-$DEFAULT_APPID}}"
  if [[ "$APPID" == "" && "$PREFIX_DIR" =~ compatdata/([0-9]+)/pfx$ ]]; then APPID="${BASH_REMATCH[1]}"; fi

  GAME_PFX="$PREFIX_DIR"
  TOOL_PFX="$PREFIX_DIR"
  if [[ "$INSTANCE_MODE" == "split" ]]; then
    local split_root="$(dirname "$PREFIX_DIR")/${APPID}_tools/pfx"
    mkdir -p "$split_root"
    TOOL_PFX="$split_root"
  fi
}

setup_logging_env() {
  mkdir -p "$LOG_DIR"
  local run_id
  run_id="$(date +%Y%m%d_%H%M%S)_$$"
  COORD_LOG="$LOG_DIR/coordinator_${run_id}.log"
  touch "$COORD_LOG"
  if (( DEBUG == 1 )); then
    LOG_FILE="/tmp/ed_launcher_debug_${run_id}.log"
    export WINEDEBUG="-all,+seh,+err,+mscoree,+loaddll"
  else
    export WINEDEBUG="-all"
  fi

  export WINEFSYNC="$(cfg_get wine.fsync 1)"
  export WINEESYNC="$(cfg_get wine.esync 1)"
  export SDL_JOYSTICK_DISABLE="$(cfg_get input.sdl_joystick_disable 1)"
  export SDL_GAMECONTROLLER_DISABLE="$(cfg_get input.sdl_gamecontroller_disable 1)"
  export PYGAME_FORCE_JOYSTICK="$(cfg_get input.pygame_force_joystick 0)"
  export WINEDLLOVERRIDES="$(cfg_get wine.dll_overrides 'dinput=n;dinput8=n;hid=n;hidraw=n')"
  export PULSE_LATENCY_MSEC="$PULSE_LATENCY"
  export DXVK_FILTER_DEVICE_NAME="$GPU_FILTER"
  export DXVK_FRAME_RATE="$DXVK_CAP"

  unset __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus
  if [[ -n "${WAYLAND_DISPLAY:-}" && -z "${PROTON_ENABLE_WAYLAND:-}" ]]; then
    export PROTON_ENABLE_WAYLAND=1
    WAYLAND_DECISION="enabled"
  else
    WAYLAND_DECISION="unchanged"
  fi

  if [[ -f "/usr/share/vulkan/icd.d/nvidia_icd.json" && "${VK_ICD_MODE}" == "auto" ]]; then
    export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.json"
    ICD_DECISION="nvidia"
  else
    ICD_DECISION="default"
  fi
}

steam_mode_detect() {
  if (( ${#FORWARDED_CMD[@]} > 0 )); then
    if printf '%s\n' "${FORWARDED_CMD[@]}" | rg -q '^%command%$'; then
      warn "literal %command% detected in terminal invocation; ignoring forwarded tokens"
      FORWARDED_CMD=()
      MODE="terminal"
    else
      MODE="steam"
    fi
  else
    MODE="terminal"
  fi
}

launch_game() {
  local mined_exe="${MINED_EXE:-$PWD/MinEdLauncher.exe}"
  local mined_native="${MINED_NATIVE:-$PWD/MinEdLauncher}"
  local game_exe="${GAME_EXE:-$PWD/EliteDangerous64.exe}"
  local profile_arg="${PROFILE_NAME:-default}"

  if (( NO_GAME == 1 )); then
    log INFO "no-game mode enabled; skipping game launch"
    return 0
  fi

  if (( NO_MINED == 1 )); then
    log INFO "Launching game directly via proton"
    local g_log="$LOG_DIR/game_direct.log"
    launch_detached_logged "$g_log" env STEAM_COMPAT_DATA_PATH="$GAME_PFX" "$PROTON" run "$game_exe" >/dev/null
  else
    if [[ "$MODE" == "steam" && -x "$mined_native" ]]; then
      log INFO "Steam mode + native MinEdLauncher selected"
      local m_log="$LOG_DIR/mined_native.log"
      launch_detached_logged "$m_log" env STEAM_COMPAT_DATA_PATH="$GAME_PFX" "${FORWARDED_CMD[@]}" "$mined_native" /autorun /autoquit /edo /frontier "$profile_arg" >/dev/null
    else
      log INFO "Launching MinEdLauncher.exe under Proton"
      local m_log="$LOG_DIR/mined_proton.log"
      local cmd=(env STEAM_COMPAT_DATA_PATH="$GAME_PFX" "$PROTON" run "$mined_exe" /autorun /autoquit /edo /frontier "$profile_arg")
      if (( DEBUG == 1 )); then
        launch_detached_logged "$m_log" "${cmd[@]}" >/dev/null
      else
        launch_detached_logged "$m_log" "${cmd[@]}" >/dev/null
      fi
    fi
  fi

  if pid=$(wait_stable_proc 'EliteDangerous64.exe' "$TIMEOUT" "$STABLE_SECS"); then
    log INFO "EliteDangerous64.exe stable PID=$pid"
  else
    die "Game never reached stable running state within ${TIMEOUT}s"
  fi
}

wait_for_bus_name() {
  local bus_name="$1" timeout="$2"
  command -v busctl >/dev/null 2>&1 || return 2
  local start now
  start=$(date +%s)
  while true; do
    if busctl --user list 2>/dev/null | awk '{print $1}' | rg -q "^${bus_name}$"; then
      return 0
    fi
    now=$(date +%s)
    (( now - start >= timeout )) && return 1
    sleep 1
  done
}

launch_edcopilot_runtime() {
  local exe="$1" logf="$2" bus_name="$3"
  runtime_client_detect || return 11
  wait_for_bus_name "$bus_name" "$EDCOPILOT_BUS_WAIT" || return $?
  [[ -x "$PROTON_WINE" ]] || return 12

  launch_detached_logged "$logf" env \
    STEAM_COMPAT_DATA_PATH="$TOOL_PFX" \
    SteamGameId="$APPID" \
    SteamAppId="$APPID" \
    WINEDEBUG="$WINEDEBUG" \
    WINEFSYNC="$WINEFSYNC" \
    WINEESYNC="$WINEESYNC" \
    "$RUNTIME_CLIENT" --bus-name="$bus_name" -- "$PROTON_WINE" "$exe" >/dev/null
}

launch_edcopilot_proton() {
  local exe="$1" logf="$2"
  launch_detached_logged "$logf" env STEAM_COMPAT_DATA_PATH="$TOOL_PFX" "$PROTON" run "$exe" >/dev/null
}

launch_edcopilot() {
  (( NO_EDCOPILOT == 1 )) && { log INFO "EDCoPilot disabled"; return 0; }
  local exe="${EDCOPILOT_EXE:-$PWD/LaunchEDCoPilot.exe}"
  sleep "$EDCOPILOT_DELAY"
  local bus_name="com.steampowered.App${APPID}"
  local logf="$LOG_DIR/edcopilot.log"
  local selected="${EDCOPILOT_MODE,,}"

  case "$selected" in
    runtime)
      if ! launch_edcopilot_runtime "$exe" "$logf" "$bus_name"; then
        die "EDCoPilot runtime mode failed"
      fi
      ;;
    proton)
      launch_edcopilot_proton "$exe" "$logf"
      ;;
    auto)
      if launch_edcopilot_runtime "$exe" "$logf" "$bus_name"; then
        log INFO "EDCoPilot mode selected: runtime (auto)"
      else
        warn "EDCoPilot runtime unavailable; falling back to proton"
        launch_edcopilot_proton "$exe" "$logf"
      fi
      ;;
    *) die "invalid --edcopilot-mode: $selected" ;;
  esac

  if wait_stable_proc 'EDCoPilotGUI2.exe' "$EDCOPILOT_TIMEOUT" 2 >/dev/null; then
    log INFO "EDCoPilot detected"
  else
    warn "EDCoPilot process not detected in ${EDCOPILOT_TIMEOUT}s; tailing log"
    tail -n 30 "$logf" >> "$COORD_LOG" 2>/dev/null || true
  fi
}

launch_extra_tools() {
  local idx=0
  local tool
  for tool in "${TOOLS[@]}"; do
    idx=$((idx+1))
    local tlog="$LOG_DIR/tool_${idx}.log"
    launch_detached_logged "$tlog" env STEAM_COMPAT_DATA_PATH="$TOOL_PFX" "$PROTON" run "$tool" >/dev/null
    log INFO "launched tool[$idx]=$tool log=$tlog prefix=$TOOL_PFX"
  done
}

monitor_game_lifetime() {
  (( NO_MONITOR == 1 )) && return 0
  if (( NO_GAME == 0 )); then
    log INFO "monitoring game lifetime (Ctrl+C to exit)"
    while pgrep -f 'EliteDangerous64.exe' >/dev/null 2>&1; do sleep 5; done
    log INFO "game exited"
  fi
}

plan_summary() {
  log INFO "Plan: appid=$APPID mode=$MODE profile=${PROFILE_NAME:-none} instance_mode=$INSTANCE_MODE"
  log INFO "Paths: steam_root=$STEAM_ROOT proton=$PROTON prefix_game=$GAME_PFX prefix_tools=$TOOL_PFX"
  log INFO "Launch: no_game=$NO_GAME no_mined=$NO_MINED no_edcopilot=$NO_EDCOPILOT tools=${#TOOLS[@]} wait_tools=$WAIT_TOOLS"
  log INFO "EDCoPilot: mode=$EDCOPILOT_MODE delay=$EDCOPILOT_DELAY bus_wait=$EDCOPILOT_BUS_WAIT timeout=$EDCOPILOT_TIMEOUT runtime_client=${RUNTIME_CLIENT:-not-detected}"
  log INFO "Perf: PULSE_LATENCY_MSEC=$PULSE_LATENCY_MSEC DXVK_FILTER_DEVICE_NAME=$DXVK_FILTER_DEVICE_NAME DXVK_FRAME_RATE=$DXVK_FRAME_RATE PROTON_ENABLE_WAYLAND=${PROTON_ENABLE_WAYLAND:-0} VK_ICD=$ICD_DECISION"
  log INFO "Prime cleanup: __NV_PRIME_RENDER_OFFLOAD/__GLX_VENDOR_LIBRARY_NAME/__VK_LAYER_NV_optimus unset"
  (( DEBUG == 1 )) && log INFO "Debug enabled WINEDEBUG=$WINEDEBUG debug_log=$LOG_FILE"
  log INFO "Coordinator log: $COORD_LOG"
}

main() {
  parse_args "$@"
  load_config_and_profile
  select_paths
  setup_logging_env
  steam_mode_detect
  plan_summary

  if (( NO_GAME == 1 )) && (( WAIT_TOOLS == 0 )); then
    CLEANUP_ON_EXIT=0
  fi

  apply_shared_bridge

  if (( NO_GAME == 0 )); then
    launch_game
    launch_edcopilot
  else
    log INFO "tools-only mode active"
    if (( NO_EDCOPILOT == 0 )); then launch_edcopilot; fi
  fi

  launch_extra_tools

  if (( NO_GAME == 1 )) && (( WAIT_TOOLS == 1 )); then
    log INFO "waiting for tools due to --wait-tools"
    while true; do
      sleep 5
      local alive=0
      local pg
      for pg in "${TOOL_PGIDS[@]}"; do
        if kill -0 "-$pg" 2>/dev/null; then alive=1; break; fi
      done
      (( alive == 1 )) || break
    done
  fi

  monitor_game_lifetime
}

main "$@"
