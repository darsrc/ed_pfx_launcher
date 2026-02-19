# 1) Project Design Document (PDD)

## Purpose

`ed_pfx_launcher.sh` is a **Steam-safe** launcher wrapper for *Elite Dangerous* (Steam AppID `359320`) that:

- Launches the game via **MinEdLauncher.exe** (preferred) or `%command%` (fallback).
- Launches **EDCoPilot** (and optional other tools) reliably under Proton/Wine.
- Works from:
  - Steam “Launch Options” (single line) without hanging on **STOP**.
  - Terminal (with sensible fallbacks).

**Why Steam-safe matters:** Steam marks a game “running” based on the **PID it launched**. If your wrapper stays running and never becomes the game process, Steam often hangs with **STOP**. The design below solves this by:

- spawning a detached **watcher** process to manage tools, then
- `exec`-ing into the actual game command so the wrapper PID becomes the game PID.

*(French exposure)* **Voilà** (“there you go”): the wrapper becomes the game; the watcher does the rest.

## Goals

1. **Reliability**: EDCoPilot starts consistently (with retries), including a standalone mode.
2. **Portability**: Works across common native Steam installs; supports Flatpak via config overrides.
3. **Configurability**: Everything important lives in `ed_pfx_launcher.ini`.
4. **Feature-complete** (per your requirements):
   - MinEd profile support
   - game-only, tools-only, tools+game
   - timed EDCoPilot launch + DBus runtime attempt when available
   - optional HOTAS crash workaround (`windows.gaming.input` override)
   - clean shutdown logic

## Non-goals

- Solving EDCoPilot internal bugs under Wine (we can surface logs and improve launch context, but not rewrite EDCoPilot).
- Managing Steam accounts, login, or Frontier auth.

## Architecture

### Processes

- **Main process** (Steam entrypoint):

  1. Loads config
  2. Spawns watcher (detached)
  3. `exec`s into the game command (so Steam sees the correct running PID)

- **Watcher process** (`--watcher`):

  - Launches tools (EDCoPilot, EDCoPTER, generic tools)
  - Waits for Elite/launcher detection (optional)
  - Applies time-based delays and bus waits
  - Stops tools when the game exits (optional)

### Launch modes

- `elite.launch_mode=mined`: run MinEdLauncher via Proton
- `elite.launch_mode=steam`: run the original `%command%`
- `elite.launch_mode=auto`: prefer MinEd if present, else `%command%` or `steam -applaunch`

### EDCoPilot modes

- `edcopilot.mode=runtime`: use `steam-runtime-launch-client` **only** when DBus bus-name exists
- `edcopilot.mode=wine`: run via `proton run` directly
- `edcopilot.mode=auto`: try runtime when possible, else wine

### Config sources and precedence

Precedence (highest → lowest):

1. CLI args (e.g., `--no-game`)
2. Environment (Steam exports some vars)
3. `ed_pfx_launcher.ini`
4. Auto-detection defaults

### Logging

Default log dir: `~/.local/state/ed_pfx_launcher/logs/`

- `main.log` – config summary + launch decision
- `watcher.log` – tool orchestration
- `edcopilot.*.log` – EDCoPilot stdout/stderr

## Feature list

### Required

- ✅ Select profile for MinEdLauncher (`elite.profile`) and keep MinEd flags (`elite.mined_flags`)
- ✅ Launch only game, only tools, or both
- ✅ EDCoPilot delay/bus-wait defaults: `delay=30`, `bus_wait=30`
- ✅ EDCoPilot standalone support (`edcopilot.standalone=true`)
- ✅ Steam-safe execution (no “STOP” hang)

### Optional / nice-to-have

- HOTAS fix: registry override for `windows.gaming.input`
- Generic tool sections: `[tool.<name>]`
- Flatpak overrides via config

## Verification checklist

This script is designed to avoid the issues you hit:

- No `set -u` “unbound variable” explosions: all optional values use `${var:-}`.
- No “tools-only but tools get killed”: tools-only detaches by default; only cleans up if `--wait-tools`.
- No Steam hang: Steam entrypoint **execs into the game**.
- EDCoPilot reliability: retries, delay, optional INI Linux flag patch.

## Usage

### Steam Launch Options (single line)

Replace `/ABS/PATH/...` with your actual paths:

```bash
"/ABS/PATH/ed_pfx_launcher.sh" --config "/ABS/PATH/ed_pfx_launcher.ini" -- %command%
```

### Terminal

- Game + tools (auto):

```bash
./ed_pfx_launcher.sh --config ./ed_pfx_launcher.ini
```

- Tools only (keep running):

```bash
./ed_pfx_launcher.sh --config ./ed_pfx_launcher.ini --no-game
```

- Tools only (stay attached):

```bash
./ed_pfx_launcher.sh --config ./ed_pfx_launcher.ini --no-game --wait-tools
```

## Troubleshooting quick hits

- If EDCoPilot “speaks then disappears”, check:
  - `~/.local/state/ed_pfx_launcher/logs/edcopilot.wine.log`
  - `~/.local/state/ed_pfx_launcher/logs/edcopilot.runtime.log`
- If runtime launch fails, it’s usually missing DBus bus-name (`com.steampowered.App359320`). In `auto` mode we fall back to wine.

---

# 2) `ed_pfx_launcher.sh` (100% script)

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'
	'

# ============================================================
# ed_pfx_launcher.sh
# Feature-complete, Steam-safe Elite Dangerous + EDCoPilot launcher
#
# Core behavior (Steam-safe):
# - Main entrypoint spawns a detached watcher (tools orchestration)
# - Then it *execs* into the actual game command so Steam sees the
#   correct running PID (prevents the Steam "STOP" hang).
#
# Supports:
# - Game only / tools only / game+tools
# - MinEdLauncher profile support (when launch_mode=mined or terminal)
# - EDCoPilot runtime (pressure-vessel) when bus-name exists, with retry
# - Optional HOTAS crash workaround (windows.gaming.input override)
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

wlog()  { echo "[$(_ts)] $*" | tee -a "$WATCHER_LOG" >/dev/null; }
wwarn() { echo "[$(_ts)] WARN: $*" | tee -a "$WATCHER_LOG" >&2 >/dev/null; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Defaults / CLI state
# ----------------------------
CONFIG_PATH="$SCRIPT_DIR/ed_pfx_launcher.ini"
NO_GAME=0
WAIT_TOOLS=0
DRY_RUN=0
WATCHER_MODE=0

WATCHER_GAME_PID=""
WATCHER_LAUNCH_MODE=""

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
  --wait-tools         With --no-game: keep script attached until tools exit (Ctrl+C)
  --dry-run            Print decisions, don't launch
  --watcher <pid> <kind>  Internal: watcher mode
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
      # Allow accidental missing "--" by treating remaining args as forwarded.
      FORWARDED_CMD+=( "$1" ); shift;;
  esac
done

# Truncate logs only in main mode (avoid watcher racing and wiping logs)
if [[ "$WATCHER_MODE" -eq 0 ]]; then
  : > "$MAIN_LOG" || true
  : > "$WATCHER_LOG" || true
fi

log "Starting: $SCRIPT_NAME"
log "CONFIG=$CONFIG_PATH"

# ----------------------------
# INI parsing: store keys as CFG["section.key"]
# ----------------------------
declare -A CFG=()

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_strip_inline_comment() {
  local s="$1"
  local out=""
  local in_sq=0 in_dq=0
  local i ch prev
  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"
    prev=""
    (( i > 0 )) && prev="${s:i-1:1}"

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

  local section="" raw line key val
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
  p="$steam_root/steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client"
  [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
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

find_mined_exe() {
  local appid="$1" steam_root="$2" library_vdf="$3"

  if [[ -f "$steam_root/steamapps/common/Elite Dangerous/MinEdLauncher.exe" ]]; then
    printf '%s' "$steam_root/steamapps/common/Elite Dangerous/MinEdLauncher.exe"; return 0
  fi

  local lp
  while IFS= read -r lp; do
    [[ -z "$lp" ]] && continue
    if [[ -f "$lp/steamapps/common/Elite Dangerous/MinEdLauncher.exe" ]]; then
      printf '%s' "$lp/steamapps/common/Elite Dangerous/MinEdLauncher.exe"; return 0
    fi
  done < <(vdf_library_paths_for_appid "$library_vdf" "$appid")

  return 1
}

find_proton_from_config_info() {
  local compatdata="$1"
  local cfg="$compatdata/config_info"
  [[ -f "$cfg" ]] || return 1

  local line
  line="$(grep -m1 -E '/(common|compatibilitytools\.d)/[^[:space:]\"]+/proton' "$cfg" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    local p
    p="$(echo "$line" | grep -oE '/(common|compatibilitytools\.d)/[^[:space:]\"]+/proton' | head -n1)"
    [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  fi
  return 1
}

find_proton_fallback() {
  local steam_root="$1"

  local d
  for d in "$HOME/.steam/steam/compatibilitytools.d" "$steam_root/compatibilitytools.d" "$steam_root/steamapps/compatibilitytools.d"; do
    if [[ -d "$d" ]]; then
      local p
      p="$(ls -1d "$d"/*/proton 2>/dev/null | head -n1 || true)"
      [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
    fi
  done

  local p
  p="$(ls -1d "$steam_root"/steamapps/common/Proton*/proton 2>/dev/null | head -n1 || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }

  return 1
}

is_elite_running() {
  pgrep -f 'EliteDangerous64\.exe' >/dev/null 2>&1 && return 0
  pgrep -f 'EDLaunch\.exe' >/dev/null 2>&1 && return 0
  return 1
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

# ----------------------------
# Perf + environment
# ----------------------------
DXVK_FILTER_DEVICE_NAME="$(cfg_get 'perf.dxvk_filter_device_name' "${DXVK_FILTER_DEVICE_NAME:-}")"
DXVK_FRAME_RATE="$(cfg_get 'perf.dxvk_frame_rate' "${DXVK_FRAME_RATE:-}")"
PULSE_LATENCY_MSEC="$(cfg_get 'perf.pulse_latency_msec' "${PULSE_LATENCY_MSEC:-90}")"
PROTON_ENABLE_WAYLAND="$(cfg_get 'perf.proton_enable_wayland' "${PROTON_ENABLE_WAYLAND:-}")"

# Disable Steam overlay injection when called as wrapper (matches your working script)
unset LD_PRELOAD || true

unset __NV_PRIME_RENDER_OFFLOAD || true
unset __GLX_VENDOR_LIBRARY_NAME || true
unset __VK_LAYER_NV_optimus || true

[[ -n "$DXVK_FILTER_DEVICE_NAME" ]] && export DXVK_FILTER_DEVICE_NAME="$DXVK_FILTER_DEVICE_NAME"
[[ -n "$DXVK_FRAME_RATE" ]] && export DXVK_FRAME_RATE="$DXVK_FRAME_RATE"
export PULSE_LATENCY_MSEC="$PULSE_LATENCY_MSEC"

if [[ -n "${WAYLAND_DISPLAY:-}" && -n "$PROTON_ENABLE_WAYLAND" ]]; then
  export PROTON_ENABLE_WAYLAND="$PROTON_ENABLE_WAYLAND"
fi

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
TERMINAL_MODE="$(cfg_get 'elite.terminal_mode' 'auto')"     # auto|steam_applaunch
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

# EDCoPTER (optional)
EDCOPTER_ENABLED="$(cfg_get 'edcopter.enabled' 'false')"
EDCOPTER_EXE_ABS="$(cfg_get 'edcopter.exe' '')"
EDCOPTER_EXE_REL="$(cfg_get 'edcopter.exe_rel' '')"
EDCOPTER_COMMAND_NAME="$(cfg_get 'edcopter.command_name' 'EDCoPTER')"
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
declare -A TOOL_NAMES=()
for k in "${!CFG[@]}"; do
  if [[ "$k" == tool.*.* ]]; then
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

for t in "${CLI_TOOLS[@]}"; do
  [[ -f "$t" ]] || die "CLI tool not found: $t"
done

# ----------------------------
# HOTAS fix helper
# ----------------------------
apply_hotas_fix() {
  local enabled="$1"
  [[ "$enabled" == "true" ]] || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    wlog "DRY-RUN: would apply HOTAS fix (windows.gaming.input override)"
    return 0
  fi

  wlog "Applying HOTAS fix: windows.gaming.input DLL override"
  "$WINELOADER" reg add "HKEY_CURRENT_USER\Software\Wine\DllOverrides" /v "windows.gaming.input" /t REG_SZ /d "" /f >/dev/null 2>&1 || true
}

# ----------------------------
# EDCoPilot INI patch (RunningOnLinux)
# ----------------------------
patch_edcopilot_linux_flag() {
  local enabled="$1"
  local exe="$2"
  [[ "$enabled" == "true" ]] || return 0

  local dir f1 f2
  dir="$(dirname "$exe")"
  f1="$dir/EDCoPilot.ini"
  f2="$dir/edcopilotgui.ini"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    wlog "DRY-RUN: would patch RunningOnLinux in: $f1 and $f2"
    return 0
  fi

  [[ -f "$f1" ]] && sed -i $'s/RunningOnLinux="0"/RunningOnLinux="1"
/g' "$f1" || true
  [[ -f "$f2" ]] && sed -i $'s/RunningOnLinux="0"/RunningOnLinux="1"
/g' "$f2" || true
}

# ----------------------------
# Tool launching helpers (watcher)
# ----------------------------
declare -a TOOL_PGIDS=()

start_tool_wine_detached() {
  local exe="$1"
  local label="$2"
  shift 2
  local -a args=("$@")

  local log_file="$DEFAULT_LOG_DIR/${label}.wine.log"
  local cwd
  cwd="$(dirname "$exe")"

  wlog "Launching (wine): $label"
  wlog "  exe: $exe"
  wlog "  cwd: $cwd"
  wlog "  args: ${args[*]:-<none>}"
  wlog "  log: $log_file"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if have setsid; then
    setsid bash -lc "cd \"$cwd\" && exec \"$PROTON_BIN\" run \"$exe\" ${args[*]:+\"${args[@]}\"}" >>"$log_file" 2>&1 < /dev/null &
    TOOL_PGIDS+=("$!")
  else
    ( cd "$cwd" && "$PROTON_BIN" run "$exe" "${args[@]}" >>"$log_file" 2>&1 < /dev/null ) &
    TOOL_PGIDS+=("$!")
  fi
}

start_tool_runtime_detached() {
  local exe="$1"
  local label="$2"
  shift 2
  local -a args=("$@")

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
  wlog "  args: ${args[*]:-<none>}"
  wlog "  log: $log_file"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if have setsid; then
    setsid bash -lc "cd \"$cwd\" && exec \"$RUNTIME_CLIENT\" --bus-name=\"$BUS_NAME\" --pass-env-matching='WINE*' --pass-env-matching='STEAM*' --pass-env-matching='PROTON*' --env=SteamGameId=$APPID -- \"$WINELOADER\" \"$exe\" ${args[*]:+\"${args[@]}\"}" >>"$log_file" 2>&1 < /dev/null &
    TOOL_PGIDS+=("$!")
  else
    ( cd "$cwd" && "$RUNTIME_CLIENT" --bus-name="$BUS_NAME" --pass-env-matching="WINE*" --pass-env-matching="STEAM*" --pass-env-matching="PROTON*" --env="SteamGameId=$APPID" -- "$WINELOADER" "$exe" "${args[@]}" >>"$log_file" 2>&1 < /dev/null ) &
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
  [[ "${#TOOL_PGIDS[@]}" -gt 0 ]] || return 0
  wlog "Stopping tools..."
  for pid in "${TOOL_PGIDS[@]}"; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 1
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

request_edcopilot_shutdown() {
  local exe="$1"
  local dir req
  dir="$(dirname "$exe")"
  req="$dir/EDCoPilot.request.txt"

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
resolve_tool_path() {
  local name="$1"
  local raw
  raw="$(cfg_get "tool.$name.path" "")"
  [[ -n "$raw" ]] || { printf '%s' ""; return 0; }
  raw="$(expand_tokens "$raw" "$APPID" "$STEAM_ROOT" "$COMPATDATA_DIR" "$WINEPREFIX")"
  printf '%s' "$raw"
}

split_words_to_array() {
  local s="$1"
  local -n out="$2"
  out=()
  # shellcheck disable=SC2206
  out=( $s )
}

print_cmd() { printf '%q ' "$@"; printf '
'; }

# ----------------------------
# Game launch command builder
# ----------------------------
GAME_CMD_KIND=""
declare -a GAME_CMD_ARR=()
GAME_INSTALL_DIR=""   # if set, we cd there before exec and export STEAM_COMPAT_INSTALL_PATH

build_game_command() {
  local mode="$1"

  # Detect whether we're launched from Steam (i.e., %command% expanded).
  local have_forwarded=0
  if [[ "${#FORWARDED_CMD[@]}" -gt 0 && "${FORWARDED_CMD[0]:-}" != "%command%" ]]; then
    have_forwarded=1
  fi

  # Find MinEdLauncher.exe
  local mined_exe
  mined_exe="$(cfg_get 'elite.mined_exe' '')"
  if [[ -z "$mined_exe" ]]; then
    mined_exe="$(find_mined_exe "$APPID" "$STEAM_ROOT" "$LIBVDF" || true)"
  fi

  local -a mined_flags
  split_words_to_array "$ELITE_MINED_FLAGS" mined_flags

  local -a mined_args
  mined_args=("${mined_flags[@]}" "/frontier" "$ELITE_PROFILE")

  # AUTO policy (this fixes your current failure mode):
  # - If Steam provided %command% (have_forwarded=1), prefer STEAM command in auto.
  #   This guarantees the game starts in the same way Steam expects.
  # - If terminal (have_forwarded=0), prefer MinEd if present.
  case "$mode" in
    steam)
      (( have_forwarded == 1 )) || die "launch_mode=steam but no %command% provided. Use Steam Launch Options with: -- %command%"
      GAME_CMD_KIND="steam"
      GAME_CMD_ARR=("${FORWARDED_CMD[@]}")
      return 0
      ;;

    mined)
      [[ -n "$mined_exe" && -f "$mined_exe" ]] || die "launch_mode=mined but MinEdLauncher.exe not found. Set [elite] mined_exe."
      GAME_CMD_KIND="mined"
      GAME_INSTALL_DIR="$(dirname "$mined_exe")"
      GAME_CMD_ARR=("$PROTON_BIN" run "$mined_exe" "${mined_args[@]}")
      return 0
      ;;

    auto)
      if (( have_forwarded == 1 )); then
        GAME_CMD_KIND="steam"
        GAME_CMD_ARR=("${FORWARDED_CMD[@]}")
        return 0
      fi

      if [[ -n "$mined_exe" && -f "$mined_exe" ]]; then
        GAME_CMD_KIND="mined"
        GAME_INSTALL_DIR="$(dirname "$mined_exe")"
        GAME_CMD_ARR=("$PROTON_BIN" run "$mined_exe" "${mined_args[@]}")
        return 0
      fi

      # Terminal fallback: ask Steam to launch it.
      if [[ "$TERMINAL_MODE" == "auto" || "$TERMINAL_MODE" == "steam_applaunch" ]]; then
        have steam || die "Terminal fallback requires 'steam' command in PATH."
        GAME_CMD_KIND="steam_applaunch"
        GAME_CMD_ARR=(steam -applaunch "$APPID")
        return 0
      fi

      die "Unable to build game command."
      ;;

    *)
      die "elite.launch_mode must be auto|steam|mined (got: $mode)"
      ;;
  esac
}

# ----------------------------
# Watcher main
# ----------------------------
watcher_main() {
  wlog "Watcher started"
  wlog "kind=$WATCHER_LAUNCH_MODE game_pid=${WATCHER_GAME_PID:-<none>}"

  apply_hotas_fix "$HOTAS_FIX_ENABLED"

  # INI tools: pre/always
  for name in "${!TOOL_NAMES[@]}"; do
    enabled="$(cfg_get "tool.$name.enabled" "false")"
    [[ "$enabled" == "true" ]] || continue

    when="$(cfg_get "tool.$name.when" "always")"
    kind="$(cfg_get "tool.$name.kind" "auto")"
    path="$(resolve_tool_path "$name")"
    raw_args="$(cfg_get "tool.$name.args" "")"

    [[ -n "$path" && -f "$path" ]] || { wwarn "Tool $name path missing: $path"; continue; }

    local -a targs=()
    [[ -n "$raw_args" ]] && split_words_to_array "$raw_args" targs

    if [[ "$when" == "pre" || "$when" == "always" ]]; then
      case "$kind" in
        runtime) start_tool_runtime_detached "$path" "tool_${name}" "${targs[@]}" || start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
        wine)    start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
        auto)
          if bus_available "$BUS_NAME"; then
            start_tool_runtime_detached "$path" "tool_${name}" "${targs[@]}" || start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}"
          else
            start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}"
          fi
          ;;
        *) start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
      esac
    fi
  done

  # CLI tools (non-EDCoPilot)
  for t in "${CLI_TOOLS[@]}"; do
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

      if [[ "$EDCOPILOT_STANDALONE" != "true" ]] && ! is_elite_running; then
        wwarn "EDCoPilot standalone disabled and Elite not running; skipping."
      else
        wlog "EDCoPilot delay=${EDCOPILOT_DELAY}s"
        sleep "$EDCOPILOT_DELAY" || true

        attempt=1
        launched=0
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
              if [[ -n "${RUNTIME_CLIENT:-}" && -x "${RUNTIME_CLIENT:-}" ]] && wait_for_bus "$BUS_NAME" "$EDCOPILOT_BUS_WAIT"; then
                start_tool_runtime_detached "$EDCOPILOT_EXE" "edcopilot" || start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot"
              else
                start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot"
              fi
              ;;
            *)
              start_tool_wine_detached "$EDCOPILOT_EXE" "edcopilot";;
          esac

          if wait_for_process 'EDCoPilotGUI2\.exe' "$EDCOPILOT_INIT_TIMEOUT"; then
            wlog "EDCoPilot GUI detected."
            launched=1
            break
          fi

          wwarn "EDCoPilot GUI not detected after ${EDCOPILOT_INIT_TIMEOUT}s"
          if (( attempt < EDCOPILOT_RETRIES )); then
            wlog "Retry sleep: ${EDCOPILOT_RETRY_SLEEP}s"
            sleep "$EDCOPILOT_RETRY_SLEEP" || true
          fi

          attempt=$((attempt+1))
        done

        (( launched == 1 )) || wwarn "EDCoPilot did not reach GUI after retries. Check logs in: $DEFAULT_LOG_DIR"
      fi
    else
      wwarn "EDCoPilot enabled but exe not found: $EDCOPILOT_EXE"
    fi
  fi

  # EDCoPTER (optional) — IMPORTANT: arguments must be passed
  if [[ "$EDCOPTER_ENABLED" == "true" && -n "$EDCOPTER_EXE" && -f "$EDCOPTER_EXE" ]]; then
    wlog "Launching EDCoPTER"

    local -a eargs=()
    [[ "$EDCOPTER_HEADLESS" == "true" ]] && eargs+=("--headless")
    [[ -n "$EDCOPTER_LISTEN_IP" ]] && eargs+=("--ip" "$EDCOPTER_LISTEN_IP")
    [[ -n "$EDCOPTER_LISTEN_PORT" ]] && eargs+=("--port" "$EDCOPTER_LISTEN_PORT")
    [[ -n "$EDCOPTER_EDCOPILOT_IP" ]] && eargs+=("--edcopilot-ip" "$EDCOPTER_EDCOPILOT_IP")

    if [[ -n "$EDCOPTER_ARGS_EXTRA" ]]; then
      local -a extra=()
      split_words_to_array "$EDCOPTER_ARGS_EXTRA" extra
      eargs+=("${extra[@]}")
    fi

    # Many EDCoPTER builds expect a leading command name argument (your working script did this).
    start_tool_wine_detached "$EDCOPTER_EXE" "edcopter" "$EDCOPTER_COMMAND_NAME" "${eargs[@]}"
  fi

  # INI tools: post
  for name in "${!TOOL_NAMES[@]}"; do
    enabled="$(cfg_get "tool.$name.enabled" "false")"
    [[ "$enabled" == "true" ]] || continue

    when="$(cfg_get "tool.$name.when" "always")"
    [[ "$when" == "post" ]] || continue

    kind="$(cfg_get "tool.$name.kind" "auto")"
    path="$(resolve_tool_path "$name")"
    raw_args="$(cfg_get "tool.$name.args" "")"

    [[ -n "$path" && -f "$path" ]] || continue

    local -a targs=()
    [[ -n "$raw_args" ]] && split_words_to_array "$raw_args" targs

    case "$kind" in
      runtime) start_tool_runtime_detached "$path" "tool_${name}" "${targs[@]}" || start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
      wine)    start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
      auto)
        if bus_available "$BUS_NAME"; then
          start_tool_runtime_detached "$path" "tool_${name}" "${targs[@]}" || start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}"
        else
          start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}"
        fi
        ;;
      *) start_tool_wine_detached "$path" "tool_${name}" "${targs[@]}";;
    esac
  done

  # Tools-only behavior
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

  # Monitor game and shutdown tools when it exits
  if [[ "$ELITE_MONITOR_GAME" == "true" ]]; then
    wlog "Monitoring Elite processes..."

    # If we were exec'd into the actual game process, WATCHER_GAME_PID stays valid.
    if [[ -n "$WATCHER_GAME_PID" && "$WATCHER_LAUNCH_MODE" != "steam_applaunch" ]]; then
      while kill -0 "$WATCHER_GAME_PID" >/dev/null 2>&1; do
        sleep 5
      done
    else
      while is_elite_running; do
        sleep 5
      done
    fi

    wlog "Elite exited."

    if [[ "$EDCOPILOT_ENABLED" == "true" && -f "$EDCOPILOT_EXE" ]]; then
      request_edcopilot_shutdown "$EDCOPILOT_EXE"
      sleep 2 || true
    fi

    stop_tools
    stop_wineserver
  else
    wlog "monitor_game=false; watcher exits without stopping tools."
  fi
}

# ----------------------------
# Entry
# ----------------------------
if [[ "$WATCHER_MODE" -eq 1 ]]; then
  watcher_main
  exit 0
fi

# Tools-only mode
if [[ "$NO_GAME" -eq 1 ]]; then
  log "Tools-only mode."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would start tools-only watcher."
    exit 0
  fi

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

if [[ -n "$GAME_INSTALL_DIR" ]]; then
  export STEAM_COMPAT_INSTALL_PATH="$GAME_INSTALL_DIR"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: would spawn watcher + exec into game."
  exit 0
fi

# Spawn watcher (detached) BEFORE exec
watch_pid_arg="$$"
[[ "$GAME_CMD_KIND" == "steam_applaunch" ]] && watch_pid_arg=""

if have setsid; then
  setsid "$0" --config "$CONFIG_PATH" --watcher "$watch_pid_arg" "$GAME_CMD_KIND" >>"$WATCHER_LOG" 2>&1 < /dev/null &
else
  "$0" --config "$CONFIG_PATH" --watcher "$watch_pid_arg" "$GAME_CMD_KIND" >>"$WATCHER_LOG" 2>&1 < /dev/null &
fi

# If launching MinEd, run from its directory (this is what your working script did,
# and it matters for some Proton/Wine setups).
if [[ -n "$GAME_INSTALL_DIR" ]]; then
  cd "$GAME_INSTALL_DIR"
fi

# Exec into game so Steam tracks this PID as the game process.
exec "${GAME_CMD_ARR[@]}"
```

---

# 3) `ed_pfx_launcher.ini` (100% with comments + examples)

```ini
; ============================================================
; ed_pfx_launcher.ini
; Shareable configuration for ed_pfx_launcher.sh
; ============================================================

[steam]
; Elite Dangerous (base game) AppID
appid=359320

; Optional overrides (auto-detection usually works on native installs)
; steam_root={home}/.local/share/Steam
; compatdata_dir={steam_root}/steamapps/compatdata/{appid}
; libraryfolders_vdf={steam_root}/config/libraryfolders.vdf
; runtime_client={steam_root}/steamapps/common/SteamLinuxRuntime_sniper/pressure-vessel/bin/steam-runtime-launch-client

[proton]
; Optional: explicit Proton binary
; proton={home}/.steam/steam/compatibilitytools.d/GE-Proton10-32/proton

[elite]
; launch_mode behavior:
;   - steam : (recommended for Steam Launch Options) uses %command% exactly.
;   - mined : runs MinEdLauncher.exe via Proton and passes profile/flags.
;   - auto  : IMPORTANT
;       * If %command% is present (Steam launch), auto chooses STEAM to avoid
;         wrapper/nesting issues and to guarantee the game starts.
;       * If started from terminal (no %command%), auto chooses MinEd if found.
launch_mode=auto

; Terminal fallback if not launched from Steam and MinEd wasn't found.
; auto -> steam_applaunch
terminal_mode=auto

; MinEd profile to use (passed as: /frontier <profile>)
profile=darvix

; MinEd base flags (space-separated). These are appended before /frontier <profile>
; Typical:
;   /autorun /autoquit /edo
mined_flags=/autorun /autoquit /edo

; Optional: if MinEdLauncher.exe is somewhere unusual
; mined_exe=/run/media/you/1TB/Games/EliteDangerous/MinEdLauncher.exe

; If true, watcher stops tools when Elite exits
monitor_game=true

; Optional HOTAS crash workaround (registry override windows.gaming.input)
; true/false
hotas_fix_enabled=false

[edcopilot]
; Master enable
enabled=true

; auto: try runtime if bus appears within bus_wait, else wine
; runtime: require runtime bus-name (best integration when running under Steam)
; wine: always use proton run
mode=auto

; Defaults that match your working command:
;   --edcopilot-delay 30 --edcopilot-bus-wait 30
delay=30
bus_wait=30

; How long to wait for EDCoPilotGUI2.exe after launch (seconds)
init_timeout=45

; Retry count + sleep between retries
retries=3
retry_sleep=3

; Patch EDCoPilot.ini / edcopilotgui.ini RunningOnLinux="1"
force_linux_flag=true

; If true, allow EDCoPilot to run even if Elite isn't running
standalone=true

; Prefer relative path inside prefix (portable)
exe_rel=drive_c/EDCoPilot/LaunchEDCoPilot.exe

; OR you can hardcode an absolute path:
; exe={prefix}/drive_c/EDCoPilot/LaunchEDCoPilot.exe

[edcopter]
; Optional: disabled by default for shareability
enabled=false

; Example relative path (adjust if you use EDCoPTER)
; exe_rel=drive_c/Program Files/EDCoPTER/EDCoPTER.exe

; EDCoPTER often expects a leading command name argument (your working script used "EDCoPTER")
command_name=EDCoPTER

; headless=false
; listen_ip=
; listen_port=
; edcopilot_ip=
; args_extra=

[perf]
; Optional performance knobs
; dxvk_filter_device_name=RTX 3060
; dxvk_frame_rate=60
pulse_latency_msec=90

; If you are on Wayland and want to hint Proton
proton_enable_wayland=1

[debug]
; Enables noisy WINEDEBUG if true
winedebug=false

; ============================================================
; Optional generic tools
; Define as many as you want:
;
; [tool.some_name]
; enabled=true
; kind=auto            ; auto|runtime|wine
; when=pre             ; pre|post|always
; path={prefix}/drive_c/SomeTool/Tool.exe
; args=--flag1 --flag2
; ============================================================
```

