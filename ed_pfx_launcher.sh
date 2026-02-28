#!/usr/bin/env bash
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG_DIR="$STATE_HOME/ed_pfx_launcher/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/coordinator.log"
: > "$LOG_FILE" || true

_ts() { date +'%H:%M:%S'; }
DEBUG=0
DEBUG_VERBOSE="${ED_PFX_TRACE:-0}"
_emit_log_line() {
  local line="$1"
  echo "$line" | tee -a "$LOG_FILE" >/dev/null
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "$line"
  fi
}
log() { _emit_log_line "[$(_ts)] $*"; }
warn() { _emit_log_line "[$(_ts)] WARN: $*"; }
die() { _emit_log_line "[$(_ts)] ERROR: $*"; exit 1; }
debug() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  local line="[$(_ts)] [DEBUG] $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >&2
}

trace() {
  [[ "$DEBUG" -eq 1 && "$DEBUG_VERBOSE" == "1" ]] || return 0
  local line="[$(_ts)] [TRACE] $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line" >&2
}

ensure_session_bus_env() {
  if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [[ -S "$runtime_dir/bus" ]]; then
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus"
    fi
  fi
}

on_error() {
  local line_no="$1" cmd="$2" code="$3"
  if [[ "$DEBUG" -eq 1 ]]; then
    warn "[DEBUG] Command failed (exit=$code line=$line_no): $cmd"
  fi
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

phase_start() { log "[PHASE:$1] START"; }
phase_end() { log "[PHASE:$1] END"; }
phase_fail() { log "[PHASE:$1] FAIL: $2"; }

have() { command -v "$1" >/dev/null 2>&1; }

format_cmd_for_log() {
  local -a parts=("$@")
  local joined=""
  local part

  for part in "${parts[@]}"; do
    if [[ -z "$joined" ]]; then
      printf -v joined '%q' "$part"
    else
      local escaped
      printf -v escaped '%q' "$part"
      joined+=" $escaped"
    fi
  done

  printf '%s' "$joined"
}


debug_cmd() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  log "[DEBUG] $1=$(format_cmd_for_log "${@:2}")"
}

CONFIG_PATH="$SCRIPT_DIR/ed_pfx_launcher.ini"
NO_GAME=0
WAIT_TOOLS=0
DRY_RUN=0
SELF_TEST=0
PRINT_RESOLVED=0
INTERACTIVE=0
DEBUG=0
declare -a CLI_TOOLS=()
declare -a FORWARDED_CMD=()
declare -a MINED_ARGS_ARR=()
NO_GAME_TOOL_MODE=0
STEAM_MODE=0
FRONTIER_ACTIVE=0
PASS_COMMAND="false"
PASS_COMMAND_EXPLICIT="false"
PREFIX_DIR_CLI=""
PREFIX_SELECT_CLI=""
PROTON_DIR_CLI=""
PROTON_SELECT_CLI=""
INTERACTIVE_UI_CLI=""

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME [--config <ini>] [--prefix-dir <path>] [--prefix-select <first|newest>] [--proton-dir <path>] [--proton-select <first|newest>] [--interactive] [--interactive-ui <legacy|wizard>] [--no-game] [--wait-tools] [--tool <exe>]... [--dry-run] [--print-resolved] [--self-test] [--pass-command|--no-pass-command] [--debug] [--] %command%
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    --tool) CLI_TOOLS+=("${2:-}"); shift 2;;
    --no-game) NO_GAME=1; shift;;
    --wait-tools) WAIT_TOOLS=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --print-resolved) PRINT_RESOLVED=1; shift;;
    --interactive) INTERACTIVE=1; shift;;
    --interactive-ui) INTERACTIVE_UI_CLI="${2:-}"; shift 2;;
    --self-test) SELF_TEST=1; shift;;
    --prefix-dir) PREFIX_DIR_CLI="${2:-}"; shift 2;;
    --prefix-select) PREFIX_SELECT_CLI="${2:-}"; shift 2;;
    --proton-dir) PROTON_DIR_CLI="${2:-}"; shift 2;;
    --proton-select) PROTON_SELECT_CLI="${2:-}"; shift 2;;
    --pass-command) PASS_COMMAND="true"; PASS_COMMAND_EXPLICIT="true"; shift;;
    --no-pass-command) PASS_COMMAND="false"; PASS_COMMAND_EXPLICIT="true"; shift;;
    --debug|--degbug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; FORWARDED_CMD=("$@"); break;;
    *) FORWARDED_CMD+=("$1"); shift;;
  esac
done

if [[ "$DEBUG" -eq 1 ]]; then
  debug "Debug mode enabled"
fi

# INI parsing
declare -A CFG=()
declare -A CFG_SOURCE=()
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

set_var() {
  local name="$1" value="$2"
  printf -v "$name" '%s' "$value"
  debug "set $name=${!name}"
}

set_state() {
  local next_state="$1"
  debug "state transition: $CURRENT_STATE -> $next_state"
  CURRENT_STATE="$next_state"
}

log_loaded_config() {
  local key
  debug "Loaded config entries from $CONFIG_PATH:"
  for key in $(printf '%s\n' "${!CFG[@]}" | sort); do
    debug "  $key=${CFG[$key]}"
  done
}

cfg_get() { printf '%s' "${CFG[$1]:-${2:-}}"; }
cfg_has() { [[ -n "${CFG[$1]+x}" ]]; }
cfg_bool() {
  local v="$(cfg_get "$1" "${2:-false}")"
  case "${v,,}" in true|false) printf '%s' "${v,,}" ;; *) printf '%s' "${2:-false}" ;; esac
}
cfg_int() {
  local raw="$(cfg_get "$1" "$2")"
  [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= $3 )) && { printf '%s' "$raw"; return; }
  printf '%s' "$2"
}

cfg_select() {
  local target="$1" default="$2"
  shift 2
  local key="" val=""
  CFG_SOURCE["$target"]="default"

  for key in "$@"; do
    if cfg_has "$key"; then
      val="$(cfg_get "$key")"
      if [[ "$key" == "$target" ]]; then
        CFG_SOURCE["$target"]="config:$key"
      else
        CFG_SOURCE["$target"]="compat:$key"
        warn "Deprecated config key '$key' is in use; migrate to '$target'"
      fi
      printf '%s' "$val"
      return 0
    fi
  done

  printf '%s' "$default"
}

cfg_select_bool() {
  local target="$1" default="$2"
  shift 2
  local raw
  raw="$(cfg_select "$target" "$default" "$@")"
  case "${raw,,}" in true|false) printf '%s' "${raw,,}" ;; *) printf '%s' "$default" ;; esac
}

cfg_select_int() {
  local target="$1" default="$2" min="$3"
  shift 3
  local raw
  raw="$(cfg_select "$target" "$default" "$@")"
  if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= min )); then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$default"
}

cfg_assign_select() {
  local out_var="$1" target="$2" default="$3"
  shift 3
  local key="" val="$default" source="default"

  for key in "$@"; do
    if cfg_has "$key"; then
      val="$(cfg_get "$key")"
      if [[ "$key" == "$target" ]]; then
        source="config:$key"
      else
        source="compat:$key"
        warn "Deprecated config key '$key' is in use; migrate to '$target'"
      fi
      break
    fi
  done

  printf -v "$out_var" '%s' "$val"
  CFG_SOURCE["$target"]="$source"
}

cfg_assign_select_bool() {
  local out_var="$1" target="$2" default="$3"
  shift 3
  local raw
  cfg_assign_select raw "$target" "$default" "$@"
  case "${raw,,}" in
    true|false) printf -v "$out_var" '%s' "${raw,,}" ;;
    *) printf -v "$out_var" '%s' "$default" ;;
  esac
}

cfg_assign_select_int() {
  local out_var="$1" target="$2" default="$3" min="$4"
  shift 4
  local raw
  cfg_assign_select raw "$target" "$default" "$@"
  if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= min )); then
    printf -v "$out_var" '%s' "$raw"
    return 0
  fi
  printf -v "$out_var" '%s' "$default"
}

cfg_source_or_unknown() {
  local key="$1"
  printf '%s' "${CFG_SOURCE[$key]:-unknown}"
}

log_effective_config() {
  log "Effective startup configuration:"
  log "  detection.launcher_timeout=$LAUNCHER_DETECT_TIMEOUT source=$(cfg_source_or_unknown 'detection.launcher_timeout')"
  log "  detection.game_timeout=$GAME_DETECT_TIMEOUT source=$(cfg_source_or_unknown 'detection.game_timeout')"
  log "  steam.prefix_dir=$PREFIX_DIR source=$(cfg_source_or_unknown 'steam.prefix_dir')"
  log "  steam.prefix_select=$PREFIX_SELECT source=$(cfg_source_or_unknown 'steam.prefix_select')"
  log "  proton.dir=$PROTON_DIR source=$(cfg_source_or_unknown 'proton.dir')"
  log "  proton.select=$PROTON_SELECT source=$(cfg_source_or_unknown 'proton.select')"
  log "  interactive.ui=$INTERACTIVE_UI source=$(cfg_source_or_unknown 'interactive.ui')"
  log "  resolved.prefix_dir=$PREFIX_DIR"
  log "  resolved.proton_bin=$PROTON_BIN"
  log "  elite.launcher_preference=$LAUNCHER_PREFERENCE source=$(cfg_source_or_unknown 'elite.launcher_preference')"
  log "  elite.pass_command=$PASS_COMMAND source=$(cfg_source_or_unknown 'elite.pass_command')"
  log "  steam.prefix_dir=$WINEPREFIX source=$(cfg_source_or_unknown 'steam.prefix_dir')"
  log "  proton.dir=$(dirname "$PROTON_BIN") source=$(cfg_source_or_unknown 'proton.dir')"
  log "  edcopilot.enabled=$EDCOPILOT_ENABLED source=$(cfg_source_or_unknown 'edcopilot.enabled')"
  log "  edcopilot.exe=$EDCOPILOT_EXE source=$(cfg_source_or_unknown 'edcopilot.exe')"
  log "  edcopilot.mode=$EDCOPILOT_MODE source=$(cfg_source_or_unknown 'edcopilot.mode')"
  log "  edcopilot.startup_delay=$EDCOPILOT_DELAY source=$(cfg_source_or_unknown 'edcopilot.startup_delay')"
  log "  edcopilot.bus_wait=$EDCOPILOT_BUS_WAIT source=$(cfg_source_or_unknown 'edcopilot.bus_wait')"
  log "  edcopilot.init_timeout=$EDCOPILOT_INIT_TIMEOUT source=$(cfg_source_or_unknown 'edcopilot.init_timeout')"
  log "  edcopilot.graceful_shutdown_timeout=$EDCOPILOT_SHUTDOWN_TIMEOUT source=$(cfg_source_or_unknown 'edcopilot.graceful_shutdown_timeout')"
  log "  edcopilot.hotas_fix=$EDCOPILOT_HOTAS_FIX source=$(cfg_source_or_unknown 'edcopilot.hotas_fix')"
  log "  edcopilot.disable_sdl_joystick=$EDCOPILOT_DISABLE_SDL_JOYSTICK source=$(cfg_source_or_unknown 'edcopilot.disable_sdl_joystick')"
  log "  shutdown.monitor_target=$SHUTDOWN_MONITOR_TARGET source=$(cfg_source_or_unknown 'shutdown.monitor_target')"
  log "  shutdown.close_tools_with_game=$CLOSE_TOOLS_ON_SHUTDOWN source=$(cfg_source_or_unknown 'shutdown.close_tools_with_game')"
  log "  shutdown.wineserver_cleanup=$WINESERVER_CLEANUP source=$(cfg_source_or_unknown 'shutdown.wineserver_cleanup')"
  log "  audio.pulse_latency_msec=$PULSE_LATENCY_MSEC source=$(cfg_source_or_unknown 'audio.pulse_latency_msec')"
}

safe_expand_tokens() {
  local s="$1"
  s="${s//\{home\}/${HOME:-}}"
  s="${s//\{appid\}/${APPID:-}}"
  s="${s//\{steam_root\}/${STEAM_ROOT:-}}"
  s="${s//\{compatdata\}/${COMPATDATA_DIR:-}}"
  s="${s//\{prefix\}/${WINEPREFIX:-}}"
  printf '%s' "$s"
}

expand_tokens() {
  safe_expand_tokens "$1"
}

detect_steam_root() {
  local c="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-}"
  [[ -n "$c" && -d "$c" ]] && { printf '%s' "$c"; return 0; }

  local candidate
  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done < <(discover_steam_roots)

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

extract_library_paths() {
  local vdf="$1"
  [[ -f "$vdf" ]] || return 0

  sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf"
  sed -n 's/^[[:space:]]*"[0-9]\+"[[:space:]]*"\(.*\)".*/\1/p' "$vdf"
}

uniq_lines() { awk '!seen[$0]++'; }

discover_steam_roots() {
  local -a roots=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/debian-installation"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.steam"
    "/usr/share/steam"
  )
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r/steamapps" ]] && printf '%s\n' "$r"
  done | uniq_lines
}

discover_libraries() {
  local -a roots=("$@")
  local root vdf p
  local -a libs=()

  for root in "${roots[@]}"; do
    [[ -d "$root/steamapps" ]] && libs+=("$root")

    vdf="$root/steamapps/libraryfolders.vdf"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      [[ -d "$p/steamapps" ]] && libs+=("$p")
    done < <(extract_library_paths "$vdf" || true)
  done

  printf '%s\n' "${libs[@]}" | uniq_lines
}

normalize_prefix_dir() {
  local p="$1"
  [[ -z "$p" ]] && return 1
  if [[ "${p##*/}" == "pfx" ]]; then
    printf '%s' "$(dirname "$p")"
    return 0
  fi
  printf '%s' "$p"
}

select_path_by_mode() {
  local mode="$1"
  shift
  local -a paths=("$@")
  local p newest="" newest_mtime=-1 current_mtime
  (( ${#paths[@]} > 0 )) || return 1

  case "$mode" in
    newest)
      for p in "${paths[@]}"; do
        current_mtime="$(stat -c '%Y' "$p" 2>/dev/null || echo 0)"
        if (( current_mtime >= newest_mtime )); then
          newest="$p"
          newest_mtime=$current_mtime
        fi
      done
      [[ -n "$newest" ]] && { printf '%s' "$newest"; return 0; }
      ;;
    first|*)
      printf '%s' "${paths[0]}"
      return 0
      ;;
  esac

  return 1
}

discover_prefix_candidates() {
  local appid="$1"
  local preferred_base="$2"
  local -a libs=() all_roots=() out=()
  local lib compat normalized

  if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
    normalized="$(normalize_prefix_dir "$STEAM_COMPAT_DATA_PATH")"
    [[ -d "$normalized/pfx" ]] && out+=("$normalized")
  fi

  if [[ -n "$preferred_base" ]]; then
    normalized="$(normalize_prefix_dir "$preferred_base")"
    if [[ -d "$normalized/pfx" ]]; then
      out+=("$normalized")
    elif [[ -d "$normalized/steamapps" ]]; then
      libs+=("$normalized")
    elif [[ -d "$normalized" ]]; then
      for compat in "$normalized"/*; do
        [[ -d "$compat/pfx" ]] && out+=("$compat")
      done
    fi
  fi

  mapfile -t all_roots < <(discover_steam_roots)
  mapfile -t libs < <(printf '%s\n' "${libs[@]}"; discover_libraries "${all_roots[@]}" | uniq_lines)

  for lib in "${libs[@]}"; do
    [[ -d "$lib/steamapps/compatdata" ]] || continue
    compat="$lib/steamapps/compatdata/$appid"
    [[ -d "$compat/pfx" ]] && out+=("$compat")

    for compat in "$lib/steamapps/compatdata"/*; do
      [[ -d "$compat/pfx" ]] && out+=("$compat")
    done
  done

  printf '%s\n' "${out[@]}" | awk 'NF' | uniq_lines
}

detect_prefix_candidates() {
  local steam_root="$1" appid="$2" preferred_base="$3"
  discover_prefix_candidates "$appid" "$preferred_base"
}

detect_prefix_dir() {
  local steam_root="$1" appid="$2" preferred_base="$3" select_mode="$4"
  local -a candidates=()
  mapfile -t candidates < <(detect_prefix_candidates "$steam_root" "$appid" "$preferred_base")
  (( ${#candidates[@]} > 0 )) || return 1
  select_path_by_mode "$select_mode" "${candidates[@]}"
}

discover_proton_candidates() {
  local steam_root="$1"
  local preferred_dir="$2"
  local -a all_roots=() tool_dirs=() candidates=()
  local d pd

  [[ -n "$preferred_dir" ]] && tool_dirs+=("$preferred_dir")

  mapfile -t all_roots < <(discover_steam_roots)
  [[ -n "$steam_root" ]] && all_roots+=("$steam_root")

  tool_dirs+=(
    "$HOME/.local/share/Steam/compatibilitytools.d"
    "$HOME/.steam/root/compatibilitytools.d"
    "$HOME/.steam/debian-installation/compatibilitytools.d"
    "$HOME/.steam/steam/compatibilitytools.d"
    "/usr/share/steam/compatibilitytools.d"
    "/usr/local/share/steam/compatibilitytools.d"
  )

  for d in "${all_roots[@]}"; do
    tool_dirs+=("$d/compatibilitytools.d")
    tool_dirs+=("$d/steamapps/compatibilitytools.d")
    tool_dirs+=("$d/steamapps/common")
  done

  for d in "${tool_dirs[@]}"; do
    [[ -d "$d" ]] || continue

    if [[ -x "$d/proton" && -x "$d/files/bin/wine" ]]; then
      candidates+=("$d/proton")
      continue
    fi

    for pd in "$d"/*; do
      [[ -d "$pd" ]] || continue
      [[ -x "$pd/proton" ]] || continue
      [[ -x "$pd/files/bin/wine" ]] || continue
      candidates+=("$pd/proton")
    done
  done

  printf '%s\n' "${candidates[@]}" | awk 'NF' | uniq_lines
}

detect_proton_candidates() {
  local steam_root="$1" proton_dir="$2"
  discover_proton_candidates "$steam_root" "$proton_dir"
}

find_proton() {
  local steam_root="$1" proton_dir="$2" select_mode="$3"
  local -a candidates=()
  mapfile -t candidates < <(detect_proton_candidates "$steam_root" "$proton_dir")
  (( ${#candidates[@]} > 0 )) || return 1
  select_path_by_mode "$select_mode" "${candidates[@]}"
}

pick_one() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local idx

  (( ${#options[@]} > 0 )) || return 1

  if have fzf && [[ -t 0 && -t 1 ]]; then
    printf '%s\n' "${options[@]}" | fzf --prompt="$prompt " --height=40% --reverse
    return $?
  fi

  echo
  echo "$prompt"
  for idx in "${!options[@]}"; do
    echo "  $((idx + 1))) ${options[$idx]}"
  done

  while true; do
    read -r -p "Select [1-${#options[@]}]: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#options[@]} )); then
      printf '%s' "${options[$((idx - 1))]}"
      return 0
    fi
    echo "Invalid selection '$idx'. Please choose 1-${#options[@]}." >&2
  done
}

render_interactive_menu() {
  local -n state_ref="$1"
  local -a steps=("Detect" "Select Prefix" "Select Proton" "Review" "Save")
  local -a prefix_candidates=()
  local -a proton_candidates=()
  local active_step="${state_ref[active_step]:-0}"
  local focus="${state_ref[focus]:-main}"
  local idx marker

  [[ -n "${state_ref[prefix_candidates]:-}" ]] && IFS=$'\n' read -r -d '' -a prefix_candidates < <(printf '%s\0' "${state_ref[prefix_candidates]}")
  [[ -n "${state_ref[proton_candidates]:-}" ]] && IFS=$'\n' read -r -d '' -a proton_candidates < <(printf '%s\0' "${state_ref[proton_candidates]}")

  printf '\033[H\033[2J'
  printf 'ed_pfx_launcher interactive wizard\n'
  printf 'Steam root: %s\n' "${state_ref[steam_root]}"
  printf 'AppID: %s | Config: %s\n' "${state_ref[appid]}" "${state_ref[config_path]}"
  printf 'Status: %s\n\n' "${state_ref[status]}"

  printf 'Steps '
  for idx in "${!steps[@]}"; do
    marker=' '
    (( idx == active_step )) && marker='>'
    if [[ "$focus" == "steps" && $idx -eq $active_step ]]; then
      printf '[%s* %s] ' "$marker" "${steps[$idx]}"
    else
      printf '[%s %s] ' "$marker" "${steps[$idx]}"
    fi
  done
  printf '\n\n'

  case "$active_step" in
    0)
      printf 'Detect\n'
      printf '  Prefix candidates: %s\n' "${#prefix_candidates[@]}"
      printf '  Proton candidates: %s\n' "${#proton_candidates[@]}"
      printf '  Press Enter to continue to prefix selection.\n'
      ;;
    1)
      printf 'Select Prefix\n'
      for idx in "${!prefix_candidates[@]}"; do
        marker=' '
        (( idx == ${state_ref[prefix_idx]:-0} )) && marker='❯'
        printf '  %s %s\n' "$marker" "${prefix_candidates[$idx]}"
      done
      ;;
    2)
      printf 'Select Proton\n'
      for idx in "${!proton_candidates[@]}"; do
        marker=' '
        (( idx == ${state_ref[proton_idx]:-0} )) && marker='❯'
        printf '  %s %s\n' "$marker" "${proton_candidates[$idx]}"
      done
      ;;
    3)
      printf 'Review\n'
      printf '  Prefix: %s\n' "${state_ref[selected_prefix]:-<not selected>}"
      printf '  Proton: %s\n' "${state_ref[selected_proton]:-<not selected>}"
      printf '  Proton dir to save: %s\n' "${state_ref[selected_proton_dir]:-<not selected>}"
      if [[ "${state_ref[is_valid]}" == "1" ]]; then
        printf '  Validation: OK\n'
      else
        printf '  Validation: Incomplete\n'
      fi
      ;;
    4)
      printf 'Save\n'
      printf '  Press Enter or s to persist selections.\n'
      printf '  q cancels without modifying config.\n'
      ;;
  esac

  printf '\nKeys: ↑/↓ (or j/k) move, Tab step/focus, Enter confirm, s=save, q=cancel\n'
}

prompt_selection_tui() {
  local label="$1"
  shift
  local -a choices=("$@")
  local count="${#choices[@]}"
  local selected=0 key

  (( count > 0 )) || return 1
  [[ -t 0 && -t 1 ]] || return 1

  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' RETURN

  printf '\r\033[J'
  printf '%s\n' "$label"
  printf '  Use ↑/↓ (or j/k), Enter to confirm, q to cancel.\n\n'
  local idx
  for idx in "${!choices[@]}"; do
    if (( idx == selected )); then
      printf '  ❯ %s\n' "${choices[$idx]}"
    else
      printf '    %s\n' "${choices[$idx]}"
    fi
  done
  while true; do
    IFS= read -rsn1 key || return 1
    case "$key" in
      "")
        printf '\n'
        printf '%s' "${choices[$selected]}"
        return 0
        ;;
      q|Q)
        printf '\n'
        return 1
        ;;
      k)
        selected=$(((selected - 1 + count) % count))
        ;;
      j)
        selected=$(((selected + 1) % count))
        ;;
      $'\x1b')
        IFS= read -rsn1 -t 0.05 key || continue
        [[ "$key" == "[" ]] || continue
        IFS= read -rsn1 -t 0.05 key || continue
        case "$key" in
          A) selected=$(((selected - 1 + count) % count)) ;;
          B) selected=$(((selected + 1) % count)) ;;
        esac
        ;;
    esac

    printf '\r\033[J'
    printf '%s\n' "$label"
    printf '  Use ↑/↓ (or j/k), Enter to confirm, q to cancel.\n\n'
    for idx in "${!choices[@]}"; do
      if (( idx == selected )); then
        printf '  ❯ %s\n' "${choices[$idx]}"
      else
        printf '    %s\n' "${choices[$idx]}"
      fi
    done
  done
}

prompt_selection() {
  local label="$1"
  shift
  local -a choices=("$@")

  if prompt_selection_tui "$label" "${choices[@]}"; then
    debug "Legacy prompt selection used prompt_selection_tui for '$label'"
    return 0
  fi

  debug "Legacy prompt_selection_tui unavailable for '$label'; using pick_one fallback"
  pick_one "$label" "${choices[@]}"
}

write_config_value() {
  local section="$1" key="$2" value="$3" file="$4"
  python3 - "$file" "$section" "$key" "$value" <<'PY'
from pathlib import Path
import sys

file_path = Path(sys.argv[1])
section = sys.argv[2].lower()
key = sys.argv[3].lower()
value = sys.argv[4]

text = file_path.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)

def normalize_newline(lines):
    if not lines:
        return '\n'
    return '\r\n' if any(line.endswith('\r\n') for line in lines) else '\n'

newline = normalize_newline(lines)
section_start = None
section_end = len(lines)
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        current = stripped[1:-1].strip().lower()
        if section_start is None:
            if current == section:
                section_start = i
        elif i > section_start:
            section_end = i
            break

entry = f"{key}={value}{newline}"
if section_start is None:
    if lines and not lines[-1].endswith(('\n', '\r')):
        lines[-1] += newline
    if lines and lines[-1].strip():
        lines.append(newline)
    lines.append(f"[{section}]{newline}")
    lines.append(entry)
else:
    key_line = None
    for i in range(section_start + 1, section_end):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith(';') or stripped.startswith('#') or '=' not in stripped:
            continue
        existing_key = stripped.split('=', 1)[0].strip().lower()
        if existing_key == key:
            key_line = i
            break
    if key_line is None:
        insert_at = section_end
        while insert_at > section_start + 1 and not lines[insert_at - 1].strip():
            insert_at -= 1
        lines.insert(insert_at, entry)
    else:
        lines[key_line] = entry

file_path.write_text(''.join(lines), encoding='utf-8')
PY
}

commit_interactive_config_changes() {
  local file="$1" selected_prefix="$2" selected_proton_dir="$3"
  local config_dir config_base tmp_file backup_file timestamp commit_state

  [[ -f "$file" ]] || {
    log "Interactive save rollback/error: config file not found at $file"
    return 1
  }

  config_dir="$(dirname "$file")"
  config_base="$(basename "$file")"
  tmp_file="$(mktemp "$config_dir/.${config_base}.tmp.XXXXXX")"

  if ! commit_state="$({
    python3 - "$file" "$tmp_file" "$selected_prefix" "$selected_proton_dir" <<'PY'
from pathlib import Path
import sys

file_path = Path(sys.argv[1])
tmp_path = Path(sys.argv[2])
selected_prefix = sys.argv[3]
selected_proton_dir = sys.argv[4]

text = file_path.read_text(encoding='utf-8')
lines = text.splitlines(keepends=True)

def normalize_newline(lines):
    if not lines:
        return '\n'
    return '\r\n' if any(line.endswith('\r\n') for line in lines) else '\n'

def parse_ini(lines):
    data = {}
    section = None
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith(';') or stripped.startswith('#'):
            continue
        if stripped.startswith('[') and stripped.endswith(']'):
            section = stripped[1:-1].strip().lower()
            data.setdefault(section, {})
            continue
        if '=' not in stripped or section is None:
            continue
        key, value = stripped.split('=', 1)
        data.setdefault(section, {})[key.strip().lower()] = value.strip()
    return data

def set_value(lines, section, key, value, newline):
    section_start = None
    section_end = len(lines)
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            current = stripped[1:-1].strip().lower()
            if section_start is None:
                if current == section:
                    section_start = i
            elif i > section_start:
                section_end = i
                break

    entry = f"{key}={value}{newline}"
    if section_start is None:
        if lines and not lines[-1].endswith(('\n', '\r')):
            lines[-1] += newline
        if lines and lines[-1].strip():
            lines.append(newline)
        lines.append(f"[{section}]{newline}")
        lines.append(entry)
        return

    key_line = None
    for i in range(section_start + 1, section_end):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith(';') or stripped.startswith('#') or '=' not in stripped:
            continue
        existing_key = stripped.split('=', 1)[0].strip().lower()
        if existing_key == key:
            key_line = i
            break

    if key_line is None:
        insert_at = section_end
        while insert_at > section_start + 1 and not lines[insert_at - 1].strip():
            insert_at -= 1
        lines.insert(insert_at, entry)
    else:
        lines[key_line] = entry

existing = parse_ini(lines)
changes = {
    ('steam', 'prefix_dir'): selected_prefix,
    ('proton', 'dir'): selected_proton_dir,
}
noop = True
for (section, key), value in changes.items():
    if existing.get(section, {}).get(key) != value:
        noop = False
        break

if noop:
    print('noop')
    sys.exit(0)

new_lines = list(lines)
newline = normalize_newline(new_lines)
for (section, key), value in changes.items():
    set_value(new_lines, section, key, value, newline)

updated = parse_ini(new_lines)
required = {
    'steam': {'prefix_dir'},
    'proton': {'dir'},
}
for section, keys in required.items():
    if section not in updated:
        raise SystemExit(f"validation failed: missing [{section}] section")
    missing = [k for k in keys if not updated[section].get(k)]
    if missing:
        raise SystemExit(f"validation failed: missing keys in [{section}]: {', '.join(missing)}")

tmp_path.write_text(''.join(new_lines), encoding='utf-8')
print('changed')
PY
  } 2>&1)"; then
    rm -f -- "$tmp_file"
    log "Interactive save rollback/error: failed to prepare updated config ($commit_state)"
    return 1
  fi

  if [[ "$commit_state" == "noop" ]]; then
    rm -f -- "$tmp_file"
    log "Interactive save no-op: selected values already match $file"
    return 0
  fi

  timestamp="$(date +%Y%m%d%H%M%S)"
  backup_file="$file.bak-$timestamp"
  if ! cp -p -- "$file" "$backup_file"; then
    rm -f -- "$tmp_file"
    log "Interactive save rollback/error: could not create backup at $backup_file"
    return 1
  fi

  if mv -f -- "$tmp_file" "$file"; then
    log "Interactive save committed successfully to $file (backup: $backup_file)"
    return 0
  fi

  rm -f -- "$tmp_file"
  if cp -p -- "$backup_file" "$file"; then
    log "Interactive save rollback/error: atomic replace failed; restored original from $backup_file"
  else
    log "Interactive save rollback/error: atomic replace failed and restore from $backup_file also failed"
  fi
  return 1
}

detect_prefix_candidates() {
  local steam_root="$1" appid="$2" preferred_base="$3"
  local -a compat_roots=() prefix_candidates=()
  local root dir normalized

  if [[ -n "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
    normalized="$(normalize_prefix_dir "$STEAM_COMPAT_DATA_PATH")"
    if [[ -d "$normalized/pfx" ]]; then
      prefix_candidates+=("$normalized")
    fi
  fi

  if [[ -n "$preferred_base" ]]; then
    compat_roots+=("$preferred_base")
  fi
  compat_roots+=(
    "$steam_root/steamapps/compatdata"
    "$HOME/.local/share/Steam/steamapps/compatdata"
    "$HOME/.steam/debian-installation/steamapps/compatdata"
    "$HOME/.steam/steam/steamapps/compatdata"
  )

  for root in "${compat_roots[@]}"; do
    [[ -d "$root" ]] || continue

    dir="$root/$appid"
    [[ -d "$dir/pfx" ]] && prefix_candidates+=("$dir")

    for dir in "$root"/*; do
      [[ -d "$dir/pfx" ]] && prefix_candidates+=("$dir")
    done
  done

  local -A seen=()
  local -a unique=()
  for dir in "${prefix_candidates[@]}"; do
    normalized="$(normalize_prefix_dir "$dir")"
    [[ -d "$normalized/pfx" ]] || continue
    if [[ -z "${seen[$normalized]+x}" ]]; then
      seen["$normalized"]=1
      unique+=("$normalized")
    fi
  done

  printf '%s\n' "${unique[@]}"
}

detect_proton_candidates() {
  local steam_root="$1" proton_dir="$2"
  local -a bases=() candidates=()
  local base p

  if [[ -n "$proton_dir" ]]; then
    bases+=("$proton_dir")
  fi

  bases+=(
    "$steam_root/steamapps/common"
    "$HOME/.steam/steam/compatibilitytools.d"
    "$HOME/.steam/debian-installation/compatibilitytools.d"
    "$HOME/.local/share/Steam/compatibilitytools.d"
  )

  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue

    if [[ -x "$base/proton" ]]; then
      candidates+=("$base/proton")
      continue
    fi

    for p in "$base"/Proton*/proton "$base"/*/proton; do
      [[ -x "$p" ]] && candidates+=("$p")
    done
  done

  local -A seen=()
  local -a unique=()
  for p in "${candidates[@]}"; do
    if [[ -z "${seen[$p]+x}" ]]; then
      seen["$p"]=1
      unique+=("$p")
    fi
  done

  printf '%s\n' "${unique[@]}"
}


interactive_configure_paths() {
  local steam_root="$1"
  local appid="$2"
  local preferred_prefix_root="$3"
  local preferred_proton_root="$4"
  local requested_ui="${INTERACTIVE_UI:-wizard}"
  local selected_ui="$requested_ui"
  local reason="Requested UI from config/CLI"

  case "$requested_ui" in
    wizard)
      if ! wizard_terminal_capabilities_ok reason; then
        selected_ui="legacy"
      fi
      ;;
    legacy)
      reason="Legacy UI explicitly selected"
      ;;
    *)
      warn "Invalid interactive UI '$requested_ui'; defaulting to wizard with capability fallback"
      requested_ui="wizard"
      selected_ui="wizard"
      reason="Invalid request defaulted to wizard"
      if ! wizard_terminal_capabilities_ok reason; then
        selected_ui="legacy"
      fi
      ;;
  esac

  log "Interactive UI route selected: ui=$selected_ui requested=$requested_ui source=$(cfg_source_or_unknown 'interactive.ui') reason=$reason"
  debug "Interactive routing context: tty0=$([[ -t 0 ]] && echo yes || echo no) tty1=$([[ -t 1 ]] && echo yes || echo no) TERM=${TERM:-<unset>}"

  if [[ "$selected_ui" == "legacy" ]]; then
    warn "Interactive legacy UI is deprecated and will be removed after one release window"
    interactive_legacy_run "$steam_root" "$appid" "$preferred_prefix_root" "$preferred_proton_root"
    return
  fi

  interactive_wizard_run "$steam_root" "$appid" "$preferred_prefix_root" "$preferred_proton_root"
}

wizard_terminal_capabilities_ok() {
  local -n reason_ref="$1"
  reason_ref="wizard terminal capabilities are sufficient"

  if [[ ! -t 0 || ! -t 1 ]]; then
    reason_ref="non-TTY session detected"
    return 1
  fi

  if ! have tput; then
    reason_ref="terminal capability check failed: 'tput' not found"
    return 1
  fi

  local cols lines
  cols="$(tput cols 2>/dev/null || echo 0)"
  lines="$(tput lines 2>/dev/null || echo 0)"
  if [[ ! "$cols" =~ ^[0-9]+$ || ! "$lines" =~ ^[0-9]+$ || "$cols" -lt 60 || "$lines" -lt 15 ]]; then
    reason_ref="terminal size/capabilities insufficient for wizard (cols=${cols:-?} lines=${lines:-?})"
    return 1
  fi

  return 0
}

interactive_legacy_run() {
  local steam_root="$1"
  local appid="$2"
  local preferred_prefix_root="$3"
  local preferred_proton_root="$4"
  local selected_prefix selected_proton
  local -a prefix_candidates=() proton_candidates=()

  mapfile -t prefix_candidates < <(detect_prefix_candidates "$steam_root" "$appid" "$preferred_prefix_root")
  mapfile -t proton_candidates < <(detect_proton_candidates "$steam_root" "$preferred_proton_root")

  if (( ${#prefix_candidates[@]} == 0 )); then
    die "Interactive mode could not find any Wine prefix candidates"
  fi
  if (( ${#proton_candidates[@]} == 0 )); then
    die "Interactive mode could not find any Proton candidates"
  fi

  if [[ -t 0 && -t 1 ]]; then
    selected_prefix="$(prompt_selection "Select Wine prefix candidate" "${prefix_candidates[@]}")" || {
      warn "Legacy interactive selection cancelled; config unchanged"
      return 1
    }
    selected_proton="$(prompt_selection "Select Proton candidate" "${proton_candidates[@]}")" || {
      warn "Legacy interactive selection cancelled; config unchanged"
      return 1
    }
    log "Legacy interactive UI used menu-based selection"
  else
    selected_prefix="$(select_path_by_mode "$PREFIX_SELECT" "${prefix_candidates[@]}")"
    selected_proton="$(select_path_by_mode "$PROTON_SELECT" "${proton_candidates[@]}")"
    log "Legacy interactive UI auto-selected values in non-TTY mode (prefix_select=$PREFIX_SELECT proton_select=$PROTON_SELECT)"
  fi

  if ! commit_interactive_config_changes "$CONFIG_PATH" "$selected_prefix" "$(dirname "$selected_proton")"; then
    warn "Legacy interactive save failed; leaving configuration unchanged"
    return 1
  fi

  CFG['steam.prefix_dir']="$selected_prefix"
  CFG['proton.dir']="$(dirname "$selected_proton")"
  CFG_SOURCE['steam.prefix_dir']="interactive"
  CFG_SOURCE['proton.dir']="interactive"
  PREFIX_DIR="$selected_prefix"
  PROTON_DIR="$(dirname "$selected_proton")"

  log "Legacy interactive selection applied: steam.prefix_dir=$selected_prefix"
  log "Legacy interactive selection applied: proton.dir=$(dirname "$selected_proton")"
}

interactive_wizard_run() {
  local steam_root="$1"
  local appid="$2"
  local preferred_prefix_root="$3"
  local preferred_proton_root="$4"
  local selected_prefix selected_proton key
  local -a prefix_candidates=() proton_candidates=()
  local -A wizard_state=()

  mapfile -t prefix_candidates < <(detect_prefix_candidates "$steam_root" "$appid" "$preferred_prefix_root")
  mapfile -t proton_candidates < <(detect_proton_candidates "$steam_root" "$preferred_proton_root")

  if (( ${#prefix_candidates[@]} == 0 )); then
    die "Interactive mode could not find any Wine prefix candidates"
  fi
  if (( ${#proton_candidates[@]} == 0 )); then
    die "Interactive mode could not find any Proton candidates"
  fi

  wizard_state[steam_root]="$steam_root"
  wizard_state[appid]="$appid"
  wizard_state[config_path]="$CONFIG_PATH"
  wizard_state[active_step]=0
  wizard_state[focus]=main
  wizard_state[prefix_idx]=0
  wizard_state[proton_idx]=0
  wizard_state[status]="Detecting candidates"
  wizard_state[prefix_candidates]="$(printf '%s\n' "${prefix_candidates[@]}")"
  wizard_state[proton_candidates]="$(printf '%s\n' "${proton_candidates[@]}")"
  wizard_state[is_valid]=0

  [[ -t 0 && -t 1 ]] || die "Interactive mode requires a TTY"
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' RETURN

  while true; do
    selected_prefix="${prefix_candidates[${wizard_state[prefix_idx]}]}"
    selected_proton="${proton_candidates[${wizard_state[proton_idx]}]}"
    wizard_state[selected_prefix]="$selected_prefix"
    wizard_state[selected_proton]="$selected_proton"
    wizard_state[selected_proton_dir]="$(dirname "$selected_proton")"
    if [[ -d "$selected_prefix/pfx" && -x "$selected_proton" ]]; then
      wizard_state[is_valid]=1
    else
      wizard_state[is_valid]=0
    fi
    render_interactive_menu wizard_state
    IFS= read -rsn1 key || return 1
    case "$key" in
      q|Q)
        printf '\n'
        log "Interactive wizard cancelled; config unchanged"
        return 1
        ;;
      s|S)
        if [[ "${wizard_state[is_valid]}" == "1" ]]; then
          wizard_state[active_step]=4
          break
        else
          wizard_state[status]="Cannot save: select valid prefix and Proton"
        fi
        ;;
      "")
        case "${wizard_state[active_step]}" in
          0) wizard_state[active_step]=1; wizard_state[status]="Select a prefix" ;;
          1) wizard_state[active_step]=2; wizard_state[status]="Prefix selected" ;;
          2) wizard_state[active_step]=3; wizard_state[status]="Proton selected" ;;
          3) wizard_state[active_step]=4; wizard_state[status]="Review complete" ;;
          4) [[ "${wizard_state[is_valid]}" == "1" ]] && break ;;
        esac
        ;;
      $'\t')
        wizard_state[active_step]=$(( (wizard_state[active_step] + 1) % 5 ))
        ;;
      j)
        case "${wizard_state[active_step]}" in
          1) wizard_state[prefix_idx]=$(( (wizard_state[prefix_idx] + 1) % ${#prefix_candidates[@]} )) ;;
          2) wizard_state[proton_idx]=$(( (wizard_state[proton_idx] + 1) % ${#proton_candidates[@]} )) ;;
        esac
        ;;
      k)
        case "${wizard_state[active_step]}" in
          1) wizard_state[prefix_idx]=$(( (wizard_state[prefix_idx] - 1 + ${#prefix_candidates[@]}) % ${#prefix_candidates[@]} )) ;;
          2) wizard_state[proton_idx]=$(( (wizard_state[proton_idx] - 1 + ${#proton_candidates[@]}) % ${#proton_candidates[@]} )) ;;
        esac
        ;;
      $'\x1b')
        IFS= read -rsn1 -t 0.05 key || continue
        [[ "$key" == "[" ]] || continue
        IFS= read -rsn1 -t 0.05 key || continue
        case "$key" in
          A)
            case "${wizard_state[active_step]}" in
              1) wizard_state[prefix_idx]=$(( (wizard_state[prefix_idx] - 1 + ${#prefix_candidates[@]}) % ${#prefix_candidates[@]} )) ;;
              2) wizard_state[proton_idx]=$(( (wizard_state[proton_idx] - 1 + ${#proton_candidates[@]}) % ${#proton_candidates[@]} )) ;;
            esac
            ;;
          B)
            case "${wizard_state[active_step]}" in
              1) wizard_state[prefix_idx]=$(( (wizard_state[prefix_idx] + 1) % ${#prefix_candidates[@]} )) ;;
              2) wizard_state[proton_idx]=$(( (wizard_state[proton_idx] + 1) % ${#proton_candidates[@]} )) ;;
            esac
            ;;
        esac
        ;;
    esac
  done

  selected_prefix="${wizard_state[selected_prefix]}"
  selected_proton="${wizard_state[selected_proton]}"

  if ! commit_interactive_config_changes "$CONFIG_PATH" "$selected_prefix" "$(dirname "$selected_proton")"; then
    warn "Interactive wizard save failed; leaving configuration unchanged"
    return 1
  fi

  CFG['steam.prefix_dir']="$selected_prefix"
  CFG['proton.dir']="$(dirname "$selected_proton")"
  CFG_SOURCE['steam.prefix_dir']="interactive"
  CFG_SOURCE['proton.dir']="interactive"
  PREFIX_DIR="$selected_prefix"
  PROTON_DIR="$(dirname "$selected_proton")"

  log "Interactive selection applied: steam.prefix_dir=$selected_prefix"
  log "Interactive selection applied: proton.dir=$(dirname "$selected_proton")"
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
      set_var DETECTED_KIND "game"
      set_var DETECTED_PID "$game_pid"
      log "Detected game process (EliteDangerous64.exe) pid=$DETECTED_PID"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

wait_for_game_window_or_launcher_exit() {
  local timeout="$1"
  local launcher_pid="$2"
  local launcher_name="$3"
  local elapsed=0
  local game_pid=""
  local launcher_exited_early="false"

  while (( elapsed < timeout )); do
    game_pid="$(first_pid_for_pattern 'EliteDangerous64\.exe')"
    if [[ -n "$game_pid" ]]; then
      set_var DETECTED_KIND "game"
      set_var DETECTED_PID "$game_pid"
      log "Detected game process (EliteDangerous64.exe) pid=$DETECTED_PID"
      return 0
    fi

    if [[ "$launcher_exited_early" != "true" ]] && ! kill -0 "$launcher_pid" >/dev/null 2>&1; then
      launcher_exited_early="true"
      warn "$launcher_name pid=$launcher_pid exited before EliteDangerous64.exe was detected; continuing to wait"
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  if [[ "$launcher_exited_early" == "true" ]]; then
    return 2
  fi

  return 1
}

wait_for_launcher() {
  local timeout="$1"
  local elapsed=0
  local mined_pid=""

  while (( elapsed < timeout )); do
    mined_pid="$(first_pid_for_pattern 'MinEdLauncher')"
    if [[ -n "$mined_pid" ]]; then
      log "Detected MinEdLauncher pid=$mined_pid; waiting for EliteDangerous64.exe"
      if wait_for_game_window_or_launcher_exit "$GAME_DETECT_TIMEOUT" "$mined_pid" "MinEdLauncher"; then
        return 0
      fi
      local wait_status=$?
      if [[ "$wait_status" -eq 2 ]]; then
        return 2
      fi
      return 1
    fi

    edlaunch_pid="$(first_pid_for_pattern 'EDLaunch\.exe')"
    if [[ -n "$edlaunch_pid" ]]; then
      log "Detected EDLaunch process pid=$edlaunch_pid"

      if [[ "$SHUTDOWN_MONITOR_TARGET" == "launcher" ]]; then
        set_var DETECTED_KIND "edlaunch"
        set_var DETECTED_PID "$edlaunch_pid"
        return 0
      fi

      log "Waiting for EliteDangerous64.exe after EDLaunch detection"
      if wait_for_game_window "$GAME_DETECT_TIMEOUT"; then
        return 0
      fi
      return 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

is_elite_running() { pgrep -f 'EliteDangerous64\.exe' >/dev/null 2>&1; }

bus_name_has_owner() {
  local bus_name="$1"

  ensure_session_bus_env

  if have gdbus; then
    timeout 2 gdbus call --session \
      --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner \
      "$bus_name" 2>/dev/null | grep -q '(true,'
    return $?
  fi

  if have dbus-send; then
    timeout 2 dbus-send --session --print-reply \
      --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus \
      org.freedesktop.DBus.NameHasOwner string:"$bus_name" 2>/dev/null | grep -q 'boolean true'
    return $?
  fi

  return 1
}


debug_session_bus_snapshot() {
  [[ "$DEBUG" -eq 1 ]] || return 0

  local names=""
  names="$(list_session_bus_names || true)"
  if [[ -z "$names" ]]; then
    trace "Session D-Bus names snapshot: <none or unavailable>"
    return 0
  fi

  trace "Session D-Bus names snapshot (steam-related):"
  while IFS= read -r name; do
    case "$name" in
      com.steampowered.App*|com.steam.*)
        trace "  $name"
        ;;
    esac
  done <<< "$names"
}

debug_runtime_process_snapshot() {
  [[ "$DEBUG" -eq 1 ]] || return 0

  local lines=""
  lines="$(pgrep -fa 'steam-runtime-launch-client|pressure-vessel|EliteDangerous64\.exe|MinEdLauncher|EDLaunch\.exe' 2>/dev/null || true)"
  if [[ -z "$lines" ]]; then
    trace "Runtime process snapshot: <no matching processes>"
    return 0
  fi

  trace "Runtime process snapshot:"
  while IFS= read -r line; do
    trace "  $line"
  done <<< "$lines"
}

debug_bus_diagnostics() {
  local context="$1" fallback_bus="$2"
  [[ "$DEBUG" -eq 1 ]] || return 0

  debug "Bus diagnostics [$context]: fallback_bus=$fallback_bus DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-<unset>}"
  debug_runtime_process_snapshot
  debug_session_bus_snapshot

  if [[ -n "$fallback_bus" ]]; then
    if bus_name_has_owner "$fallback_bus"; then
      trace "Bus diagnostics [$context]: fallback bus has owner: $fallback_bus"
    else
      trace "Bus diagnostics [$context]: fallback bus has no owner: $fallback_bus"
    fi
  fi
}

extract_bus_name_from_command_line() {
  local process_line="$1"
  local bus_name=""

  bus_name="$(printf '%s\n' "$process_line" | sed -n 's/.*--bus-name=\([^[:space:]]*\).*/\1/p' | head -n1)"
  if [[ -z "$bus_name" ]]; then
    bus_name="$(printf '%s\n' "$process_line" | sed -n 's/.*--bus-name[[:space:]]\+\([^[:space:]]*\).*/\1/p' | head -n1)"
  fi

  bus_name="${bus_name%\"}"
  bus_name="${bus_name#\"}"
  bus_name="${bus_name%\'}"
  bus_name="${bus_name#\'}"

  if [[ "$bus_name" =~ ^com\.[A-Za-z0-9_.-]+$ ]]; then
    printf '%s' "$bus_name"
    return 0
  fi

  return 1
}

list_session_bus_names() {
  ensure_session_bus_env

  if have gdbus; then
    timeout 2 gdbus call --session \
      --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.ListNames 2>/dev/null \
      | grep -oE 'com\.[A-Za-z0-9_.-]+' || true
    return 0
  fi

  if have dbus-send; then
    timeout 2 dbus-send --session --print-reply \
      --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus \
      org.freedesktop.DBus.ListNames 2>/dev/null \
      | sed -n 's/.*string "\(com\.[A-Za-z0-9_.-]*\)".*/\1/p' || true
    return 0
  fi

  return 1
}

derive_bus_names_from_appid() {
  local app_id="$1"
  [[ "$app_id" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' "com.steampowered.App$app_id"
  printf '%s\n' "com.steam.App$app_id"
  printf '%s\n' "com.valvesoftware.Steam.App$app_id"
}

extract_appid_candidates_from_process_line() {
  local process_line="$1"
  local app_id=""

  app_id="$(printf '%s\n' "$process_line" | sed -n 's/.*SteamGameId=\([0-9]\+\).*/\1/p' | head -n1)"
  [[ -n "$app_id" ]] && printf '%s\n' "$app_id"

  app_id="$(printf '%s\n' "$process_line" | sed -n 's/.*STEAM_COMPAT_APP_ID=\([0-9]\+\).*/\1/p' | head -n1)"
  [[ -n "$app_id" ]] && printf '%s\n' "$app_id"

  app_id="$(printf '%s\n' "$process_line" | sed -n 's/.*[Aa]pp\([0-9]\{4,\}\).*/\1/p' | head -n1)"
  [[ -n "$app_id" ]] && printf '%s\n' "$app_id"
}

discover_runtime_bus_name() {
  local fallback_bus="$1"
  local process_line candidate app_id synthesized_bus

  debug_bus_diagnostics "discover_runtime_bus_name:start" "$fallback_bus"

  while IFS= read -r process_line; do
    trace "discover_runtime_bus_name: checking process line: $process_line"
    candidate="$(extract_bus_name_from_command_line "$process_line" || true)"
    [[ -n "$candidate" ]] && trace "discover_runtime_bus_name: extracted bus candidate: $candidate"
    if [[ -n "$candidate" ]] && bus_name_has_owner "$candidate"; then
      debug "discover_runtime_bus_name: selected process-derived bus: $candidate"
      printf '%s' "$candidate"
      return 0
    fi

    while IFS= read -r app_id; do
      [[ -n "$app_id" ]] || continue
      trace "discover_runtime_bus_name: extracted appid candidate: $app_id"
      while IFS= read -r synthesized_bus; do
        trace "discover_runtime_bus_name: checking synthesized bus candidate: $synthesized_bus"
        if bus_name_has_owner "$synthesized_bus"; then
          debug "discover_runtime_bus_name: selected synthesized bus: $synthesized_bus"
          printf '%s' "$synthesized_bus"
          return 0
        fi
      done < <(derive_bus_names_from_appid "$app_id" || true)
    done < <(extract_appid_candidates_from_process_line "$process_line" || true)
  done < <(pgrep -fa 'steam-runtime-launch-client|pressure-vessel|SteamGameId=|STEAM_COMPAT_APP_ID=' 2>/dev/null || true)

  while IFS= read -r candidate; do
    case "$candidate" in
      com.steampowered.App*|com.steam.*)
        trace "discover_runtime_bus_name: checking session bus candidate: $candidate"
        if bus_name_has_owner "$candidate"; then
          debug "discover_runtime_bus_name: selected session bus: $candidate"
          printf '%s' "$candidate"
          return 0
        fi
        ;;
    esac
  done < <(list_session_bus_names || true)

  if [[ -n "$fallback_bus" ]] && bus_name_has_owner "$fallback_bus"; then
    debug "discover_runtime_bus_name: selected fallback bus: $fallback_bus"
    printf '%s' "$fallback_bus"
    return 0
  fi

  debug "discover_runtime_bus_name: no bus detected"
  return 1
}

# state enum via functions
STATE_WAIT_LAUNCHER() { :; }
STATE_WAIT_GAME() { :; }
STATE_LAUNCH_EDCOPILOT() { :; }
STATE_WAIT_EDCOPILOT_GUI() { :; }
STATE_LAUNCH_AUX() { :; }
STATE_MONITOR() { :; }
STATE_SHUTDOWN() { :; }

set_var CURRENT_STATE "STATE_WAIT_LAUNCHER"

declare -a CHILD_PIDS=()
register_child() { CHILD_PIDS+=("$1"); }
MINED_FALLBACK_ATTEMPTED=0

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
  debug_cmd "child[$label] command" "$@"
  [[ "$DRY_RUN" -eq 1 ]] && { log "DRY-RUN child[$label]: $*"; return 0; }
  "$@" >>"$log_file" 2>&1 &
  register_child "$!"
  debug "child[$label] started pid=$! log=$log_file"
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

build_edcopilot_winedlloverrides() {
  local required="dinput=n;dinput8=n;hid=n;hidraw=n"
  local existing="${WINEDLLOVERRIDES:-}"

  if [[ -z "$existing" ]]; then
    printf '%s' "$required"
  elif [[ "$existing" == *"$required"* ]]; then
    printf '%s' "$existing"
  else
    printf '%s;%s' "$required" "$existing"
  fi
}

build_edcopilot_env_args() {
  local merged_overrides=""
  local default_winedebug='-all,+seh,+err,+mscoree,+loaddll'

  EDCOPILOT_ENV_ARGS=(
    "WINEPREFIX=$WINEPREFIX"
    "WINEFSYNC=1"
    "WINEESYNC=1"
    "SDL_JOYSTICK_DISABLE=1"
    "SDL_GAMECONTROLLER_DISABLE=1"
    "PYGAME_FORCE_JOYSTICK=0"
  )

  merged_overrides="$(build_edcopilot_winedlloverrides)"
  EDCOPILOT_ENV_ARGS+=("WINEDLLOVERRIDES=$merged_overrides")

  if [[ -z "${WINEDEBUG+x}" ]]; then
    EDCOPILOT_ENV_ARGS+=("WINEDEBUG=$default_winedebug")
  fi
}

launch_edcopilot_runtime() {
  local runtime_client="$1"
  local log_file="$LOG_DIR/edcopilot.log"
  local pid=""
  local elapsed=0
  build_edcopilot_env_args
  local -a edcopilot_cmd=(env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$EDCOPILOT_EXE")

  [[ "$DRY_RUN" -eq 1 ]] && {
    log "DRY-RUN child[edcopilot]: $runtime_client --bus-name=\"com.steampowered.App${APPID}\" --pass-env-matching=\"WINE*\" --pass-env-matching=\"STEAM*\" --pass-env-matching=\"PROTON*\" --env=\"SteamGameId=${APPID}\" -- \"$WINELOADER\" \"$EDCOPILOT_EXE\""
    return 0
  }

  debug_cmd "edcopilot runtime command" "$runtime_client" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=${APPID}" -- "${edcopilot_cmd[@]}"

  "$runtime_client" \
    --bus-name="$BUS_NAME" \
    --pass-env-matching="WINE*" \
    --pass-env-matching="STEAM*" \
    --pass-env-matching="PROTON*" \
    --env="SteamGameId=${APPID}" \
    -- "${edcopilot_cmd[@]}" >>"$log_file" 2>&1 &
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

is_edcopilot_cli_duplicate() {
  local tool_path="$1"
  local tool_real="" ed_real=""

  [[ "$EDCOPILOT_ENABLED" == "true" ]] || return 1

  tool_real="$(realpath -m "$tool_path" 2>/dev/null || true)"
  ed_real="$(realpath -m "$EDCOPILOT_EXE" 2>/dev/null || true)"

  [[ -n "$tool_real" && -n "$ed_real" && "$tool_real" == "$ed_real" ]]
}

is_edcopilot_tool_binary() {
  local tool_path="$1"
  local tool_name

  tool_name="$(basename "$tool_path")"
  case "${tool_name,,}" in
    edcopilot.exe|edcopilotgui2.exe|launchedcopilot.exe)
      return 0
      ;;
  esac
  return 1
}

apply_edcopilot_hotas_fix() {
  [[ "$EDCOPILOT_HOTAS_FIX" == "true" ]] || return 0

  debug_cmd "edcopilot hotas fix registry" "$WINELOADER" reg add 'HKCU\\Software\\Wine\\DllOverrides' /v windows.gaming.input /t REG_SZ /d '' /f
  "$WINELOADER" reg add 'HKCU\Software\Wine\DllOverrides' /v windows.gaming.input /t REG_SZ /d '' /f >/dev/null 2>&1 \
    || warn "Failed to apply EDCoPilot HOTAS registry override"
}

launch_edcopilot() {
  local mode="$1" runtime_client="" resolved_bus=""
  local waited=0
  local bus_ready="false"
  local log_file="$LOG_DIR/edcopilot.log"

  : > "$log_file" || true
  apply_edcopilot_hotas_fix

  debug "launch_edcopilot: mode=$mode bus_wait=${EDCOPILOT_BUS_WAIT}s default_bus=$DEFAULT_BUS_NAME runtime_client=${RUNTIME_CLIENT:-<unset>}"

  if [[ "$mode" == "wine" ]]; then
    log "Launching EDCoPilot via Proton wine loader"
    build_edcopilot_env_args
    launch_wine_child "edcopilot" env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$EDCOPILOT_EXE"
    return 0
  fi

  if [[ "$mode" != "runtime" && "$mode" != "auto" ]]; then
    warn "Unknown edcopilot.mode '$mode'; defaulting to runtime behavior"
  fi

  while (( waited < EDCOPILOT_BUS_WAIT )); do
    runtime_client="$(resolve_runtime_client_from_processes || true)"
    resolved_bus="$(discover_runtime_bus_name "$DEFAULT_BUS_NAME" || true)"
    debug "launch_edcopilot: wait=$waited runtime_candidate=${runtime_client:-<none>} bus_candidate=${resolved_bus:-<none>}"
    if [[ -n "$resolved_bus" ]]; then
      set_var BUS_NAME "$resolved_bus"
      bus_ready="true"
    fi
    [[ -n "$runtime_client" && "$bus_ready" == "true" ]] && break
    sleep 1
    waited=$((waited + 1))
  done

  if [[ "$bus_ready" != "true" ]]; then
    debug "launch_edcopilot: bus not ready after wait loop; retrying one final discovery"
    resolved_bus="$(discover_runtime_bus_name "$DEFAULT_BUS_NAME" || true)"
    if [[ -n "$resolved_bus" ]]; then
      set_var BUS_NAME "$resolved_bus"
      bus_ready="true"
    fi
  fi

  if [[ -n "$runtime_client" ]]; then
    set_var RUNTIME_CLIENT "$runtime_client"
    log "Resolved runtime client from running process: $RUNTIME_CLIENT"
  elif [[ -n "${RUNTIME_CLIENT:-}" && -x "$RUNTIME_CLIENT" ]]; then
    log "Falling back to static runtime client: $RUNTIME_CLIENT"
  else
    debug "launch_edcopilot: runtime client unavailable"
  fi

  if [[ "$bus_ready" != "true" ]]; then
    if [[ "$mode" == "auto" ]]; then
      warn "Steam runtime bus not present; auto mode falling back to Proton wine loader"
      build_edcopilot_env_args
      launch_wine_child "edcopilot" env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$EDCOPILOT_EXE"
      return 0
    fi
    warn "Steam runtime bus not present; runtime mode requires Steam. Use mode=wine for steamless."
    return 1
  fi

  if [[ -x "${RUNTIME_CLIENT:-}" ]]; then
    launch_edcopilot_runtime "$RUNTIME_CLIENT"
    return $?
  fi

  if [[ "$mode" == "auto" ]]; then
    warn "Steam runtime client unavailable; auto mode falling back to Proton wine loader"
    build_edcopilot_env_args
    launch_wine_child "edcopilot" env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$EDCOPILOT_EXE"
    return 0
  fi

  warn "Steam runtime client unavailable; runtime mode requires Steam."
  return 1
}

build_windows_launch_cmd() {
  local exe_path="$1"

  if [[ "${RUNTIME_CLIENT_READY:-false}" == "true" && -x "${RUNTIME_CLIENT:-}" ]]; then
    GAME_CMD_ARR=(
      "$RUNTIME_CLIENT"
      --bus-name="$BUS_NAME"
      --pass-env-matching="WINE*"
      --pass-env-matching="STEAM*"
      --pass-env-matching="PROTON*"
      --env="SteamGameId=$APPID"
      -- "$WINELOADER" "$exe_path"
    )
  else
    GAME_CMD_ARR=("$PROTON_BIN" run "$exe_path")
  fi
}

build_mined_launch_cmd() {
  local mined_exe="$1"
  local mined_native=""
  local mined_dir=""
  local pass_command_effective="$PASS_COMMAND"

  if [[ "$mined_exe" == */MinEdLauncher.exe ]]; then
    mined_dir="$(dirname "$mined_exe")"
    if [[ -x "$mined_dir/MinEdLauncher" ]]; then
      mined_native="$mined_dir/MinEdLauncher"
    fi
  fi

  if [[ "$STEAM_MODE" -eq 1 && -n "$mined_native" && "$PASS_COMMAND_EXPLICIT" != "true" ]]; then
    pass_command_effective="true"
  fi

  # DRY-RUN scenario notes:
  # - Terminal mode (Steam mode=0) should resolve to Proton/runtime + MinEdLauncher.exe, never native MinEdLauncher.
  # - Steam mode (Steam mode=1) may resolve to native MinEdLauncher, and may prepend forwarded %command% tokens.
  if [[ "$STEAM_MODE" -eq 1 && -n "$mined_native" ]]; then
    # MinEdLauncher contract: %command% tokens (optional) must come before MinEd flags.
    GAME_CMD_ARR=("$mined_native")
    if [[ "$STEAM_MODE" -eq 1 && "$pass_command_effective" == "true" && ${#FORWARDED_CMD[@]} -gt 0 ]]; then
      GAME_CMD_ARR+=("${FORWARDED_CMD[@]}")
    fi
    GAME_CMD_ARR+=("${MINED_ARGS_ARR[@]}")
  elif [[ "${RUNTIME_CLIENT_READY:-false}" == "true" && -x "${RUNTIME_CLIENT:-}" ]]; then
    GAME_CMD_ARR=(
      "$RUNTIME_CLIENT"
      --bus-name="$BUS_NAME"
      --pass-env-matching="WINE*"
      --pass-env-matching="STEAM*"
      --pass-env-matching="PROTON*"
      --env="SteamGameId=$APPID"
      -- "$WINELOADER" "$mined_exe"
    )
    if [[ "$STEAM_MODE" -eq 1 && "$pass_command_effective" == "true" && ${#FORWARDED_CMD[@]} -gt 0 ]]; then
      GAME_CMD_ARR+=("${FORWARDED_CMD[@]}")
    fi
    GAME_CMD_ARR+=("${MINED_ARGS_ARR[@]}")
  else
    GAME_CMD_ARR=("$PROTON_BIN" run "$mined_exe")
    if [[ "$STEAM_MODE" -eq 1 && "$pass_command_effective" == "true" && ${#FORWARDED_CMD[@]} -gt 0 ]]; then
      GAME_CMD_ARR+=("${FORWARDED_CMD[@]}")
    fi
    GAME_CMD_ARR+=("${MINED_ARGS_ARR[@]}")
  fi
}

launch_game_process() {
  local game_log_file="$LOG_DIR/game.log"
  local launch_dir="${GAME_WORKDIR:-}"

  debug_cmd "game command" "${GAME_CMD_ARR[@]}"

  if [[ -n "$launch_dir" ]]; then
    (
      cd "$launch_dir"
      "${GAME_CMD_ARR[@]}"
    ) >>"$game_log_file" 2>&1 &
  else
    "${GAME_CMD_ARR[@]}" >>"$game_log_file" 2>&1 &
  fi
}


retry_with_edlaunch_fallback() {
  local edlaunch_exe

  [[ "$GAME_CMD_KIND" == "mined" ]] || return 1
  [[ "$MINED_FALLBACK_ATTEMPTED" -eq 0 ]] || return 1

  MINED_FALLBACK_ATTEMPTED=1
  edlaunch_exe="$(cfg_get 'elite.edlaunch_exe' '')"
  [[ -z "$edlaunch_exe" ]] && edlaunch_exe="$STEAM_ROOT/steamapps/common/Elite Dangerous/EDLaunch.exe"

  if [[ ! -f "$edlaunch_exe" ]]; then
    warn "MinEdLauncher launch failed and EDLaunch fallback is unavailable: $edlaunch_exe"
    return 1
  fi

  log "MinEdLauncher exited before game start; retrying with EDLaunch.exe"
  GAME_CMD_KIND="edlaunch"
  GAME_EXE_PATH="$edlaunch_exe"
  GAME_WORKDIR="$(dirname "$edlaunch_exe")"
  build_windows_launch_cmd "$edlaunch_exe"
  log "Game fallback command=$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"

  launch_game_process
  set_var GAME_PID "$!"
  register_child "$GAME_PID"
  log "Game process restarted via EDLaunch fallback pid=$GAME_PID"
  return 0
}

launch_tool() {
  local tool_path="$1"
  local label="$2"

  debug "launch_tool: label=$label path=$tool_path no_game_tool_mode=$NO_GAME_TOOL_MODE runtime_ready=${RUNTIME_CLIENT_READY:-false}"

  if [[ "$NO_GAME_TOOL_MODE" -eq 1 ]]; then
    if is_edcopilot_tool_binary "$tool_path"; then
      log "Launching tool '$label' via Proton wine loader (EDCoPilot binary)"
      build_edcopilot_env_args
      launch_wine_child "$label" env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$tool_path"
    else
      log "Launching tool '$label' via Proton (no-game tool mode)"
      launch_wine_child "$label" "$PROTON_BIN" run "$tool_path"
    fi
    return 0
  fi

  if [[ "${RUNTIME_CLIENT_READY:-false}" == "true" && -x "${RUNTIME_CLIENT:-}" ]]; then
    local resolved_bus=""
    resolved_bus="$(discover_runtime_bus_name "$DEFAULT_BUS_NAME" || true)"
    if [[ -n "$resolved_bus" ]]; then
      set_var BUS_NAME "$resolved_bus"
      log "Launching tool '$label' via Steam runtime bus '$BUS_NAME'"
      if is_edcopilot_tool_binary "$tool_path"; then
        build_edcopilot_env_args
        launch_wine_child "$label" "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$tool_path"
      else
        launch_wine_child "$label" "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$tool_path"
      fi
      return 0
    fi
    warn "Steam runtime bus could not be detected for tool '$label'; falling back to Proton"
  fi

  if is_edcopilot_tool_binary "$tool_path"; then
    log "Launching tool '$label' via Proton wine loader (EDCoPilot binary fallback)"
    build_edcopilot_env_args
    launch_wine_child "$label" env "${EDCOPILOT_ENV_ARGS[@]}" "$WINELOADER" "$tool_path"
  else
    launch_wine_child "$label" "$PROTON_BIN" run "$tool_path"
  fi
}


run_self_test() {
  local mined_exe terminal_cmd steam_cmd
  local saved_steam_mode="$STEAM_MODE"
  local saved_proton_bin="${PROTON_BIN:-}"
  local saved_runtime_ready="${RUNTIME_CLIENT_READY:-false}"
  local saved_runtime_client="${RUNTIME_CLIENT:-}"
  local saved_wineloader="${WINELOADER:-}"
  local saved_bus_name="${BUS_NAME:-}"
  local saved_appid="${APPID:-}"
  local -a saved_forwarded_cmd=("${FORWARDED_CMD[@]}")

  mined_exe="$(cfg_get 'elite.mined_exe' '')"
  [[ -z "$mined_exe" ]] && mined_exe="./MinEdLauncher.exe"

  PROTON_BIN="${PROTON_BIN:-proton}"
  RUNTIME_CLIENT_READY="false"
  RUNTIME_CLIENT="${RUNTIME_CLIENT:-steam-runtime-launch-client}"
  WINELOADER="${WINELOADER:-wine}"
  BUS_NAME="${BUS_NAME:-com.steampowered.App359320}"
  APPID="${APPID:-359320}"

  STEAM_MODE=0
  FORWARDED_CMD=()
  build_mined_launch_cmd "$mined_exe"
  terminal_cmd="$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"

  STEAM_MODE=1
  FORWARDED_CMD=("pressure-vessel" "--simulate")
  build_mined_launch_cmd "$mined_exe"
  steam_cmd="$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"

  STEAM_MODE="$saved_steam_mode"
  PROTON_BIN="$saved_proton_bin"
  RUNTIME_CLIENT_READY="$saved_runtime_ready"
  RUNTIME_CLIENT="$saved_runtime_client"
  WINELOADER="$saved_wineloader"
  BUS_NAME="$saved_bus_name"
  APPID="$saved_appid"
  FORWARDED_CMD=("${saved_forwarded_cmd[@]}")

  printf "SELF-TEST terminal-mode command: %s\n" "$terminal_cmd"
  printf "SELF-TEST steam-mode command: %s\n" "$steam_cmd"
}

build_game_command() {
  GAME_CMD_KIND=""
  GAME_WORKDIR=""
  GAME_EXE_PATH=""
  GAME_CMD_ARR=()
  FRONTIER_ACTIVE=0

  MINED_ARGS_ARR=()
  if [[ -n "$ELITE_MINED_FLAGS" ]]; then
    local old_ifs="$IFS"
    IFS=' '
    read -r -a MINED_ARGS_ARR <<< "$ELITE_MINED_FLAGS"
    IFS="$old_ifs"
  fi

  local have_frontier=0 arg
  for arg in "${MINED_ARGS_ARR[@]}"; do
    if [[ "$arg" == "/frontier" ]]; then
      have_frontier=1
      break
    fi
  done

  if [[ "$ELITE_PLATFORM" == "frontier" ]]; then
    if [[ -z "$ELITE_PROFILE" && "$have_frontier" -eq 0 ]]; then
      die "Frontier mode requires elite.profile or /frontier in mined_flags; otherwise MinEdLauncher will try Steam auth and crash."
    fi
    if [[ -n "$ELITE_PROFILE" && "$have_frontier" -eq 0 ]]; then
      MINED_ARGS_ARR=("/frontier" "$ELITE_PROFILE" "${MINED_ARGS_ARR[@]}")
      have_frontier=1
    fi
  elif [[ -n "$ELITE_PROFILE" && "$have_frontier" -eq 0 ]]; then
    MINED_ARGS_ARR=("/frontier" "$ELITE_PROFILE" "${MINED_ARGS_ARR[@]}")
    have_frontier=1
  fi

  if [[ "$have_frontier" -eq 1 ]]; then
    FRONTIER_ACTIVE=1
  fi

  STEAM_MODE=0
  if (( ${#FORWARDED_CMD[@]} > 0 )); then
    if [[ "${FORWARDED_CMD[0]}" == "%command%" ]]; then
      warn "Literal %command% detected (terminal run). Steam expands it, your shell doesn't. Ignoring forwarded command."
      FORWARDED_CMD=()
    else
      STEAM_MODE=1
    fi
  fi

  local launcher_preference mined_exe edlaunch_exe
  launcher_preference="${LAUNCHER_PREFERENCE:-mined}"
  launcher_preference="${launcher_preference,,}"

  mined_exe="$(cfg_get 'elite.mined_exe' '')"
  [[ -z "$mined_exe" ]] && mined_exe="$STEAM_ROOT/steamapps/common/Elite Dangerous/MinEdLauncher.exe"
  edlaunch_exe="$(cfg_get 'elite.edlaunch_exe' '')"
  [[ -z "$edlaunch_exe" ]] && edlaunch_exe="$STEAM_ROOT/steamapps/common/Elite Dangerous/EDLaunch.exe"

  case "$launcher_preference" in
    edlaunch)
      if [[ -f "$edlaunch_exe" ]]; then
        GAME_CMD_KIND="edlaunch"
        GAME_EXE_PATH="$edlaunch_exe"
        GAME_WORKDIR="$(dirname "$edlaunch_exe")"
        build_windows_launch_cmd "$edlaunch_exe"
        return 0
      fi
      die "elite.launcher_preference=edlaunch but EDLaunch.exe not found: $edlaunch_exe"
      ;;
    mined)
      if [[ -f "$mined_exe" ]]; then
        GAME_CMD_KIND="mined"
        GAME_EXE_PATH="$mined_exe"
        GAME_WORKDIR="$(dirname "$mined_exe")"
        build_mined_launch_cmd "$mined_exe"
        return 0
      fi
      die "elite.launcher_preference=mined but MinEdLauncher.exe not found: $mined_exe"
      ;;
    auto)
      if [[ -f "$edlaunch_exe" ]]; then
        GAME_CMD_KIND="edlaunch"
        GAME_EXE_PATH="$edlaunch_exe"
        GAME_WORKDIR="$(dirname "$edlaunch_exe")"
        build_windows_launch_cmd "$edlaunch_exe"
        return 0
      fi
      if [[ -f "$mined_exe" ]]; then
        GAME_CMD_KIND="mined"
        GAME_EXE_PATH="$mined_exe"
        GAME_WORKDIR="$(dirname "$mined_exe")"
        build_mined_launch_cmd "$mined_exe"
        return 0
      fi
      ;;
    *)
      warn "Invalid elite.launcher_preference='$launcher_preference'; using auto"
      if [[ -f "$edlaunch_exe" ]]; then
        GAME_CMD_KIND="edlaunch"
        GAME_EXE_PATH="$edlaunch_exe"
        GAME_WORKDIR="$(dirname "$edlaunch_exe")"
        build_windows_launch_cmd "$edlaunch_exe"
        return 0
      fi
      if [[ -f "$mined_exe" ]]; then
        GAME_CMD_KIND="mined"
        GAME_EXE_PATH="$mined_exe"
        GAME_WORKDIR="$(dirname "$mined_exe")"
        build_mined_launch_cmd "$mined_exe"
        return 0
      fi
      ;;
  esac

  if [[ -f "$mined_exe" ]]; then
    GAME_CMD_KIND="mined"
    GAME_EXE_PATH="$mined_exe"
    GAME_WORKDIR="$(dirname "$mined_exe")"
    build_mined_launch_cmd "$mined_exe"
    return 0
  fi

  die "MinEdLauncher-only mode is enabled, but MinEdLauncher.exe was not found. Set elite.mined_exe in config."
  die "Unable to build game command. Pass Steam %command% or set elite.edlaunch_exe/elite.mined_exe"
}

ini_load "$CONFIG_PATH"
if [[ -n "$PREFIX_DIR_CLI" ]]; then
  CFG['steam.prefix_dir']="$PREFIX_DIR_CLI"
  CFG_SOURCE['steam.prefix_dir']="cli"
fi
if [[ -n "$PROTON_DIR_CLI" ]]; then
  CFG['proton.dir']="$PROTON_DIR_CLI"
  CFG_SOURCE['proton.dir']="cli"
fi
log_loaded_config

if [[ "$SELF_TEST" -eq 1 ]]; then
  run_self_test
  exit 0
fi

if [[ "$NO_GAME" -eq 1 && ${#CLI_TOOLS[@]} -gt 0 ]]; then
  set_var NO_GAME_TOOL_MODE "1"
fi

phase_start "bootstrap"
set_var APPID "$(cfg_get 'steam.appid' "${SteamGameId:-359320}")"
set_var BUS_NAME "com.steampowered.App$APPID"
set_var DEFAULT_BUS_NAME "$BUS_NAME"
cfg_assign_select_bool EDCOPILOT_ENABLED 'edcopilot.enabled' 'true' 'edcopilot.enabled'
cfg_assign_select EDCOPILOT_MODE 'edcopilot.mode' 'runtime' 'edcopilot.mode'
cfg_assign_select_bool EDCOPILOT_HOTAS_FIX 'edcopilot.hotas_fix' 'true' 'edcopilot.hotas_fix'
cfg_assign_select_bool EDCOPILOT_DISABLE_SDL_JOYSTICK 'edcopilot.disable_sdl_joystick' 'true' 'edcopilot.disable_sdl_joystick'
cfg_assign_select_int EDCOPILOT_DELAY 'edcopilot.startup_delay' '30' '0' 'edcopilot.startup_delay' 'edcopilot.delay'
cfg_assign_select_int EDCOPILOT_BUS_WAIT 'edcopilot.bus_wait' '30' '0' 'edcopilot.bus_wait'
cfg_assign_select_int EDCOPILOT_INIT_TIMEOUT 'edcopilot.init_timeout' '45' '1' 'edcopilot.init_timeout'
cfg_assign_select_int EDCOPILOT_SHUTDOWN_TIMEOUT 'edcopilot.graceful_shutdown_timeout' '15' '1' 'edcopilot.graceful_shutdown_timeout' 'edcopilot.shutdown_timeout'
EDCOPILOT_FORCE_KILL_TIMEOUT="$(cfg_int 'edcopilot.force_kill_timeout' '5' '1')"
EDCOPILOT_ALLOW_PROTON_FALLBACK="$(cfg_bool 'edcopilot.allow_proton_fallback' 'false')"
EDCOPILOT_FORCE_LINUX_FLAG="$(cfg_bool 'edcopilot.force_linux_flag' 'true')"
cfg_assign_select_int LAUNCHER_DETECT_TIMEOUT 'detection.launcher_timeout' '120' '1' 'detection.launcher_timeout' 'elite.launcher_detect_timeout'
cfg_assign_select_int GAME_DETECT_TIMEOUT 'detection.game_timeout' '120' '1' 'detection.game_timeout' 'elite.game_detect_timeout'
cfg_assign_select PREFIX_DIR 'steam.prefix_dir' '' 'steam.prefix_dir' 'steam.compatdata_dir'
cfg_assign_select PREFIX_SELECT 'steam.prefix_select' 'first' 'steam.prefix_select'
PREFIX_SELECT="${PREFIX_SELECT,,}"
case "$PREFIX_SELECT" in
  first|newest) ;;
  *) warn "Invalid steam.prefix_select='$PREFIX_SELECT'; defaulting to first"; PREFIX_SELECT="first"; CFG_SOURCE['steam.prefix_select']="default" ;;
esac
cfg_assign_select PROTON_DIR 'proton.dir' '' 'proton.dir'
cfg_assign_select PROTON_SELECT 'proton.select' 'first' 'proton.select'
cfg_assign_select INTERACTIVE_UI 'interactive.ui' 'wizard' 'interactive.ui'
PROTON_SELECT="${PROTON_SELECT,,}"
INTERACTIVE_UI="${INTERACTIVE_UI,,}"
case "$PROTON_SELECT" in
  first|newest) ;;
  *) warn "Invalid proton.select='$PROTON_SELECT'; defaulting to first"; PROTON_SELECT="first"; CFG_SOURCE['proton.select']="default" ;;
esac
cfg_assign_select LAUNCHER_PREFERENCE 'elite.launcher_preference' 'mined' 'elite.launcher_preference'
if [[ "$PASS_COMMAND_EXPLICIT" == "true" ]]; then
  CFG_SOURCE['elite.pass_command']="cli"
elif cfg_has 'elite.pass_command'; then
  PASS_COMMAND="$(cfg_bool 'elite.pass_command' 'false')"
  CFG_SOURCE['elite.pass_command']="config:elite.pass_command"
else
  PASS_COMMAND="false"
  CFG_SOURCE['elite.pass_command']="default"
fi
if [[ -n "$PREFIX_DIR_CLI" ]]; then
  PREFIX_DIR="$PREFIX_DIR_CLI"
  CFG_SOURCE['steam.prefix_dir']="cli"
fi
if [[ -n "$PREFIX_SELECT_CLI" ]]; then
  PREFIX_SELECT="${PREFIX_SELECT_CLI,,}"
  CFG_SOURCE['steam.prefix_select']="cli"
fi
if [[ -n "$PROTON_DIR_CLI" ]]; then
  PROTON_DIR="$PROTON_DIR_CLI"
  CFG_SOURCE['proton.dir']="cli"
fi
if [[ -n "$PROTON_SELECT_CLI" ]]; then
  PROTON_SELECT="${PROTON_SELECT_CLI,,}"
  CFG_SOURCE['proton.select']="cli"
fi
if [[ -n "$INTERACTIVE_UI_CLI" ]]; then
  INTERACTIVE_UI="${INTERACTIVE_UI_CLI,,}"
  CFG_SOURCE['interactive.ui']="cli"
fi
case "$PREFIX_SELECT" in
  first|newest) ;;
  *) warn "Invalid prefix selection '$PREFIX_SELECT'; defaulting to first"; PREFIX_SELECT="first"; [[ "${CFG_SOURCE['steam.prefix_select']}" == "cli" ]] || CFG_SOURCE['steam.prefix_select']="default" ;;
esac
case "$PROTON_SELECT" in
  first|newest) ;;
  *) warn "Invalid proton selection '$PROTON_SELECT'; defaulting to first"; PROTON_SELECT="first"; [[ "${CFG_SOURCE['proton.select']}" == "cli" ]] || CFG_SOURCE['proton.select']="default" ;;
esac
case "$INTERACTIVE_UI" in
  wizard|legacy) ;;
  *) warn "Invalid interactive.ui='$INTERACTIVE_UI'; defaulting to wizard"; INTERACTIVE_UI="wizard"; [[ "${CFG_SOURCE['interactive.ui']}" == "cli" ]] || CFG_SOURCE['interactive.ui']="default" ;;
esac
ELITE_PLATFORM="$(cfg_get 'elite.platform' 'frontier')"
ELITE_PLATFORM="${ELITE_PLATFORM,,}"
case "$ELITE_PLATFORM" in
  frontier|steam) ;;
  *) warn "Invalid elite.platform='$ELITE_PLATFORM'; defaulting to frontier"; ELITE_PLATFORM="frontier";;
esac
ELITE_PROFILE="$(cfg_get 'elite.profile' '')"
ELITE_MINED_FLAGS="$(cfg_get 'elite.mined_flags' '/autorun /autoquit /edo')"
EDCOPILOT_EXE_REL="$(cfg_get 'edcopilot.exe_rel' 'drive_c/EDCoPilot/LaunchEDCoPilot.exe')"
EDCOPTER_ENABLED="$(cfg_bool 'edcopter.enabled' 'false')"
EDCOPTER_SHUTDOWN_TIMEOUT="$(cfg_int 'edcopter.shutdown_timeout' '5' '1')"
EDCOPTER_EXE_REL="$(cfg_get 'edcopter.exe_rel' '')"
cfg_assign_select SHUTDOWN_MONITOR_TARGET 'shutdown.monitor_target' 'game' 'shutdown.monitor_target'
case "$SHUTDOWN_MONITOR_TARGET" in
  launcher|game) ;;
  *) warn "Invalid shutdown.monitor_target='$SHUTDOWN_MONITOR_TARGET'; defaulting to game"; set_var SHUTDOWN_MONITOR_TARGET "game"; CFG_SOURCE['shutdown.monitor_target']="default";;
esac
cfg_assign_select_bool WINESERVER_CLEANUP 'shutdown.wineserver_cleanup' 'false' 'shutdown.wineserver_cleanup' 'wine.wineserver_kill_on_shutdown' 'wine.wineserver_wait_on_shutdown'
cfg_assign_select_bool CLOSE_TOOLS_ON_SHUTDOWN 'shutdown.close_tools_with_game' 'false' 'shutdown.close_tools_with_game'
cfg_assign_select PULSE_LATENCY_MSEC 'audio.pulse_latency_msec' '90' 'audio.pulse_latency_msec'
phase_end "bootstrap"

phase_start "detect steam/prefix/runtime"
debug "CLI modes: NO_GAME=$NO_GAME WAIT_TOOLS=$WAIT_TOOLS NO_GAME_TOOL_MODE=$NO_GAME_TOOL_MODE DRY_RUN=$DRY_RUN PASS_COMMAND=$PASS_COMMAND"
detected_bus_name=""
set_var STEAM_ROOT "$(expand_tokens "$(cfg_get 'steam.steam_root' '')")"
[[ -z "$STEAM_ROOT" ]] && set_var STEAM_ROOT "$(detect_steam_root || true)"
[[ -n "$STEAM_ROOT" && -d "$STEAM_ROOT" ]] || { phase_fail "detect steam/prefix/runtime" "steam root not found"; die "steam root not found"; }
if [[ "$INTERACTIVE" -eq 1 ]]; then
  interactive_configure_paths "$STEAM_ROOT" "$APPID" "$PREFIX_DIR" "$PROTON_DIR"
fi
if [[ -n "$PREFIX_DIR" ]]; then
  set_var PREFIX_DIR "$(normalize_prefix_dir "$PREFIX_DIR")"
  if [[ ! -d "$PREFIX_DIR/pfx" ]]; then
    set_var PREFIX_DIR "$(detect_prefix_dir "$STEAM_ROOT" "$APPID" "$PREFIX_DIR" "$PREFIX_SELECT" || true)"
  fi
else
  set_var PREFIX_DIR "$(detect_prefix_dir "$STEAM_ROOT" "$APPID" "" "$PREFIX_SELECT" || true)"
fi
[[ -n "$PREFIX_DIR" && -d "$PREFIX_DIR/pfx" ]] || { phase_fail "detect steam/prefix/runtime" "wineprefix not found"; die "Prefix dir not found or missing pfx: $PREFIX_DIR"; }
set_var COMPATDATA_DIR "$PREFIX_DIR"
set_var WINEPREFIX "$PREFIX_DIR/pfx"
set_var RUNTIME_CLIENT "$(cfg_get 'steam.runtime_client' '')"
[[ -z "$RUNTIME_CLIENT" ]] && set_var RUNTIME_CLIENT "$(detect_runtime_client "$STEAM_ROOT" || true)"
set_var RUNTIME_CLIENT_READY "false"
if [[ -n "$RUNTIME_CLIENT" && -x "$RUNTIME_CLIENT" ]]; then
  debug_bus_diagnostics "detect-steam-runtime" "$DEFAULT_BUS_NAME"
  detected_bus_name="$(discover_runtime_bus_name "$DEFAULT_BUS_NAME" || true)"
  if [[ -n "$detected_bus_name" ]]; then
    set_var BUS_NAME "$detected_bus_name"
    set_var RUNTIME_CLIENT_READY "true"
    log "Detected Steam runtime bus: $BUS_NAME"
  else
    warn "Steam runtime bus is not available; using Proton directly"
  fi
else
  debug "Runtime client unavailable or not executable: ${RUNTIME_CLIENT:-<unset>}"
  debug_bus_diagnostics "detect-steam-runtime:no-runtime-client" "$DEFAULT_BUS_NAME"
fi
if [[ "$NO_GAME_TOOL_MODE" -eq 1 ]]; then
  set_var RUNTIME_CLIENT_READY "false"
  log "No-game tool mode active: forcing Proton tool launches without Steam app bus attach"
fi
set_var PROTON_BIN "$(cfg_get 'proton.proton' '')"
[[ -z "$PROTON_BIN" ]] && set_var PROTON_BIN "$(find_proton "$STEAM_ROOT" "$PROTON_DIR" "$PROTON_SELECT" || true)"
[[ -n "$PROTON_BIN" && -x "$PROTON_BIN" ]] || { phase_fail "detect steam/prefix/runtime" "proton not found"; die "proton not found"; }
set_var WINELOADER "$(dirname "$PROTON_BIN")/files/bin/wine"
set_var EDCOPILOT_EXE "$(cfg_get 'edcopilot.exe' '')"
[[ -z "$EDCOPILOT_EXE" ]] && set_var EDCOPILOT_EXE "$WINEPREFIX/$EDCOPILOT_EXE_REL"
CFG_SOURCE['edcopilot.exe']="config:edcopilot.exe"
if ! cfg_has 'edcopilot.exe'; then
  CFG_SOURCE['edcopilot.exe']="default:edcopilot.exe_rel"
fi
prepare_edcopilot_config "$EDCOPILOT_FORCE_LINUX_FLAG"
set_var EDCOPTER_EXE ""
[[ -n "$EDCOPTER_EXE_REL" ]] && set_var EDCOPTER_EXE "$WINEPREFIX/$EDCOPTER_EXE_REL"
if [[ "$PULSE_LATENCY_MSEC" =~ ^[0-9]+$ ]]; then
  export PULSE_LATENCY_MSEC
else
  warn "Invalid audio.pulse_latency_msec='$PULSE_LATENCY_MSEC'; using 90"
  export PULSE_LATENCY_MSEC="90"
fi
if [[ "${FRONTIER_ACTIVE:-0}" -eq 1 || "$ELITE_PLATFORM" == "frontier" ]]; then
  unset SteamGameId SteamAppId
  export WINEPREFIX STEAM_COMPAT_DATA_PATH="$COMPATDATA_DIR" STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" WINEDEBUG="-all"
else
  export WINEPREFIX STEAM_COMPAT_DATA_PATH="$COMPATDATA_DIR" STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT" SteamGameId="$APPID" WINEDEBUG="-all"
fi
log_effective_config
phase_end "detect steam/prefix/runtime"

phase_start "detect launcher/game"
if [[ "$NO_GAME" -eq 0 ]]; then
  build_game_command
  log "Game launch kind=$GAME_CMD_KIND"
  log "Steam mode=$STEAM_MODE"
  log "Game command=$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"
else
  log "No-game mode enabled"
fi
phase_end "detect launcher/game"

if [[ "$PRINT_RESOLVED" -eq 1 ]]; then
  log "Resolved frontier_active=$FRONTIER_ACTIVE"
  log "Resolved game command=$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN resolved game command=$(format_cmd_for_log "${GAME_CMD_ARR[@]}")"
  log "DRY-RUN frontier_active=$FRONTIER_ACTIVE"
  log "DRY-RUN exiting before launching processes"
  exit 0
fi

set_var GAME_PID ""
set_var DETECTED_KIND ""
set_var DETECTED_PID ""
set_var MONITOR_PID ""
set_var MONITOR_KIND ""

while true; do
  case "$CURRENT_STATE" in
    STATE_WAIT_LAUNCHER)
      phase_start "STATE_WAIT_LAUNCHER"
      if [[ "$NO_GAME" -eq 0 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "DRY-RUN would launch game command"
        else
          launch_game_process
          set_var GAME_PID "$!"
          register_child "$GAME_PID"
          log "Game process started pid=$GAME_PID"

          if [[ "${GAME_CMD_ARR[0]}" == "${RUNTIME_CLIENT:-}" ]]; then
            sleep 3
            if ! kill -0 "$GAME_PID" >/dev/null 2>&1; then
              warn "Runtime launch exited early; retrying launch via Proton"
              if [[ "$GAME_CMD_KIND" == "mined" ]]; then
                build_mined_launch_cmd "$GAME_EXE_PATH"
                debug "updated GAME_CMD_ARR fallback to Proton run $GAME_EXE_PATH with MinEdLauncher args"
              else
                GAME_CMD_ARR=("$PROTON_BIN" run "$GAME_EXE_PATH")
                debug "updated GAME_CMD_ARR fallback to Proton run $GAME_EXE_PATH"
              fi
              launch_game_process
              set_var GAME_PID "$!"
              register_child "$GAME_PID"
              log "Game process restarted via Proton pid=$GAME_PID"
            fi
          fi
        fi
      fi
      set_state "STATE_WAIT_GAME"
      phase_end "STATE_WAIT_LAUNCHER"
      ;;
    STATE_WAIT_GAME)
      phase_start "STATE_WAIT_GAME"
      if [[ "$NO_GAME" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
        log "Skipping wait for game in no-game/dry-run"
      else
        if ! wait_for_launcher "$LAUNCHER_DETECT_TIMEOUT"; then
          wait_status=$?
          if [[ "$wait_status" -eq 2 ]] && retry_with_edlaunch_fallback; then
            phase_end "STATE_WAIT_GAME"
            continue
          fi
          phase_fail "STATE_WAIT_GAME" "launcher/game detection timeout"
          die "Launcher detection timed out after ${LAUNCHER_DETECT_TIMEOUT}s or game detection timed out after ${GAME_DETECT_TIMEOUT}s"
        fi

        if [[ "$DETECTED_KIND" == "game" ]]; then
          set_var MONITOR_KIND "game"
          set_var MONITOR_PID "$DETECTED_PID"
          log "Monitor lifecycle token=game initial_pid=$MONITOR_PID"
        elif [[ "$DETECTED_KIND" == "edlaunch" && "$SHUTDOWN_MONITOR_TARGET" == "launcher" ]]; then
          set_var MONITOR_KIND "launcher"
          set_var MONITOR_PID "$DETECTED_PID"
          log "Monitor lifecycle token=launcher pid=$MONITOR_PID"
        else
          phase_fail "STATE_WAIT_GAME" "unexpected detection kind"
          die "Unexpected detection result kind='$DETECTED_KIND' monitor_target='$SHUTDOWN_MONITOR_TARGET'"
        fi
      fi
      set_state "STATE_LAUNCH_EDCOPILOT"
      phase_end "STATE_WAIT_GAME"
      ;;
    STATE_LAUNCH_EDCOPILOT)
      phase_start "STATE_LAUNCH_EDCOPILOT"
      if [[ "$NO_GAME" -eq 1 && ${#CLI_TOOLS[@]} -gt 0 ]]; then
        log "Skipping managed EDCoPilot launch in --no-game tool mode"
      elif [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
        if [[ "$NO_GAME" -eq 0 && "$DRY_RUN" -eq 0 ]] && ! is_elite_running; then
          warn "EliteDangerous64.exe is not running; skipping EDCoPilot launch"
        else
          [[ "$EDCOPILOT_DELAY" -gt 0 ]] && sleep "$EDCOPILOT_DELAY"
          if ! launch_edcopilot "$EDCOPILOT_MODE"; then
            phase_fail "STATE_LAUNCH_EDCOPILOT" "EDCoPilot launch/verification failed"
            die "EDCoPilot failed to launch or EDCoPilotGUI2.exe was not detected"
          fi
        fi
      else
        warn "EDCoPilot disabled or missing exe: $EDCOPILOT_EXE"
      fi
      set_state "STATE_WAIT_EDCOPILOT_GUI"
      phase_end "STATE_LAUNCH_EDCOPILOT"
      ;;
    STATE_WAIT_EDCOPILOT_GUI)
      phase_start "STATE_WAIT_EDCOPILOT_GUI"
      log "EDCoPilot GUI verification completed in launch phase"
      set_state "STATE_LAUNCH_AUX"
      phase_end "STATE_WAIT_EDCOPILOT_GUI"
      ;;
    STATE_LAUNCH_AUX)
      phase_start "STATE_LAUNCH_AUX"
      if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
        runtime_client="$(resolve_runtime_client_from_processes || true)"
        if [[ -n "$runtime_client" ]]; then
          set_var RUNTIME_CLIENT "$runtime_client"
          log "Resolved runtime client from running process: $RUNTIME_CLIENT"
        elif [[ -n "${RUNTIME_CLIENT:-}" && -x "$RUNTIME_CLIENT" ]]; then
          log "Falling back to static runtime client: $RUNTIME_CLIENT"
        fi

        if [[ -x "${RUNTIME_CLIENT:-}" ]]; then
          resolved_bus="$(discover_runtime_bus_name "$DEFAULT_BUS_NAME" || true)"
          if [[ -n "$resolved_bus" ]]; then
            set_var BUS_NAME "$resolved_bus"
            launch_wine_child "edcopter" "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$EDCOPTER_EXE"
          else
            warn "Steam runtime bus could not be detected for EDCoPTER; falling back to Proton"
            launch_wine_child "edcopter" "$PROTON_BIN" run "$EDCOPTER_EXE"
          fi
        else
          launch_wine_child "edcopter" "$PROTON_BIN" run "$EDCOPTER_EXE"
        fi
      fi
      for t in "${CLI_TOOLS[@]}"; do
        [[ -f "$t" ]] || { warn "tool not found: $t"; continue; }
        if is_edcopilot_cli_duplicate "$t"; then
          debug "Skipping duplicate EDCoPilot tool launch (same realpath as EDCOPILOT_EXE): $t"
          continue
        fi
        log "Queueing CLI tool launch: $t"
        launch_tool "$t" "tool_$(basename "$t")"
      done
      set_state "STATE_MONITOR"
      phase_end "STATE_LAUNCH_AUX"
      ;;
    STATE_MONITOR)
      phase_start "STATE_MONITOR"
      if [[ "$NO_GAME" -eq 1 ]]; then
        if [[ ${#CHILD_PIDS[@]} -gt 0 ]]; then
          log "No-game monitor active; waiting while launched tools are still running"
          while collect_pids_for_patterns 'EDCoPilotGUI2\.exe' 'LaunchEDCoPilot\.exe' 'EDCoPilot\.exe' 'EDCoPTER\.exe' | grep -q .; do
            sleep 5
          done
        else
          log "No-game monitor: no managed tool processes detected, exiting"
        fi
      elif [[ "$DRY_RUN" -eq 0 ]]; then
        if [[ "$MONITOR_KIND" == "game" ]]; then
          while is_elite_running; do sleep 5; done
        elif [[ -n "$MONITOR_PID" ]]; then
          while kill -0 "$MONITOR_PID" >/dev/null 2>&1; do sleep 5; done
        else
          while is_elite_running; do sleep 5; done
        fi
        log "Game ended; transitioning to shutdown"
      fi
      set_state "STATE_SHUTDOWN"
      phase_end "STATE_MONITOR"
      ;;
    STATE_SHUTDOWN)
      phase_start "STATE_SHUTDOWN"
      if [[ "$CLOSE_TOOLS_ON_SHUTDOWN" == "true" ]]; then
        if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
          shutdown_edcopilot
        fi
        if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
          shutdown_edcopter
        fi
        cleanup_children
        if [[ -x "$(dirname "$PROTON_BIN")/files/bin/wineserver" ]]; then
          if [[ "$WINESERVER_CLEANUP" == "true" ]]; then
            "$(dirname "$PROTON_BIN")/files/bin/wineserver" -k >/dev/null 2>&1 || true
            log "Ran wineserver -k"
            "$(dirname "$PROTON_BIN")/files/bin/wineserver" -w >/dev/null 2>&1 || true
            log "Ran wineserver -w"
          fi
        fi
      else
        log "Leaving launched tools and wineserver running (shutdown.close_tools_with_game=false)"
      fi
      phase_end "STATE_SHUTDOWN"
      break
      ;;
    *) die "Unknown state: $CURRENT_STATE" ;;
  esac
done

log "Coordinator finished"
