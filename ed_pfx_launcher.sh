#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================
# ed_pfx_launcher.sh
# Feature-complete, Steam-safe Elite Dangerous + EDCoPilot launcher
#
# Key design:
# - Steam entrypoint spawns a detached watcher, then execs into the game
#   so Steam sees the correct running PID (prevents STOP hang).
# - Watcher orchestrates EDCoPilot/tools + shutdown.
# - Configurable via ed_pfx_launcher.ini.
# ============================================================

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Logging
# ----------------------------
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
DEFAULT_LOG_DIR="$STATE_HOME/ed_pfx_launcher/logs"
mkdir -p "$DEFAULT_LOG_DIR"

MAIN_LOG="$DEFAULT_LOG_DIR/main.log"
WATCHER_LOG="$DEFAULT_LOG_DIR/watcher.log"

_ts() { date +'%H:%M:%S'; }
log()  { echo "[$(_ts)] $*" | tee -a "$MAIN_LOG" >/dev/null; }
warn() { echo "[$(_ts)] WARN: $*" | tee -a "$MAIN_LOG" >&2 >/dev/null; }
die()  { echo "[$(_ts)] ERROR: $*" | tee -a "$MAIN_LOG" >&2 >/dev/null; exit 1; }

# Watcher logging (separate file)
wlog()  { echo "[$(_ts)] $*" | tee -a "$WATCHER_LOG" >/dev/null; }
wwarn() { echo "[$(_ts)] WARN: $*" | tee -a "$WATCHER_LOG" >&2 >/dev/null; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Defaults / CLI state
# ----------------------------
CONFIG_PATH="$SCRIPT_DIR/ed_pfx_launcher.ini"
NO_GAME=0
WAIT_TOOLS=0
VERBOSE=1
DRY_RUN=0
WATCHER_MODE=0

# When invoked by watcher, we pass a couple explicit args
WATCHER_GAME_PID=""
WATCHER_LAUNCH_MODE=""

# CLI tool list (in addition to INI tools)
declare -a CLI_TOOLS=()

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME [--config <ini>] [--no-game] [--wait-tools] [--tool <exe>]... [--dry-run] [--] %command%

Steam Launch Options (single line):
  "/ABS/PATH/$SCRIPT_NAME" --config "/ABS/PATH/ed_pfx_launcher.ini" -- %command%

Options:
  --config <path>      Path to ed_pfx_launcher.ini (default: $CONFIG_PATH)
  --tool <exe>         Add a tool exe path (repeatable)
  --no-game            Tools-only mode
  --wait-tools         With --no-game: keep script attached until tools exit
  --dry-run            Print decisions, don't launch
  --watcher            Internal: watcher mode (do not call directly)
  -h, --help
EOF
}

# Parse args
FORWARDED_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    --tool) CLI_TOOLS+=( "${2:-}" ); shift 2;;
    --no-game) NO_GAME=1; shift;;
    --wait-tools) WAIT_TOOLS=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --watcher)
      WATCHER_MODE=1
      WATCHER_GAME_PID="${2:-}"; shift 2
      WATCHER_LAUNCH_MODE="${2:-}"; shift 2
      ;;
    -h|--help) usage; exit 0;;
    --) shift; FORWARDED_CMD=( "$@" ); break;;
    *)
      # If user forgets -- and this is %command% expansion, it'll look like a path.
      # We accept it as forwarded cmd if it looks executable-ish.
      FORWARDED_CMD+=( "$1" ); shift;;
  esac
done

# Ensure log files exist
: > "$MAIN_LOG" || true
: > "$WATCHER_LOG" || true

log "Starting: $SCRIPT_NAME"
log "CONFIG=$CONFIG_PATH"

# ----------------------------
# INI parsing
# ----------------------------
# We store keys as CFG["section.key"]
declare -A CFG=()

_trim() {
  local s="$1"
  # remove leading/trailing whitespace
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_strip_inline_comment() {
  local s="$1"
  local out=""
  local in_sq=0
  local in_dq=0
  local i ch prev
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    prev=""
    if (( i > 0 )); then prev="${s:i-1:1}"; fi

    if [[ "$ch" == "'" && $in_dq -eq 0 ]]; then
      in_sq=$((1-in_sq))
    elif [[ "$ch" == '"' && $in_sq -eq 0 ]]; then
      in_dq=$((1-in_dq))
    fi

    if (( in_sq == 0 && in_dq == 0 )); then
      if [[ ( "$ch" == ";" || "$ch" == "#" ) && ( $i -eq 0 || "$prev" =~ [[:space:]] ) ]]; then
        break
      fi
    fi
    out+="$ch"
  done
  printf '%s' "$out"
}

_unquote() {
  local s="$1"
  if [[ "$s" =~ ^".*"$ ]]; then
    s="${s:1:${#s}-2}"
  elif [[ "$s" =~ ^'.*'$ ]]; then
    s="${s:1:${#s}-2}"
  fi
  printf '%s' "$s"
}

ini_load() {
  local file="$1"
  [[ -f "$file" ]] || die "Config not found: $file"

  local section=""
  local line raw key val

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(_trim "$raw")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \;* || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^\[[^\]]+\]$ ]]; then
      section="${line:1:${#line}-2}"
      section="${section,,}"
      continue
    fi

    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      key="$(_trim "$key")"
      val="$(_trim "$val")"
      val="$(_strip_inline_comment "$val")"
      val="$(_trim "$val")"
      val="$(_unquote "$val")"
      key="${key,,}"
      if [[ -n "$section" && -n "$key" ]]; then
        CFG["$section.$key"]="$val"
      fi
    fi
  done < "$file"
}

cfg_get() {
  local k="$1"
  local def="${2:-}"
  local v="${CFG[$k]:-$def}"
  printf '%s' "$v"
}

# Expand {tokens} in values
expand_tokens() {
  local s="$1"
  local home="$HOME"
  local appid="$2"
  local steam_root="$3"
  local compatdata="$4"
  local prefix="$5"

  s="${s//\{home\}/$home}"
  s="${s//\{appid\}/$appid}"
  s="${s//\{steam_root\}/$steam_root}"
  s="${s//\{compatdata\}/$compatdata}"
  s="${s//\{prefix\}/$prefix}"
  printf '%s' "$s"
}

# ----------------------------
# Detection helpers
# ----------------------------
detect_steam_root() {
  local c
  c="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
  if [[ -n "$c" && -d "$c" ]]; then printf '%s' "$c"; return 0; fi

  if [[ -d "$HOME/.local/share/Steam" ]]; then printf '%s' "$HOME/.local/share/Steam"; return 0; fi
  if [[ -d "$HOME/.steam/debian-installation" ]]; then printf '%s' "$HOME/.steam/debian-installation"; return 0; fi

  if [[ -e "$HOME/.steam/root" ]]; then
    c="$(readlink -f "$HOME/.steam/root" 2>/dev/null || true)"
    [[ -n "$c" && -d "$c" ]] && { printf '%s' "$c"; return 0; }
  fi

  if [[ -d "$HOME/.steam/steam" ]]; then printf '%s' "$HOME/.steam/steam"; return 0; fi

  return 1
}

detect_runtime_client() {
  local steam_root="$1"
  local p
  # common location
  p="$steam_root/steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client"
  [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }

  # other runtimes (soldier/sniper variations)
  for p in "$steam_root"/steamapps/common/SteamLinuxRuntime_*/pressure-vessel/bin/steam-runtime-launch-client; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

bus_available() {
  local bus="$1"
  have busctl || return 1
  busctl --user list 2>/dev/null | awk '{print $1}' | grep -qx "$bus"
}

wait_for_bus() {
  local bus="$1" timeout="$2"
  local i=0
  while (( i < timeout )); do
    bus_available "$bus" && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

# Find libraryfolders.vdf paths containing appid
vdf_library_paths_for_appid() {
  local vdf="$1" appid="$2"
  [[ -f "$vdf" ]] || return 0

  awk -v appid="$appid" '
    /"path"/ {
      p=$2; gsub(/"/,"",p)
      current_path=p
    }
    /"apps"/ { in_apps=1 }
    in_apps && $1 ~ "\""appid"\"" {
      print current_path
    }
    /}/ && in_apps { in_apps=0 }
  ' "$vdf" | sort -u
}

# Try to locate Elite install dir and MinEdLauncher.exe
find_mined_exe() {
  local appid="$1" steam_root="$2" library_vdf="$3"

  # Most common
  if [[ -f "$steam_root/steamapps/common/Elite Dangerous/MinEdLauncher.exe" ]]; then
    printf '%s' "$steam_root/steamapps/common/Elite Dangerous/MinEdLauncher.exe"; return 0
  fi

  # Check libraries
  local lp
  while IFS= read -r lp; do
    [[ -z "$lp" ]] && continue
    if [[ -f "$lp/steamapps/common/Elite Dangerous/MinEdLauncher.exe" ]]; then
      printf '%s' "$lp/steamapps/common/Elite Dangerous/MinEdLauncher.exe"; return 0
    fi
  done < <(vdf_library_paths_for_appid "$library_vdf" "$appid")

  return 1
}

# Find Proton path from compatdata/config_info if possible
find_proton_from_config_info() {
  local compatdata="$1"
  local cfg="$compatdata/config_info"
  [[ -f "$cfg" ]] || return 1

  local line
  line="$(grep -m1 -E '/(common|compatibilitytools\.d)/[^[:space:]"]+/proton' "$cfg" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    # extract path containing .../proton
    local p
    p="$(echo "$line" | grep -oE '/(common|compatibilitytools\.d)/[^[:space:]"]+/proton' | head -n1)"
    [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  fi

  return 1
}

# Find Proton path by searching common locations
find_proton_fallback() {
  local steam_root="$1"

  # Prefer GE-Proton if present
  local d
  for d in "$HOME/.steam/steam/compatibilitytools.d" "$steam_root/compatibilitytools.d" "$steam_root/steamapps/compatibilitytools.d"; do
    if [[ -d "$d" ]]; then
      local p
      p="$(ls -1d "$d"/*/proton 2>/dev/null | head -n1 || true)"
      [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
    fi
  done

  # Steam shipped Proton
  local p
  p="$(ls -1d "$steam_root"/steamapps/common/Proton*/*/proton 2>/dev/null | head -n1 || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }

  p="$(ls -1d "$steam_root"/steamapps/common/Proton*/proton 2>/dev/null | head -n1 || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }

  return 1
}

# Detect game running
is_elite_running() {
  pgrep -f 'EliteDangerous64\.exe' >/dev/null 2>&1 && return 0
  pgrep -f 'EDLaunch\.exe' >/dev/null 2>&1 && return 0
  return 1
}

# Find a PID to monitor (launcher or game)
detect_elite_pid() {
  local pid
  pid="$(pgrep -f 'EliteDangerous64\.exe' | head -n1 || true)"
  [[ -n "$pid" ]] && { printf '%s' "$pid"; return 0; }
  pid="$(pgrep -f 'EDLaunch\.exe' | head -n1 || true)"
  [[ -n "$pid" ]] && { printf '%s' "$pid"; return 0; }
  printf '%s' ""
}

# ----------------------------
# Load INI
# ----------------------------
ini_load "$CONFIG_PATH"

# ----------------------------
# Resolve core paths
# ----------------------------
APPID="$(cfg_get 'steam.appid' "${SteamGameId:-${SteamAppId:-359320}}")"
[[ "$APPID" =~ ^[0-9]+$ ]] || die "steam.appid must be numeric (got: $APPID)"
BUS_NAME="com.steampowered.App$APPID"

STEAM_ROOT="$(cfg_get 'steam.steam_root' "")"
if [[ -z "$STEAM_ROOT" ]]; then
  STEAM_ROOT="$(detect_steam_root || true)"
fi
[[ -n "$STEAM_ROOT" && -d "$STEAM_ROOT" ]] || die "Could not detect Steam root. Set [steam] steam_root in INI."

COMPATDATA_DIR="$(cfg_get 'steam.compatdata_dir' "${STEAM_COMPAT_DATA_PATH:-}")"
if [[ -z "$COMPATDATA_DIR" ]]; then
  COMPATDATA_DIR="$STEAM_ROOT/steamapps/compatdata/$APPID"
fi
[[ -d "$COMPATDATA_DIR" ]] || die "Compatdata not found: $COMPATDATA_DIR (set [steam] compatdata_dir)"

WINEPREFIX="$COMPATDATA_DIR/pfx"
[[ -d "$WINEPREFIX" ]] || die "WINEPREFIX not found: $WINEPREFIX"

LIBVDF="$(cfg_get 'steam.libraryfolders_vdf' "")"
[[ -z "$LIBVDF" ]] && LIBVDF="$STEAM_ROOT/config/libraryfolders.vdf"

RUNTIME_CLIENT="$(cfg_get 'steam.runtime_client' "")"
if [[ -z "$RUNTIME_CLIENT" ]]; then
  RUNTIME_CLIENT="$(detect_runtime_client "$STEAM_ROOT" || true)"
fi

PROTON_BIN="$(cfg_get 'proton.proton' "")"
if [[ -z "$PROTON_BIN" ]]; then
  PROTON_BIN="$(find_proton_from_config_info "$COMPATDATA_DIR" || true)"
fi
if [[ -z "$PROTON_BIN" ]]; then
  PROTON_BIN="$(find_proton_fallback "$STEAM_ROOT" || true)"
fi
[[ -n "$PROTON_BIN" && -x "$PROTON_BIN" ]] || die "Could not find Proton 'proton' binary. Set [proton] proton in INI."

PROTON_DIR="$(dirname "$PROTON_BIN")"
WINELOADER="$PROTON_DIR/files/bin/wine"
WINESERVER="$PROTON_DIR/files/bin/wineserver"
[[ -x "$WINELOADER" ]] || die "WINELOADER not executable: $WINELOADER"
[[ -x "$WINESERVER" ]] || warn "WINESERVER not executable: $WINESERVER (cleanup may be reduced)"

# ----------------------------
# Perf + environment
# ----------------------------
DXVK_FILTER_DEVICE_NAME="$(cfg_get 'perf.dxvk_filter_device_name' "${DXVK_FILTER_DEVICE_NAME:-}")"
DXVK_FRAME_RATE="$(cfg_get 'perf.dxvk_frame_rate' "${DXVK_FRAME_RATE:-}")"
PULSE_LATENCY_MSEC="$(cfg_get 'perf.pulse_latency_msec' "${PULSE_LATENCY_MSEC:-90}")"
PROTON_ENABLE_WAYLAND="$(cfg_get 'perf.proton_enable_wayland' "${PROTON_ENABLE_WAYLAND:-}")"

# Unset laptop/offload vars
unset __NV_PRIME_RENDER_OFFLOAD
unset __GLX_VENDOR_LIBRARY_NAME
unset __VK_LAYER_NV_optimus

[[ -n "$DXVK_FILTER_DEVICE_NAME" ]] && export DXVK_FILTER_DEVICE_NAME="$DXVK_FILTER_DEVICE_NAME"
[[ -n "$DXVK_FRAME_RATE" ]] && export DXVK_FRAME_RATE="$DXVK_FRAME_RATE"
export PULSE_LATENCY_MSEC="$PULSE_LATENCY_MSEC"

# Wayland hint (if already in Wayland session)
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  [[ -n "$PROTON_ENABLE_WAYLAND" ]] && export PROTON_ENABLE_WAYLAND="$PROTON_ENABLE_WAYLAND"
fi

# Steam/Proton env that helps tools launched outside Steam context
export WINEPREFIX="$WINEPREFIX"
export STEAM_COMPAT_DATA_PATH="$COMPATDATA_DIR"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
export SteamGameId="$APPID"

WINDEBUG="$(cfg_get 'debug.winedebug' 'false')"
if [[ "$WINDEBUG" == "true" ]]; then
  export WINEDEBUG="+fixme,+err,+loaddll,+warn"
else
  export WINEDEBUG="-all"
fi

# ----------------------------
# Elite config
# ----------------------------
ELITE_LAUNCH_MODE="$(cfg_get 'elite.launch_mode' 'auto')"   # auto|steam|mined
TERMINAL_MODE="$(cfg_get 'elite.terminal_mode' 'auto')"     # auto|mined|steam_applaunch|command
ELITE_PROFILE="$(cfg_get 'elite.profile' 'default')"
ELITE_MINED_FLAGS="$(cfg_get 'elite.mined_flags' '/autorun /autoquit /edo')"
ELITE_MONITOR_GAME="$(cfg_get 'elite.monitor_game' 'true')"
HOTAS_FIX_ENABLED="$(cfg_get 'elite.hotas_fix_enabled' 'false')"

# ----------------------------
# EDCoPilot config
# ----------------------------
EDCOPILOT_ENABLED="$(cfg_get 'edcopilot.enabled' 'true')"
EDCOPILOT_MODE="$(cfg_get 'edcopilot.mode' 'auto')"         # auto|runtime|wine
EDCOPILOT_DELAY="$(cfg_get 'edcopilot.delay' '30')"
EDCOPILOT_BUS_WAIT="$(cfg_get 'edcopilot.bus_wait' '30')"
EDCOPILOT_INIT_TIMEOUT="$(cfg_get 'edcopilot.init_timeout' '45')"
EDCOPILOT_RETRIES="$(cfg_get 'edcopilot.retries' '3')"
EDCOPILOT_RETRY_SLEEP="$(cfg_get 'edcopilot.retry_sleep' '3')"
EDCOPILOT_FORCE_LINUX_FLAG="$(cfg_get 'edcopilot.force_linux_flag' 'true')"
EDCOPILOT_STANDALONE="$(cfg_get 'edcopilot.standalone' 'true')"
EDCOPILOT_EXE_ABS="$(cfg_get 'edcopilot.exe' '')"
EDCOPILOT_EXE_REL="$(cfg_get 'edcopilot.exe_rel' 'drive_c/EDCoPilot/LaunchEDCoPilot.exe')"

# EDCoPTER config (optional)
EDCOPTER_ENABLED="$(cfg_get 'edcopter.enabled' 'false')"
EDCOPTER_MODE="$(cfg_get 'edcopter.mode' 'auto')"
EDCOPTER_EXE_ABS="$(cfg_get 'edcopter.exe' '')"
EDCOPTER_EXE_REL="$(cfg_get 'edcopter.exe_rel' '')"
EDCOPTER_HEADLESS="$(cfg_get 'edcopter.headless' 'false')"
EDCOPTER_LISTEN_IP="$(cfg_get 'edcopter.listen_ip' '')"
EDCOPTER_LISTEN_PORT="$(cfg_get 'edcopter.listen_port' '')"
EDCOPTER_EDCOPILOT_IP="$(cfg_get 'edcopter.edcopilot_ip' '')"
EDCOPTER_ARGS_EXTRA="$(cfg_get 'edcopter.args_extra' '')"

# Expand tokens for exe paths
EDCOPILOT_EXE=""
if [[ -n "$EDCOPILOT_EXE_ABS" ]]; then
  EDCOPILOT_EXE="$(expand_tokens "$EDCOPILOT_EXE_ABS" "$APPID" "$STEAM_ROOT" "$COMPATDATA_DIR" "$WINEPREFIX")"
else
  EDCOPILOT_EXE="$WINEPREFIX/$EDCOPILOT_EXE_REL"
fi

EDCOPTER_EXE=""
if [[ -n "$EDCOPTER_EXE_ABS" ]]; then
  EDCOPTER_EXE="$(expand_tokens "$EDCOPTER_EXE_ABS" "$APPID" "$STEAM_ROOT" "$COMPATDATA_DIR" "$WINEPREFIX")"
elif [[ -n "$EDCOPTER_EXE_REL" ]]; then
  EDCOPTER_EXE="$WINEPREFIX/$EDCOPTER_EXE_REL"
fi

# ----------------------------
# Tool sections: [tool.<name>]
# ----------------------------
# We discover any CFG keys beginning with "tool." and group them.
declare -A TOOL_NAMES=()
for k in "${!CFG[@]}"; do
  if [[ "$k" == tool.*.* ]]; then
    # tool.<name>.<key>
    local_part="${k#tool.}"
    name="${local_part%%.*}"
    TOOL_NAMES["$name"]=1
  fi
done

# ----------------------------
# Validation / summary
# ----------------------------
log "Config summary:"
log "  CONFIG=$CONFIG_PATH"
log "  APPID=$APPID"
log "  BUS_NAME=$BUS_NAME"
log "  STEAM_ROOT=$STEAM_ROOT"
log "  COMPATDATA_DIR=$COMPATDATA_DIR"
log "  WINEPREFIX=$WINEPREFIX"
log "  PROTON=$PROTON_BIN"
log "  WINELOADER=$WINELOADER"
log "  runtime_client=${RUNTIME_CLIENT:-<none>}"
log "  EDCOPILOT exe=$EDCOPILOT_EXE"
log "  EDCOPILOT mode=$EDCOPILOT_MODE delay=$EDCOPILOT_DELAY bus_wait=$EDCOPILOT_BUS_WAIT init_timeout=$EDCOPILOT_INIT_TIMEOUT retries=$EDCOPILOT_RETRIES"
log "  NO_GAME=$NO_GAME WAIT_TOOLS=$WAIT_TOOLS"
log "  LOG_DIR=$DEFAULT_LOG_DIR"

# CLI tools validation
for t in "${CLI_TOOLS[@]}"; do
  [[ -f "$t" ]] || die "CLI tool not found: $t"
done

# ----------------------------
# HOTAS fix helper
# ----------------------------
apply_hotas_fix() {
  # Implements the same concept you had: override windows.gaming.input to avoid HOTAS crash.
  # This is optional and only applied if enabled.
  local enabled="$1"

  if [[ "$enabled" != "true" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    wlog "DRY-RUN: would apply HOTAS fix (windows.gaming.input override)"
    return 0
  fi

  wlog "Applying HOTAS fix: setting windows.gaming.input DLL override"
  "$WINELOADER" reg add "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" /v "windows.gaming.input" /t REG_SZ /d "" /f >/dev/null 2>&1 || true
}

# ----------------------------
# EDCoPilot INI patch (RunningOnLinux)
# ----------------------------
patch_edcopilot_linux_flag() {
  local enabled="$1"
  local exe="$2"

  [[ "$enabled" == "true" ]] || return 0

  local dir
  dir="$(dirname "$exe")"
  local f1="$dir/EDCoPilot.ini"
  local f2="$dir/edcopilotgui.ini"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    wlog "DRY-RUN: would patch RunningOnLinux in: $f1 and $f2"
    return 0
  fi

  # Only patch if files exist
  if [[ -f "$f1" ]]; then
    # Preserve CRLF possibility by appending \r when replacing
    sed -i $'s/RunningOnLinux="0"/RunningOnLinux="1"\r/g' "$f1" || true
  fi
  if [[ -f "$f2" ]]; then
    sed -i $'s/RunningOnLinux="0"/RunningOnLinux="1"\r/g' "$f2" || true
  fi
}

# ----------------------------
# Tool launching helpers (watcher)
# ----------------------------
# We launch tools in separate process groups, so we can stop them cleanly.
declare -a TOOL_PGIDS=()

start_tool_wine_detached() {
  local exe="$1"
  local label="$2"
  local log_file="$DEFAULT_LOG_DIR/${label}.wine.log"
  local cwd
  cwd="$(dirname "$exe")"

  wlog "Launching (wine): $label"
  wlog "  exe: $exe"
  wlog "  cwd: $cwd"
  wlog "  log: $log_file"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  # setsid makes it independent from Steam/terminal session
  if have setsid; then
    setsid bash -lc "cd \"$cwd\" && exec \"$PROTON_BIN\" run \"$exe\"" >>"$log_file" 2>&1 < /dev/null &
    local pid=$!
    TOOL_PGIDS+=("$pid")
  else
    ( cd "$cwd" && "$PROTON_BIN" run "$exe" >>"$log_file" 2>&1 < /dev/null ) &
    TOOL_PGIDS+=("$!")
  fi
}

start_tool_runtime_detached() {
  local exe="$1"
  local label="$2"
  local log_file="$DEFAULT_LOG_DIR/${label}.runtime.log"
  local cwd
  cwd="$(dirname "$exe")"

  if [[ -z "${RUNTIME_CLIENT:-}" || ! -x "${RUNTIME_CLIENT:-}" ]]; then
    wwarn "Runtime client missing; cannot runtime-launch $label"
    return 1
  fi

  wlog "Launching (runtime): $label"
  wlog "  bus: $BUS_NAME"
  wlog "  runtime: $RUNTIME_CLIENT"
  wlog "  wine: $WINELOADER"
  wlog "  exe: $exe"
  wlog "  log: $log_file"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if have setsid; then
    setsid bash -lc "cd \"$cwd\" && exec \"$RUNTIME_CLIENT\" --bus-name=\"$BUS_NAME\" --pass-env-matching='WINE*' --pass-env-matching='STEAM*' --pass-env-matching='PROTON*' --env=SteamGameId=$APPID -- \"$WINELOADER\" \"$exe\"" >>"$log_file" 2>&1 < /dev/null &
    TOOL_PGIDS+=("$!")
  else
    ( cd "$cwd" && "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$exe" >>"$log_file" 2>&1 < /dev/null ) &
    TOOL_PGIDS+=("$!")
  fi
}

wait_for_process() {
  local pattern="$1" timeout="$2"
  local i=0
  while (( i < timeout )); do
    pgrep -f "$pattern" >/dev/null 2>&1 && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

stop_tools() {
  if [[ "${#TOOL_PGIDS[@]}" -eq 0 ]]; then
    return 0
  fi

  wlog "Stopping tools..."
  # First try graceful
  for pid in "${TOOL_PGIDS[@]}"; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 1
  # Then force
  for pid in "${TOOL_PGIDS[@]}"; do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
}

stop_wineserver() {
  if [[ -x "$WINESERVER" ]]; then
    wlog "Stopping wineserver..."
    "$WINESERVER" -k >/dev/null 2>&1 || true
    "$WINESERVER" -w >/dev/null 2>&1 || true
  fi
}

# Graceful EDCoPilot shutdown (optional)
request_edcopilot_shutdown() {
  local exe="$1"
  local dir
  dir="$(dirname "$exe")"
  local req="$dir/EDCoPilot.request.txt"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    wlog "DRY-RUN: would request EDCoPilot shutdown: $req"
    return 0
  fi

  if pgrep -f 'EDCoPilotGUI2\.exe' >/dev/null 2>&1; then
    wlog "Requesting EDCoPilot graceful shutdown"
    echo Shutdown >> "$req" || true
  fi
}

# ----------------------------
# Tool resolution from INI tool sections
# ----------------------------
# Each [tool.name] can specify:
# enabled=true/false
# kind=wine|runtime|auto|edcopilot|edcopter
# when=pre|post|always|standalone
# path=... (supports {prefix}, etc)

resolve_tool_path() {
  local name="$1"
  local raw
  raw="$(cfg_get "tool.$name.path" "")"
  [[ -n "$raw" ]] || { printf '%s' ""; return 0; }
  raw="$(expand_tokens "$raw" "$APPID" "$STEAM_ROOT" "$COMPATDATA_DIR" "$WINEPREFIX")"
  printf '%s' "$raw"
}

# ----------------------------
# Game launch command builder
# ----------------------------
# Returns: echoes a shell-escaped command line for logs
# Also sets two globals:
#   GAME_CMD_KIND = mined|steam|steam_applaunch
#   GAME_CMD_ARR  = array of argv to exec

GAME_CMD_KIND=""
declare -a GAME_CMD_ARR=()

split_words_to_array() {
  # naive split for flag strings (space-separated). we intentionally keep it simple.
  # If you need quoted values, set them via CLI rather than INI.
  local s="$1"
  local -n out="$2"
  out=()
  # shellcheck disable=SC2206
  out=( $s )
}

print_cmd() {
  printf '%q ' "$@"; printf '\n'
}

build_game_command() {
  local mode="$1"

  # If Steam passed us %command% expansion, it should be in FORWARDED_CMD.
  local have_forwarded=0
  if [[ "${#FORWARDED_CMD[@]}" -gt 0 ]]; then
    # If user ran from terminal and literally typed %command%, it will be literal.
    if [[ "${FORWARDED_CMD[0]:-}" != "%command%" ]]; then
      have_forwarded=1
    fi
  fi

  local mined_exe="$(cfg_get 'elite.mined_exe' '')"
  if [[ -z "$mined_exe" ]]; then
    mined_exe="$(find_mined_exe "$APPID" "$STEAM_ROOT" "$LIBVDF" || true)"
  fi

  local -a mined_flags
  split_words_to_array "$ELITE_MINED_FLAGS" mined_flags

  local -a mined_args
  mined_args=( "${mined_flags[@]}" "/frontier" "$ELITE_PROFILE" )

  if [[ "$mode" == "mined" || "$mode" == "auto" ]]; then
    if [[ -n "$mined_exe" && -f "$mined_exe" ]]; then
      GAME_CMD_KIND="mined"
      GAME_CMD_ARR=( "$PROTON_BIN" run "$mined_exe" "${mined_args[@]}" )
      return 0
    fi
  fi

  if [[ "$mode" == "steam" || "$mode" == "auto" ]]; then
    if (( have_forwarded == 1 )); then
      GAME_CMD_KIND="steam"
      GAME_CMD_ARR=( "${FORWARDED_CMD[@]}" )
      return 0
    fi
  fi

  # Terminal fallback
  local tmode="$TERMINAL_MODE"
  if [[ "$tmode" == "auto" ]]; then
    # prefer steam_applaunch if no mined
    tmode="steam_applaunch"
  fi

  if [[ "$tmode" == "steam_applaunch" ]]; then
    if have steam; then
      GAME_CMD_KIND="steam_applaunch"
      GAME_CMD_ARR=( steam -applaunch "$APPID" )
      return 0
    fi
  fi

  die "Unable to build game command. Set elite.mined_exe or provide -- %command% from Steam."
}

# ----------------------------
# Watcher main
# ----------------------------
watcher_main() {
  # Watcher gets its own log
  : > "$WATCHER_LOG" || true

  wlog "Watcher started"
  wlog "mode=$WATCHER_LAUNCH_MODE game_pid=${WATCHER_GAME_PID:-<none>}"

  # Optional HOTAS fix
  apply_hotas_fix "$HOTAS_FIX_ENABLED"

  # Generic tools: pre/always
  for name in "${!TOOL_NAMES[@]}"; do
    local enabled="$(cfg_get "tool.$name.enabled" "false")"
    [[ "$enabled" == "true" ]] || continue

    local when="$(cfg_get "tool.$name.when" "always")"
    local kind="$(cfg_get "tool.$name.kind" "auto")"
    local path
    path="$(resolve_tool_path "$name")"

    [[ -n "$path" && -f "$path" ]] || { wwarn "Tool $name path missing: $path"; continue; }

    if [[ "$when" == "pre" || "$when" == "always" ]]; then
      case "$kind" in
        runtime)
          start_tool_runtime_detached "$path" "tool_${name}" || start_tool_wine_detached "$path" "tool_${name}";;
        wine)
          start_tool_wine_detached "$path" "tool_${name}";;
        auto)
          # try runtime if bus is present quickly
          if bus_available "$BUS_NAME"; then
            start_tool_runtime_detached "$path" "tool_${name}" || start_tool_wine_detached "$path" "tool_${name}"
          else
            start_tool_wine_detached "$path" "tool_${name}"
          fi
          ;;
        *)
          start_tool_wine_detached "$path" "tool_${name}";;
      esac
    fi
  done

  # CLI tools: treat as pre tools unless they look like EDCoPilot
  for t in "${CLI_TOOLS[@]}"; do
    local base
    base="$(basename "$t")"
    if [[ "${base,,}" == *edcopilot* ]]; then
      continue
    fi
    start_tool_wine_detached "$t" "cli_${base//[^A-Za-z0-9._-]/_}"
  done

  # EDCoPilot
  if [[ "$EDCOPILOT_ENABLED" == "true" ]]; then
    if [[ -f "$EDCOPILOT_EXE" ]]; then
      patch_edcopilot_linux_flag "$EDCOPILOT_FORCE_LINUX_FLAG" "$EDCOPILOT_EXE"

      # If not standalone and game isn't running, skip
      if [[ "$EDCOPILOT_STANDALONE" != "true" && ! $(is_elite_running && echo true || echo false) ]]; then
        wwarn "EDCoPilot standalone disabled and Elite not running; skipping."
      else
        wlog "EDCoPilot delay=${EDCOPILOT_DELAY}s"
        sleep "$EDCOPILOT_DELAY" || true

        local attempt=1
        local launched=0
        while (( attempt <= EDCOPILOT_RETRIES )); do
          wlog "Launching EDCoPilot attempt $attempt/$EDCOPILOT_RETRIES (mode=$EDCOPILOT_MODE)"

          case "$EDCOPILOT_MODE" in
            runtime)
              if wait_for_bus "$BUS_NAME" "$EDCOPILOT_BUS_WAIT"; then
                start_tool_runtime_detached "$EDCOPILOT_EXE" "edcopilot" || true
              else
                wwarn "Runtime mode requested but bus not available after ${EDCOPILOT_BUS_WAIT}s: $BUS_NAME"
              fi
              ;;
            wine)
              start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot";;
            auto)
              # try runtime if bus appears within bus_wait, else wine
              if [[ -n "${RUNTIME_CLIENT:-}" && -x "${RUNTIME_CLIENT:-}" ]]; then
                if wait_for_bus "$BUS_NAME" "$EDCOPILOT_BUS_WAIT"; then
                  start_tool_runtime_detached "$EDCOPILOT_EXE" "edcopilot" || start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot"
                else
                  start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot"
                fi
              else
                start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot"
              fi
              ;;
            *)
              start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot";;
          esac

          # Wait for GUI
          if wait_for_process 'EDCoPilotGUI2\.exe' "$EDCOPILOT_INIT_TIMEOUT"; then
            wlog "EDCoPilot GUI detected."
            launched=1
            break
          else
            wwarn "EDCoPilot GUI not detected after ${EDCOPILOT_INIT_TIMEOUT}s"
            if (( attempt < EDCOPILOT_RETRIES )); then
              wlog "Retry sleep: ${EDCOPILOT_RETRY_SLEEP}s"
              sleep "$EDCOPILOT_RETRY_SLEEP" || true
            fi
          fi

          attempt=$((attempt+1))
        done

        if (( launched == 0 )); then
          wwarn "EDCoPilot did not reach GUI after retries. Check logs in: $DEFAULT_LOG_DIR"
        fi
      fi
    else
      wwarn "EDCoPilot enabled but exe not found: $EDCOPILOT_EXE"
    fi
  fi

  # EDCoPTER (optional)
  if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
    # Build args
    local -a args=()
    [[ "$EDCOPTER_HEADLESS" == "true" ]] && args+=("--headless")
    [[ -n "$EDCOPTER_LISTEN_IP" ]] && args+=("--ip" "$EDCOPTER_LISTEN_IP")
    [[ -n "$EDCOPTER_LISTEN_PORT" ]] && args+=("--port" "$EDCOPTER_LISTEN_PORT")
    [[ -n "$EDCOPTER_EDCOPILOT_IP" ]] && args+=("--edcopilot-ip" "$EDCOPTER_EDCOPILOT_IP")

    # extra args (simple split)
    if [[ -n "$EDCOPTER_ARGS_EXTRA" ]]; then
      local -a extra
      split_words_to_array "$EDCOPTER_ARGS_EXTRA" extra
      args+=("${extra[@]}")
    fi

    start_tool_wine_detached "$EDCOPTER_EXE" "edcopter"
  fi

  # Post tools
  for name in "${!TOOL_NAMES[@]}"; do
    local enabled="$(cfg_get "tool.$name.enabled" "false")"
    [[ "$enabled" == "true" ]] || continue

    local when="$(cfg_get "tool.$name.when" "always")"
    local kind="$(cfg_get "tool.$name.kind" "auto")"
    local path
    path="$(resolve_tool_path "$name")"

    [[ -n "$path" && -f "$path" ]] || continue

    if [[ "$when" == "post" ]]; then
      case "$kind" in
        runtime)
          start_tool_runtime_detached "$path" "tool_${name}" || start_tool_wine_detached "$path" "tool_${name}";;
        wine)
          start_tool_wine_detached "$path" "tool_${name}";;
        auto)
          if bus_available "$BUS_NAME"; then
            start_tool_runtime_detached "$path" "tool_${name}" || start_tool_wine_detached "$path" "tool_${name}"
          else
            start_tool_wine_detached "$path" "tool_${name}"
          fi
          ;;
        *)
          start_tool_wine_detached "$path" "tool_${name}";;
      esac
    fi
  done

  # Tools-only watcher behavior
  if [[ "$NO_GAME" -eq 1 ]]; then
    wlog "Tools-only watcher active."
    if [[ "$WAIT_TOOLS" -eq 1 ]]; then
      wlog "--wait-tools enabled: blocking until Ctrl+C"
      while true; do sleep 2; done
    else
      wlog "Tools-only: detached; exiting watcher."
    fi
    return 0
  fi

  # Monitor game and shutdown tools when it exits (optional)
  if [[ "$ELITE_MONITOR_GAME" == "true" ]]; then
    wlog "Monitoring Elite processes..."

    # Prefer explicit PID (from Steam exec) if provided
    if [[ -n "$WATCHER_GAME_PID" ]]; then
      while kill -0 "$WATCHER_GAME_PID" >/dev/null 2>&1; do
        sleep 5
      done
    else
      # fallback: poll for Elite processes
      while is_elite_running; do
        sleep 5
      done
    fi

    wlog "Elite exited."

    # EDCoPilot graceful request
    if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
      request_edcopilot_shutdown "$EDCOPILOT_EXE"
      # give a moment
      sleep 2 || true
    fi

    stop_tools
    stop_wineserver
  else
    wlog "monitor_game=false; watcher will exit without stopping tools."
  fi
}

# ----------------------------
# Main: tools-only vs game
# ----------------------------
if [[ "$WATCHER_MODE" -eq 1 ]]; then
  watcher_main
  exit 0
fi

# Tools-only mode: run watcher directly (no exec)
if [[ "$NO_GAME" -eq 1 ]]; then
  log "Tools-only mode."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would start watcher tools-only."
    exit 0
  fi

  # Start watcher (not necessarily detached if wait-tools)
  if [[ "$WAIT_TOOLS" -eq 1 ]]; then
    "$0" --config "$CONFIG_PATH" --no-game --wait-tools --watcher "" "tools" &
    wait $! || true
  else
    if have setsid; then
      setsid "$0" --config "$CONFIG_PATH" --no-game --watcher "" "tools" >>"$WATCHER_LOG" 2>&1 < /dev/null &
    else
      "$0" --config "$CONFIG_PATH" --no-game --watcher "" "tools" >>"$WATCHER_LOG" 2>&1 < /dev/null &
    fi
  fi
  exit 0
fi

# Build game command
build_game_command "$ELITE_LAUNCH_MODE"

log "Game launch kind=$GAME_CMD_KIND"
log "Game command: $(print_cmd "${GAME_CMD_ARR[@]}")"

# Spawn watcher detached before exec
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would spawn watcher + exec into game."
  exit 0
fi

if have setsid; then
  setsid "$0" --config "$CONFIG_PATH" --watcher "$$" "$GAME_CMD_KIND" >>"$WATCHER_LOG" 2>&1 < /dev/null &
else
  "$0" --config "$CONFIG_PATH" --watcher "$$" "$GAME_CMD_KIND" >>"$WATCHER_LOG" 2>&1 < /dev/null &
fi

# Exec into game so Steam tracks this PID as the game
exec "${GAME_CMD_ARR[@]}"
