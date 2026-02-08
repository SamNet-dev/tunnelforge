#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════════╗
# ║  ▀▀█▀▀ █  █ █▄ █ █▄ █ █▀▀ █   █▀▀ █▀█ █▀█ █▀▀ █▀▀            ║
# ║    █   █  █ █ ▀█ █ ▀█ █▀▀ █   █▀  █ █ █▀█ █ █ █▀▀            ║
# ║    █    ▀▀  █  █ █  █ ▀▀▀ ▀▀▀ █   ▀▀▀ █ █ ▀▀▀ ▀▀▀            ║
# ╚════════════════════════════════════════════════════════════════════╝
#
# TunnelForge — SSH Tunnel Manager
# Copyright (C) 2026 SamNet Technologies, LLC
#
# Single-file bash tool with TUI menu, live dashboard,
# DNS leak protection, kill switch, server hardening, and Telegram bot.
#
# Version : 1.0.0
# Author  : SamNet Technologies, LLC
# License : GNU General Public License v3.0
# GitHub  : github.com/SamNet-dev/tunnelforge
# Usage   : tunnelforge [command] [options]
#           Run 'tunnelforge help' for full command reference.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

# ============================================================================
# STRICT MODE & BASH VERSION CHECK
# ============================================================================

set -eo pipefail

MIN_BASH_VERSION="4.3"

check_bash_version() {
    local major="${BASH_VERSINFO[0]}"
    local minor="${BASH_VERSINFO[1]}"
    local req_major="${MIN_BASH_VERSION%%.*}"
    local req_minor="${MIN_BASH_VERSION##*.}"

    if (( major < req_major )) || \
       (( major == req_major && minor < req_minor )); then
        echo "ERROR: TunnelForge requires bash ${MIN_BASH_VERSION}+" \
             "(found ${BASH_VERSION})" >&2
        exit 1
    fi
}
check_bash_version

# ============================================================================
# VERSION & GLOBAL CONSTANTS
# ============================================================================

readonly VERSION="1.0.0"
readonly APP_NAME="TunnelForge"
readonly APP_NAME_LOWER="tunnelforge"

# Installation directories
readonly INSTALL_DIR="/opt/tunnelforge"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly PROFILES_DIR="${INSTALL_DIR}/profiles"
readonly PID_DIR="${INSTALL_DIR}/pids"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly BACKUP_DIR="${INSTALL_DIR}/backups"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly BIN_LINK="/usr/local/bin/tunnelforge"

# Config files
readonly MAIN_CONFIG="${CONFIG_DIR}/tunnelforge.conf"

# Temp / lock
TMP_DIR=""
# Background Telegram PIDs for cleanup
declare -a _TG_BG_PIDS=()
# SSH ControlMaster
readonly SSH_CONTROL_DIR="${INSTALL_DIR}/sockets"

# Bandwidth & reconnect history
readonly BW_HISTORY_DIR="${DATA_DIR}/bandwidth"
readonly RECONNECT_LOG_DIR="${DATA_DIR}/reconnects"

# ============================================================================
# TEMP FILE CLEANUP TRAP
# ============================================================================

cleanup() {
    local exit_code=$?
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    # Reap background Telegram sends
    local _tg_p
    for _tg_p in "${_TG_BG_PIDS[@]}"; do
        kill "$_tg_p" 2>/dev/null || true
        wait "$_tg_p" 2>/dev/null || true
    done
    rm -rf "${TMP_DIR}" 2>/dev/null
    rm -f "${PID_DIR}"/*.lock "${CONFIG_DIR}"/*.lock "${PROFILES_DIR}"/*.lock 2>/dev/null
    # Clean stale SSH ControlMaster sockets
    find "${SSH_CONTROL_DIR}" -type s -delete 2>/dev/null || true
    # Clean up our own mkdir-based locks (stale after SIGKILL)
    local _cleanup_lck _cleanup_pid
    for _cleanup_lck in "${CONFIG_DIR}"/*.lck "${PROFILES_DIR}"/*.lck "${PID_DIR}"/*.lck "${BW_HISTORY_DIR}"/*.lck; do
        if [[ -d "$_cleanup_lck" ]]; then
            _cleanup_pid=$(cat "${_cleanup_lck}/pid" 2>/dev/null) || true
            if [[ "${_cleanup_pid}" == "$$" ]] || [[ -z "$_cleanup_pid" ]]; then
                rm -f "${_cleanup_lck}/pid" 2>/dev/null || true
                rmdir "$_cleanup_lck" 2>/dev/null || true
            fi
        fi
    done
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM HUP QUIT

TMP_DIR=$(mktemp -d "/tmp/tunnelforge.XXXXXX" 2>/dev/null) || {
    echo "FATAL: Cannot create secure temporary directory" >&2
    exit 1
}
chmod 700 "${TMP_DIR}" 2>/dev/null || true
readonly TMP_DIR

# ============================================================================
# CONFIGURATION DEFAULTS  (declare -gA CONFIG)
# ============================================================================

declare -gA CONFIG=(
    # SSH defaults
    [SSH_DEFAULT_USER]="root"
    [SSH_DEFAULT_PORT]="22"
    [SSH_DEFAULT_KEY]=""
    [SSH_CONNECT_TIMEOUT]="10"
    [SSH_SERVER_ALIVE_INTERVAL]="30"
    [SSH_SERVER_ALIVE_COUNT_MAX]="3"
    [SSH_STRICT_HOST_KEY]="yes"

    # AutoSSH
    [AUTOSSH_ENABLED]="true"
    [AUTOSSH_POLL]="30"
    [AUTOSSH_FIRST_POLL]="30"
    [AUTOSSH_GATETIME]="30"
    [AUTOSSH_MONITOR_PORT]="0"
    [AUTOSSH_LOG_LEVEL]="1"

    # ControlMaster
    [CONTROLMASTER_ENABLED]="false"
    [CONTROLMASTER_PERSIST]="600"

    # Security
    [DNS_LEAK_PROTECTION]="false"
    [DNS_SERVER_1]="1.1.1.1"
    [DNS_SERVER_2]="1.0.0.1"
    [KILL_SWITCH]="false"

    # Telegram
    [TELEGRAM_ENABLED]="false"
    [TELEGRAM_BOT_TOKEN]=""
    [TELEGRAM_CHAT_ID]=""
    [TELEGRAM_ALERTS]="true"
    [TELEGRAM_PERIODIC_STATUS]="false"
    [TELEGRAM_STATUS_INTERVAL]="3600"

    # Dashboard
    [DASHBOARD_REFRESH]="3"
    [DASHBOARD_THEME]="retro"

    # Logging
    [LOG_LEVEL]="info"
    [LOG_JSON]="false"
    [LOG_MAX_SIZE]="10485760"
    [LOG_ROTATE_COUNT]="5"

    # General
    [AUTO_UPDATE_CHECK]="false"
)

config_get() {
    local key="$1"
    local default="${2:-}"
    echo "${CONFIG[$key]:-$default}"
}

config_set() {
    local key="$1"
    local value="$2"
    CONFIG["$key"]="$value"
}

# ============================================================================
# COLORS & TERMINAL DETECTION
# ============================================================================

if [[ -t 1 ]] && [[ -t 2 ]]; then
    IS_TTY=true
else
    IS_TTY=false
fi

if [[ "${IS_TTY}" == true ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'

    BOLD=$'\033[1m'
    BOLD_RED=$'\033[1;31m'
    BOLD_GREEN=$'\033[1;32m'
    BOLD_YELLOW=$'\033[1;33m'
    BOLD_BLUE=$'\033[1;34m'
    BOLD_MAGENTA=$'\033[1;35m'
    BOLD_CYAN=$'\033[1;36m'
    BOLD_WHITE=$'\033[1;37m'

    BG_RED=$'\033[41m'
    BG_GREEN=$'\033[42m'
    BG_YELLOW=$'\033[43m'
    BG_BLUE=$'\033[44m'

    DIM=$'\033[2m'
    UNDERLINE=$'\033[4m'
    REVERSE=$'\033[7m'
    RESET=$'\033[0m'

    # Status indicators (Unicode + color)
    readonly STATUS_OK="${GREEN}●${RESET}"
    readonly STATUS_FAIL="${RED}✗${RESET}"
    readonly STATUS_WARN="${YELLOW}▲${RESET}"
    readonly STATUS_STOP="${DIM}■${RESET}"
    readonly STATUS_SPIN="${CYAN}◆${RESET}"
else
    RED=''   GREEN=''  YELLOW=''  BLUE=''  MAGENTA=''  CYAN=''  WHITE=''
    BOLD=''  BOLD_RED=''  BOLD_GREEN=''  BOLD_YELLOW=''  BOLD_BLUE=''
    BOLD_MAGENTA=''  BOLD_CYAN=''  BOLD_WHITE=''
    BG_RED=''  BG_GREEN=''  BG_YELLOW=''  BG_BLUE=''
    DIM=''  UNDERLINE=''  REVERSE=''  RESET=''
    IS_TTY=false

    # Status indicators (ASCII fallback for dumb/pipe/NO_COLOR)
    readonly STATUS_OK="*"
    readonly STATUS_FAIL="x"
    readonly STATUS_WARN="!"
    readonly STATUS_STOP="-"
    readonly STATUS_SPIN="+"
fi

# ============================================================================
# LOGGING
# ============================================================================

declare -gA LOG_LEVELS=( [debug]=0 [info]=1 [success]=2 [warn]=3 [error]=4 )

_get_log_level_num() { echo "${LOG_LEVELS[${1:-info}]:-1}"; }

_should_log() {
    local msg_level="$1"
    local configured_level
    configured_level=$(config_get "LOG_LEVEL" "info")
    local msg_num configured_num
    msg_num=$(_get_log_level_num "$msg_level")
    configured_num=$(_get_log_level_num "$configured_level")
    if (( msg_num >= configured_num )); then return 0; fi
    return 1
}

log_json() {
    local level="$1" message="$2"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Escape JSON special characters: backslash first, then quotes, then control chars
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    message="${message//$'\n'/\\n}"
    message="${message//$'\t'/\\t}"
    message="${message//$'\r'/\\r}"
    printf '{"timestamp":"%s","level":"%s","app":"%s","message":"%s"}\n' \
        "$ts" "$level" "$APP_NAME_LOWER" "$message"
}

_log() {
    local level="$1" color="$2" prefix="$3" message="$4"
    _should_log "$level" || return 0

    if [[ "$(config_get LOG_JSON false)" == "true" ]]; then
        log_json "$level" "$message" \
            >> "${LOG_DIR}/${APP_NAME_LOWER}.log" 2>/dev/null || true
    fi

    local ts
    ts=$(date '+%H:%M:%S')
    if [[ "${IS_TTY}" == true ]]; then
        printf "${DIM}[%s]${RESET} ${color}${prefix}${RESET} %s\n" \
            "$ts" "$message" >&2
    else
        printf "[%s] %s %s\n" "$ts" "$prefix" "$message" >&2
    fi
}

log_debug()   { _log "debug"   "${DIM}"    "[DEBUG]" "$1"; }
log_info()    { _log "info"    "${CYAN}"   "[INFO] " "$1"; }
log_success() { _log "success" "${GREEN}"  "[  OK ]" "$1"; }
log_warn()    { _log "warn"    "${YELLOW}" "[WARN] " "$1"; }
log_error()   { _log "error"   "${RED}"    "[ERROR]" "$1"; }

log_file() {
    local level="$1" message="$2"
    if [[ "$(config_get LOG_JSON false)" == "true" ]]; then
        log_json "$level" "$message" \
            >> "${LOG_DIR}/${APP_NAME_LOWER}.log" 2>/dev/null || true
    else
        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        printf "[%s] [%s] %s\n" "$ts" "$level" "$message" \
            >> "${LOG_DIR}/${APP_NAME_LOWER}.log" 2>/dev/null || true
    fi
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Drain trailing bytes from multi-byte escape sequences (arrow keys, etc.)
# Call after read -rsn1: if key is ESC, consume the rest and blank the var.
# Usage: _drain_esc varname
_drain_esc() {
    local -n _de_ref="$1"
    if [[ "${_de_ref}" == $'\033' ]]; then
        local _de_trash
        read -rsn2 -t 0.1 _de_trash </dev/tty 2>/dev/null || true
        _de_ref=""
    fi
}

validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    return 1
}

# Check if a local port is already in use or assigned
# Returns 0 if free, 1 if busy. Prints suggestion on conflict.
_check_port_conflict() {
    local _cp_port="$1" _cp_type="${2:-local}"
    local _cp_busy=false _cp_who=""

    # Check active listeners via ss
    if command -v ss &>/dev/null; then
        if ss -tln 2>/dev/null | tail -n +2 | grep -qE "[:.]${_cp_port}[[:space:]]"; then
            _cp_busy=true
            _cp_who="system process"
        fi
    fi

    # Check other TunnelForge profiles
    if [[ -d "$PROFILES_DIR" ]]; then
        local _cp_f _cp_pname
        for _cp_f in "$PROFILES_DIR"/*.conf; do
            [[ -f "$_cp_f" ]] || continue
            _cp_pname=$(basename "$_cp_f" .conf)
            local _cp_pport=""
            _cp_pport=$(grep -oE "^LOCAL_PORT='[0-9]+'" "$_cp_f" 2>/dev/null | cut -d"'" -f2) || true
            if [[ "$_cp_pport" == "$_cp_port" ]]; then
                _cp_busy=true
                _cp_who="profile '${_cp_pname}'"
                break
            fi
        done
    fi

    if [[ "$_cp_busy" == true ]]; then
        printf "  ${YELLOW}! Port %s is used by %s${RESET}\n" "$_cp_port" "$_cp_who" >/dev/tty
        # Suggest next free port
        local _cp_try=$(( _cp_port + 1 ))
        local _cp_max=$(( _cp_port + 20 ))
        while (( _cp_try <= _cp_max && _cp_try <= 65535 )); do
            local _cp_free=true
            if command -v ss &>/dev/null; then
                if ss -tln 2>/dev/null | tail -n +2 | grep -qE "[:.]${_cp_try}[[:space:]]"; then
                    _cp_free=false
                fi
            fi
            if [[ "$_cp_free" == true ]] && [[ -d "$PROFILES_DIR" ]]; then
                for _cp_f in "$PROFILES_DIR"/*.conf; do
                    [[ -f "$_cp_f" ]] || continue
                    local _cp_pp=""
                    _cp_pp=$(grep -oE "^LOCAL_PORT='[0-9]+'" "$_cp_f" 2>/dev/null | cut -d"'" -f2) || true
                    if [[ "$_cp_pp" == "$_cp_try" ]]; then
                        _cp_free=false; break
                    fi
                done
            fi
            if [[ "$_cp_free" == true ]]; then
                printf "  ${DIM}Suggested: %s${RESET}\n" "$_cp_try" >/dev/tty
                return 1
            fi
            (( ++_cp_try ))
        done
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            # Reject leading zeros (octal ambiguity with iptables/ssh)
            if [[ "$octet" =~ ^0[0-9] ]]; then return 1; fi
            if (( 10#$octet > 255 )); then return 1; fi
        done
        return 0
    fi
    return 1
}

validate_ip6() {
    local ip="$1"
    # Accept bracketed form [::1]
    if [[ "$ip" =~ ^\[([0-9a-fA-F:]+)\]$ ]]; then
        ip="${BASH_REMATCH[1]}"
    fi
    # Basic IPv6: must contain at least one colon, only hex digits and colons
    if [[ "$ip" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]*$ ]]; then
        # Reject more than one :: (invalid shorthand)
        local _dc="${ip//[^:]/}"
        if [[ "${ip}" == *"::"*"::"* ]]; then return 1; fi
        return 0
    fi
    return 1
}

validate_hostname() {
    local host="$1"
    validate_ip "$host" && return 0
    # Accept bracket-wrapped IPv6 (e.g., [::1], [2001:db8::1])
    if [[ "$host" =~ ^\[[0-9a-fA-F:]+\]$ ]]; then return 0; fi
    # Accept bare IPv6 (e.g., ::1, 2001:db8::1)
    if [[ "$host" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]+$ ]]; then return 0; fi
    [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$ ]]
}

validate_profile_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]
}

format_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes < 1024 )); then
        printf "%d B" "$bytes"
    elif (( bytes < 1048576 )); then
        printf "%d.%d KB" "$(( bytes / 1024 ))" "$(( (bytes % 1024) * 10 / 1024 ))"
    elif (( bytes < 1073741824 )); then
        printf "%d.%d MB" "$(( bytes / 1048576 ))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
    else
        printf "%d.%02d GB" "$(( bytes / 1073741824 ))" "$(( (bytes % 1073741824) * 100 / 1073741824 ))"
    fi
}

format_duration() {
    local seconds="${1:-0}"
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
    local d=$(( seconds / 86400 ))
    local h=$(( (seconds % 86400) / 3600 ))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$(( seconds % 60 ))

    if (( d > 0 )); then
        printf "%dd %dh %dm" "$d" "$h" "$m"
    elif (( h > 0 )); then
        printf "%dh %dm %ds" "$h" "$m" "$s"
    elif (( m > 0 )); then
        printf "%dm %ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

get_public_ip() {
    local ip="" svc
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )
    for svc in "${services[@]}"; do
        ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ip "$ip" || validate_ip6 "$ip"; then
            echo "$ip"; return 0
        fi
    done
    echo "unknown"; return 1
}

check_root() {
    local hint="${1:-}"
    if [[ $EUID -ne 0 ]]; then
        log_error "This operation requires root privileges"
        log_info  "Run with: sudo tunnelforge ${hint}"
        return 1
    fi
}

confirm_action() {
    local message="${1:-Are you sure?}"
    local default="${2:-n}"
    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="${message} [Y/n]: "
    else
        prompt="${message} [y/N]: "
    fi
    printf "${BOLD}%s${RESET}" "$prompt" >/dev/tty
    local answer
    read -r answer </dev/tty || true
    answer="${answer:-$default}"
    case "${answer,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

print_line() {
    local char="${1:-─}" width="${2:-$(get_term_width)}"
    local i
    local line=""
    for (( i=0; i<width; i++ )); do
        line+="$char"
    done
    printf '%s\n' "$line"
}

spinner() {
    local pid="$1" message="${2:-Working...}"
    local -a chars
    if [[ "${IS_TTY}" == true ]] && [[ "${TERM:-dumb}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
        chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    else
        chars=('|' '/' '-' '\')
    fi
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}%s${RESET} %s" "${chars[$i]}" "$message" >&2
        i=$(( (i + 1) % ${#chars[@]} ))
        sleep 0.1
    done
    printf "\r%*s\r" $(( ${#message} + 3 )) "" >&2
}

is_port_in_use() {
    local port="$1" bind_addr="${2:-127.0.0.1}"
    if command -v ss &>/dev/null; then
        local _ss_pattern
        if [[ "$bind_addr" == "0.0.0.0" ]] || [[ "$bind_addr" == "::" ]] || [[ "$bind_addr" == "[::]" ]]; then
            _ss_pattern="\\*"
        elif [[ "$bind_addr" =~ : ]]; then
            # IPv6 — ss shows as [addr]:port; escape brackets for grep
            local _stripped="${bind_addr#\[}"
            _stripped="${_stripped%\]}"
            _ss_pattern="\\[${_stripped}\\]"
        else
            _ss_pattern="${bind_addr//./\\.}"
        fi
        ss -tln sport = :"${port}" 2>/dev/null | tail -n +2 | grep -qE "(${_ss_pattern}|\\*):" 2>/dev/null
    elif command -v netstat &>/dev/null; then
        netstat -tln 2>/dev/null | grep -qE "(${bind_addr//./\\.}|0\\.0\\.0\\.0):${port}([[:space:]]|$)"
    else
        return 1
    fi
}

get_term_width() {
    tput cols 2>/dev/null || echo 80
}

# ============================================================================
# OS DETECTION & PACKAGE MANAGEMENT
# ============================================================================

declare -g OS_ID=""
declare -g OS_VERSION=""
declare -g OS_FAMILY=""
declare -g PKG_MANAGER=""
declare -g PKG_INSTALL=""
declare -g PKG_UPDATE=""
declare -g INIT_SYSTEM=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # Parse directly — sourcing collides with our readonly VERSION
        OS_ID=$(grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"') || true
        OS_VERSION=$(grep -m1 '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"') || true
        : "${OS_ID:=unknown}" "${OS_VERSION:=unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1 || true)
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi

    case "${OS_ID}" in
        ubuntu|debian|raspbian|linuxmint|pop|kali|parrot)
            OS_FAMILY="debian"
            PKG_MANAGER="apt-get"
            PKG_INSTALL="apt-get install -y"
            PKG_UPDATE="apt-get update"
            ;;
        fedora|centos|rhel|rocky|almalinux|ol)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
                PKG_INSTALL="dnf install -y"
                PKG_UPDATE="dnf check-update"
            else
                PKG_MANAGER="yum"
                PKG_INSTALL="yum install -y"
                PKG_UPDATE="yum check-update"
            fi
            ;;
        arch|manjaro|endeavouros)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_UPDATE="pacman -Sy"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            PKG_INSTALL="apk add"
            PKG_UPDATE="apk update"
            ;;
        opensuse*|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            PKG_INSTALL="zypper install -y"
            PKG_UPDATE="zypper refresh"
            ;;
        *)
            OS_FAMILY="unknown"
            log_warn "Unknown OS: ${OS_ID}. Some features may not work."
            ;;
    esac

    # Detect init system
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    elif [[ -d /etc/init.d ]]; then
        INIT_SYSTEM="sysvinit"
    else
        INIT_SYSTEM="unknown"
    fi

    log_debug "Detected OS: ${OS_ID} ${OS_VERSION} (${OS_FAMILY}), init: ${INIT_SYSTEM}"
}

install_package() {
    local pkg="$1"
    local pkg_name="$pkg"

    case "${OS_FAMILY}" in
        debian)
            case "$pkg" in
                openssh-client) pkg_name="openssh-client" ;;
                ncurses)        pkg_name="ncurses-bin"    ;;
            esac ;;
        rhel)
            case "$pkg" in
                openssh-client) pkg_name="openssh-clients" ;;
                ncurses)        pkg_name="ncurses"         ;;
                iproute2)       pkg_name="iproute"         ;;
            esac ;;
        arch)
            case "$pkg" in
                openssh-client) pkg_name="openssh"   ;;
                ncurses)        pkg_name="ncurses"   ;;
                iproute2)       pkg_name="iproute2"  ;;
            esac ;;
        alpine)
            case "$pkg" in
                openssh-client) pkg_name="openssh-client" ;;
                ncurses)        pkg_name="ncurses"        ;;
                iproute2)       pkg_name="iproute2"       ;;
            esac ;;
        suse)
            case "$pkg" in
                openssh-client) pkg_name="openssh"        ;;
                ncurses)        pkg_name="ncurses-utils"  ;;
                iproute2)       pkg_name="iproute2"       ;;
            esac ;;
    esac

    if [[ -z "$PKG_INSTALL" ]]; then
        log_error "No package manager configured for this OS"
        return 1
    fi
    log_info "Installing ${pkg_name}..."
    if ${PKG_INSTALL} "${pkg_name}" &>/dev/null; then
        log_success "Installed ${pkg_name}"
        return 0
    else
        log_error "Failed to install ${pkg_name}"
        return 1
    fi
}

check_dependencies() {
    local missing=()

    local -A deps=(
        [ssh]="openssh-client"
        [autossh]="autossh"
        [sshpass]="sshpass"
        [iptables]="iptables"
        [curl]="curl"
        [ip]="iproute2"
        [tput]="ncurses"
        [bc]="bc"
        [jq]="jq"
    )

    log_info "Checking dependencies..."
    for cmd in "${!deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("${deps[$cmd]}")
            log_warn "Missing: ${cmd} (package: ${deps[$cmd]})"
        else
            log_debug "Found: ${cmd}"
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "All dependencies satisfied"
        return 0
    fi

    log_info "Missing ${#missing[@]} package(s): ${missing[*]}"

    if ! check_root; then
        log_error "Root access needed to install missing packages"
        return 1
    fi

    log_info "Updating package cache..."
    ${PKG_UPDATE} &>/dev/null || true

    local failed=0
    for pkg in "${missing[@]}"; do
        install_package "$pkg" || ((++failed))
    done

    if (( failed > 0 )); then
        log_error "${failed} package(s) failed to install"
        return 1
    fi

    log_success "All dependencies installed"
    return 0
}

# ============================================================================
# SETTINGS LOAD / SAVE  (safe whitelist-validated parser)
# ============================================================================

readonly CONFIG_WHITELIST=(
    SSH_DEFAULT_USER SSH_DEFAULT_PORT SSH_DEFAULT_KEY
    SSH_CONNECT_TIMEOUT SSH_SERVER_ALIVE_INTERVAL SSH_SERVER_ALIVE_COUNT_MAX
    SSH_STRICT_HOST_KEY
    AUTOSSH_ENABLED AUTOSSH_POLL AUTOSSH_GATETIME AUTOSSH_MONITOR_PORT
    AUTOSSH_FIRST_POLL AUTOSSH_LOG_LEVEL
    CONTROLMASTER_ENABLED CONTROLMASTER_PERSIST
    DNS_LEAK_PROTECTION DNS_SERVER_1 DNS_SERVER_2 KILL_SWITCH
    TELEGRAM_ENABLED TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    TELEGRAM_ALERTS TELEGRAM_PERIODIC_STATUS TELEGRAM_STATUS_INTERVAL
    DASHBOARD_REFRESH DASHBOARD_THEME
    LOG_LEVEL LOG_JSON LOG_MAX_SIZE LOG_ROTATE_COUNT
    AUTO_UPDATE_CHECK
)

_is_whitelisted() {
    local key="$1" k
    for k in "${CONFIG_WHITELIST[@]}"; do
        if [[ "$k" == "$key" ]]; then return 0; fi
    done
    return 1
}

load_settings() {
    local config_file="${1:-$MAIN_CONFIG}"
    [[ -f "$config_file" ]] || return 0

    log_debug "Loading settings from: ${config_file}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]]  && continue
        [[ "$line" =~ ^[[:space:]]*$ ]]   && continue

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Strip matched outer quote pairs, then un-escape
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"; value="${value%\'}"
                value="${value//\'\\\'\'/\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"; value="${value%\"}"
            fi

            if _is_whitelisted "$key"; then
                CONFIG["$key"]="$value"
                if [[ "$key" == "TELEGRAM_BOT_TOKEN" ]] || [[ "$key" == "TELEGRAM_CHAT_ID" ]]; then
                    log_debug "Loaded: ${key}=****"
                else
                    log_debug "Loaded: ${key}=${value}"
                fi
            else
                log_warn "Ignoring unknown config key: ${key}"
            fi
        fi
    done < "$config_file"

    log_debug "Settings loaded"
}

save_settings() {
    local config_file="${1:-$MAIN_CONFIG}"

    # Acquire file-level lock to prevent concurrent writer races
    local _ss_lock_fd="" _ss_lock_dir=""
    _ss_unlock() {
        if [[ -n "${_ss_lock_fd:-}" ]]; then exec {_ss_lock_fd}>&- 2>/dev/null || true; fi
        if [[ -n "${_ss_lock_dir:-}" ]]; then
            rm -f "${_ss_lock_dir}/pid" 2>/dev/null || true
            rmdir "${_ss_lock_dir}" 2>/dev/null || true
            _ss_lock_dir=""
        fi
    }
    if command -v flock &>/dev/null; then
        exec {_ss_lock_fd}>"${config_file}.lock"
        flock -w 5 "$_ss_lock_fd" 2>/dev/null || { log_warn "Could not acquire settings lock"; _ss_unlock; return 1; }
    else
        _ss_lock_dir="${config_file}.lck"
        local _ss_try=0
        while ! mkdir "$_ss_lock_dir" 2>/dev/null; do
            local _ss_stale_pid=""
            _ss_stale_pid=$(cat "${_ss_lock_dir}/pid" 2>/dev/null) || true
            if [[ -n "$_ss_stale_pid" ]] && ! kill -0 "$_ss_stale_pid" 2>/dev/null; then
                rm -f "${_ss_lock_dir}/pid" 2>/dev/null || true
                rmdir "$_ss_lock_dir" 2>/dev/null || true
                continue
            fi
            if (( ++_ss_try >= 10 )); then log_warn "Could not acquire settings lock"; return 1; fi
            sleep 0.5
        done
        printf '%s' "$$" > "${_ss_lock_dir}/pid" 2>/dev/null || true
    fi

    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/config.XXXXXX")

    mkdir -p "$(dirname "$config_file")" 2>/dev/null || true

    cat > "$tmp_file" <<'HEADER'
# ============================================================================
# TunnelForge Configuration
# Generated automatically — edit with care
# ============================================================================
HEADER

    local key _sv
    {
        for key in "${CONFIG_WHITELIST[@]}"; do
            if [[ -n "${CONFIG[$key]+x}" ]]; then
                _sv="${CONFIG[$key]//$'\n'/}"
                _sv="${_sv//\'/\'\\\'\'}"
                printf "%s='%s'\n" "$key" "$_sv"
            fi
        done
    } >> "$tmp_file"

    # Set permissions before mv so there's no window of insecure perms
    chmod 600 "$tmp_file" 2>/dev/null || true
    # mv fails across filesystems (/tmp → /etc), fall back to cp to same-dir temp then mv
    if mv "$tmp_file" "$config_file" 2>/dev/null || \
       { cp "$tmp_file" "${config_file}.tmp.$$" 2>/dev/null && \
         mv "${config_file}.tmp.$$" "$config_file" 2>/dev/null && \
         rm -f "$tmp_file" 2>/dev/null; }; then
        log_debug "Settings saved to: ${config_file}"
        _ss_unlock
        return 0
    fi
    rm -f "${config_file}.tmp.$$" 2>/dev/null
    rm -f "$tmp_file" 2>/dev/null
    log_error "Failed to save settings to: ${config_file}"
    _ss_unlock
    return 1
}

# ============================================================================
# DIRECTORY INITIALIZATION
# ============================================================================

init_directories() {
    local dirs=(
        "$INSTALL_DIR"  "$CONFIG_DIR"     "$PROFILES_DIR"
        "$PID_DIR"      "$LOG_DIR"        "$BACKUP_DIR"
        "$DATA_DIR"     "$SSH_CONTROL_DIR"
        "$BW_HISTORY_DIR" "$RECONNECT_LOG_DIR"
    )
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || {
                log_error "Failed to create directory: ${dir}"
                return 1
            }
        fi
    done
    chmod 700 "$CONFIG_DIR"      2>/dev/null || true
    chmod 700 "$SSH_CONTROL_DIR" 2>/dev/null || true
    chmod 700 "$LOG_DIR"         2>/dev/null || true
    chmod 700 "$PROFILES_DIR"    2>/dev/null || true
    chmod 700 "$PID_DIR"         2>/dev/null || true
    chmod 700 "$BACKUP_DIR"      2>/dev/null || true
    chmod 700 "$DATA_DIR"        2>/dev/null || true
    chmod 700 "$BW_HISTORY_DIR"      2>/dev/null || true
    chmod 700 "$RECONNECT_LOG_DIR"   2>/dev/null || true
    chmod 755 "$INSTALL_DIR"     2>/dev/null || true
    log_debug "Directories initialized"
}

# ============================================================================
# PROFILE MANAGEMENT
# ============================================================================

readonly PROFILE_FIELDS=(
    PROFILE_NAME TUNNEL_TYPE
    SSH_HOST SSH_PORT SSH_USER SSH_PASSWORD IDENTITY_KEY
    LOCAL_BIND_ADDR LOCAL_PORT REMOTE_HOST REMOTE_PORT
    JUMP_HOSTS SSH_OPTIONS
    AUTOSSH_ENABLED AUTOSSH_MONITOR_PORT
    DNS_LEAK_PROTECTION KILL_SWITCH AUTOSTART
    OBFS_MODE OBFS_PORT OBFS_LOCAL_PORT OBFS_PSK
    DESCRIPTION
)

_profile_path() { echo "${PROFILES_DIR}/${1}.conf"; }

create_profile() {
    local name="$1"

    if ! validate_profile_name "$name"; then
        log_error "Invalid profile name: '${name}'"
        log_info  "Use letters, numbers, hyphens, underscores (max 64 chars)"
        return 1
    fi

    local profile_file
    profile_file=$(_profile_path "$name")
    if [[ -f "$profile_file" ]]; then
        log_error "Profile '${name}' already exists"
        return 1
    fi

    local -A profile=(
        [PROFILE_NAME]="$name"
        [TUNNEL_TYPE]="socks5"
        [SSH_HOST]=""
        [SSH_PORT]="$(config_get SSH_DEFAULT_PORT 22)"
        [SSH_USER]="$(config_get SSH_DEFAULT_USER root)"
        [IDENTITY_KEY]="$(config_get SSH_DEFAULT_KEY)"
        [LOCAL_BIND_ADDR]="127.0.0.1"
        [LOCAL_PORT]="1080"
        [REMOTE_HOST]=""
        [REMOTE_PORT]=""
        [JUMP_HOSTS]=""
        [SSH_OPTIONS]=""
        [AUTOSSH_ENABLED]="$(config_get AUTOSSH_ENABLED true)"
        [AUTOSSH_MONITOR_PORT]="0"
        [DNS_LEAK_PROTECTION]="false"
        [KILL_SWITCH]="false"
        [AUTOSTART]="false"
        [DESCRIPTION]=""
    )

    _save_profile_data "$profile_file" profile
    log_success "Profile '${name}' created"
}

load_profile() {
    local name="$1"
    local -n _profile_ref="$2"

    local profile_file
    profile_file=$(_profile_path "$name")
    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile '${name}' not found"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            # Strip matched outer quote pairs, then un-escape
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"; value="${value%\'}"
                value="${value//\'\\\'\'/\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"; value="${value%\"}"
            fi

            local valid=false field
            for field in "${PROFILE_FIELDS[@]}"; do
                [[ "$field" == "$key" ]] && { valid=true; break; }
            done
            if [[ "$valid" == true ]]; then _profile_ref["$key"]="$value"; fi
        fi
    done < "$profile_file"

    # Validate critical fields against injection
    local _fld _fval
    for _fld in SSH_USER SSH_HOST REMOTE_HOST; do
        _fval="${_profile_ref[$_fld]:-}"
        [[ -z "$_fval" ]] && continue
        if [[ "$_fval" =~ [[:cntrl:]] ]]; then
            log_error "Profile '${name}': ${_fld} contains control characters"
            return 1
        fi
    done
    if [[ -n "${_profile_ref[SSH_USER]:-}" ]] && \
       ! [[ "${_profile_ref[SSH_USER]}" =~ ^[a-zA-Z0-9._@-]+$ ]]; then
        log_error "Profile '${name}': SSH_USER contains invalid characters"
        return 1
    fi
    if [[ -n "${_profile_ref[SSH_HOST]:-}" ]] && \
       ! [[ "${_profile_ref[SSH_HOST]}" =~ ^[a-zA-Z0-9._:%-]+$|^\[[0-9a-fA-F:]+\]$ ]]; then
        log_error "Profile '${name}': SSH_HOST contains invalid characters"
        return 1
    fi
    if [[ -n "${_profile_ref[REMOTE_HOST]:-}" ]] && \
       ! [[ "${_profile_ref[REMOTE_HOST]}" =~ ^[a-zA-Z0-9._:%-]+$|^\[[0-9a-fA-F:]+\]$ ]]; then
        log_error "Profile '${name}': REMOTE_HOST contains invalid characters"
        return 1
    fi

    log_debug "Profile '${name}' loaded"
}

_save_profile_data() {
    local file="$1"
    local -n _data_ref="$2"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true

    # Acquire file-level lock to prevent concurrent writer races
    local _spd_lock_fd="" _spd_lock_dir=""
    _spd_unlock() {
        if [[ -n "${_spd_lock_fd:-}" ]]; then exec {_spd_lock_fd}>&- 2>/dev/null || true; fi
        if [[ -n "${_spd_lock_dir:-}" ]]; then
            rm -f "${_spd_lock_dir}/pid" 2>/dev/null || true
            rmdir "${_spd_lock_dir}" 2>/dev/null || true
            _spd_lock_dir=""
        fi
    }
    if command -v flock &>/dev/null; then
        exec {_spd_lock_fd}>"${file}.lock"
        flock -w 5 "$_spd_lock_fd" 2>/dev/null || { log_warn "Could not acquire profile lock"; _spd_unlock; return 1; }
    else
        _spd_lock_dir="${file}.lck"
        local _spd_try=0
        while ! mkdir "$_spd_lock_dir" 2>/dev/null; do
            local _spd_stale_pid=""
            _spd_stale_pid=$(cat "${_spd_lock_dir}/pid" 2>/dev/null) || true
            if [[ -n "$_spd_stale_pid" ]] && ! kill -0 "$_spd_stale_pid" 2>/dev/null; then
                rm -f "${_spd_lock_dir}/pid" 2>/dev/null || true
                rmdir "$_spd_lock_dir" 2>/dev/null || true
                continue
            fi
            if (( ++_spd_try >= 10 )); then log_warn "Could not acquire profile lock"; return 1; fi
            sleep 0.5
        done
        printf '%s' "$$" > "${_spd_lock_dir}/pid" 2>/dev/null || true
    fi

    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/profile.XXXXXX")

    {
        printf "# TunnelForge Profile\n"
        printf "# Generated: %s\n\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local _sv field
        for field in "${PROFILE_FIELDS[@]}"; do
            if [[ -n "${_data_ref[$field]+x}" ]]; then
                _sv="${_data_ref[$field]//$'\n'/}"
                _sv="${_sv//\'/\'\\\'\'}"
                printf "%s='%s'\n" "$field" "$_sv"
            fi
        done
    } > "$tmp_file"

    # Set permissions before mv so there's no window of insecure perms
    chmod 600 "$tmp_file" 2>/dev/null || true
    # mv fails across filesystems (/tmp → /opt), fall back to cp to same-dir temp then mv
    if ! { mv "$tmp_file" "$file" 2>/dev/null || \
           { cp "$tmp_file" "${file}.tmp.$$" 2>/dev/null && \
             mv "${file}.tmp.$$" "$file" 2>/dev/null && \
             rm -f "$tmp_file" 2>/dev/null; }; }; then
        rm -f "$tmp_file" "${file}.tmp.$$" 2>/dev/null
        log_error "Failed to save profile: ${file}"
        _spd_unlock
        return 1
    fi
    _spd_unlock
}

save_profile() {
    local name="$1"
    local -n _prof_ref="$2"
    _save_profile_data "$(_profile_path "$name")" _prof_ref || { log_error "Failed to save profile '${name}'"; return 1; }
    log_debug "Profile '${name}' saved"
}

delete_profile() {
    local name="$1"
    local profile_file
    profile_file=$(_profile_path "$name")

    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile '${name}' not found"
        return 1
    fi

    # Stop tunnel if running
    if is_tunnel_running "$name"; then
        log_info "Stopping running tunnel '${name}'..."
        stop_tunnel "$name" || log_warn "Could not stop tunnel '${name}'"
    fi

    rm -f "$profile_file" 2>/dev/null || true
    rm -f "${PID_DIR}/${name}.pid"         2>/dev/null || true
    rm -f "${BW_HISTORY_DIR}/${name}.dat"  2>/dev/null || true
    rm -f "${RECONNECT_LOG_DIR}/${name}.log" 2>/dev/null || true
    log_success "Profile '${name}' deleted"
}

list_profiles() {
    if [[ ! -d "$PROFILES_DIR" ]] || \
       [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]]; then
        return 0
    fi
    local f
    for f in "${PROFILES_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        basename "$f" .conf
    done
}

get_profile_field() {
    local name="$1" field="$2"
    local -A _gpf
    if load_profile "$name" _gpf; then
        echo "${_gpf[$field]:-}"
    else
        return 1
    fi
}

update_profile_field() {
    local name="$1" field="$2" value="$3"
    local -A _upf
    load_profile "$name" _upf || return 1
    _upf["$field"]="$value"
    save_profile "$name" _upf
}

# ============================================================================
# SSH COMMAND BUILDERS
# ============================================================================

_validate_jump_hosts() {
    local hosts="$1"
    [[ -z "$hosts" ]] && return 0
    if [[ ! "$hosts" =~ ^([a-zA-Z0-9._@:%-]+,)*[a-zA-Z0-9._@:%-]+$ ]]; then
        log_error "Invalid JUMP_HOSTS format: ${hosts}"
        return 1
    fi
    return 0
}

get_ssh_base_opts() {
    local -n _opts_profile="$1"
    local opts=()

    opts+=(-o "ConnectTimeout=$(config_get SSH_CONNECT_TIMEOUT 10)")
    opts+=(-o "ServerAliveInterval=$(config_get SSH_SERVER_ALIVE_INTERVAL 30)")
    opts+=(-o "ServerAliveCountMax=$(config_get SSH_SERVER_ALIVE_COUNT_MAX 3)")

    local strict
    strict=$(config_get SSH_STRICT_HOST_KEY "yes")
    opts+=(-o "StrictHostKeyChecking=${strict}")

    opts+=(-N)                                   # no remote command
    opts+=(-T)                                   # no pseudo-TTY
    opts+=(-o "ExitOnForwardFailure=yes")

    # Identity key
    local key="${_opts_profile[IDENTITY_KEY]:-}"
    if [[ -n "$key" ]] && [[ -f "$key" ]]; then opts+=(-i "$key"); fi

    # Port
    local _ssh_port="${_opts_profile[SSH_PORT]:-22}"
    if ! validate_port "$_ssh_port"; then
        log_error "Invalid SSH port: ${_ssh_port}"
        return 1
    fi
    opts+=(-p "$_ssh_port")

    # Extra SSH options (allowlist — only known-safe options accepted)
    local extra="${_opts_profile[SSH_OPTIONS]:-}"
    if [[ -n "$extra" ]]; then
        local -a _extra_arr
        read -ra _extra_arr <<< "$extra" || true
        local -a _validated_opts=()
        local _opt _opt_name _skip_next=false
        for _opt in "${_extra_arr[@]}"; do
            if [[ "$_skip_next" == true ]]; then
                _skip_next=false
                _opt_name="${_opt%%=*}"
                if ! printf '%s' "$_opt_name" | grep -qiE '^(Compression|TCPKeepAlive|IPQoS|RekeyLimit|Ciphers|MACs|KexAlgorithms|HostKeyAlgorithms|PubkeyAcceptedAlgorithms|PubkeyAcceptedKeyTypes|ConnectionAttempts|ConnectTimeout|NumberOfPasswordPrompts|PreferredAuthentications|AddressFamily|BatchMode|CheckHostIP|HashKnownHosts|NoHostAuthenticationForLocalhost|PasswordAuthentication|StrictHostKeyChecking|UpdateHostKeys|VerifyHostKeyDNS|VisualHostKey|LogLevel|ServerAliveInterval|ServerAliveCountMax|GSSAPIAuthentication|GSSAPIDelegateCredentials)$'; then
                    log_error "SSH option not in allowlist: ${_opt}"
                    return 1
                fi
                _validated_opts+=(-o "$_opt")
                continue
            fi
            if [[ "$_opt" == "-o" ]]; then
                _skip_next=true; continue
            fi
            _opt_name="${_opt%%=*}"
            if ! printf '%s' "$_opt_name" | grep -qiE '^(Compression|TCPKeepAlive|IPQoS|RekeyLimit|Ciphers|MACs|KexAlgorithms|HostKeyAlgorithms|PubkeyAcceptedAlgorithms|PubkeyAcceptedKeyTypes|ConnectionAttempts|ConnectTimeout|NumberOfPasswordPrompts|PreferredAuthentications|AddressFamily|BatchMode|CheckHostIP|HashKnownHosts|NoHostAuthenticationForLocalhost|PasswordAuthentication|StrictHostKeyChecking|UpdateHostKeys|VerifyHostKeyDNS|VisualHostKey|LogLevel|ServerAliveInterval|ServerAliveCountMax|GSSAPIAuthentication|GSSAPIDelegateCredentials)$'; then
                log_error "SSH option not in allowlist: ${_opt}"
                return 1
            fi
            _validated_opts+=(-o "$_opt")
        done
        if [[ "$_skip_next" == true ]]; then
            log_error "SSH option -o without value"
            return 1
        fi
        opts+=("${_validated_opts[@]}")
    fi

    # ControlMaster
    if [[ "$(config_get CONTROLMASTER_ENABLED false)" == "true" ]]; then
        opts+=(-o "ControlMaster=auto")
        opts+=(-o "ControlPath=${SSH_CONTROL_DIR}/%C")
        opts+=(-o "ControlPersist=$(config_get CONTROLMASTER_PERSIST 600)")
    fi

    printf '%s\n' "${opts[@]}"
}

# Wrap bare IPv6 addresses in brackets for SSH forwarding specs
_bracket_ipv6() {
    local addr="$1"
    if [[ "$addr" =~ : ]] && [[ "$addr" != \[* ]]; then
        printf '[%s]' "$addr"
    else
        printf '%s' "$addr"
    fi
}

_unbracket_ipv6() {
    local addr="$1"
    addr="${addr#\[}"
    addr="${addr%\]}"
    printf '%s' "$addr"
}

# ── Obfuscation-aware jump/proxy options builder ──
# Appends the correct jump/proxy flags based on OBFS_MODE.
# When OBFS_MODE=stunnel: uses ProxyCommand with openssl s_client.
# When no obfuscation: uses standard -J for jump hosts.
# Args: profile_nameref cmd_array_nameref
_build_obfs_proxy_or_jump() {
    local -n _ob_prof="$1"
    local -n _ob_cmd="$2"

    local _ob_mode="${_ob_prof[OBFS_MODE]:-none}"
    local _ob_port="${_ob_prof[OBFS_PORT]:-443}"
    local _ob_jump="${_ob_prof[JUMP_HOSTS]:-}"

    # Validate port is numeric to prevent injection in ProxyCommand
    if [[ -n "$_ob_port" ]] && ! [[ "$_ob_port" =~ ^[0-9]+$ ]]; then
        log_error "OBFS_PORT must be numeric"; return 1
    fi

    if [[ "$_ob_mode" == "stunnel" ]]; then
        if [[ -n "$_ob_jump" ]]; then
            # Jump host + stunnel: wrap the jump connection in TLS
            _validate_jump_hosts "$_ob_jump" || return 1
            # Parse first jump host: user@host:port
            local _jh="${_ob_jump%%,*}"
            local _juser="" _jhost="" _jport="22"
            if [[ "$_jh" == *@* ]]; then
                _juser="${_jh%%@*}"
                _jh="${_jh#*@}"
            fi
            if [[ "$_jh" == *:* ]]; then
                _jport="${_jh##*:}"
                _jhost="${_jh%%:*}"
            else
                _jhost="$_jh"
            fi
            # Validate parsed jump host/port to prevent ProxyCommand injection
            if ! [[ "$_jport" =~ ^[0-9]+$ ]]; then
                log_error "Jump host port must be numeric"; return 1
            fi
            if ! [[ "$_jhost" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
                log_error "Jump host contains invalid characters"; return 1
            fi
            local _jdest="${_juser:+${_juser}@}${_jhost}"
            # Nested ProxyCommand: connect to jump via stunnel, then -W to target
            local _inner_pc="openssl s_client -connect ${_jhost}:${_ob_port} -quiet 2>/dev/null"
            _ob_cmd+=(-o "ProxyCommand=ssh -o 'ProxyCommand=${_inner_pc}' -p ${_jport} -W %h:%p ${_jdest}")
        else
            # Direct tunnel + stunnel: openssl s_client as ProxyCommand
            _ob_cmd+=(-o "ProxyCommand=openssl s_client -connect %h:${_ob_port} -quiet 2>/dev/null")
        fi
    else
        # No obfuscation: standard -J for jump hosts
        if [[ -n "$_ob_jump" ]]; then
            _validate_jump_hosts "$_ob_jump" || return 1
            _ob_cmd+=(-J "$_ob_jump")
        fi
    fi
    return 0
}

build_socks5_cmd() {
    local -n _s5="$1"
    local cmd=() base_opts _base_output
    _base_output=$(get_ssh_base_opts _s5) || return 1
    mapfile -t base_opts <<< "$_base_output"
    cmd+=(ssh "${base_opts[@]}")

    local bind
    bind=$(_bracket_ipv6 "${_s5[LOCAL_BIND_ADDR]:-127.0.0.1}")
    local port="${_s5[LOCAL_PORT]:-1080}"
    cmd+=(-D "${bind}:${port}")

    _build_obfs_proxy_or_jump _s5 cmd || return 1

    local user="${_s5[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"
    local _ssh_dest
    _ssh_dest=$(_unbracket_ipv6 "${_s5[SSH_HOST]}")
    cmd+=("${user}@${_ssh_dest}")

    printf '%s\n' "${cmd[@]}"
}

build_local_forward_cmd() {
    local -n _lf="$1"
    local cmd=() base_opts _base_output
    _base_output=$(get_ssh_base_opts _lf) || return 1
    mapfile -t base_opts <<< "$_base_output"
    cmd+=(ssh "${base_opts[@]}")

    local bind rhost
    bind=$(_bracket_ipv6 "${_lf[LOCAL_BIND_ADDR]:-127.0.0.1}")
    rhost=$(_bracket_ipv6 "${_lf[REMOTE_HOST]}")
    cmd+=(-L "${bind}:${_lf[LOCAL_PORT]}:${rhost}:${_lf[REMOTE_PORT]}")

    _build_obfs_proxy_or_jump _lf cmd || return 1

    local user="${_lf[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"
    local _ssh_dest
    _ssh_dest=$(_unbracket_ipv6 "${_lf[SSH_HOST]}")
    cmd+=("${user}@${_ssh_dest}")

    printf '%s\n' "${cmd[@]}"
}

build_remote_forward_cmd() {
    local -n _rf="$1"
    local cmd=() base_opts _base_output
    _base_output=$(get_ssh_base_opts _rf) || return 1
    mapfile -t base_opts <<< "$_base_output"
    cmd+=(ssh "${base_opts[@]}")

    local rhost rbind
    rhost=$(_bracket_ipv6 "${_rf[REMOTE_HOST]:-localhost}")
    rbind="${_rf[LOCAL_BIND_ADDR]:-}"
    if [[ -n "$rbind" ]]; then
        rbind=$(_bracket_ipv6 "$rbind")
        cmd+=(-R "${rbind}:${_rf[REMOTE_PORT]}:${rhost}:${_rf[LOCAL_PORT]}")
    else
        cmd+=(-R "${_rf[REMOTE_PORT]}:${rhost}:${_rf[LOCAL_PORT]}")
    fi

    _build_obfs_proxy_or_jump _rf cmd || return 1

    local user="${_rf[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"
    local _ssh_dest
    _ssh_dest=$(_unbracket_ipv6 "${_rf[SSH_HOST]}")
    cmd+=("${user}@${_ssh_dest}")

    printf '%s\n' "${cmd[@]}"
}

build_tunnel_cmd() {
    local name="$1"
    local -A _bt
    load_profile "$name" _bt || return 1

    case "${_bt[TUNNEL_TYPE]:-socks5}" in
        socks5)  build_socks5_cmd         _bt ;;
        local)   build_local_forward_cmd  _bt ;;
        remote)  build_remote_forward_cmd _bt ;;
        jump)    # Legacy: dispatch based on whether remote target is set
                 if [[ -n "${_bt[REMOTE_HOST]:-}" ]] && [[ -n "${_bt[REMOTE_PORT]:-}" ]]; then
                     build_local_forward_cmd _bt
                 else
                     build_socks5_cmd _bt
                 fi ;;
        *)
            log_error "Unknown tunnel type: ${_bt[TUNNEL_TYPE]}"
            return 1 ;;
    esac
}

# ============================================================================
# TUNNEL LIFECYCLE
# ============================================================================

_pid_file() { echo "${PID_DIR}/${1}.pid"; }
_log_file() { echo "${LOG_DIR}/${1}.log"; }

is_tunnel_running() {
    local name="$1"
    local pid_file
    pid_file=$(_pid_file "$name")
    [[ -f "$pid_file" ]] || return 1

    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || true
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    return 0
}

_clean_stale_pid() {
    local name="$1"
    local pid_file
    pid_file=$(_pid_file "$name")
    [[ -f "$pid_file" ]] || return 0
    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || true
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file" "${pid_file}.autossh" "${PID_DIR}/${name}.stunnel" \
             "${PID_DIR}/${name}.started" "${PID_DIR}/${name}.askpass" "${PID_DIR}/${name}.pass" 2>/dev/null
    fi
    return 0
}

get_tunnel_pid() {
    local pid_file
    pid_file=$(_pid_file "$1")
    if [[ -f "$pid_file" ]]; then
        cat "$pid_file" 2>/dev/null || true
    fi
    return 0
}

_record_reconnect() {
    local name="$1" reason="${2:-unknown}"
    printf "%s|%s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$reason" \
        >> "${RECONNECT_LOG_DIR}/${name}.log" 2>/dev/null || true
    _notify_reconnect "$name" "$reason"
    return 0
}

start_tunnel() {
    local name="$1"

    # Per-profile lock to prevent concurrent start/stop races
    local _st_lock_fd="" _st_lock_dir=""
    _st_unlock() {
        if [[ -n "${_st_lock_fd:-}" ]]; then exec {_st_lock_fd}>&- 2>/dev/null || true; fi
        if [[ -n "${_st_lock_dir:-}" ]]; then
            rm -f "${_st_lock_dir}/pid" 2>/dev/null || true
            rmdir "${_st_lock_dir}" 2>/dev/null || true
            _st_lock_dir=""
        fi
        rm -f "${PID_DIR}/${name}.lock" 2>/dev/null || true
    }
    if command -v flock &>/dev/null; then
        exec {_st_lock_fd}>"${PID_DIR}/${name}.lock" 2>/dev/null || { log_error "Could not open lock file for '${name}'"; return 1; }
        flock -w 10 "$_st_lock_fd" 2>/dev/null || { log_error "Could not acquire lock for '${name}'"; _st_unlock; return 1; }
    else
        _st_lock_dir="${PID_DIR}/${name}.lck"
        local _st_try=0
        while ! mkdir "$_st_lock_dir" 2>/dev/null; do
            local _st_stale_pid=""
            _st_stale_pid=$(cat "${_st_lock_dir}/pid" 2>/dev/null) || true
            if [[ -n "$_st_stale_pid" ]] && ! kill -0 "$_st_stale_pid" 2>/dev/null; then
                rm -f "${_st_lock_dir}/pid" 2>/dev/null || true
                rmdir "$_st_lock_dir" 2>/dev/null || true
                continue
            fi
            if (( ++_st_try >= 20 )); then log_error "Could not acquire lock for '${name}'"; return 1; fi
            sleep 0.5
        done
        printf '%s' "$$" > "${_st_lock_dir}/pid" 2>/dev/null || true
    fi

    # Rotate logs if needed
    rotate_logs 2>/dev/null || true

    local profile_file
    profile_file=$(_profile_path "$name")
    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile '${name}' not found"
        _st_unlock; return 1
    fi

    if is_tunnel_running "$name"; then
        log_warn "Tunnel '${name}' is already running (PID: $(get_tunnel_pid "$name"))"
        _st_unlock; return 2
    fi

    local -A _sp
    load_profile "$name" _sp || { _st_unlock; return 1; }

    local tunnel_type="${_sp[TUNNEL_TYPE]:-socks5}"
    local ssh_host="${_sp[SSH_HOST]}"
    local local_port="${_sp[LOCAL_PORT]:-}"
    local bind_addr="${_sp[LOCAL_BIND_ADDR]:-127.0.0.1}"

    # Force 127.0.0.1 binding when inbound TLS is active (stunnel wraps the port)
    if [[ -n "${_sp[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_sp[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
        if [[ "$bind_addr" != "127.0.0.1" ]]; then
            log_info "Inbound TLS active — forcing bind to 127.0.0.1 (stunnel handles external access)"
            bind_addr="127.0.0.1"
            _sp[LOCAL_BIND_ADDR]="127.0.0.1"
        fi
    fi

    # Validate port numbers
    if [[ -n "$local_port" ]] && ! validate_port "$local_port"; then
        log_error "Invalid LOCAL_PORT '${local_port}' in profile '${name}'"
        _st_unlock; return 1
    fi
    if [[ -n "${_sp[REMOTE_PORT]:-}" ]] && ! validate_port "${_sp[REMOTE_PORT]}"; then
        log_error "Invalid REMOTE_PORT '${_sp[REMOTE_PORT]}' in profile '${name}'"
        _st_unlock; return 1
    fi

    if [[ -z "$ssh_host" ]]; then
        log_error "SSH host not configured for profile '${name}'"
        _st_unlock; return 1
    fi

    # Validate openssl is available for TLS obfuscation
    if [[ "${_sp[OBFS_MODE]:-none}" == "stunnel" ]]; then
        if ! command -v openssl &>/dev/null; then
            log_error "openssl required for TLS obfuscation but not found"
            _st_unlock; return 1
        fi
        log_debug "TLS obfuscation enabled (port ${_sp[OBFS_PORT]:-443})"
    fi

    # Validate required fields for forward tunnels
    if [[ "$tunnel_type" == "local" ]]; then
        if [[ -z "${_sp[REMOTE_HOST]:-}" ]] || [[ -z "${_sp[REMOTE_PORT]:-}" ]]; then
            log_error "Local forward requires REMOTE_HOST and REMOTE_PORT"
            _st_unlock; return 1
        fi
        if [[ -z "${_sp[LOCAL_PORT]:-}" ]]; then
            log_error "Local forward requires LOCAL_PORT"
            _st_unlock; return 1
        fi
    elif [[ "$tunnel_type" == "remote" ]]; then
        if [[ -z "${_sp[REMOTE_PORT]:-}" ]] || [[ -z "${_sp[LOCAL_PORT]:-}" ]]; then
            log_error "Remote forward requires REMOTE_PORT and LOCAL_PORT"
            _st_unlock; return 1
        fi
    fi

    # Check port collision (non-remote tunnels)
    if [[ "$tunnel_type" != "remote" ]] && [[ -n "$local_port" ]]; then
        if is_port_in_use "$local_port" "$bind_addr"; then
            log_error "Port ${local_port} is already in use"
            _st_unlock; return 1
        fi
    fi

    # Build SSH command
    local -a ssh_cmd
    local _build_output
    _build_output=$(build_tunnel_cmd "$name") || { log_error "Failed to build SSH command for '${name}'"; _st_unlock; return 1; }
    mapfile -t ssh_cmd <<< "$_build_output"
    if [[ ${#ssh_cmd[@]} -eq 0 ]]; then
        log_error "Failed to build SSH command for '${name}'"
        _st_unlock; return 1
    fi

    local tunnel_log tunnel_pid_file
    tunnel_log=$(_log_file "$name")
    tunnel_pid_file=$(_pid_file "$name")

    log_info "Starting tunnel '${name}' (${tunnel_type})..."
    log_debug "Command: ${ssh_cmd[*]}"

    # Password-based auth via sshpass or SSH_ASKPASS
    local _st_password="${_sp[SSH_PASSWORD]:-}"
    local _st_use_sshpass=false
    local _st_use_askpass=false
    local _st_saved_display="${DISPLAY:-}"
    local _st_had_display=false
    if [[ -n "${DISPLAY+x}" ]]; then _st_had_display=true; fi

    # Auth cleanup helper — unset env vars, restore DISPLAY, remove askpass files
    _st_cleanup_auth() {
        if [[ "${_st_use_sshpass:-}" == true ]]; then unset SSHPASS 2>/dev/null || true; fi
        if [[ "${_st_use_askpass:-}" == true ]]; then
            unset SSH_ASKPASS SSH_ASKPASS_REQUIRE 2>/dev/null || true
            if [[ "${_st_had_display:-}" == true ]]; then
                export DISPLAY="$_st_saved_display"
            else
                unset DISPLAY 2>/dev/null || true
            fi
            rm -f "${PID_DIR}/${name}.askpass" "${PID_DIR}/${name}.pass" 2>/dev/null || true
        fi
    }

    if [[ -n "$_st_password" ]]; then
        if [[ -n "${_sp[JUMP_HOSTS]:-}" ]]; then
            # Jump host tunnels need multiple password prompts.
            # sshpass only handles one, so use SSH_ASKPASS instead.
            local _askpass_file="${PID_DIR}/${name}.askpass"
            local _passfile="${PID_DIR}/${name}.pass"
            printf '%s\n' "$_st_password" > "$_passfile"
            chmod 600 "$_passfile"
            printf '#!/bin/bash\ncat "%s"\n' "$_passfile" > "$_askpass_file"
            chmod 700 "$_askpass_file"
            export DISPLAY="${DISPLAY:-:0}"
            export SSH_ASKPASS="$_askpass_file"
            export SSH_ASKPASS_REQUIRE="force"
            _st_use_askpass=true
        else
            if ! command -v sshpass &>/dev/null; then
                log_info "Installing sshpass for password authentication..."
                if [[ -n "${PKG_UPDATE:-}" ]]; then ${PKG_UPDATE} &>/dev/null || true; fi
                install_package "sshpass" || log_warn "Failed to install sshpass"
            fi
            if command -v sshpass &>/dev/null; then
                _st_use_sshpass=true
                export SSHPASS="$_st_password"
            else
                log_warn "sshpass unavailable — SSH will prompt for password interactively"
            fi
        fi
    fi

    local use_autossh="${_sp[AUTOSSH_ENABLED]:-$(config_get AUTOSSH_ENABLED true)}"

    # autossh cannot handle -J (ProxyJump) — it mangles the argument parsing.
    # Fall back to plain SSH for jump host tunnels.
    if [[ -n "${_sp[JUMP_HOSTS]:-}" ]] && [[ "$use_autossh" == "true" ]]; then
        log_debug "Jump host tunnel — skipping autossh (incompatible with -J)"
        use_autossh="false"
    fi

    if [[ "$use_autossh" == "true" ]] && command -v autossh &>/dev/null; then
        # ── AutoSSH mode ──
        local monitor_port="${_sp[AUTOSSH_MONITOR_PORT]:-$(config_get AUTOSSH_MONITOR_PORT 0)}"

        export AUTOSSH_PIDFILE="$tunnel_pid_file"
        export AUTOSSH_LOGFILE="$tunnel_log"
        export AUTOSSH_POLL="$(config_get AUTOSSH_POLL 30)"
        export AUTOSSH_GATETIME="$(config_get AUTOSSH_GATETIME 30)"
        export AUTOSSH_FIRST_POLL="$(config_get AUTOSSH_FIRST_POLL 30)"
        export AUTOSSH_LOGLEVEL="$(config_get AUTOSSH_LOG_LEVEL 1)"

        ssh_cmd[0]="autossh"
        local -a autossh_cmd=("${ssh_cmd[0]}" "-M" "$monitor_port" "${ssh_cmd[@]:1}")

        if [[ "$_st_use_sshpass" == true ]]; then
            local -a _sshpass_autossh=(sshpass -e "${autossh_cmd[@]}")
            "${_sshpass_autossh[@]}" >> "$tunnel_log" 2>&1 &
        else
            "${autossh_cmd[@]}" >> "$tunnel_log" 2>&1 &
        fi
        local bg_pid=$!
        disown "$bg_pid" 2>/dev/null || true
        # Always record autossh parent PID for reliable kill
        printf '%s\n' "$bg_pid" > "${tunnel_pid_file}.autossh" 2>/dev/null || true

        # Wait for autossh to write its PID (AUTOSSH_PIDFILE)
        local _as_wait
        for _as_wait in 1 2 3; do
            if [[ -f "$tunnel_pid_file" ]]; then break; fi
            sleep 1
        done
        # Fallback: if autossh didn't write PID, use background job PID
        if [[ ! -f "$tunnel_pid_file" ]]; then
            local _pid_tmp
            _pid_tmp=$(mktemp "${tunnel_pid_file}.XXXXXX") || {
                log_error "Cannot create PID temp file"
                unset AUTOSSH_PIDFILE AUTOSSH_LOGFILE AUTOSSH_POLL AUTOSSH_GATETIME AUTOSSH_FIRST_POLL AUTOSSH_LOGLEVEL
                _st_cleanup_auth; _st_unlock; return 1
            }
            printf '%s\n' "$bg_pid" > "$_pid_tmp" && mv -f "$_pid_tmp" "$tunnel_pid_file" || {
                rm -f "$_pid_tmp" 2>/dev/null
                log_error "Failed to write PID file for '${name}'"
                unset AUTOSSH_PIDFILE AUTOSSH_LOGFILE AUTOSSH_POLL AUTOSSH_GATETIME AUTOSSH_FIRST_POLL AUTOSSH_LOGLEVEL
                _st_cleanup_auth; _st_unlock; return 1
            }
        fi

        unset AUTOSSH_PIDFILE AUTOSSH_LOGFILE AUTOSSH_POLL
        unset AUTOSSH_GATETIME AUTOSSH_FIRST_POLL AUTOSSH_LOGLEVEL
    else
        # ── Plain SSH mode ──
        if [[ "$_st_use_sshpass" == true ]] || [[ "$_st_use_askpass" == true ]]; then
            # sshpass/askpass and ssh -f are incompatible (-f breaks pty).
            # Background the whole command ourselves instead.
            if [[ "$_st_use_sshpass" == true ]]; then
                sshpass -e "${ssh_cmd[@]}" >> "$tunnel_log" 2>&1 &
            else
                # </dev/null ensures SSH has no terminal on stdin
                "${ssh_cmd[@]}" </dev/null >> "$tunnel_log" 2>&1 &
            fi
            local bg_pid=$!
            disown "$bg_pid" 2>/dev/null || true

            # Wait for SSH to authenticate and establish the tunnel
            sleep 3
            if ! kill -0 "$bg_pid" 2>/dev/null; then
                log_error "SSH connection failed for '${name}'"
                _st_cleanup_auth; _st_unlock; return 1
            fi
        else
            # Use -f so SSH authenticates in foreground (password prompt works)
            # then forks to background after successful auth
            local _ssh_rc=0
            "${ssh_cmd[@]}" -f >> "$tunnel_log" 2>&1 </dev/tty || _ssh_rc=$?

            if (( _ssh_rc != 0 )); then
                log_error "SSH connection failed for '${name}'"
                _st_unlock; return 1
            fi

            sleep 1
            local bg_pid=""
            # Try lsof on the local port first (works for socks5 + local forward)
            if [[ -n "$local_port" ]]; then
                bg_pid=$(lsof -ti:"${local_port}" -sTCP:LISTEN 2>/dev/null | head -1) || true
            fi
            # Fallback: search for the SSH process
            if [[ -z "$bg_pid" ]]; then
                bg_pid=$(pgrep -n -f "ssh.*${ssh_host}" 2>/dev/null) || true
            fi

            if [[ -z "$bg_pid" ]]; then
                log_error "Could not find SSH process for '${name}'"
                _st_cleanup_auth; _st_unlock; return 1
            fi
        fi

        local _pid_tmp
        _pid_tmp=$(mktemp "${tunnel_pid_file}.XXXXXX") || { log_error "Cannot create PID temp file"; _st_cleanup_auth; _st_unlock; return 1; }
        printf '%s\n' "$bg_pid" > "$_pid_tmp" && mv -f "$_pid_tmp" "$tunnel_pid_file" || {
            rm -f "$_pid_tmp" 2>/dev/null
            log_error "Failed to write PID file for '${name}'"
            _st_cleanup_auth; _st_unlock; return 1
        }
    fi

    # Clean up auth env vars + restore DISPLAY (keep askpass files for autossh reconnection)
    if [[ "$_st_use_sshpass" == true ]]; then unset SSHPASS 2>/dev/null || true; fi
    if [[ "$_st_use_askpass" == true ]]; then
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE 2>/dev/null || true
        if [[ "$_st_had_display" == true ]]; then
            export DISPLAY="$_st_saved_display"
        else
            unset DISPLAY 2>/dev/null || true
        fi
    fi

    sleep 1
    if is_tunnel_running "$name"; then
        local pid
        pid=$(get_tunnel_pid "$name")
        # Write startup timestamp for reliable uptime tracking
        date +%s > "${PID_DIR}/${name}.started" 2>/dev/null || true
        log_success "Tunnel '${name}' started (PID: ${pid})"
        log_file "info" "Tunnel '${name}' started (PID: ${pid}, type: ${tunnel_type})" || true
        _notify_tunnel_start "$name" "$tunnel_type" "$pid" || true

        # Enable security features if configured
        if [[ "${_sp[DNS_LEAK_PROTECTION]:-}" == "true" ]]; then
            log_info "Enabling DNS leak protection..."
            if ! enable_dns_leak_protection; then
                log_warn "DNS leak protection FAILED — tunnel running WITHOUT DNS protection"
            fi
        fi
        if [[ "${_sp[KILL_SWITCH]:-}" == "true" ]]; then
            log_info "Enabling kill switch..."
            if ! enable_kill_switch "$name"; then
                log_warn "Kill switch FAILED — tunnel running WITHOUT kill switch"
            fi
        fi

        # Start local stunnel for inbound TLS+PSK if configured
        if [[ -n "${_sp[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_sp[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
            log_info "Starting inbound TLS wrapper (stunnel + PSK)..."
            if _obfs_start_local_stunnel "$name" _sp; then
                _obfs_show_client_config "$name" _sp
            else
                log_warn "Inbound TLS wrapper failed — tunnel running WITHOUT inbound protection"
            fi
        fi
        _st_unlock; return 0
    else
        log_error "Tunnel '${name}' failed to start"
        log_info  "Check logs: ${tunnel_log}"
        _notify_tunnel_fail "$name" || true
        _st_cleanup_auth
        rm -f "$tunnel_pid_file" 2>/dev/null || true
        _st_unlock; return 1
    fi
}

stop_tunnel() {
    local name="$1"

    # Per-profile lock to prevent concurrent start/stop races
    local _stp_lock_fd="" _stp_lock_dir=""
    _stp_unlock() {
        if [[ -n "${_stp_lock_fd:-}" ]]; then exec {_stp_lock_fd}>&- 2>/dev/null || true; fi
        if [[ -n "${_stp_lock_dir:-}" ]]; then
            rm -f "${_stp_lock_dir}/pid" 2>/dev/null || true
            rmdir "${_stp_lock_dir}" 2>/dev/null || true
            _stp_lock_dir=""
        fi
        rm -f "${PID_DIR}/${name}.lock" 2>/dev/null || true
    }
    if command -v flock &>/dev/null; then
        exec {_stp_lock_fd}>"${PID_DIR}/${name}.lock" 2>/dev/null || { log_error "Could not open lock file for '${name}'"; return 1; }
        flock -w 10 "$_stp_lock_fd" 2>/dev/null || { log_error "Could not acquire lock for '${name}'"; _stp_unlock; return 1; }
    else
        _stp_lock_dir="${PID_DIR}/${name}.lck"
        local _stp_try=0
        while ! mkdir "$_stp_lock_dir" 2>/dev/null; do
            local _stp_stale_pid=""
            _stp_stale_pid=$(cat "${_stp_lock_dir}/pid" 2>/dev/null) || true
            if [[ -n "$_stp_stale_pid" ]] && ! kill -0 "$_stp_stale_pid" 2>/dev/null; then
                rm -f "${_stp_lock_dir}/pid" 2>/dev/null || true
                rmdir "$_stp_lock_dir" 2>/dev/null || true
                continue
            fi
            if (( ++_stp_try >= 20 )); then log_error "Could not acquire lock for '${name}'"; return 1; fi
            sleep 0.5
        done
        printf '%s' "$$" > "${_stp_lock_dir}/pid" 2>/dev/null || true
    fi

    if ! is_tunnel_running "$name"; then
        log_warn "Tunnel '${name}' is not running"
        # Still clean up stale PID and security features
        _clean_stale_pid "$name"
        local -A _stp_stale
        if load_profile "$name" _stp_stale 2>/dev/null; then
            if [[ "${_stp_stale[KILL_SWITCH]:-}" == "true" ]]; then
                disable_kill_switch "$name" || log_warn "Kill switch disable failed for stale tunnel"
            fi
            if [[ "${_stp_stale[DNS_LEAK_PROTECTION]:-}" == "true" ]]; then
                disable_dns_leak_protection || log_warn "DNS leak protection disable failed for stale tunnel"
            fi
        fi
        _stp_unlock; return 0
    fi

    local tunnel_pid tunnel_pid_file
    tunnel_pid=$(get_tunnel_pid "$name")
    tunnel_pid_file=$(_pid_file "$name")

    log_info "Stopping tunnel '${name}' (PID: ${tunnel_pid})..."

    # Load profile for security cleanup
    local -A _stp
    load_profile "$name" _stp 2>/dev/null || true

    if [[ "${_stp[KILL_SWITCH]:-}" == "true" ]]; then
        log_info "Disabling kill switch..."
        disable_kill_switch "$name" || log_warn "Kill switch disable failed"
    fi
    if [[ "${_stp[DNS_LEAK_PROTECTION]:-}" == "true" ]]; then
        log_info "Disabling DNS leak protection..."
        disable_dns_leak_protection || log_warn "DNS leak protection disable failed"
    fi

    # Stop local stunnel (inbound TLS+PSK) if running
    _obfs_stop_local_stunnel "$name" || true

    # Kill autossh parent first (if present) — it handles SSH child cleanup
    local _autossh_parent_file="${tunnel_pid_file}.autossh"
    if [[ -f "$_autossh_parent_file" ]]; then
        local _as_parent_pid
        _as_parent_pid=$(cat "$_autossh_parent_file" 2>/dev/null) || true
        if [[ -n "$_as_parent_pid" ]] && kill -0 "$_as_parent_pid" 2>/dev/null; then
            kill "$_as_parent_pid" 2>/dev/null || true
        fi
        rm -f "$_autossh_parent_file" 2>/dev/null || true
    fi

    # Graceful SIGTERM → wait → SIGKILL
    kill "$tunnel_pid" 2>/dev/null || true
    local waited=0
    while (( waited < 5 )) && kill -0 "$tunnel_pid" 2>/dev/null; do
        sleep 1; ((++waited))
    done
    if kill -0 "$tunnel_pid" 2>/dev/null; then
        log_warn "Force killing tunnel '${name}'..."
        kill -9 "$tunnel_pid" 2>/dev/null || true
        sleep 1
    fi

    # Clean up SSH control sockets (stale sockets from %C hash naming)
    # Find and remove any sockets in the control dir that are no longer active
    find "${SSH_CONTROL_DIR}" -maxdepth 1 -type s ! -name '.' -exec \
        sh -c 'ssh -O check -o "ControlPath=$1" dummy 2>/dev/null || rm -f "$1"' _ {} \; 2>/dev/null || true

    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
        rm -f "$tunnel_pid_file" "${tunnel_pid_file}.autossh" "${PID_DIR}/${name}.stunnel" \
             "${PID_DIR}/${name}.started" "${PID_DIR}/${name}.askpass" "${PID_DIR}/${name}.pass" 2>/dev/null || true
        log_success "Tunnel '${name}' stopped"
        log_file "info" "Tunnel '${name}' stopped" || true
        _notify_tunnel_stop "$name" || true
        _stp_unlock; return 0
    else
        log_error "Failed to stop tunnel '${name}'"
        _stp_unlock; return 1
    fi
}

restart_tunnel() {
    local name="$1"

    # Hold a restart lock across the entire stop+start sequence
    # to prevent another process from starting during the gap
    local _rt_lock_fd="" _rt_lock_dir=""
    _rt_unlock() {
        if [[ -n "${_rt_lock_fd:-}" ]]; then exec {_rt_lock_fd}>&- 2>/dev/null || true; fi
        if [[ -n "${_rt_lock_dir:-}" ]]; then
            rm -f "${_rt_lock_dir}/pid" 2>/dev/null || true
            rmdir "${_rt_lock_dir}" 2>/dev/null || true
            _rt_lock_dir=""
        fi
        rm -f "${PID_DIR}/${name}.restart.lock" 2>/dev/null || true
    }
    if command -v flock &>/dev/null; then
        exec {_rt_lock_fd}>"${PID_DIR}/${name}.restart.lock" 2>/dev/null || { log_error "Could not open restart lock file for '${name}'"; return 1; }
        flock -w 10 "$_rt_lock_fd" 2>/dev/null || { log_error "Could not acquire restart lock for '${name}'"; _rt_unlock; return 1; }
    else
        _rt_lock_dir="${PID_DIR}/${name}.restart.lck"
        local _rt_try=0
        while ! mkdir "$_rt_lock_dir" 2>/dev/null; do
            local _rt_stale_pid=""
            _rt_stale_pid=$(cat "${_rt_lock_dir}/pid" 2>/dev/null) || true
            if [[ -n "$_rt_stale_pid" ]] && ! kill -0 "$_rt_stale_pid" 2>/dev/null; then
                rm -f "${_rt_lock_dir}/pid" 2>/dev/null || true
                rmdir "$_rt_lock_dir" 2>/dev/null || true
                continue
            fi
            if (( ++_rt_try >= 20 )); then log_error "Could not acquire restart lock for '${name}'"; return 1; fi
            sleep 0.5
        done
        printf '%s' "$$" > "${_rt_lock_dir}/pid" 2>/dev/null || true
    fi

    log_info "Restarting tunnel '${name}'..."
    _record_reconnect "$name" "manual_restart"
    stop_tunnel "$name" || true
    sleep 1
    start_tunnel "$name" || { log_error "Failed to restart tunnel '${name}'"; _rt_unlock; return 1; }
    _rt_unlock
}

start_all_tunnels() {
    local started=0 failed=0 name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local autostart
        autostart=$(get_profile_field "$name" "AUTOSTART") || true
        if [[ "$autostart" == "true" ]]; then
            local _st_rc=0
            start_tunnel "$name" || _st_rc=$?
            if (( _st_rc == 0 )); then
                ((++started))
            elif (( _st_rc == 2 )); then
                : # already running — skip counting
            else
                ((++failed))
            fi
        fi
    done < <(list_profiles)
    log_info "Started ${started} tunnel(s), ${failed} failed"
    if (( failed > 0 )); then return 1; fi
    return 0
}

stop_all_tunnels() {
    local stopped=0 failed=0 name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if is_tunnel_running "$name"; then
            if stop_tunnel "$name"; then
                ((++stopped))
            else
                ((++failed))
            fi
        fi
    done < <(list_profiles)
    if (( failed > 0 )); then
        log_info "Stopped ${stopped} tunnel(s), ${failed} failed"
        return 1
    else
        log_info "Stopped ${stopped} tunnel(s)"
    fi
    return 0
}

# ── Traffic & uptime helpers ──

get_tunnel_uptime() {
    local name="$1"
    local pid
    pid=$(get_tunnel_pid "$name")
    [[ -z "$pid" ]] && { echo 0; return 0; }
    kill -0 "$pid" 2>/dev/null || { echo 0; return 0; }

    # Primary: startup timestamp file (most reliable, survives across invocations)
    local _started_file="${PID_DIR}/${name}.started"
    if [[ -f "$_started_file" ]]; then
        local _st_epoch
        _st_epoch=$(cat "$_started_file" 2>/dev/null) || true
        if [[ "$_st_epoch" =~ ^[0-9]+$ ]]; then
            echo $(( $(date +%s) - _st_epoch ))
            return 0
        fi
    fi

    # Fallback 1: /proc/PID/stat (Linux only)
    if [[ -f "/proc/${pid}/stat" ]]; then
        local start_ticks clk_tck boot_time
        start_ticks=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || true)
        clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
        [[ "$clk_tck" =~ ^[0-9]+$ ]] || clk_tck=100
        boot_time=$(awk '/btime/ {print $2}' /proc/stat 2>/dev/null || true)

        if [[ "$start_ticks" =~ ^[0-9]+$ ]] && [[ "$boot_time" =~ ^[0-9]+$ ]]; then
            local start_sec=$(( boot_time + start_ticks / clk_tck ))
            echo $(( $(date +%s) - start_sec ))
            return 0
        fi
    fi

    # Fallback 2: PID file mtime
    local pf
    pf=$(_pid_file "$name")
    if [[ -f "$pf" ]]; then
        local ft
        ft=$(stat -c %Y "$pf" 2>/dev/null || stat -f %m "$pf" 2>/dev/null) || true
        if [[ -n "$ft" ]]; then
            echo $(( $(date +%s) - ft )); return 0
        fi
    fi
    echo 0; return 0
}

get_tunnel_traffic() {
    local pid
    pid=$(get_tunnel_pid "$1")
    if [[ -z "$pid" ]] || [[ ! -d "/proc/${pid}" ]]; then
        echo "0 0"; return 0
    fi
    # Walk process tree to find actual ssh process (autossh/sshpass are wrappers)
    local _target="$pid" _try
    for _try in 1 2 3; do
        local _comm=""
        _comm=$(cat "/proc/${_target}/comm" 2>/dev/null) || true
        [[ "$_comm" == "ssh" ]] && break
        local _next=""
        _next=$(pgrep -P "$_target" 2>/dev/null | head -1) || true
        [[ -z "$_next" ]] && break
        _target="$_next"
    done
    if [[ ! -f "/proc/${_target}/io" ]]; then
        echo "0 0"; return 0
    fi
    local rchar wchar
    rchar=$(awk '/^rchar:/ {print $2}' "/proc/${_target}/io" 2>/dev/null || echo 0)
    wchar=$(awk '/^wchar:/ {print $2}' "/proc/${_target}/io" 2>/dev/null || echo 0)
    echo "${rchar} ${wchar}"
}

get_tunnel_connections() {
    local name="$1"
    local -A _cc
    load_profile "$name" _cc 2>/dev/null || { echo 0; return 0; }
    local port="${_cc[LOCAL_PORT]:-}"
    [[ -z "$port" ]] && { echo 0; return 0; }
    [[ "$port" =~ ^[0-9]+$ ]] || { echo 0; return 0; }

    local _nc=0
    # Count connections on SSH SOCKS port + inbound TLS port if active
    local _ports_to_check=("$port")
    local _olp="${_cc[OBFS_LOCAL_PORT]:-0}"
    if [[ "$_olp" =~ ^[0-9]+$ ]] && (( _olp > 0 )); then
        _ports_to_check+=("$_olp")
    fi
    # Use cached ss output if available (set by dashboard), else run ss
    local _ss_data="${_DASH_SS_CACHE:-}"
    if [[ -z "$_ss_data" ]]; then
        _ss_data=$(ss -tn 2>/dev/null) || true
    fi
    local _p
    for _p in "${_ports_to_check[@]}"; do
        local _cnt=0
        _cnt=$(echo "$_ss_data" | grep -cE "ESTAB.*:${_p}[[:space:]]") || true
        (( _nc += _cnt )) || true
    done
    echo "${_nc:-0}"
}

# ============================================================================
# SECURITY FEATURES  (Phase 4)
# ============================================================================

readonly _RESOLV_CONF="/etc/resolv.conf"
readonly _RESOLV_BACKUP="${BACKUP_DIR}/resolv.conf.bak"
readonly _IPTABLES_BACKUP_DIR="${BACKUP_DIR}/iptables"
readonly _TF_CHAIN="TUNNELFORGE"

# ── DNS Leak Protection ──
# Forces DNS through specified servers by rewriting /etc/resolv.conf

enable_dns_leak_protection() {
    if [[ $EUID -ne 0 ]]; then
        log_error "DNS leak protection requires root privileges"
        return 1
    fi

    mkdir -p "$BACKUP_DIR" 2>/dev/null || true

    # Backup current resolv.conf if not already backed up
    if [[ ! -f "$_RESOLV_BACKUP" ]] && [[ -f "$_RESOLV_CONF" ]]; then
        if ! cp "$_RESOLV_CONF" "$_RESOLV_BACKUP" 2>/dev/null; then
            log_error "Failed to backup resolv.conf"
            return 1
        fi
        log_debug "Backed up resolv.conf"
    fi

    # Remove immutable flag if set from previous run
    if command -v chattr &>/dev/null; then
        chattr -i "$_RESOLV_CONF" 2>/dev/null || true
    fi

    # Write new resolv.conf with secure DNS
    local dns1 dns2 _dns_val
    dns1=$(config_get DNS_SERVER_1 "1.1.1.1")
    dns2=$(config_get DNS_SERVER_2 "1.0.0.1")

    # Validate DNS server values are valid IPv4 or IPv6 addresses
    local _dns_ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local _dns_ip6_re='^[0-9a-fA-F]*:[0-9a-fA-F:]*$'
    for _dns_val in "$dns1" "$dns2"; do
        if ! [[ "$_dns_val" =~ $_dns_ip_re ]] && ! [[ "$_dns_val" =~ $_dns_ip6_re ]]; then
            log_error "Invalid DNS server address: ${_dns_val}"
            return 1
        fi
    done

    # Abort if resolv.conf is a symlink (systemd-resolved, etc.)
    if [[ -L "$_RESOLV_CONF" ]]; then
        log_error "resolv.conf is a symlink ($(readlink "$_RESOLV_CONF" 2>/dev/null || true)) — cannot safely rewrite; disable systemd-resolved first"
        return 1
    fi

    # Atomic write via temp file + mv
    local _resolv_tmp
    _resolv_tmp=$(mktemp "${_RESOLV_CONF}.tf_tmp.XXXXXX") || { log_error "Failed to create temp file"; return 1; }
    {
        printf "# TunnelForge DNS Leak Protection — do not edit\n"
        printf "# Original backed up to: %s\n" "$_RESOLV_BACKUP"
        printf "nameserver %s\n" "$dns1"
        printf "nameserver %s\n" "$dns2"
        printf "options edns0\n"
    } > "$_resolv_tmp" 2>/dev/null || {
        log_error "Failed to write resolv.conf temp file"
        rm -f "$_resolv_tmp" 2>/dev/null
        return 1
    }
    if ! mv -f "$_resolv_tmp" "$_RESOLV_CONF" 2>/dev/null; then
        log_error "Failed to install resolv.conf (mv failed)"
        rm -f "$_resolv_tmp" 2>/dev/null
        return 1
    fi

    # Make immutable to prevent overwriting by system services
    if command -v chattr &>/dev/null; then
        if ! chattr +i "$_RESOLV_CONF" 2>/dev/null; then
            log_warn "Could not make resolv.conf immutable (chattr +i failed)"
        fi
    fi

    log_success "DNS leak protection enabled (${dns1}, ${dns2})"
    return 0
}

disable_dns_leak_protection() {
    if [[ $EUID -ne 0 ]]; then
        log_error "DNS leak protection requires root privileges"
        return 1
    fi

    # Remove immutable flag
    if command -v chattr &>/dev/null; then
        chattr -i "$_RESOLV_CONF" 2>/dev/null || true
    fi

    # Restore backup (atomic: copy to temp then mv)
    if [[ -f "$_RESOLV_BACKUP" ]]; then
        local _restore_tmp
        _restore_tmp=$(mktemp "${_RESOLV_CONF}.tf_restore.XXXXXX") || { log_error "Failed to create temp file"; return 1; }
        if ! cp "$_RESOLV_BACKUP" "$_restore_tmp" 2>/dev/null; then
            log_error "Failed to copy resolv.conf backup to temp file"
            rm -f "$_restore_tmp" 2>/dev/null
            return 1
        fi
        if ! mv -f "$_restore_tmp" "$_RESOLV_CONF" 2>/dev/null; then
            log_error "Failed to restore resolv.conf (mv failed)"
            rm -f "$_restore_tmp" 2>/dev/null
            return 1
        fi
        rm -f "$_RESOLV_BACKUP" 2>/dev/null
        log_success "DNS leak protection disabled (resolv.conf restored)"
    else
        log_warn "No resolv.conf backup found; writing sane defaults"
        local _defaults_tmp
        _defaults_tmp=$(mktemp "${_RESOLV_CONF}.tf_defaults.XXXXXX") || { log_error "Failed to create temp file"; return 1; }
        if ! { printf "nameserver 8.8.8.8\n"; printf "nameserver 8.8.4.4\n"; } > "$_defaults_tmp" 2>/dev/null; then
            log_error "Failed to write sane defaults to temp file"
            rm -f "$_defaults_tmp" 2>/dev/null
            return 1
        fi
        if ! mv -f "$_defaults_tmp" "$_RESOLV_CONF" 2>/dev/null; then
            log_error "Failed to apply sane defaults (mv failed)"
            rm -f "$_defaults_tmp" 2>/dev/null
            return 1
        fi
    fi
    return 0
}

is_dns_leak_protected() {
    if [[ -f "$_RESOLV_CONF" ]] && grep -qF "TunnelForge DNS" "$_RESOLV_CONF" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ── Kill Switch (iptables firewall) ──
# Blocks all non-tunnel traffic to prevent data leaks if tunnel drops

enable_kill_switch() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Kill switch requires root privileges"
        return 1
    fi
    if ! command -v iptables &>/dev/null; then
        log_error "iptables is required for kill switch"
        return 1
    fi

    local _has_ip6tables=false
    if command -v ip6tables &>/dev/null; then _has_ip6tables=true; fi

    local -A _ks_prof
    load_profile "$name" _ks_prof 2>/dev/null || {
        log_error "Cannot load profile '${name}' for kill switch"
        return 1
    }

    local ssh_host="${_ks_prof[SSH_HOST]:-}"
    local ssh_port="${_ks_prof[SSH_PORT]:-22}"

    if [[ -z "$ssh_host" ]]; then
        log_error "No SSH host configured for kill switch"
        return 1
    fi

    # Resolve hostname to IPv4 and IPv6 (with fallback chain for portability)
    local ssh_ip ssh_ip6=""
    ssh_ip=$(getent ahostsv4 "$ssh_host" 2>/dev/null | awk '{print $1; exit}') || true
    if [[ -z "$ssh_ip" ]]; then
        ssh_ip=$(dig +short A "$ssh_host" 2>/dev/null | head -1) || true
    fi
    if [[ -z "$ssh_ip" ]]; then
        ssh_ip=$(host "$ssh_host" 2>/dev/null | awk '/has address/{print $NF; exit}') || true
    fi
    if [[ -z "$ssh_ip" ]]; then
        ssh_ip=$(nslookup "$ssh_host" 2>/dev/null \
            | awk '/^Address/ && !/127\.0\.0/ && NR>2 {print $NF; exit}') || true
    fi
    if [[ -z "$ssh_ip" ]]; then
        ssh_ip="$ssh_host"  # Assume already an IP
    fi
    if ! validate_ip "$ssh_ip" && ! validate_ip6 "$ssh_ip"; then
        log_error "Could not resolve SSH host '${ssh_host}' to a valid IP — kill switch aborted"
        return 1
    fi
    if [[ "$_has_ip6tables" == true ]]; then
        ssh_ip6=$(getent ahostsv6 "$ssh_host" 2>/dev/null | awk '{print $1; exit}') || true
    fi

    mkdir -p "$_IPTABLES_BACKUP_DIR" 2>/dev/null || true

    # Create chain if it doesn't exist
    iptables -N "$_TF_CHAIN" 2>/dev/null || true
    if [[ "$_has_ip6tables" == true ]]; then
        ip6tables -N "$_TF_CHAIN" 2>/dev/null || true
    fi

    # Check if chain already has rules (multi-tunnel support)
    if iptables -S "$_TF_CHAIN" 2>/dev/null | grep -q -- "-j DROP"; then
        # Chain active — remove old DROP, add this tunnel's SSH host, re-add DROP
        iptables -D "$_TF_CHAIN" -j DROP 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -d "$ssh_ip" -p tcp --dport "$ssh_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -j DROP 2>/dev/null || true
        if [[ "$_has_ip6tables" == true ]]; then
            ip6tables -D "$_TF_CHAIN" -j DROP 2>/dev/null || true
            if [[ -n "$ssh_ip6" ]]; then
                ip6tables -A "$_TF_CHAIN" -d "$ssh_ip6" -p tcp --dport "$ssh_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
            fi
            ip6tables -A "$_TF_CHAIN" -j DROP 2>/dev/null || true
        fi
    else
        # Fresh chain — build with all standard rules
        iptables -F "$_TF_CHAIN" 2>/dev/null || true
        # Allow loopback
        iptables -A "$_TF_CHAIN" -o lo -j ACCEPT 2>/dev/null || true
        # Allow established/related
        iptables -A "$_TF_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        # Allow SSH to tunnel server
        iptables -A "$_TF_CHAIN" -d "$ssh_ip" -p tcp --dport "$ssh_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
        # Allow local DNS
        iptables -A "$_TF_CHAIN" -d 127.0.0.0/8 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -d 127.0.0.0/8 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        # Allow configured DNS servers (for DNS leak protection compatibility)
        local _dns1 _dns2
        _dns1=$(config_get DNS_SERVER_1 "1.1.1.1")
        _dns2=$(config_get DNS_SERVER_2 "1.0.0.1")
        iptables -A "$_TF_CHAIN" -d "$_dns1" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -d "$_dns1" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -d "$_dns2" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A "$_TF_CHAIN" -d "$_dns2" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        # Allow DHCP
        iptables -A "$_TF_CHAIN" -p udp --dport 67:68 -j ACCEPT 2>/dev/null || true
        # Drop everything else
        iptables -A "$_TF_CHAIN" -j DROP 2>/dev/null || true

        # IPv6 mirror
        if [[ "$_has_ip6tables" == true ]]; then
            ip6tables -F "$_TF_CHAIN" 2>/dev/null || true
            ip6tables -A "$_TF_CHAIN" -o lo -j ACCEPT 2>/dev/null || true
            ip6tables -A "$_TF_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            if [[ -n "$ssh_ip6" ]]; then
                ip6tables -A "$_TF_CHAIN" -d "$ssh_ip6" -p tcp --dport "$ssh_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
            fi
            ip6tables -A "$_TF_CHAIN" -d ::1 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
            ip6tables -A "$_TF_CHAIN" -d ::1 -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
            # Allow configured DNS servers if they are IPv6
            local _dns_v
            for _dns_v in "$_dns1" "$_dns2"; do
                if [[ "$_dns_v" =~ : ]]; then
                    ip6tables -A "$_TF_CHAIN" -d "$_dns_v" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
                    ip6tables -A "$_TF_CHAIN" -d "$_dns_v" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
                fi
            done
            ip6tables -A "$_TF_CHAIN" -p udp --dport 546:547 -j ACCEPT 2>/dev/null || true
            ip6tables -A "$_TF_CHAIN" -p ipv6-icmp -j ACCEPT 2>/dev/null || true
            ip6tables -A "$_TF_CHAIN" -j DROP 2>/dev/null || true
        fi
    fi

    # Insert jump to chain (avoid duplicates)
    if ! iptables -C OUTPUT -j "$_TF_CHAIN" 2>/dev/null; then
        iptables -I OUTPUT 1 -j "$_TF_CHAIN" 2>/dev/null || true
    fi
    if ! iptables -C FORWARD -j "$_TF_CHAIN" 2>/dev/null; then
        iptables -I FORWARD 1 -j "$_TF_CHAIN" 2>/dev/null || true
    fi
    if [[ "$_has_ip6tables" == true ]]; then
        if ! ip6tables -C OUTPUT -j "$_TF_CHAIN" 2>/dev/null; then
            ip6tables -I OUTPUT 1 -j "$_TF_CHAIN" 2>/dev/null || true
        fi
        if ! ip6tables -C FORWARD -j "$_TF_CHAIN" 2>/dev/null; then
            ip6tables -I FORWARD 1 -j "$_TF_CHAIN" 2>/dev/null || true
        fi
    fi

    log_success "Kill switch enabled for '${name}' (allow ${ssh_ip}:${ssh_port})"
    return 0
}

disable_kill_switch() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Kill switch requires root privileges"
        return 1
    fi
    if ! command -v iptables &>/dev/null; then
        return 0
    fi

    local _has_ip6tables=false
    if command -v ip6tables &>/dev/null; then _has_ip6tables=true; fi

    # Remove only this tunnel's SSH ACCEPT rule (multi-tunnel safe)
    # Load profile to get SSH host/port for exact rule match
    local -A _dks_prof
    load_profile "$name" _dks_prof 2>/dev/null || true
    local _dks_host="${_dks_prof[SSH_HOST]:-}"
    local _dks_port="${_dks_prof[SSH_PORT]:-22}"
    local _dks_ip
    _dks_ip=$(getent ahostsv4 "$_dks_host" 2>/dev/null | awk '{print $1; exit}') || true
    if [[ -z "$_dks_ip" ]]; then
        _dks_ip=$(dig +short A "$_dks_host" 2>/dev/null | head -1) || true
    fi
    if [[ -z "$_dks_ip" ]]; then
        _dks_ip=$(host "$_dks_host" 2>/dev/null | awk '/has address/{print $NF; exit}') || true
    fi
    : "${_dks_ip:=$_dks_host}"
    if [[ -n "$_dks_ip" ]]; then
        iptables -D "$_TF_CHAIN" -d "$_dks_ip" -p tcp --dport "$_dks_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
    fi
    # IPv6: remove tunnel rule
    if [[ "$_has_ip6tables" == true ]]; then
        local _dks_ip6
        _dks_ip6=$(getent ahostsv6 "$_dks_host" 2>/dev/null | awk '{print $1; exit}') || true
        if [[ -n "$_dks_ip6" ]]; then
            ip6tables -D "$_TF_CHAIN" -d "$_dks_ip6" -p tcp --dport "$_dks_port" -m comment --comment "tf:${name}" -j ACCEPT 2>/dev/null || true
        fi
    fi
    # Fallback: find exact rule by comment using -S output and delete it
    local _fb_rule
    _fb_rule=$(iptables -S "$_TF_CHAIN" 2>/dev/null | grep -F "tf:${name}" | head -1) || true
    if [[ -n "$_fb_rule" ]]; then
        _fb_rule="${_fb_rule/-A $_TF_CHAIN/-D $_TF_CHAIN}"
        _fb_rule="${_fb_rule//\"/}"
        local -a _fb_arr
        read -ra _fb_arr <<< "$_fb_rule"
        iptables "${_fb_arr[@]}" 2>/dev/null || true
    fi
    # IPv6 fallback
    if [[ "$_has_ip6tables" == true ]]; then
        local _fb6_rule
        _fb6_rule=$(ip6tables -S "$_TF_CHAIN" 2>/dev/null | grep -F "tf:${name}" | head -1) || true
        if [[ -n "$_fb6_rule" ]]; then
            _fb6_rule="${_fb6_rule/-A $_TF_CHAIN/-D $_TF_CHAIN}"
            _fb6_rule="${_fb6_rule//\"/}"
            local -a _fb6_arr
            read -ra _fb6_arr <<< "$_fb6_rule"
            ip6tables "${_fb6_arr[@]}" 2>/dev/null || true
        fi
    fi

    # Check if any other tunnel rules remain
    local _remaining
    _remaining=$(iptables -S "$_TF_CHAIN" 2>/dev/null | grep -c 'tf:' || true)
    : "${_remaining:=0}"

    if (( _remaining == 0 )); then
        # Last tunnel — tear down the entire chain
        iptables -D OUTPUT -j "$_TF_CHAIN" 2>/dev/null || true
        iptables -D FORWARD -j "$_TF_CHAIN" 2>/dev/null || true
        iptables -F "$_TF_CHAIN" 2>/dev/null || true
        iptables -X "$_TF_CHAIN" 2>/dev/null || true
        if [[ "$_has_ip6tables" == true ]]; then
            ip6tables -D OUTPUT -j "$_TF_CHAIN" 2>/dev/null || true
            ip6tables -D FORWARD -j "$_TF_CHAIN" 2>/dev/null || true
            ip6tables -F "$_TF_CHAIN" 2>/dev/null || true
            ip6tables -X "$_TF_CHAIN" 2>/dev/null || true
        fi
    fi

    # Clean up stale pristine backup files (no longer used — chain flush+delete is sufficient)
    if (( _remaining == 0 )); then
        rm -f "${_IPTABLES_BACKUP_DIR}/pristine.rules" 2>/dev/null
        rm -f "${_IPTABLES_BACKUP_DIR}/pristine6.rules" 2>/dev/null
    fi

    log_success "Kill switch disabled for '${name}'"
    return 0
}

is_kill_switch_active() {
    command -v iptables &>/dev/null || return 1
    if iptables -C OUTPUT -j "$_TF_CHAIN" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ── SSH Key Management ──

generate_ssh_key() {
    local key_type="${1:-ed25519}"
    local key_path="${2:-${HOME}/.ssh/id_${key_type}}"
    local comment="${3:-tunnelforge@$(hostname 2>/dev/null || echo localhost)}"

    if [[ -f "$key_path" ]]; then
        log_warn "Key already exists: ${key_path}"
        return 0
    fi

    local key_dir
    key_dir=$(dirname "$key_path")
    mkdir -p "$key_dir" 2>/dev/null || true
    chmod 700 "$key_dir" 2>/dev/null || true

    log_info "Generating ${key_type} SSH key..."

    if ssh-keygen -t "$key_type" -f "$key_path" -C "$comment" -N "" 2>/dev/null; then
        chmod 600 "$key_path" 2>/dev/null || true
        chmod 644 "${key_path}.pub" 2>/dev/null || true
        log_success "SSH key generated: ${key_path}"
        log_info "Public key:"
        printf "  %s\n" "$(cat "${key_path}.pub" 2>/dev/null)"
        return 0
    fi
    log_error "Failed to generate SSH key"
    return 1
}

deploy_ssh_key() {
    local name="$1"

    local -A _dk_prof
    load_profile "$name" _dk_prof 2>/dev/null || {
        log_error "Cannot load profile '${name}'"
        return 1
    }

    local ssh_host="${_dk_prof[SSH_HOST]:-}"
    local ssh_port="${_dk_prof[SSH_PORT]:-22}"
    local ssh_user="${_dk_prof[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"
    local key="${_dk_prof[IDENTITY_KEY]:-}"

    if [[ -z "$ssh_host" ]]; then
        log_error "No SSH host in profile '${name}'"
        return 1
    fi

    # Find public key
    local pub_key=""
    if [[ -n "$key" ]] && [[ -f "${key}.pub" ]]; then
        pub_key="${key}.pub"
    elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        pub_key="${HOME}/.ssh/id_ed25519.pub"
    elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        pub_key="${HOME}/.ssh/id_rsa.pub"
    else
        log_error "No public key found to deploy"
        return 1
    fi

    log_info "Deploying key to ${ssh_user}@${ssh_host}:${ssh_port}..."

    local _dk_pass="${_dk_prof[SSH_PASSWORD]:-}"
    local -a _dk_sshpass_prefix=()
    if [[ -n "$_dk_pass" ]] && command -v sshpass &>/dev/null; then
        _dk_sshpass_prefix=(env "SSHPASS=${_dk_pass}" sshpass -e)
    fi

    if command -v ssh-copy-id &>/dev/null; then
        local priv_key="${pub_key%.pub}"
        local -a _dk_opts=(-i "$priv_key" -p "$ssh_port" -o "StrictHostKeyChecking=accept-new")
        if [[ -n "$key" ]] && [[ -f "$key" ]]; then _dk_opts+=(-o "IdentityFile=${key}"); fi
        if "${_dk_sshpass_prefix[@]}" ssh-copy-id "${_dk_opts[@]}" "${ssh_user}@${ssh_host}" 2>/dev/null; then
            log_success "Key deployed to ${ssh_user}@${ssh_host}"
            return 0
        fi
    fi

    # Manual fallback (always attempted if ssh-copy-id missing or failed)
    local -a _dk_ssh_opts=(-p "$ssh_port" -o "StrictHostKeyChecking=accept-new")
    if [[ -n "$key" ]] && [[ -f "$key" ]]; then _dk_ssh_opts+=(-o "IdentityFile=${key}"); fi
    if "${_dk_sshpass_prefix[@]}" ssh "${_dk_ssh_opts[@]}" "${ssh_user}@${ssh_host}" \
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
        < "$pub_key" 2>/dev/null; then
        log_success "Key deployed to ${ssh_user}@${ssh_host}"
        return 0
    fi

    log_error "Failed to deploy key"
    return 1
}

check_key_permissions() {
    local key_path="$1"
    local issues=0

    if [[ ! -f "$key_path" ]]; then
        log_warn "Key not found: ${key_path}"
        return 1
    fi

    local perms
    perms=$(stat -c "%a" "$key_path" 2>/dev/null || stat -f "%Lp" "$key_path" 2>/dev/null) || true
    if [[ -n "$perms" ]]; then
        case "$perms" in
            600|400) ;;
            *)  log_warn "Insecure permissions on ${key_path}: ${perms} (should be 600)"
                ((++issues)) ;;
        esac
    fi

    local owner
    owner=$(stat -c "%U" "$key_path" 2>/dev/null || stat -f "%Su" "$key_path" 2>/dev/null) || true
    if [[ -n "$owner" ]] && [[ "$owner" != "$(whoami 2>/dev/null || echo root)" ]]; then
        log_warn "Key ${key_path} owned by ${owner}"
        ((++issues))
    fi

    if (( issues == 0 )); then
        log_debug "Key permissions OK: ${key_path}"
        return 0
    fi
    return 1
}

# ── Verify SSH Host Fingerprint ──

verify_host_fingerprint() {
    local host="$1" port="${2:-22}"

    if [[ -z "$host" ]]; then
        log_error "Usage: verify_host_fingerprint <host> [port]"
        return 1
    fi

    # Validate hostname — reject option injection and shell metacharacters
    if [[ "$host" == -* ]] || [[ "$host" =~ [^a-zA-Z0-9._:@%\[\]-] ]]; then
        log_error "Invalid hostname: ${host}"
        return 1
    fi

    printf "\n${BOLD}SSH Host Fingerprints for %s:%s${RESET}\n\n" "$host" "$port"

    if ! command -v ssh-keyscan &>/dev/null; then
        log_error "ssh-keyscan is required"
        return 1
    fi

    local keys
    keys=$(ssh-keyscan -p "$port" -- "$host" 2>/dev/null) || true
    if [[ -z "$keys" ]]; then
        log_error "Could not retrieve host keys from ${host}:${port}"
        return 1
    fi

    while IFS= read -r _fline; do
        [[ -z "$_fline" ]] && continue
        [[ "$_fline" == \#* ]] && continue
        local _fp
        _fp=$(echo "$_fline" | ssh-keygen -lf - 2>/dev/null) || true
        if [[ -n "$_fp" ]]; then
            printf "  ${CYAN}●${RESET} %s\n" "$_fp"
        fi
    done <<< "$keys"

    printf "\n${DIM}Known hosts status:${RESET}\n"
    if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
        local _kh_lookup="$host"
        if [[ "$port" != "22" ]]; then _kh_lookup="[${host}]:${port}"; fi
        if ssh-keygen -F "$_kh_lookup" -f "${HOME}/.ssh/known_hosts" &>/dev/null; then
            printf "  ${GREEN}●${RESET} Host is in known_hosts\n"
        else
            printf "  ${YELLOW}▲${RESET} Host is NOT in known_hosts\n"
        fi
    else
        printf "  ${YELLOW}▲${RESET} No known_hosts file found\n"
    fi
    printf "\n"
    return 0
}

# ── Security Audit ──

security_audit() {
    local score=100 issues=0 warnings=0

    printf "\n${BOLD_CYAN}═══ TunnelForge Security Audit ═══${RESET}\n\n"

    # 1. SSH key permissions
    printf "${BOLD}[1/6] SSH Key Permissions${RESET}\n"
    local _found_keys=false _key_f _key_penalty=0
    for _key_f in "${HOME}/.ssh/"*; do
        [[ -f "$_key_f" ]] || continue
        [[ "$_key_f" == *.pub ]] && continue
        [[ "$_key_f" == */known_hosts* ]] && continue
        [[ "$_key_f" == */authorized_keys* ]] && continue
        [[ "$_key_f" == */config ]] && continue
        # Only check files that look like private keys (contain BEGIN marker)
        head -1 "$_key_f" 2>/dev/null | grep -q "PRIVATE KEY" || continue
        _found_keys=true
        local _kp
        _kp=$(stat -c "%a" "$_key_f" 2>/dev/null || stat -f "%Lp" "$_key_f" 2>/dev/null) || true
        if [[ "$_kp" == "600" ]] || [[ "$_kp" == "400" ]]; then
            printf "  ${GREEN}●${RESET} %s (%s) OK\n" "$(basename "$_key_f")" "$_kp"
        else
            printf "  ${RED}✗${RESET} %s (%s) — should be 600\n" "$(basename "$_key_f")" "${_kp:-?}"
            ((++issues))
            if (( _key_penalty < 20 )); then
                score=$(( score - 10 ))
                (( _key_penalty += 10 ))
            fi
        fi
    done
    if [[ "$_found_keys" != true ]]; then
        printf "  ${YELLOW}▲${RESET} No SSH keys found in ~/.ssh/\n"
        ((++warnings))
    fi

    # 2. SSH directory permissions
    printf "\n${BOLD}[2/6] SSH Directory${RESET}\n"
    if [[ -d "${HOME}/.ssh" ]]; then
        local _ssh_perms
        _ssh_perms=$(stat -c "%a" "${HOME}/.ssh" 2>/dev/null || stat -f "%Lp" "${HOME}/.ssh" 2>/dev/null) || true
        if [[ "$_ssh_perms" == "700" ]]; then
            printf "  ${GREEN}●${RESET} ~/.ssh permissions: %s OK\n" "$_ssh_perms"
        else
            printf "  ${RED}✗${RESET} ~/.ssh permissions: %s — should be 700\n" "${_ssh_perms:-?}"
            ((++issues)); score=$(( score - 5 ))
        fi
    else
        printf "  ${YELLOW}▲${RESET} ~/.ssh directory does not exist\n"
        ((++warnings))
    fi

    # 3. DNS leak protection status
    printf "\n${BOLD}[3/6] DNS Leak Protection${RESET}\n"
    if is_dns_leak_protected; then
        printf "  ${GREEN}●${RESET} DNS leak protection is ACTIVE\n"
    else
        printf "  ${DIM}■${RESET} DNS leak protection is not active\n"
        ((++warnings))
    fi

    # 4. Kill switch status
    printf "\n${BOLD}[4/6] Kill Switch${RESET}\n"
    if [[ $EUID -ne 0 ]]; then
        printf "  ${YELLOW}▲${RESET} Skipped — requires root to inspect iptables\n"
        ((++warnings))
    elif is_kill_switch_active; then
        printf "  ${GREEN}●${RESET} Kill switch is ACTIVE (IPv4)\n"
        if command -v ip6tables &>/dev/null && ip6tables -C OUTPUT -j "$_TF_CHAIN" 2>/dev/null; then
            printf "  ${GREEN}●${RESET} Kill switch is ACTIVE (IPv6)\n"
        else
            printf "  ${YELLOW}▲${RESET} IPv6 kill switch not active\n"
            ((++warnings))
        fi
    else
        printf "  ${DIM}■${RESET} Kill switch is not active\n"
        ((++warnings))
    fi

    # 5. Tunnel PID integrity
    printf "\n${BOLD}[5/6] Tunnel Integrity${RESET}\n"
    local _audit_profiles
    _audit_profiles=$(list_profiles)
    if [[ -n "$_audit_profiles" ]]; then
        while IFS= read -r _aname; do
            [[ -z "$_aname" ]] && continue
            local _apid
            _apid=$(get_tunnel_pid "$_aname" 2>/dev/null)
            if [[ -n "$_apid" ]]; then
                if kill -0 "$_apid" 2>/dev/null; then
                    printf "  ${GREEN}●${RESET} %s (PID %s) — running\n" "$_aname" "$_apid"
                else
                    printf "  ${RED}✗${RESET} %s (PID %s) — stale PID file\n" "$_aname" "$_apid"
                    ((++issues)); score=$(( score - 5 ))
                fi
            else
                printf "  ${DIM}■${RESET} %s — not running\n" "$_aname"
            fi
        done <<< "$_audit_profiles"
    else
        printf "  ${DIM}■${RESET} No profiles configured\n"
    fi

    # 6. Listening ports check
    printf "\n${BOLD}[6/6] Listening Ports${RESET}\n"
    if command -v ss &>/dev/null; then
        local _port_count
        _port_count=$(ss -tln 2>/dev/null | tail -n +2 | wc -l) || true
        printf "  ${DIM}■${RESET} %s TCP ports listening\n" "${_port_count:-0}"
    elif command -v netstat &>/dev/null; then
        local _port_count
        _port_count=$(netstat -tln 2>/dev/null | tail -n +3 | wc -l) || true
        printf "  ${DIM}■${RESET} %s TCP ports listening\n" "${_port_count:-0}"
    else
        printf "  ${YELLOW}▲${RESET} Cannot check ports (ss/netstat not found)\n"
    fi

    # Summary
    if (( score < 0 )); then score=0; fi
    printf "\n${BOLD}──────────────────────────────────${RESET}\n"
    local _sc_color="${GREEN}"
    if (( score < 70 )); then _sc_color="${RED}"
    elif (( score < 90 )); then _sc_color="${YELLOW}"; fi
    printf "${BOLD}Security Score: ${_sc_color}%d/100${RESET}\n" "$score"
    printf "${DIM}Issues: %d  |  Warnings: %d${RESET}\n\n" "$issues" "$warnings"
    return 0
}

# ============================================================================
# SERVER SETUP & SYSTEMD  (Phase 5)
# ============================================================================

readonly _SYSTEMD_DIR="/etc/systemd/system"
readonly _SSHD_CONFIG="/etc/ssh/sshd_config"
readonly _SSHD_BACKUP="${BACKUP_DIR}/sshd_config.bak"

# ── Server Hardening ──
# Hardens a remote server's SSH config for receiving tunnel connections

_server_harden_sshd() {
    printf "\n${BOLD}[1/4] Hardening SSH daemon${RESET}\n"

    if [[ ! -f "$_SSHD_CONFIG" ]]; then
        log_error "sshd_config not found at ${_SSHD_CONFIG}"
        return 1
    fi

    # Backup original (canonical backup kept for first-run restore)
    if [[ ! -f "$_SSHD_BACKUP" ]]; then
        cp "$_SSHD_CONFIG" "$_SSHD_BACKUP" 2>/dev/null || {
            log_error "Failed to backup sshd_config"
            return 1
        }
        log_success "Backed up sshd_config (canonical)"
    fi
    # Always create a timestamped backup before each modification
    local _ts_backup="${BACKUP_DIR}/sshd_config.$(date -u '+%Y%m%d%H%M%S').bak"
    cp "$_SSHD_CONFIG" "$_ts_backup" 2>/dev/null || true

    # Check if any user has authorized_keys before disabling password auth
    local _pw_auth="no"
    local _has_keys=false
    local _huser
    for _huser in /root /home/*; do
        if [[ -f "${_huser}/.ssh/authorized_keys" ]] && [[ -s "${_huser}/.ssh/authorized_keys" ]]; then
            _has_keys=true
            break
        fi
    done
    if [[ "$_has_keys" != true ]]; then
        _pw_auth="yes"
        log_warn "No authorized_keys found — keeping PasswordAuthentication=yes to prevent lockout"
    fi

    # Apply hardening settings
    local -A _harden=(
        [PermitRootLogin]="prohibit-password"
        [PasswordAuthentication]="$_pw_auth"
        [PubkeyAuthentication]="yes"
        [X11Forwarding]="no"
        [AllowTcpForwarding]="yes"
        [GatewayPorts]="clientspecified"
        [MaxAuthTries]="3"
        [LoginGraceTime]="30"
        [ClientAliveInterval]="60"
        [ClientAliveCountMax]="3"
        [PermitEmptyPasswords]="no"
    )

    local _hk _hv _changed=false
    for _hk in "${!_harden[@]}"; do
        _hv="${_harden[$_hk]}"
        if grep -qE "^[[:space:]]*${_hk}[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null; then
            # Setting exists — update it
            local _cur
            _cur=$(grep -E "^[[:space:]]*${_hk}[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1) || true
            if [[ "$_cur" != "$_hv" ]]; then
                # First-match only to preserve Match block overrides
                local _ln
                _ln=$(grep -n "^[[:space:]]*${_hk}[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null | head -1 | cut -d: -f1) || true
                if [[ -n "$_ln" ]]; then
                    local _sed_tmp
                    _sed_tmp=$(mktemp "${_SSHD_CONFIG}.tf_sed.XXXXXX") || continue
                    sed "${_ln}s/.*/${_hk} ${_hv}/" "$_SSHD_CONFIG" > "$_sed_tmp" 2>/dev/null && mv -f "$_sed_tmp" "$_SSHD_CONFIG" 2>/dev/null || true
                    rm -f "$_sed_tmp" 2>/dev/null || true
                fi
                printf "  ${CYAN}~${RESET} %s: %s → %s\n" "$_hk" "${_cur:-?}" "$_hv"
                _changed=true
            else
                printf "  ${GREEN}●${RESET} %s: %s (already set)\n" "$_hk" "$_hv"
            fi
        elif grep -qE "^[[:space:]]*#[[:space:]]*${_hk}[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null; then
            # Commented out — uncomment and set (first match only)
            local _cln
            _cln=$(grep -n "^[[:space:]]*#[[:space:]]*${_hk}[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null | head -1 | cut -d: -f1) || true
            if [[ -n "$_cln" ]]; then
                local _sed_tmp
                _sed_tmp=$(mktemp "${_SSHD_CONFIG}.tf_sed.XXXXXX") || continue
                sed "${_cln}s/.*/${_hk} ${_hv}/" "$_SSHD_CONFIG" > "$_sed_tmp" 2>/dev/null && mv -f "$_sed_tmp" "$_SSHD_CONFIG" 2>/dev/null || true
                rm -f "$_sed_tmp" 2>/dev/null || true
            fi
            printf "  ${CYAN}+${RESET} %s: %s (uncommented)\n" "$_hk" "$_hv"
            _changed=true
        else
            # Not present — insert before first Match block (or append if none)
            local _match_ln
            _match_ln=$(grep -n "^[[:space:]]*Match[[:space:]]" "$_SSHD_CONFIG" 2>/dev/null | head -1 | cut -d: -f1) || true
            if [[ -n "$_match_ln" ]]; then
                local _sed_tmp
                _sed_tmp=$(mktemp "${_SSHD_CONFIG}.tf_sed.XXXXXX") || continue
                { head -n "$((_match_ln - 1))" "$_SSHD_CONFIG"; printf "%s %s\n" "$_hk" "$_hv"; tail -n "+${_match_ln}" "$_SSHD_CONFIG"; } > "$_sed_tmp" 2>/dev/null && mv -f "$_sed_tmp" "$_SSHD_CONFIG" 2>/dev/null || true
                rm -f "$_sed_tmp" 2>/dev/null || true
            else
                if [[ -s "$_SSHD_CONFIG" ]] && [[ -n "$(tail -c1 "$_SSHD_CONFIG" 2>/dev/null)" ]]; then
                    echo "" >> "$_SSHD_CONFIG" 2>/dev/null || true
                fi
                printf "%s %s\n" "$_hk" "$_hv" >> "$_SSHD_CONFIG" 2>/dev/null || true
            fi
            printf "  ${CYAN}+${RESET} %s: %s (added)\n" "$_hk" "$_hv"
            _changed=true
        fi
    done

    if [[ "$_changed" == true ]]; then
        # Test config before reload
        if sshd -t 2>/dev/null; then
            log_success "sshd_config syntax OK"
            local _reload_ok=false
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
                    _reload_ok=true
                fi
            else
                if service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
                    _reload_ok=true
                fi
            fi
            if [[ "$_reload_ok" == true ]]; then
                log_success "SSH daemon reloaded"
            else
                log_warn "Could not reload sshd (reload manually)"
            fi
        else
            log_error "sshd_config syntax error — restoring backup"
            if [[ -f "$_ts_backup" ]] && cp "$_ts_backup" "$_SSHD_CONFIG" 2>/dev/null; then
                log_info "Restored from timestamped backup"
            elif [[ -f "$_SSHD_BACKUP" ]] && cp "$_SSHD_BACKUP" "$_SSHD_CONFIG" 2>/dev/null; then
                log_warn "Timestamped backup unavailable, restored from canonical backup"
            else
                log_error "CRITICAL: No backup available — sshd_config may be broken!"
            fi
            return 1
        fi
    else
        log_info "No changes needed"
    fi
    return 0
}

_server_setup_firewall() {
    printf "\n${BOLD}[2/4] Configuring firewall${RESET}\n"

    # Detect SSH port from sshd_config (used by all firewall paths)
    local _fw_ssh_port=22
    if [[ -f "$_SSHD_CONFIG" ]]; then
        local _detected_port
        _detected_port=$(grep -E "^[[:space:]]*Port[[:space:]]+" "$_SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1) || true
        if [[ -n "$_detected_port" ]] && [[ "$_detected_port" =~ ^[0-9]+$ ]]; then
            _fw_ssh_port="$_detected_port"
        fi
    fi

    if command -v ufw &>/dev/null; then
        ufw default deny incoming 2>/dev/null || true
        ufw allow "$_fw_ssh_port/tcp" 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        printf "  ${GREEN}●${RESET} UFW enabled (default deny + SSH port %s allowed)\n" "$_fw_ssh_port"
        log_success "UFW configured with default deny"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${_fw_ssh_port}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        printf "  ${GREEN}●${RESET} firewalld: SSH port %s allowed\n" "$_fw_ssh_port"
        log_success "firewalld configured"
    elif command -v iptables &>/dev/null; then
        # IPv4 rules (conntrack instead of deprecated state module)
        if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        fi
        if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
            iptables -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true
        fi
        if ! iptables -C INPUT -p tcp --dport "$_fw_ssh_port" -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp --dport "$_fw_ssh_port" -j ACCEPT 2>/dev/null || true
        fi
        iptables -P INPUT DROP 2>/dev/null || true
        iptables -P FORWARD DROP 2>/dev/null || true
        printf "  ${GREEN}●${RESET} iptables: SSH (port %s) allowed, default deny\n" "$_fw_ssh_port"
        # IPv6 mirror rules
        if command -v ip6tables &>/dev/null; then
            if ! ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
                ip6tables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
            fi
            if ! ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
                ip6tables -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true
            fi
            if ! ip6tables -C INPUT -p tcp --dport "$_fw_ssh_port" -j ACCEPT 2>/dev/null; then
                ip6tables -A INPUT -p tcp --dport "$_fw_ssh_port" -j ACCEPT 2>/dev/null || true
            fi
            ip6tables -P INPUT DROP 2>/dev/null || true
            ip6tables -P FORWARD DROP 2>/dev/null || true
            printf "  ${GREEN}●${RESET} ip6tables: SSH (port %s) allowed, default deny\n" "$_fw_ssh_port"
        fi
        # Persist iptables rules
        if [[ -d "/etc/iptables" ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            if command -v ip6tables-save &>/dev/null; then
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
            printf "  ${GREEN}●${RESET} iptables rules persisted to /etc/iptables/\n"
        elif command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
            printf "  ${GREEN}●${RESET} iptables rules persisted via netfilter-persistent\n"
        else
            log_warn "Install iptables-persistent to survive reboots"
        fi
    else
        printf "  ${YELLOW}▲${RESET} No firewall tool found (ufw/firewalld/iptables)\n"
    fi
    return 0
}

_server_setup_fail2ban() {
    printf "\n${BOLD}[3/4] Setting up fail2ban${RESET}\n"

    if ! command -v fail2ban-client &>/dev/null; then
        log_info "Installing fail2ban..."
        if [[ -n "${PKG_INSTALL:-}" ]]; then
            ${PKG_INSTALL} fail2ban 2>/dev/null || {
                log_warn "Could not install fail2ban"
                return 0
            }
        else
            printf "  ${YELLOW}▲${RESET} Cannot install fail2ban (unknown package manager)\n"
            return 0
        fi
    fi

    # Detect SSH port
    local _f2b_ssh_port=22
    if [[ -f "$_SSHD_CONFIG" ]]; then
        local _f2b_dp
        _f2b_dp=$(grep -E "^[[:space:]]*Port[[:space:]]+" "$_SSHD_CONFIG" 2>/dev/null | awk '{print $2}' | head -1) || true
        if [[ -n "$_f2b_dp" ]] && [[ "$_f2b_dp" =~ ^[0-9]+$ ]]; then
            _f2b_ssh_port="$_f2b_dp"
        fi
    fi

    local jail_dir="/etc/fail2ban/jail.d"
    mkdir -p "$jail_dir" 2>/dev/null || true

    local jail_file="${jail_dir}/tunnelforge-sshd.conf"
    if [[ ! -f "$jail_file" ]]; then
        {
            printf "[sshd]\n"
            printf "enabled = true\n"
            printf "port = %s\n" "$_f2b_ssh_port"
            printf "filter = sshd\n"
            printf "maxretry = 5\n"
            printf "findtime = 600\n"
            printf "bantime = 3600\n"
            local _f2b_backend="auto"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then _f2b_backend="systemd"; fi
            printf "backend = %s\n" "$_f2b_backend"
        } > "$jail_file" 2>/dev/null || true
        printf "  ${GREEN}●${RESET} Created fail2ban SSH jail\n"
    else
        printf "  ${GREEN}●${RESET} fail2ban SSH jail already exists\n"
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
    fi
    log_success "fail2ban configured"
    return 0
}

_server_setup_sysctl() {
    printf "\n${BOLD}[4/4] Kernel hardening${RESET}\n"

    local sysctl_file="/etc/sysctl.d/99-tunnelforge.conf"
    if [[ ! -f "$sysctl_file" ]]; then
        {
            printf "# TunnelForge kernel hardening\n"
            printf "net.ipv4.tcp_syncookies = 1\n"
            printf "net.ipv4.conf.all.rp_filter = 1\n"
            printf "net.ipv4.conf.default.rp_filter = 1\n"
            printf "net.ipv4.icmp_echo_ignore_broadcasts = 1\n"
            printf "net.ipv4.conf.all.accept_redirects = 0\n"
            printf "net.ipv4.conf.default.accept_redirects = 0\n"
            printf "net.ipv4.conf.all.send_redirects = 0\n"
            printf "net.ipv4.conf.default.send_redirects = 0\n"
            printf "net.ipv4.ip_forward = 1\n"
        } > "$sysctl_file" 2>/dev/null || true
        sysctl -p "$sysctl_file" 2>/dev/null || true
        printf "  ${GREEN}●${RESET} Kernel parameters hardened\n"
        log_success "sysctl hardening applied"
    else
        printf "  ${GREEN}●${RESET} Kernel hardening already applied\n"
    fi
    return 0
}

server_setup() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Server setup requires root privileges"
        return 1
    fi

    printf "\n${BOLD_CYAN}═══ TunnelForge Server Setup ═══${RESET}\n"
    printf "${DIM}Hardening this server for receiving SSH tunnel connections${RESET}\n"

    printf "\nThis will:\n"
    printf "  1. Harden SSH daemon configuration\n"
    printf "  2. Configure firewall rules\n"
    printf "  3. Set up fail2ban intrusion prevention\n"
    printf "  4. Apply kernel network hardening\n\n"

    if ! confirm_action "Proceed with server hardening?"; then
        log_info "Server setup cancelled"
        return 0
    fi

    _server_harden_sshd || true
    _server_setup_firewall || true
    _server_setup_fail2ban || true
    _server_setup_sysctl || true

    printf "\n${BOLD_GREEN}═══ Server Setup Complete ═══${RESET}\n"
    printf "${DIM}Your server is now hardened for SSH tunnel connections.${RESET}\n"
    printf "${DIM}Run 'tunnelforge audit' to verify security posture.${RESET}\n\n"
    return 0
}

# ── TLS Obfuscation (stunnel) Setup ──
# Remotely installs and configures stunnel on a profile's server

# Build SSH command for remote execution on profile's server.
# Populates global _OBFS_SSH_CMD array. Caller must unset SSHPASS.
_obfs_remote_ssh() {
    local -n _ors_prof="$1"
    local host="${_ors_prof[SSH_HOST]:-}"
    local port="${_ors_prof[SSH_PORT]:-22}"
    local user="${_ors_prof[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"
    local key="${_ors_prof[IDENTITY_KEY]:-}"
    local password="${_ors_prof[SSH_PASSWORD]:-}"

    _OBFS_SSH_CMD=()
    local -a ssh_opts=(-p "$port" -o "ConnectTimeout=15" -o "StrictHostKeyChecking=accept-new")
    if [[ -n "$key" ]] && [[ -f "$key" ]]; then ssh_opts+=(-i "$key"); fi

    if [[ -n "$password" ]]; then
        if command -v sshpass &>/dev/null; then
            export SSHPASS="$password"
            _OBFS_SSH_CMD=(sshpass -e ssh "${ssh_opts[@]}" "${user}@${host}")
        else
            ssh_opts+=(-o "BatchMode=no")
            _OBFS_SSH_CMD=(ssh "${ssh_opts[@]}" "${user}@${host}")
        fi
    else
        _OBFS_SSH_CMD=(ssh "${ssh_opts[@]}" "${user}@${host}")
    fi
    return 0
}

# Core remote setup script — shared by CLI and wizard.
# Args: obfs_port ssh_port
# Requires _OBFS_SSH_CMD to be populated by _obfs_remote_ssh().
_obfs_run_remote_setup() {
    local obfs_port="$1" ssh_port="$2"
    # Validate ports are numeric before interpolation into remote script
    if ! [[ "$obfs_port" =~ ^[0-9]+$ ]] || ! [[ "$ssh_port" =~ ^[0-9]+$ ]]; then
        log_error "Port values must be numeric"; return 1
    fi
    local _setup_rc=0

    "${_OBFS_SSH_CMD[@]}" "bash -s" <<OBFS_SCRIPT || _setup_rc=$?
set -e
OBFS_PORT="${obfs_port}"
SSH_PORT="${ssh_port}"

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
    PKG_INSTALL="apt-get install -y -qq"
    PKG_UPDATE="apt-get update -qq"
elif command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL="dnf install -y -q"
    PKG_UPDATE="true"
elif command -v yum >/dev/null 2>&1; then
    PKG_INSTALL="yum install -y -q"
    PKG_UPDATE="true"
else
    echo "ERROR: No supported package manager (apt/dnf/yum)"
    exit 1
fi

# Check if port is already in use (not by our stunnel)
if ss -tln 2>/dev/null | grep -qE ":\${OBFS_PORT}[[:space:]]"; then
    LISTENER=\$(ss -tlnp 2>/dev/null | grep ":\${OBFS_PORT} " | head -1)
    if echo "\$LISTENER" | grep -q stunnel; then
        echo "INFO: stunnel already listening on port \${OBFS_PORT} — updating config"
    else
        echo "ERROR: Port \${OBFS_PORT} already in use by another service:"
        echo "  \$LISTENER"
        echo "Choose a different OBFS_PORT or stop the conflicting service."
        exit 2
    fi
fi

# Install
echo "Installing stunnel and openssl..."
\$PKG_UPDATE 2>/dev/null || true
\$PKG_INSTALL stunnel4 2>/dev/null || \$PKG_INSTALL stunnel 2>/dev/null || {
    echo "ERROR: Failed to install stunnel"
    exit 1
}

# Ensure openssl is available
command -v openssl >/dev/null 2>&1 || \$PKG_INSTALL openssl 2>/dev/null || true

# Generate self-signed cert if missing
CERT_DIR="/etc/stunnel"
CERT_FILE="\${CERT_DIR}/tunnelforge.pem"
mkdir -p "\$CERT_DIR"

if [ ! -f "\$CERT_FILE" ]; then
    echo "Generating self-signed TLS certificate..."
    openssl req -new -x509 -days 3650 -nodes \
        -out "\$CERT_FILE" -keyout "\$CERT_FILE" \
        -subj "/CN=tunnelforge/O=TunnelForge/C=US" 2>/dev/null || {
        echo "ERROR: Failed to generate certificate"
        exit 1
    }
    chmod 600 "\$CERT_FILE"
    echo "Certificate generated: \$CERT_FILE"
else
    echo "Certificate exists: \$CERT_FILE"
fi

# Write stunnel config
CONF_FILE="\${CERT_DIR}/tunnelforge-ssh.conf"
cat > "\$CONF_FILE" <<STUNNEL_CONF
; TunnelForge SSH obfuscation — wraps SSH in TLS
pid = /var/run/stunnel-tunnelforge.pid
[ssh-tls]
accept = 0.0.0.0:\${OBFS_PORT}
connect = 127.0.0.1:\${SSH_PORT}
cert = \${CERT_FILE}
STUNNEL_CONF
echo "Config written: \$CONF_FILE"

# Enable and start stunnel
if command -v systemctl >/dev/null 2>&1; then
    SVC=""
    for _sn in stunnel4 stunnel; do
        if systemctl list-unit-files "\${_sn}.service" 2>/dev/null | grep -q "\${_sn}"; then
            SVC="\$_sn"
            break
        fi
    done
    if [ -n "\$SVC" ]; then
        systemctl enable "\$SVC" 2>/dev/null || true
        systemctl restart "\$SVC" 2>/dev/null || true
        echo "Stunnel service restarted (\${SVC})"
    else
        stunnel "\$CONF_FILE" 2>/dev/null || { echo "ERROR: stunnel failed to start"; exit 1; }
        echo "Stunnel started directly"
    fi
else
    stunnel "\$CONF_FILE" 2>/dev/null || { echo "ERROR: stunnel failed to start"; exit 1; }
    echo "Stunnel started"
fi

# Open firewall port
if command -v ufw >/dev/null 2>&1; then
    ufw allow "\${OBFS_PORT}/tcp" 2>/dev/null || true
    echo "UFW: port \${OBFS_PORT} opened"
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="\${OBFS_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo "firewalld: port \${OBFS_PORT} opened"
fi

# Verify
sleep 1
if ss -tln 2>/dev/null | grep -qE ":\${OBFS_PORT}[[:space:]]"; then
    echo "SUCCESS: stunnel listening on port \${OBFS_PORT}"
else
    echo "WARNING: stunnel may not be listening yet — check manually"
fi
OBFS_SCRIPT

    unset SSHPASS 2>/dev/null || true
    return "$_setup_rc"
}

# CLI entry: tunnelforge obfs-setup <profile>
_obfs_setup_stunnel() {
    local name="$1"
    local -A _os_prof=()
    load_profile "$name" _os_prof || { log_error "Cannot load profile '${name}'"; return 1; }

    local host="${_os_prof[SSH_HOST]:-}"
    local ssh_port="${_os_prof[SSH_PORT]:-22}"
    local obfs_port="${_os_prof[OBFS_PORT]:-443}"
    local user="${_os_prof[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"

    if [[ -z "$host" ]]; then
        log_error "No SSH host in profile '${name}'"
        return 1
    fi

    if [[ "${_os_prof[OBFS_MODE]:-none}" == "none" ]]; then
        log_warn "Profile '${name}' does not have obfuscation enabled"
        printf "${DIM}  Enable it first: edit profile and set OBFS_MODE=stunnel${RESET}\n"
        printf "${DIM}  Or use the wizard: tunnelforge edit ${name}${RESET}\n\n"

        if ! confirm_action "Set up stunnel anyway?"; then
            return 0
        fi
        # Auto-enable if they proceed
        _os_prof[OBFS_MODE]="stunnel"
        _os_prof[OBFS_PORT]="$obfs_port"
        save_profile "$name" _os_prof 2>/dev/null || true
        log_info "Obfuscation enabled for profile '${name}'"
    fi

    printf "\n${BOLD_CYAN}═══ TLS Obfuscation Setup ═══${RESET}\n"
    printf "${DIM}Configuring stunnel on %s@%s to accept TLS on port %s${RESET}\n\n" "$user" "$host" "$obfs_port"

    printf "This will:\n"
    printf "  1. Install stunnel + openssl on the remote server\n"
    printf "  2. Generate a self-signed TLS certificate\n"
    printf "  3. Configure stunnel: port %s (TLS) → port %s (SSH)\n" "$obfs_port" "$ssh_port"
    printf "  4. Enable stunnel service and open firewall port\n\n"

    if ! confirm_action "Proceed with stunnel setup on ${host}?"; then
        log_info "Setup cancelled"
        return 0
    fi

    _obfs_remote_ssh _os_prof || { log_error "Cannot build SSH command"; return 1; }
    log_info "Connecting to ${user}@${host}..."

    local _rc=0
    _obfs_run_remote_setup "$obfs_port" "$ssh_port" || _rc=$?

    if (( _rc == 0 )); then
        log_success "Stunnel configured on ${host}:${obfs_port}"
        printf "\n${DIM}  SSH traffic will be wrapped in TLS — DPI sees HTTPS on port ${obfs_port}.${RESET}\n"
        printf "${DIM}  Start your tunnel: tunnelforge start ${name}${RESET}\n\n"
    elif (( _rc == 2 )); then
        log_error "Port ${obfs_port} is in use on ${host} — choose a different OBFS_PORT"
        return 1
    else
        log_error "Stunnel setup failed on ${host} (exit code: ${_rc})"
        return 1
    fi
    return 0
}

# Wizard entry: setup stunnel using profile nameref (before profile is saved)
_obfs_setup_stunnel_direct() {
    local -n _osd_prof="$1"
    local host="${_osd_prof[SSH_HOST]:-}"
    local ssh_port="${_osd_prof[SSH_PORT]:-22}"
    local obfs_port="${_osd_prof[OBFS_PORT]:-443}"
    local user="${_osd_prof[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"

    if [[ -z "$host" ]]; then
        log_error "No SSH host configured"
        return 1
    fi

    printf "\n${BOLD_CYAN}═══ TLS Obfuscation Setup ═══${RESET}\n" >/dev/tty
    printf "${DIM}Configuring stunnel on %s@%s (port %s → %s)${RESET}\n\n" "$user" "$host" "$obfs_port" "$ssh_port" >/dev/tty

    _obfs_remote_ssh _osd_prof || { log_error "Cannot build SSH command"; return 1; }
    log_info "Connecting to ${user}@${host}..."

    local _rc=0
    _obfs_run_remote_setup "$obfs_port" "$ssh_port" || _rc=$?

    unset SSHPASS 2>/dev/null || true

    if (( _rc == 0 )); then
        log_success "Stunnel configured on ${host}:${obfs_port}"
    elif (( _rc == 2 )); then
        log_error "Port ${obfs_port} is in use on ${host}"
    else
        log_error "Stunnel setup failed (exit code: ${_rc})"
    fi
    return "$_rc"
}

# ── Local Stunnel (Inbound TLS + PSK) ──
# Wraps the SOCKS5/local listener with TLS+PSK so clients connect securely.
# Architecture: client ──TLS+PSK──→ stunnel ──→ 127.0.0.1:LOCAL_PORT

# Generate a random 32-byte hex PSK
_obfs_generate_psk() {
    local _psk=""
    if command -v openssl &>/dev/null; then
        _psk=$(openssl rand -hex 32 2>/dev/null) || true
    fi
    if [[ -z "$_psk" ]] && [[ -r /dev/urandom ]]; then
        _psk=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n') || true
    fi
    if [[ -z "$_psk" ]]; then
        # Last resort: bash $RANDOM (weaker but functional)
        local _i
        for _i in 1 2 3 4 5 6 7 8; do
            printf '%08x' "$RANDOM$RANDOM" 2>/dev/null
        done
        return 0
    fi
    printf '%s' "$_psk"
    return 0
}

# Write local stunnel config and PSK secrets file.
# Args: name local_port obfs_local_port psk
_obfs_write_local_conf() {
    local _name="$1" _lport="$2" _olport="$3" _psk="$4"
    local _conf_dir="${CONFIG_DIR}/stunnel"
    local _conf_file="${_conf_dir}/${_name}-local.conf"
    local _psk_file="${_conf_dir}/${_name}-local.psk"
    local _pid_f="${PID_DIR}/${_name}.stunnel"
    local _log_f="${LOG_DIR}/${_name}-stunnel.log"

    mkdir -p "$_conf_dir" 2>/dev/null || true

    # Write PSK secrets file (identity:key format)
    printf 'tunnelforge:%s\n' "$_psk" > "$_psk_file" 2>/dev/null || {
        log_error "Cannot write PSK file: $_psk_file"
        return 1
    }
    chmod 600 "$_psk_file" 2>/dev/null || true

    # Write stunnel config — global options MUST come before [section]
    printf '; TunnelForge inbound TLS+PSK wrapper\n' > "$_conf_file"
    printf 'pid = %s\n' "$_pid_f" >> "$_conf_file"
    printf 'output = %s\n' "$_log_f" >> "$_conf_file"
    printf 'foreground = no\n\n' >> "$_conf_file"
    printf '[tunnelforge-inbound]\n' >> "$_conf_file"
    printf 'accept = 0.0.0.0:%s\n' "$_olport" >> "$_conf_file"
    printf 'connect = 127.0.0.1:%s\n' "$_lport" >> "$_conf_file"
    printf 'PSKsecrets = %s\n' "$_psk_file" >> "$_conf_file"
    printf 'ciphers = PSK\n' >> "$_conf_file"

    chmod 600 "$_conf_file" 2>/dev/null || true
    return 0
}

# Start local stunnel for inbound TLS+PSK.
# Args: name
# Reads profile to get LOCAL_PORT, OBFS_LOCAL_PORT, OBFS_PSK.
_obfs_start_local_stunnel() {
    local _name="$1"
    local -n _osl_prof="$2"
    local _lport="${_osl_prof[LOCAL_PORT]:-}"
    local _olport="${_osl_prof[OBFS_LOCAL_PORT]:-}"
    local _psk="${_osl_prof[OBFS_PSK]:-}"

    if [[ -z "$_olport" ]] || [[ "$_olport" == "0" ]]; then return 0; fi
    if [[ -z "$_lport" ]]; then
        log_warn "No LOCAL_PORT for local stunnel — skipping inbound TLS"
        return 0
    fi
    if [[ -z "$_psk" ]]; then
        log_warn "No PSK for local stunnel — skipping inbound TLS"
        return 0
    fi

    if ! command -v stunnel &>/dev/null && ! command -v stunnel4 &>/dev/null; then
        log_info "Installing stunnel for inbound TLS..."
        if [[ -n "${PKG_UPDATE:-}" ]]; then ${PKG_UPDATE} &>/dev/null || true; fi
        install_package "stunnel4" 2>/dev/null || install_package "stunnel" 2>/dev/null || true
        if ! command -v stunnel &>/dev/null && ! command -v stunnel4 &>/dev/null; then
            log_error "Failed to install stunnel — inbound TLS unavailable"
            return 1
        fi
        log_success "stunnel installed"
    fi

    # Write config + PSK file (includes global options at top)
    _obfs_write_local_conf "$_name" "$_lport" "$_olport" "$_psk" || return 1

    local _conf_file="${CONFIG_DIR}/stunnel/${_name}-local.conf"
    local _pid_f="${PID_DIR}/${_name}.stunnel"
    local _log_f="${LOG_DIR}/${_name}-stunnel.log"

    # Check if OBFS_LOCAL_PORT is already in use
    if is_port_in_use "$_olport" "0.0.0.0"; then
        log_error "Inbound TLS port ${_olport} already in use"
        return 1
    fi

    # Launch stunnel
    local _stunnel_bin="stunnel"
    if ! command -v stunnel &>/dev/null; then _stunnel_bin="stunnel4"; fi

    "$_stunnel_bin" "$_conf_file" >> "$_log_f" 2>&1 || {
        log_error "Local stunnel failed to start (check ${_log_f})"
        return 1
    }

    # Wait for PID file
    local _sw
    for _sw in 1 2 3; do
        if [[ -f "$_pid_f" ]]; then break; fi
        sleep 1
    done

    if [[ -f "$_pid_f" ]]; then
        local _spid=""
        _spid=$(cat "$_pid_f" 2>/dev/null) || true
        log_success "Inbound TLS active on 0.0.0.0:${_olport} → 127.0.0.1:${_lport} (PID: ${_spid:-?})"
    else
        log_warn "Local stunnel started but PID file missing"
    fi
    return 0
}

# Stop local stunnel for a profile.
# Args: name
_obfs_stop_local_stunnel() {
    local _name="$1"
    local _pid_f="${PID_DIR}/${_name}.stunnel"
    local _conf_dir="${CONFIG_DIR}/stunnel"

    if [[ ! -f "$_pid_f" ]]; then return 0; fi

    local _spid=""
    _spid=$(cat "$_pid_f" 2>/dev/null) || true
    if [[ -n "$_spid" ]] && kill -0 "$_spid" 2>/dev/null; then
        log_info "Stopping local stunnel (PID: ${_spid})..."
        kill "$_spid" 2>/dev/null || true
        local _sw=0
        while (( _sw < 3 )) && kill -0 "$_spid" 2>/dev/null; do
            sleep 1; (( ++_sw ))
        done
        if kill -0 "$_spid" 2>/dev/null; then
            kill -9 "$_spid" 2>/dev/null || true
        fi
    fi

    # Clean up files
    rm -f "$_pid_f" \
          "${_conf_dir}/${_name}-local.conf" \
          "${_conf_dir}/${_name}-local.psk" 2>/dev/null || true
    return 0
}

# Display client stunnel config for the user to copy.
# Args: name prof_ref
_obfs_show_client_config() {
    local _name="$1"
    local -n _occ_prof="$2"
    local _olport="${_occ_prof[OBFS_LOCAL_PORT]:-}"
    local _psk="${_occ_prof[OBFS_PSK]:-}"
    local _lport="${_occ_prof[LOCAL_PORT]:-}"
    local _host=""

    if [[ -z "$_olport" ]] || [[ "$_olport" == "0" ]]; then return 0; fi

    # Determine the server's reachable IP/hostname
    _host="${_occ_prof[SSH_HOST]:-localhost}"
    # If this machine has a public IP, try to detect it
    local _pub_ip=""
    _pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2) || true
    if [[ -n "$_pub_ip" ]]; then _host="$_pub_ip"; fi

    printf "\n${BOLD_CYAN}═══ Client Connection Info ═══${RESET}\n"
    printf "${DIM}Users connect to this server via TLS+PSK on port ${_olport}${RESET}\n\n"

    printf "${BOLD}Server address:${RESET}  %s:%s\n" "$_host" "$_olport"
    printf "${BOLD}PSK identity:${RESET}    tunnelforge\n"
    printf "${BOLD}PSK secret:${RESET}      %s\n" "$_psk"
    printf "${BOLD}SOCKS5 port:${RESET}     %s (tunneled through TLS)\n\n" "$_lport"

    printf "${BOLD}── Client stunnel.conf ──${RESET}\n"
    printf "${DIM}Save this on the user's PC and run: stunnel stunnel.conf${RESET}\n\n"
    printf "[tunnelforge]\n"
    printf "client = yes\n"
    printf "accept = 127.0.0.1:%s\n" "$_lport"
    printf "connect = %s:%s\n" "$_host" "$_olport"
    printf "PSKsecrets = psk.txt\n"
    printf "ciphers = PSK\n\n"

    printf "${BOLD}── psk.txt ──${RESET}\n"
    printf "tunnelforge:%s\n\n" "$_psk"

    printf "${DIM}After setup, configure browser/apps to use SOCKS5 proxy:${RESET}\n"
    printf "${DIM}  127.0.0.1:%s (on the user's PC)${RESET}\n\n" "$_lport"
    return 0
}

# Show all profiles with inbound TLS+PSK configured — admin quick-reference
# for sharing client connection details.
_menu_client_configs() {
    _menu_header "Client Configs"
    printf "  ${DIM}Profiles with inbound TLS+PSK protection${RESET}\n\n" >/dev/tty

    local _mcc_profiles _mcc_found=0
    _mcc_profiles=$(list_profiles) || true
    if [[ -z "$_mcc_profiles" ]]; then
        printf "  ${YELLOW}No profiles found.${RESET}\n" >/dev/tty
        return 0
    fi

    # Detect this machine's IP once
    local _mcc_pub_ip=""
    _mcc_pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2) || true

    while IFS= read -r _mcc_name; do
        [[ -z "$_mcc_name" ]] && continue
        local -A _mcc_p=()
        load_profile "$_mcc_name" _mcc_p || continue

        local _mcc_olport="${_mcc_p[OBFS_LOCAL_PORT]:-}"
        [[ -z "$_mcc_olport" ]] || [[ "$_mcc_olport" == "0" ]] && { unset _mcc_p; continue; }

        local _mcc_psk="${_mcc_p[OBFS_PSK]:-}"
        local _mcc_lport="${_mcc_p[LOCAL_PORT]:-1080}"
        local _mcc_host="${_mcc_pub_ip:-${_mcc_p[SSH_HOST]:-localhost}}"
        local _mcc_running=""
        if is_tunnel_running "$_mcc_name"; then
            _mcc_running="${GREEN}ALIVE${RESET}"
        else
            _mcc_running="${RED}STOPPED${RESET}"
        fi

        (( ++_mcc_found ))

        printf "  ${BOLD_CYAN}┌─── %s [%b]${RESET}\n" "$_mcc_name" "$_mcc_running" >/dev/tty
        printf "  ${CYAN}│${RESET}  ${BOLD}Server address:${RESET}    %s\n" "$_mcc_host" >/dev/tty
        printf "  ${CYAN}│${RESET}  ${BOLD}Port:${RESET}              %s\n" "$_mcc_olport" >/dev/tty
        printf "  ${CYAN}│${RESET}  ${BOLD}Local SOCKS5 port:${RESET} %s ${DIM}(default for client)${RESET}\n" "$_mcc_lport" >/dev/tty
        printf "  ${CYAN}│${RESET}  ${BOLD}PSK secret key:${RESET}    %s\n" "$_mcc_psk" >/dev/tty
        printf "  ${CYAN}└───${RESET}\n\n" >/dev/tty

        unset _mcc_p
    done <<< "$_mcc_profiles"

    if (( _mcc_found == 0 )); then
        printf "  ${YELLOW}No profiles have inbound TLS+PSK configured.${RESET}\n" >/dev/tty
        printf "  ${DIM}Create a tunnel with inbound protection enabled to see configs here.${RESET}\n" >/dev/tty
    else
        printf "  ${DIM}─────────────────────────────────────────────${RESET}\n" >/dev/tty
        printf "  ${DIM}Give clients the Server, Port, and PSK above.${RESET}\n" >/dev/tty
        printf "  ${DIM}They can use tunnelforge-client.bat (Windows) or the Linux script.${RESET}\n" >/dev/tty
        printf "  ${DIM}CLI: tunnelforge client-config <name> │ tunnelforge client-script <name>${RESET}\n" >/dev/tty
    fi
    printf "\n" >/dev/tty
    return 0
}

# Generate a self-contained client setup script.
# Users run this on their PC and it installs stunnel + connects automatically.
# Args: name prof_ref [output_file]
_obfs_generate_client_script() {
    local _name="$1"
    local -n _ogs_prof="$2"
    local _out="${3:-}"
    local _olport="${_ogs_prof[OBFS_LOCAL_PORT]:-}"
    local _psk="${_ogs_prof[OBFS_PSK]:-}"
    local _lport="${_ogs_prof[LOCAL_PORT]:-}"

    if [[ -z "$_olport" ]] || [[ "$_olport" == "0" ]]; then
        log_error "No inbound TLS configured on profile '$_name'"
        return 1
    fi
    if [[ -z "$_psk" ]]; then
        log_error "No PSK configured on profile '$_name'"
        return 1
    fi

    # Determine server IP
    local _host=""
    _host="${_ogs_prof[SSH_HOST]:-localhost}"
    local _pub_ip=""
    _pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2) || true
    if [[ -n "$_pub_ip" ]]; then _host="$_pub_ip"; fi

    # Validate interpolated values to prevent injection in generated script
    if ! [[ "$_psk" =~ ^[a-fA-F0-9]+$ ]]; then
        log_error "PSK contains invalid characters (expected hex)"
        return 1
    fi
    if ! [[ "$_host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Host contains invalid characters"
        return 1
    fi
    if ! [[ "$_olport" =~ ^[0-9]+$ ]] || ! [[ "$_lport" =~ ^[0-9]+$ ]]; then
        log_error "Port values must be numeric"
        return 1
    fi

    # Default output file
    if [[ -z "$_out" ]]; then
        _out="${CONFIG_DIR}/tunnelforge-connect.sh"
    fi

    cat > "$_out" << CLIENTSCRIPT
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
# TunnelForge Client Connect Script
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server: ${_host}:${_olport}
# ═══════════════════════════════════════════════════════
set -e

SERVER="${_host}"
PORT="${_olport}"
LOCAL_PORT="${_lport}"
PSK_IDENTITY="tunnelforge"
PSK_SECRET="${_psk}"

CONF_DIR="\${HOME}/.tunnelforge-client"
CONF_FILE="\${CONF_DIR}/stunnel.conf"
PSK_FILE="\${CONF_DIR}/psk.txt"
PID_FILE="\${CONF_DIR}/stunnel.pid"
LOG_FILE="\${CONF_DIR}/stunnel.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()  { printf "\${GREEN}[+]\${RESET} %s\n" "\$1"; }
error() { printf "\${RED}[!]\${RESET} %s\n" "\$1"; }
dim()   { printf "\${DIM}%s\${RESET}\n" "\$1"; }

# ── Stop ──
do_stop() {
    if [[ -f "\$PID_FILE" ]]; then
        local pid=""
        pid=\$(cat "\$PID_FILE" 2>/dev/null) || true
        if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
            kill "\$pid" 2>/dev/null || true
            info "Disconnected (PID: \$pid)"
        fi
        rm -f "\$PID_FILE" 2>/dev/null || true
    else
        error "Not connected"
    fi
    exit 0
}

# ── Status ──
do_status() {
    if [[ -f "\$PID_FILE" ]]; then
        local pid=""
        pid=\$(cat "\$PID_FILE" 2>/dev/null) || true
        if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
            info "Connected (PID: \$pid)"
            dim "SOCKS5 proxy: 127.0.0.1:\${LOCAL_PORT}"
            exit 0
        fi
    fi
    error "Not connected"
    exit 1
}

case "\${1:-}" in
    stop)   do_stop ;;
    status) do_status ;;
esac

printf "\n\${BOLD}\${CYAN}═══ TunnelForge Client ═══\${RESET}\n"
printf "\${DIM}Connecting to \${SERVER}:\${PORT} via TLS+PSK\${RESET}\n\n"

# ── Check/install stunnel ──
if ! command -v stunnel >/dev/null 2>&1 && ! command -v stunnel4 >/dev/null 2>&1; then
    info "Installing stunnel..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq stunnel4
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y -q stunnel
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y -q stunnel
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm stunnel
    elif command -v brew >/dev/null 2>&1; then
        brew install stunnel
    else
        error "Cannot install stunnel automatically"
        error "Install it manually: https://www.stunnel.org/downloads.html"
        exit 1
    fi
fi

if ! command -v stunnel >/dev/null 2>&1 && ! command -v stunnel4 >/dev/null 2>&1; then
    error "stunnel installation failed"
    exit 1
fi
info "stunnel found"

# ── Already running? ──
if [[ -f "\$PID_FILE" ]]; then
    old_pid=\$(cat "\$PID_FILE" 2>/dev/null) || true
    if [[ -n "\$old_pid" ]] && kill -0 "\$old_pid" 2>/dev/null; then
        info "Already connected (PID: \$old_pid)"
        dim "SOCKS5 proxy: 127.0.0.1:\${LOCAL_PORT}"
        dim "Run '\$0 stop' to disconnect"
        exit 0
    fi
    rm -f "\$PID_FILE" 2>/dev/null || true
fi

# ── Write config ──
mkdir -p "\$CONF_DIR" 2>/dev/null
chmod 700 "\$CONF_DIR" 2>/dev/null || true

printf '%s:%s\n' "\$PSK_IDENTITY" "\$PSK_SECRET" > "\$PSK_FILE"
chmod 600 "\$PSK_FILE"

cat > "\$CONF_FILE" << STCONF
; TunnelForge client config
pid = \${PID_FILE}
output = \${LOG_FILE}
foreground = no

[tunnelforge]
client = yes
accept = 127.0.0.1:\${LOCAL_PORT}
connect = \${SERVER}:\${PORT}
PSKsecrets = \${PSK_FILE}
ciphers = PSK
STCONF

# ── Connect ──
STUNNEL_BIN="stunnel"
if ! command -v stunnel >/dev/null 2>&1; then STUNNEL_BIN="stunnel4"; fi

"\$STUNNEL_BIN" "\$CONF_FILE" 2>/dev/null || {
    error "Failed to connect (check \$LOG_FILE)"
    exit 1
}

sleep 1
if [[ -f "\$PID_FILE" ]]; then
    pid=\$(cat "\$PID_FILE" 2>/dev/null) || true
    if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
        printf "\n"
        info "Connected! (PID: \$pid)"
        printf "\n"
        printf "  \${BOLD}SOCKS5 proxy:\${RESET}  127.0.0.1:\${LOCAL_PORT}\n"
        printf "\n"
        dim "  Browser setup: Settings → Proxy → Manual"
        dim "    SOCKS Host: 127.0.0.1   Port: \${LOCAL_PORT}"
        dim "    Select SOCKS v5, enable Proxy DNS"
        printf "\n"
        dim "  Commands:"
        dim "    \$0 status  — check connection"
        dim "    \$0 stop    — disconnect"
        printf "\n"
        exit 0
    fi
fi
error "Connection failed (check \$LOG_FILE)"
exit 1
CLIENTSCRIPT

    chmod +x "$_out" 2>/dev/null || true
    log_success "Linux/Mac script: $_out"
    printf "  ${BOLD}./tunnelforge-connect.sh${RESET}          # Connect\n"
    printf "  ${BOLD}./tunnelforge-connect.sh stop${RESET}     # Disconnect\n"
    printf "  ${BOLD}./tunnelforge-connect.sh status${RESET}   # Check status\n\n"
    return 0
}

# Generate a Windows PowerShell client connect script.
# Args: name prof_ref [output_file]
_obfs_generate_client_script_win() {
    local _name="$1"
    local -n _ogw_prof="$2"
    local _out="${3:-}"
    local _olport="${_ogw_prof[OBFS_LOCAL_PORT]:-}"
    local _psk="${_ogw_prof[OBFS_PSK]:-}"
    local _lport="${_ogw_prof[LOCAL_PORT]:-}"

    if [[ -z "$_olport" ]] || [[ "$_olport" == "0" ]]; then
        log_error "No inbound TLS configured on profile '$_name'"
        return 1
    fi
    if [[ -z "$_psk" ]]; then
        log_error "No PSK configured on profile '$_name'"
        return 1
    fi

    local _host=""
    _host="${_ogw_prof[SSH_HOST]:-localhost}"
    local _pub_ip=""
    _pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2) || true
    if [[ -n "$_pub_ip" ]]; then _host="$_pub_ip"; fi

    # Validate interpolated values to prevent injection in generated script
    if ! [[ "$_psk" =~ ^[a-fA-F0-9]+$ ]]; then
        log_error "PSK contains invalid characters (expected hex)"
        return 1
    fi
    if ! [[ "$_host" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Host contains invalid characters"
        return 1
    fi
    if ! [[ "$_olport" =~ ^[0-9]+$ ]] || ! [[ "$_lport" =~ ^[0-9]+$ ]]; then
        log_error "Port values must be numeric"
        return 1
    fi

    if [[ -z "$_out" ]]; then
        _out="${CONFIG_DIR}/tunnelforge-connect.ps1"
    fi

    cat > "$_out" << 'WINSCRIPT_TOP'
# ═══════════════════════════════════════════════════════
# TunnelForge Client Connect Script (Windows)
WINSCRIPT_TOP

    cat >> "$_out" << WINSCRIPT_VARS
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server: ${_host}:${_olport}
# ═══════════════════════════════════════════════════════

\$Server = "${_host}"
\$Port = "${_olport}"
\$LocalPort = "${_lport}"
\$PskIdentity = "tunnelforge"
\$PskSecret = "${_psk}"
WINSCRIPT_VARS

    cat >> "$_out" << 'WINSCRIPT_BODY'

$ConfDir = "$env:USERPROFILE\.tunnelforge-client"
$StunnelDir = "$ConfDir\stunnel"
$ConfFile = "$ConfDir\stunnel.conf"
$PskFile = "$ConfDir\psk.txt"
$PidFile = "$ConfDir\stunnel.pid"
$LogFile = "$ConfDir\stunnel.log"
$StunnelExe = "$StunnelDir\stunnel.exe"
$StunnelZip = "$ConfDir\stunnel.zip"
$StunnelUrl = "https://www.stunnel.org/downloads/stunnel-5.72-win64-installer.exe"

function Write-Info($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "[!] $msg" -ForegroundColor Red }
function Write-Dim($msg)  { Write-Host "    $msg" -ForegroundColor DarkGray }

# ── Stop ──
if ($args[0] -eq "stop") {
    if (Test-Path $PidFile) {
        $pid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($pid) {
            try { Stop-Process -Id $pid -Force -ErrorAction Stop; Write-Info "Disconnected (PID: $pid)" }
            catch { Write-Err "Process $pid not found" }
        }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    } else { Write-Err "Not connected" }
    exit
}

# ── Status ──
if ($args[0] -eq "status") {
    if (Test-Path $PidFile) {
        $pid = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($pid) {
            try {
                Get-Process -Id $pid -ErrorAction Stop | Out-Null
                Write-Info "Connected (PID: $pid)"
                Write-Dim "SOCKS5 proxy: 127.0.0.1:$LocalPort"
                exit 0
            } catch {}
        }
    }
    Write-Err "Not connected"
    exit 1
}

Write-Host ""
Write-Host "=== TunnelForge Client ===" -ForegroundColor Cyan
Write-Host "Connecting to ${Server}:${Port} via TLS+PSK" -ForegroundColor DarkGray
Write-Host ""

# ── Create config dir ──
if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }

# ── Find or install stunnel ──
$stunnel = $null

# Check common locations
$searchPaths = @(
    "$StunnelExe",
    "C:\Program Files (x86)\stunnel\bin\stunnel.exe",
    "C:\Program Files\stunnel\bin\stunnel.exe",
    "$env:ProgramFiles\stunnel\bin\stunnel.exe",
    "${env:ProgramFiles(x86)}\stunnel\bin\stunnel.exe"
)
foreach ($p in $searchPaths) {
    if (Test-Path $p) { $stunnel = $p; break }
}

# Check PATH
if (-not $stunnel) {
    $inPath = Get-Command stunnel -ErrorAction SilentlyContinue
    if ($inPath) { $stunnel = $inPath.Source }
}

if (-not $stunnel) {
    Write-Info "stunnel not found. Please install it:"
    Write-Host ""
    Write-Host "  Option 1: Download from https://www.stunnel.org/downloads.html" -ForegroundColor Yellow
    Write-Host "            Install the Win64 version" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Option 2: Using winget:" -ForegroundColor Yellow
    Write-Host "            winget install stunnel" -ForegroundColor White
    Write-Host ""
    Write-Host "  Option 3: Using chocolatey:" -ForegroundColor Yellow
    Write-Host "            choco install stunnel" -ForegroundColor White
    Write-Host ""
    Write-Host "After installing, run this script again." -ForegroundColor DarkGray
    exit 1
}

Write-Info "stunnel found: $stunnel"

# ── Check if already running ──
if (Test-Path $PidFile) {
    $oldPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($oldPid) {
        try {
            Get-Process -Id $oldPid -ErrorAction Stop | Out-Null
            Write-Info "Already connected (PID: $oldPid)"
            Write-Dim "SOCKS5 proxy: 127.0.0.1:$LocalPort"
            Write-Dim "Run '$($MyInvocation.MyCommand.Name) stop' to disconnect"
            exit 0
        } catch {}
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# ── Write config files ──
Set-Content -Path $PskFile -Value "${PskIdentity}:${PskSecret}" -Force
Set-Content -Path $ConfFile -Value @"
; TunnelForge client config
pid = $PidFile
output = $LogFile
foreground = no

[tunnelforge]
client = yes
accept = 127.0.0.1:$LocalPort
connect = ${Server}:${Port}
PSKsecrets = $PskFile
ciphers = PSK
"@ -Force

# ── Connect ──
Write-Info "Connecting..."
$proc = Start-Process -FilePath $stunnel -ArgumentList "`"$ConfFile`"" -PassThru -NoNewWindow -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# Check if stunnel created a PID file or is running
if (Test-Path $PidFile) {
    $newPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($newPid) {
        try {
            Get-Process -Id $newPid -ErrorAction Stop | Out-Null
            Write-Host ""
            Write-Info "Connected! (PID: $newPid)"
            Write-Host ""
            Write-Host "  SOCKS5 proxy:  127.0.0.1:$LocalPort" -ForegroundColor White
            Write-Host ""
            Write-Dim "Browser setup: Settings > Proxy > Manual"
            Write-Dim "  SOCKS Host: 127.0.0.1   Port: $LocalPort"
            Write-Dim "  Select SOCKS v5, enable Proxy DNS"
            Write-Host ""
            Write-Dim "Commands:"
            Write-Dim "  .\$($MyInvocation.MyCommand.Name) status  - check connection"
            Write-Dim "  .\$($MyInvocation.MyCommand.Name) stop    - disconnect"
            Write-Host ""
            exit 0
        } catch {}
    }
}

# Fallback: check if process is running
if ($proc -and -not $proc.HasExited) {
    Write-Host ""
    Write-Info "Connected! (PID: $($proc.Id))"
    Set-Content -Path $PidFile -Value $proc.Id
    Write-Host ""
    Write-Host "  SOCKS5 proxy:  127.0.0.1:$LocalPort" -ForegroundColor White
    Write-Host ""
    exit 0
}

Write-Err "Connection failed (check $LogFile)"
exit 1
WINSCRIPT_BODY

    log_success "Windows script: $_out"
    printf "  ${BOLD}powershell -ExecutionPolicy Bypass -File tunnelforge-connect.ps1${RESET}          # Connect\n"
    printf "  ${BOLD}powershell -ExecutionPolicy Bypass -File tunnelforge-connect.ps1 stop${RESET}     # Disconnect\n"
    printf "  ${BOLD}powershell -ExecutionPolicy Bypass -File tunnelforge-connect.ps1 status${RESET}   # Check\n\n"
    printf "${DIM}Send both files to users — .sh for Linux/Mac, .ps1 for Windows.${RESET}\n\n"
    return 0
}

# ── Systemd Service Management ──
# Generates and manages systemd unit files for tunnel profiles

_service_unit_path() {
    printf "%s/tunnelforge-%s.service" "$_SYSTEMD_DIR" "$1"
}

generate_service() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Service management requires root privileges"
        return 1
    fi
    if [[ "$INIT_SYSTEM" != "systemd" ]]; then
        log_error "Systemd is required (detected: ${INIT_SYSTEM})"
        return 1
    fi

    local -A _svc_prof
    load_profile "$name" _svc_prof 2>/dev/null || {
        log_error "Cannot load profile '${name}'"
        return 1
    }

    local tunnel_type="${_svc_prof[TUNNEL_TYPE]:-socks5}"
    local ssh_host="${_svc_prof[SSH_HOST]:-}"
    local ssh_port="${_svc_prof[SSH_PORT]:-22}"
    local ssh_user="${_svc_prof[SSH_USER]:-$(config_get SSH_DEFAULT_USER root)}"

    if [[ -z "$ssh_host" ]]; then
        log_error "No SSH host in profile '${name}'"
        return 1
    fi

    local unit_file
    unit_file=$(_service_unit_path "$name")

    # Escape % for systemd specifier safety in all user-derived fields
    local safe_name="${name//%/%%}"
    local exec_cmd="${INSTALL_DIR}/tunnelforge.sh start ${safe_name}"

    # Build description
    local desc="TunnelForge ${tunnel_type} tunnel '${name}' (${ssh_user}@${ssh_host}:${ssh_port})"
    desc="${desc//%/%%}"

    {
        printf "[Unit]\n"
        printf "Description=%s\n" "$desc"
        printf "Documentation=man:ssh(1)\n"
        printf "After=network-online.target\n"
        printf "Wants=network-online.target\n"
        printf "StartLimitIntervalSec=60\n"
        printf "StartLimitBurst=3\n"
        printf "\n"
        printf "[Service]\n"
        printf "Type=oneshot\n"
        printf "RemainAfterExit=yes\n"
        printf "ExecStart=%s\n" "$exec_cmd"
        printf "ExecStop=%s stop %s\n" "${INSTALL_DIR}/tunnelforge.sh" "$safe_name"
        printf "TimeoutStartSec=30\n"
        printf "TimeoutStopSec=15\n"
        printf "\n"
        printf "# Security sandboxing\n"
        local _needs_net_admin=false _needs_resolv=false
        if [[ "${_svc_prof[KILL_SWITCH]:-}" == "true" ]]; then _needs_net_admin=true; fi
        if [[ "${_svc_prof[DNS_LEAK_PROTECTION]:-}" == "true" ]]; then _needs_resolv=true; fi
        printf "ProtectSystem=strict\n"
        printf "ProtectHome=tmpfs\n"
        local _svc_home
        _svc_home=$(getent passwd root 2>/dev/null | cut -d: -f6) || true
        : "${_svc_home:=/root}"
        printf "BindReadOnlyPaths=%s/.ssh\n" "$_svc_home"
        printf "ReadWritePaths=%s\n" "$INSTALL_DIR"
        if [[ "$_needs_resolv" == true ]]; then
            printf "ReadWritePaths=/etc\n"
        fi
        printf "PrivateTmp=true\n"
        # Build capabilities dynamically based on features
        local _caps=""
        if [[ "$_needs_net_admin" == true ]]; then _caps="CAP_NET_ADMIN CAP_NET_RAW"; fi
        if [[ "$_needs_resolv" == true ]]; then
            if [[ -n "$_caps" ]]; then _caps="${_caps} CAP_LINUX_IMMUTABLE"; else _caps="CAP_LINUX_IMMUTABLE"; fi
        fi
        if [[ -n "$_caps" ]]; then
            printf "AmbientCapabilities=%s\n" "$_caps"
            printf "CapabilityBoundingSet=%s\n" "$_caps"
        else
            printf "NoNewPrivileges=true\n"
        fi
        printf "\n"
        printf "[Install]\n"
        printf "WantedBy=multi-user.target\n"
    } > "$unit_file" 2>/dev/null || {
        log_error "Failed to write service file: ${unit_file}"
        return 1
    }

    chmod 644 "$unit_file" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    log_success "Service file created: ${unit_file}"
    printf "\n${DIM}Manage with:${RESET}\n"
    printf "  systemctl enable  tunnelforge-%s    ${DIM}# Start on boot${RESET}\n" "$name"
    printf "  systemctl start   tunnelforge-%s    ${DIM}# Start now${RESET}\n" "$name"
    printf "  systemctl status  tunnelforge-%s    ${DIM}# Check status${RESET}\n" "$name"
    printf "  systemctl stop    tunnelforge-%s    ${DIM}# Stop${RESET}\n" "$name"
    printf "  systemctl disable tunnelforge-%s    ${DIM}# Remove from boot${RESET}\n\n" "$name"
    return 0
}

enable_service() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Service management requires root privileges"
        return 1
    fi

    local unit_file
    unit_file=$(_service_unit_path "$name")

    if [[ ! -f "$unit_file" ]]; then
        log_info "No service file found, generating..."
        generate_service "$name" || return 1
    fi

    systemctl enable "tunnelforge-${name}" 2>/dev/null || {
        log_error "Failed to enable service"
        return 1
    }
    systemctl start "tunnelforge-${name}" 2>/dev/null || {
        log_error "Failed to start service"
        return 1
    }
    log_success "Service tunnelforge-${name} enabled and started"
    return 0
}

disable_service() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Service management requires root privileges"
        return 1
    fi

    systemctl stop "tunnelforge-${name}" 2>/dev/null || true
    systemctl disable "tunnelforge-${name}" 2>/dev/null || true
    log_success "Service tunnelforge-${name} stopped and disabled"
    return 0
}

remove_service() {
    local name="$1"

    if [[ $EUID -ne 0 ]]; then
        log_error "Service management requires root privileges"
        return 1
    fi

    disable_service "$name" || true

    local unit_file
    unit_file=$(_service_unit_path "$name")
    if [[ -f "$unit_file" ]]; then
        rm -f "$unit_file" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        log_success "Removed service file: ${unit_file}"
    else
        log_info "No service file to remove"
    fi
    return 0
}

service_status() {
    local name="$1"

    local unit_name="tunnelforge-${name}"
    local unit_file
    unit_file=$(_service_unit_path "$name")

    printf "\n${BOLD}Service: %s${RESET}\n" "$unit_name"

    if [[ ! -f "$unit_file" ]]; then
        printf "  ${DIM}■${RESET} No service file\n\n"
        return 0
    fi

    local _svc_active _svc_enabled
    _svc_active=$(systemctl is-active "$unit_name" 2>/dev/null) || true
    _svc_enabled=$(systemctl is-enabled "$unit_name" 2>/dev/null) || true

    if [[ "$_svc_active" == "active" ]]; then
        printf "  ${GREEN}●${RESET} Status:  active (running)\n"
    elif [[ "$_svc_active" == "activating" ]]; then
        printf "  ${YELLOW}▲${RESET} Status:  activating\n"
    else
        printf "  ${DIM}■${RESET} Status:  %s\n" "${_svc_active:-unknown}"
    fi

    if [[ "$_svc_enabled" == "enabled" ]]; then
        printf "  ${GREEN}●${RESET} Boot:    enabled\n"
    else
        printf "  ${DIM}■${RESET} Boot:    %s\n" "${_svc_enabled:-disabled}"
    fi

    # Show recent log entries
    if command -v journalctl &>/dev/null; then
        printf "\n${DIM}Recent logs (last 5 lines):${RESET}\n"
        journalctl -u "$unit_name" --no-pager -n 5 2>/dev/null || true
    fi
    printf "\n"
    return 0
}

# ── Service interactive menu ──

_menu_service() {
    local name="$1"

    while true; do
        clear >/dev/tty 2>/dev/null || true
        printf "\n${BOLD_CYAN}═══ Service Manager: %s ═══${RESET}\n\n" "$name" >/dev/tty

        printf "  ${CYAN}1${RESET}) Generate service file\n" >/dev/tty
        printf "  ${CYAN}2${RESET}) Enable + start service\n" >/dev/tty
        printf "  ${CYAN}3${RESET}) Disable + stop service\n" >/dev/tty
        printf "  ${CYAN}4${RESET}) Show service status\n" >/dev/tty
        printf "  ${CYAN}5${RESET}) Remove service file\n" >/dev/tty
        printf "  ${YELLOW}q${RESET}) Back\n\n" >/dev/tty

        local _sv_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _sv_choice </dev/tty || true
        _drain_esc _sv_choice
        printf "\n" >/dev/tty

        case "$_sv_choice" in
            1) generate_service "$name" || true; _press_any_key ;;
            2) enable_service "$name" || true; _press_any_key ;;
            3) disable_service "$name" || true; _press_any_key ;;
            4) service_status "$name" || true; _press_any_key ;;
            5)
                if confirm_action "Remove service for '${name}'?"; then
                    remove_service "$name" || true
                fi
                _press_any_key ;;
            q|Q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── Backup & Restore ──

backup_tunnelforge() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="tunnelforge_backup_${timestamp}.tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    mkdir -p "$BACKUP_DIR" 2>/dev/null || true

    log_info "Creating backup: ${backup_name}..."

    # Build list of paths to include
    local -a _bk_paths=()
    if [[ -d "$CONFIG_DIR" ]]; then _bk_paths+=("$CONFIG_DIR"); fi
    if [[ -d "$PROFILES_DIR" ]]; then _bk_paths+=("$PROFILES_DIR"); fi
    if [[ -d "$DATA_DIR" ]]; then _bk_paths+=("$DATA_DIR"); fi

    # Include security-related backups (sshd_config, iptables rules)
    if [[ -d "$BACKUP_DIR" ]]; then
        _bk_paths+=("$BACKUP_DIR")
    fi

    if [[ ${#_bk_paths[@]} -eq 0 ]]; then
        log_error "Nothing to backup"
        return 1
    fi

    if tar czf "$backup_path" --exclude='*.tar.gz' "${_bk_paths[@]}" 2>/dev/null; then
        chmod 600 "$backup_path" 2>/dev/null || true
        local _bk_size
        _bk_size=$(stat -c %s "$backup_path" 2>/dev/null || stat -f %z "$backup_path" 2>/dev/null) || true
        _bk_size=$(format_bytes "${_bk_size:-0}")
        log_success "Backup created: ${backup_path} (${_bk_size})"

        # Rotate old backups (keep last 5)
        local _bk_count
        _bk_count=$(find "$BACKUP_DIR" -name "tunnelforge_backup_*.tar.gz" -type f 2>/dev/null | wc -l) || true
        : "${_bk_count:=0}"
        if (( _bk_count > 5 )); then
            find "$BACKUP_DIR" -name "tunnelforge_backup_*.tar.gz" -type f 2>/dev/null | \
                sort | head -n $(( _bk_count - 5 )) | while IFS= read -r _old_bk; do
                rm -f "$_old_bk" 2>/dev/null
            done || true
            log_debug "Rotated old backups"
        fi
    else
        log_error "Failed to create backup"
        return 1
    fi

    return 0
}

restore_tunnelforge() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Restore requires root privileges"
        return 1
    fi

    local backup_file="${1:-}"

    # If no file specified, find the latest
    if [[ -z "$backup_file" ]]; then
        backup_file=$(find "$BACKUP_DIR" -name "tunnelforge_backup_*.tar.gz" -type f 2>/dev/null | \
            sort -r | head -1) || true
        if [[ -z "$backup_file" ]]; then
            log_error "No backup files found in ${BACKUP_DIR}"
            return 1
        fi
        log_info "Found backup: $(basename "$backup_file")"
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: ${backup_file}"
        return 1
    fi

    printf "\n${BOLD}Backup contents:${RESET}\n"
    if ! tar tzf "$backup_file" >/dev/null 2>&1; then
        log_error "Cannot read backup archive"
        return 1
    fi
    tar tzf "$backup_file" 2>/dev/null | head -20 || true
    printf "${DIM}  ... (truncated)${RESET}\n\n"

    if ! confirm_action "Restore from this backup? (current config will be overwritten)"; then
        log_info "Restore cancelled"
        return 0
    fi

    log_info "Restoring from backup..."

    # Pre-scan archive for path traversal and symlink attacks
    local _bad_paths _symlinks _tar_listing
    _tar_listing=$(tar tzf "$backup_file" 2>/dev/null || true)
    _bad_paths=$(printf '%s\n' "$_tar_listing" | grep -E '(^|/)\.\.(/|$)|^/' || true)
    if [[ -n "$_bad_paths" ]]; then
        log_error "Backup archive contains unsafe paths (potential path traversal)"
        log_error "Suspicious entries: $(printf '%s' "$_bad_paths" | head -5)"
        return 1
    fi
    # Check for symlinks in the archive (tar tvf shows 'l' type)
    _symlinks=$(tar tvzf "$backup_file" 2>/dev/null | grep -E '^l' || true)
    if [[ -n "$_symlinks" ]]; then
        log_error "Backup archive contains symlinks (potential symlink attack)"
        log_error "Suspicious entries: $(printf '%s' "$_symlinks" | head -5)"
        return 1
    fi

    # Feature-detect --no-unsafe-links support
    local -a _tar_safe_opts=()
    if tar --help 2>&1 | grep -q -- '--no-unsafe-links' 2>/dev/null; then
        _tar_safe_opts=(--no-unsafe-links)
    fi
    if tar xzf "$backup_file" -C / --no-same-owner --no-same-permissions "${_tar_safe_opts[@]}" 2>/dev/null; then
        log_success "Backup restored successfully"
        log_info "Reapplying directory permissions..."
        init_directories 2>/dev/null || true
        # Secure config and profile files
        find "${CONFIG_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
        find "${PROFILES_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
        log_info "Reloading settings..."
        load_settings || true
    else
        log_error "Failed to restore backup"
        return 1
    fi

    return 0
}

# ── Backup interactive menu ──

_menu_backup_restore() {
    while true; do
        clear >/dev/tty 2>/dev/null || true
        printf "\n${BOLD_CYAN}═══ Backup & Restore ═══${RESET}\n\n" >/dev/tty

        printf "  ${CYAN}1${RESET}) Create backup now\n" >/dev/tty
        printf "  ${CYAN}2${RESET}) Restore from latest backup\n" >/dev/tty
        printf "  ${CYAN}3${RESET}) List available backups\n" >/dev/tty
        printf "  ${YELLOW}q${RESET}) Back\n\n" >/dev/tty

        local _br_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _br_choice </dev/tty || true
        _drain_esc _br_choice
        printf "\n" >/dev/tty

        case "$_br_choice" in
            1) backup_tunnelforge || true; _press_any_key ;;
            2) restore_tunnelforge || true; _press_any_key ;;
            3)
                printf "\n${BOLD}Available Backups:${RESET}\n"
                local _br_found=false
                local _br_f
                while IFS= read -r _br_f; do
                    [[ -z "$_br_f" ]] && continue
                    _br_found=true
                    local _br_sz
                    _br_sz=$(stat -c %s "$_br_f" 2>/dev/null || stat -f %z "$_br_f" 2>/dev/null) || true
                    _br_sz=$(format_bytes "${_br_sz:-0}")
                    printf "  ${CYAN}●${RESET} %s  ${DIM}(%s)${RESET}\n" "$(basename "$_br_f")" "$_br_sz"
                done < <(find "$BACKUP_DIR" -name "tunnelforge_backup_*.tar.gz" -type f 2>/dev/null | sort -r || true)
                if [[ "$_br_found" != true ]]; then
                    printf "  ${DIM}No backups found${RESET}\n"
                fi
                printf "\n"
                _press_any_key ;;
            q|Q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── Uninstall ──

uninstall_tunnelforge() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Uninstall requires root privileges"
        return 1
    fi

    printf "\n${BOLD_RED}═══ TunnelForge Uninstall ═══${RESET}\n\n"
    printf "This will remove:\n"
    printf "  - All tunnel profiles and configuration\n"
    printf "  - Systemd service files\n"
    printf "  - Installation directory (%s)\n" "$INSTALL_DIR"
    printf "  - CLI symlink (%s)\n" "$BIN_LINK"
    printf "\n${YELLOW}This will NOT remove:${RESET}\n"
    printf "  - Your SSH keys (~/.ssh/)\n"
    printf "  - Final backup (saved to ~/)\n\n"

    if ! confirm_action "Are you absolutely sure you want to uninstall?"; then
        log_info "Uninstall cancelled"
        return 0
    fi

    # Offer backup BEFORE any destructive operations
    if confirm_action "Create a backup before uninstalling?"; then
        backup_tunnelforge || true
        local _ui_bk
        _ui_bk=$(find "$BACKUP_DIR" -name "tunnelforge_backup_*.tar.gz" -type f 2>/dev/null | sort -r | head -1) || true
        if [[ -n "$_ui_bk" ]]; then
            local _ui_home_bk="${HOME}/tunnelforge_final_backup.tar.gz"
            if cp "$_ui_bk" "$_ui_home_bk" 2>/dev/null; then
                log_info "Backup saved to: ${_ui_home_bk}"
            else
                log_error "Failed to copy backup to ${_ui_home_bk}"
                if ! confirm_action "Continue uninstall WITHOUT backup?"; then
                    return 0
                fi
            fi
        fi
    fi

    # Stop all running tunnels
    log_info "Stopping all tunnels..."
    stop_all_tunnels 2>/dev/null || true

    # Remove systemd services
    log_info "Removing systemd services..."
    local _ui_svc
    while IFS= read -r _ui_svc; do
        [[ -z "$_ui_svc" ]] && continue
        local _ui_name
        _ui_name=$(basename "$_ui_svc" .service)
        _ui_name="${_ui_name#tunnelforge-}"
        systemctl stop "tunnelforge-${_ui_name}" 2>/dev/null || true
        systemctl disable "tunnelforge-${_ui_name}" 2>/dev/null || true
        rm -f "$_ui_svc" 2>/dev/null || true
    done < <(find "$_SYSTEMD_DIR" -name "tunnelforge-*.service" -type f 2>/dev/null || true)
    systemctl daemon-reload 2>/dev/null || true

    # Disable security features if active
    if is_dns_leak_protected; then
        log_info "Disabling DNS leak protection..."
        disable_dns_leak_protection 2>/dev/null || true
    fi
    if is_kill_switch_active; then
        log_info "Disabling kill switch..."
        local _fw_cmd
        for _fw_cmd in iptables ip6tables; do
            if command -v "$_fw_cmd" &>/dev/null; then
                "$_fw_cmd" -D OUTPUT -j "$_TF_CHAIN" 2>/dev/null || true
                "$_fw_cmd" -D FORWARD -j "$_TF_CHAIN" 2>/dev/null || true
                "$_fw_cmd" -F "$_TF_CHAIN" 2>/dev/null || true
                "$_fw_cmd" -X "$_TF_CHAIN" 2>/dev/null || true
            fi
        done
    fi

    # Remove symlink
    rm -f "$BIN_LINK" 2>/dev/null || true
    log_success "Removed CLI symlink"

    # Remove sysctl config
    rm -f /etc/sysctl.d/99-tunnelforge.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true

    # Remove fail2ban jail and reload
    rm -f /etc/fail2ban/jail.d/tunnelforge-sshd.conf 2>/dev/null || true
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true

    # Restore original sshd_config if we have a backup
    if [[ -f "$_SSHD_BACKUP" ]]; then
        log_info "Restoring original sshd_config..."
        if cp "$_SSHD_BACKUP" "$_SSHD_CONFIG" 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            log_success "Restored original sshd_config"
        else
            log_warn "Could not restore sshd_config"
        fi
    fi

    # Remove data dirs first, install dir last (contains running script)
    rm -rf "${PID_DIR}" 2>/dev/null || true
    rm -rf "${LOG_DIR}" 2>/dev/null || true
    rm -rf "${DATA_DIR}" 2>/dev/null || true
    rm -rf "${SSH_CONTROL_DIR}" 2>/dev/null || true
    rm -rf "${PROFILES_DIR}" 2>/dev/null || true
    rm -rf "${CONFIG_DIR}" 2>/dev/null || true

    # Print farewell BEFORE deleting the script itself
    printf "\n${BOLD_GREEN}TunnelForge has been uninstalled.${RESET}\n" >/dev/tty 2>/dev/null || true
    printf "${DIM}Thank you for using TunnelForge!${RESET}\n\n" >/dev/tty 2>/dev/null || true

    rm -rf "${INSTALL_DIR}" 2>/dev/null || true
    return 0
}

# ============================================================================
# TELEGRAM NOTIFICATIONS  (Phase 6)
# ============================================================================

readonly _TG_API="https://api.telegram.org"

_telegram_enabled() {
    [[ "$(config_get TELEGRAM_ENABLED false)" == "true" ]] || return 1
    [[ -n "$(config_get TELEGRAM_BOT_TOKEN)" ]] || return 1
    [[ -n "$(config_get TELEGRAM_CHAT_ID)" ]] || return 1
    return 0
}

# Find a running SOCKS5 proxy port for Telegram API calls
# (Telegram may be blocked on the local network)
_tg_find_proxy() {
    local _pn _pt _pp
    for _pn in $(list_profiles 2>/dev/null); do
        if is_tunnel_running "$_pn" 2>/dev/null; then
            _pt=$(get_profile_field "$_pn" "TUNNEL_TYPE" 2>/dev/null) || true
            if [[ "$_pt" == "socks5" ]]; then
                _pp=$(get_profile_field "$_pn" "LOCAL_PORT" 2>/dev/null) || true
                if [[ -n "$_pp" ]]; then
                    printf '%s' "$_pp"
                    return 0
                fi
            fi
        fi
    done
    return 1
}

# Build curl proxy args if a SOCKS5 tunnel is available
# Sets _TG_PROXY_ARGS array for caller
_tg_proxy_args() {
    _TG_PROXY_ARGS=()
    local _proxy_port
    _proxy_port=$(_tg_find_proxy 2>/dev/null) || true
    if [[ -n "$_proxy_port" ]]; then
        _TG_PROXY_ARGS=(--socks5-hostname "127.0.0.1:${_proxy_port}")
    fi
    return 0
}

# Send a message via Telegram Bot API
# Usage: _telegram_send "message text" [parse_mode]
_telegram_send() {
    local message="$1"
    local parse_mode="${2:-}"
    local token chat_id

    token=$(config_get TELEGRAM_BOT_TOKEN "")
    chat_id=$(config_get TELEGRAM_CHAT_ID "")

    [[ -n "$token" ]] && [[ -n "$chat_id" ]] || return 1

    local _tg_url="${_TG_API}/bot${token}/sendMessage"
    log_debug "Telegram send to chat ${chat_id}"

    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    local -a curl_args=(
        -s --max-time 15
        "${_TG_PROXY_ARGS[@]}"
        -X POST
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "text=${message}"
        --data-urlencode "disable_web_page_preview=true"
    )
    if [[ -n "$parse_mode" ]]; then
        curl_args+=(--data-urlencode "parse_mode=${parse_mode}")
    fi

    # Write URL to temp file to hide bot token from process listing and /proc/fd
    local _tg_cfg
    _tg_cfg=$(mktemp "${TMP_DIR}/tg_cfg.XXXXXX") || return 1
    printf 'url = "%s"\n' "$_tg_url" > "$_tg_cfg" 2>/dev/null || return 1
    chmod 600 "$_tg_cfg" 2>/dev/null || true
    local _tg_rc=0
    curl --config "$_tg_cfg" "${curl_args[@]}" >/dev/null 2>&1 || _tg_rc=$?
    rm -f "$_tg_cfg" 2>/dev/null || true
    return "$_tg_rc"
}

# Send a notification (checks if enabled + alerts flag)
_telegram_notify() {
    local message="$1"
    if _telegram_enabled && [[ "$(config_get TELEGRAM_ALERTS true)" == "true" ]]; then
        _telegram_send "$message" &
        _TG_BG_PIDS+=($!)
    fi
    # Reap any completed background sends
    local -a _tg_alive=()
    local _tg_p
    for _tg_p in "${_TG_BG_PIDS[@]}"; do
        if kill -0 "$_tg_p" 2>/dev/null; then
            _tg_alive+=("$_tg_p")
        else
            wait "$_tg_p" 2>/dev/null || true
        fi
    done
    _TG_BG_PIDS=("${_tg_alive[@]}")
    return 0
}

# Test Telegram connectivity
telegram_test() {
    if ! _telegram_enabled; then
        log_error "Telegram not configured (set bot token and chat ID first)"
        return 1
    fi

    local hostname _t_ip _t_running=0 _t_stopped=0 _t_total=0
    hostname=$(hostname 2>/dev/null || echo "unknown")
    _t_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    : "${_t_ip:=unknown}"

    # Count tunnel status
    local _t_name
    while IFS= read -r _t_name; do
        [[ -z "$_t_name" ]] && continue
        (( ++_t_total ))
        if is_tunnel_running "$_t_name" 2>/dev/null; then
            (( ++_t_running ))
        else
            (( ++_t_stopped ))
        fi
    done < <(list_profiles 2>/dev/null)

    local _t_alerts _t_reports
    _t_alerts=$(config_get TELEGRAM_ALERTS true)
    _t_reports=$(config_get TELEGRAM_PERIODIC_STATUS false)

    # Build tunnel list
    local _t_list=""
    local _tl_name
    while IFS= read -r _tl_name; do
        [[ -z "$_tl_name" ]] && continue
        if is_tunnel_running "$_tl_name" 2>/dev/null; then
            _t_list="${_t_list}  ✅ ${_tl_name} [ALIVE]
"
        else
            _t_list="${_t_list}  ⛔ ${_tl_name} [STOPPED]
"
        fi
    done < <(list_profiles 2>/dev/null)
    [[ -z "$_t_list" ]] && _t_list="  (none configured)
"

    local test_msg
    test_msg="$(printf '✅ TunnelForge Connected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🖥 Server Info
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Host: %s
IP: %s
Version: %s
Time: %s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 Tunnels (%d running / %d stopped)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔔 Alerts
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Alerts: %s
Status Reports: %s

You will be notified on:
  tunnel start/stop/fail/reconnect
  periodic status reports
  security audit alerts

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🤖 Bot Commands
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
/tf_help    - Show this help
/tf_status  - Tunnel status
/tf_list    - List all tunnels
/tf_ip      - Show server IP
/tf_config  - Get client config (PSK)
/tf_uptime  - Server uptime
/tf_report  - Full status report

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⌨️ Server CLI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
tunnelforge start/stop/restart <name>
tunnelforge list
tunnelforge dashboard
tunnelforge menu
tunnelforge telegram share <name>
tunnelforge telegram report' \
        "$hostname" "$_t_ip" "${VERSION}" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$_t_running" "$_t_stopped" "$_t_list" "$_t_alerts" "$_t_reports")"

    log_info "Sending test message..."
    local _tt_token
    _tt_token=$(config_get TELEGRAM_BOT_TOKEN "")
    local _tt_url="${_TG_API}/bot${_tt_token}/sendMessage"

    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    # Write URL to temp file to hide bot token from /proc (matches _telegram_send pattern)
    local _tt_cfg
    _tt_cfg=$(mktemp "${TMP_DIR}/tg_test.XXXXXX") || { log_error "Cannot create temp file"; return 1; }
    printf 'url = "%s"\n' "$_tt_url" > "$_tt_cfg" 2>/dev/null || { rm -f "$_tt_cfg" 2>/dev/null; return 1; }
    chmod 600 "$_tt_cfg" 2>/dev/null || true
    local response
    response=$(curl --config "$_tt_cfg" \
        -s --max-time 15 "${_TG_PROXY_ARGS[@]}" -X POST \
        --data-urlencode "chat_id=$(config_get TELEGRAM_CHAT_ID)" \
        --data-urlencode "text=${test_msg}" 2>/dev/null) || true
    rm -f "$_tt_cfg" 2>/dev/null

    if printf '%s' "$response" | grep -qF '"ok":true' 2>/dev/null; then
        log_success "Telegram test message sent successfully"
        return 0
    else
        local err_desc
        err_desc=$(printf '%s' "$response" | grep -oE '"description":"[^"]*"' 2>/dev/null | head -1) || true
        log_error "Telegram test failed: ${err_desc:-no response}"
        return 1
    fi
}

# Show Telegram status
telegram_status() {
    printf "\n${BOLD}Telegram Notification Status${RESET}\n\n"
    printf "  Enabled       : ${BOLD}%s${RESET}\n" "$(config_get TELEGRAM_ENABLED false)"
    printf "  Bot Token     : ${BOLD}%s${RESET}\n" \
        "$(if [[ -n "$(config_get TELEGRAM_BOT_TOKEN)" ]]; then echo '••••••••(set)'; else echo '(not set)'; fi)"
    printf "  Chat ID       : ${BOLD}%s${RESET}\n" \
        "$(local _cid; _cid=$(config_get TELEGRAM_CHAT_ID); if [[ -n "$_cid" ]]; then echo "****${_cid: -4}"; else echo '(not set)'; fi)"
    printf "  Alerts        : ${BOLD}%s${RESET}\n" "$(config_get TELEGRAM_ALERTS true)"
    printf "  Status Reports: ${BOLD}%s${RESET}\n" "$(config_get TELEGRAM_PERIODIC_STATUS false)"
    printf "  Report Interval: ${BOLD}%s${RESET}s\n" "$(config_get TELEGRAM_STATUS_INTERVAL 3600)"
    printf "\n"
    return 0
}

# Telegram update offset file — prevents reprocessing same messages
_tg_offset_file() { printf '%s' "${CONFIG_DIR}/tg_offset"; }

_tg_get_offset() {
    local _f
    _f=$(_tg_offset_file)
    if [[ -f "$_f" ]]; then
        local _val
        _val=$(cat "$_f" 2>/dev/null) || true
        if [[ "$_val" =~ ^[0-9]+$ ]]; then
            printf '%s' "$_val"; return 0
        fi
    fi
    printf '0'
    return 0
}

_tg_set_offset() {
    local _f
    _f=$(_tg_offset_file)
    printf '%s' "$1" > "$_f" 2>/dev/null || true
}

# Auto-detect chat ID from recent messages to the bot
# Uses offset tracking to avoid reprocessing old updates
_telegram_get_chat_id() {
    local token="$1"
    [[ -z "$token" ]] && return 1

    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    local _offset
    _offset=$(_tg_get_offset) || true

    local _curl_cfg _url_str
    _curl_cfg=$(mktemp "${TMP_DIR}/tg_cid.XXXXXX") || return 1
    chmod 600 "$_curl_cfg" 2>/dev/null || true
    if [[ "$_offset" -gt 0 ]] 2>/dev/null; then
        _url_str=$(printf '%s/bot%s/getUpdates?offset=%s' "$_TG_API" "$token" "$_offset")
    else
        _url_str=$(printf '%s/bot%s/getUpdates' "$_TG_API" "$token")
    fi
    printf 'url = "%s"\n' "$_url_str" > "$_curl_cfg"
    local response
    response=$(curl -s --max-time 15 "${_TG_PROXY_ARGS[@]}" --max-filesize 1048576 -K "$_curl_cfg" 2>/dev/null) || true
    rm -f "$_curl_cfg" 2>/dev/null || true
    [[ -z "$response" ]] && return 1
    printf '%s' "$response" | grep -qF '"ok":true' || return 1

    local chat_id="" max_update_id=""
    if command -v python3 &>/dev/null; then
        local _py_out
        _py_out=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    results=d.get('result',[])
    max_uid=0
    cid=''
    for u in results:
        uid=u.get('update_id',0)
        if uid>max_uid: max_uid=uid
    for u in reversed(results):
        if 'message' in u:
            cid=str(u['message']['chat']['id']); break
        elif 'my_chat_member' in u:
            cid=str(u['my_chat_member']['chat']['id']); break
    print(cid+'|'+str(max_uid))
except: print('|0')
" <<< "$response" 2>/dev/null) || true
        chat_id="${_py_out%%|*}"
        max_update_id="${_py_out##*|}"
    fi
    # Fallback: grep extraction
    if [[ -z "$chat_id" ]]; then
        chat_id=$(printf '%s' "$response" | grep -oE '"chat"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-?[0-9]+' \
            | grep -oE -- '-?[0-9]+$' | tail -1 2>/dev/null) || true
        # Extract max update_id via grep
        if [[ -z "$max_update_id" ]] || [[ "$max_update_id" == "0" ]]; then
            max_update_id=$(printf '%s' "$response" | grep -oE '"update_id"[[:space:]]*:[[:space:]]*[0-9]+' \
                | grep -oE '[0-9]+$' | sort -n | tail -1 2>/dev/null) || true
        fi
    fi

    # Confirm processed updates by advancing offset
    if [[ -n "$max_update_id" ]] && [[ "$max_update_id" =~ ^[0-9]+$ ]] && (( max_update_id > 0 )); then
        _tg_set_offset "$(( max_update_id + 1 ))"
    fi

    if [[ -n "$chat_id" ]] && [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
        _TG_DETECTED_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

# Telegram interactive setup wizard
telegram_setup() {
    local _saved_token _saved_chatid _saved_enabled
    _saved_token=$(config_get TELEGRAM_BOT_TOKEN "")
    _saved_chatid=$(config_get TELEGRAM_CHAT_ID "")
    _saved_enabled=$(config_get TELEGRAM_ENABLED "false")

    # Restore on Ctrl+C
    trap 'config_set TELEGRAM_BOT_TOKEN "$_saved_token"; config_set TELEGRAM_CHAT_ID "$_saved_chatid"; config_set TELEGRAM_ENABLED "$_saved_enabled"; trap - INT; printf "\n" >/dev/tty; return 0' INT

    clear >/dev/tty 2>/dev/null || true
    printf "${BOLD_CYAN}══════════════════════════════════════════════════════════════${RESET}\n" >/dev/tty
    printf "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${RESET}\n" >/dev/tty
    printf "${BOLD_CYAN}══════════════════════════════════════════════════════════════${RESET}\n\n" >/dev/tty

    # ── Step 1: Bot Token ──
    printf "  ${BOLD}Step 1: Create a Telegram Bot${RESET}\n" >/dev/tty
    printf "  ${CYAN}─────────────────────────────${RESET}\n" >/dev/tty
    printf "  1. Open Telegram and search for ${BOLD}@BotFather${RESET}\n" >/dev/tty
    printf "  2. Send ${YELLOW}/newbot${RESET}\n" >/dev/tty
    printf "  3. Choose a name (e.g. \"TunnelForge Monitor\")\n" >/dev/tty
    printf "  4. Choose a username (e.g. \"my_tunnel_bot\")\n" >/dev/tty
    printf "  5. BotFather will give you a token like:\n" >/dev/tty
    printf "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${RESET}\n\n" >/dev/tty

    local _tg_token=""
    read -rp "  Enter your bot token: " _tg_token </dev/tty >/dev/tty || { trap - INT; return 0; }
    _tg_token="${_tg_token## }"; _tg_token="${_tg_token%% }"
    printf "\n" >/dev/tty

    if [[ -z "$_tg_token" ]]; then
        printf "  ${RED}No token entered. Setup cancelled.${RESET}\n" >/dev/tty
        _press_any_key || true; trap - INT; return 0
    fi

    # Validate token format
    if [[ ! "$_tg_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        printf "  ${RED}Invalid token format. Should be like: 123456789:ABCdefGHI...${RESET}\n" >/dev/tty
        _press_any_key || true; trap - INT; return 0
    fi

    # Verify token with Telegram API (route through SOCKS5 if available)
    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    printf "  Verifying bot token... " >/dev/tty
    local _me_cfg _me_resp
    _me_cfg=$(mktemp "${TMP_DIR}/tg_me.XXXXXX") || true
    if [[ -n "$_me_cfg" ]]; then
        chmod 600 "$_me_cfg" 2>/dev/null || true
        printf 'url = "%s/bot%s/getMe"\n' "$_TG_API" "$_tg_token" > "$_me_cfg"
        _me_resp=$(curl -s --max-time 15 "${_TG_PROXY_ARGS[@]}" -K "$_me_cfg" 2>/dev/null) || true
        rm -f "$_me_cfg" 2>/dev/null || true
        if printf '%s' "$_me_resp" | grep -qF '"ok":true' 2>/dev/null; then
            printf "${GREEN}Valid${RESET}\n" >/dev/tty
        else
            printf "${RED}Invalid token${RESET}\n" >/dev/tty
            printf "  ${RED}The Telegram API rejected this token. Check it and try again.${RESET}\n" >/dev/tty
            _press_any_key || true; trap - INT; return 0
        fi
    fi

    # ── Step 2: Chat ID (auto-detect) ──
    printf "\n  ${BOLD}Step 2: Get Your Chat ID${RESET}\n" >/dev/tty
    printf "  ${CYAN}────────────────────────${RESET}\n" >/dev/tty
    printf "  1. Open your new bot in Telegram\n" >/dev/tty
    printf "  2. Send it the message: ${YELLOW}/start${RESET}\n\n" >/dev/tty
    printf "  ${YELLOW}Important:${RESET} You MUST send ${BOLD}/start${RESET} to the bot first!\n\n" >/dev/tty

    read -rp "  Press Enter after sending /start to your bot... " </dev/tty >/dev/tty || { trap - INT; return 0; }

    printf "\n  Detecting chat ID... " >/dev/tty
    local _TG_DETECTED_CHAT_ID="" _attempts=0
    while (( _attempts < 3 )) && [[ -z "$_TG_DETECTED_CHAT_ID" ]]; do
        _telegram_get_chat_id "$_tg_token" || true
        if [[ -n "$_TG_DETECTED_CHAT_ID" ]]; then break; fi
        (( ++_attempts ))
        sleep 2
    done

    local _tg_chat_id=""
    if [[ -n "$_TG_DETECTED_CHAT_ID" ]]; then
        _tg_chat_id="$_TG_DETECTED_CHAT_ID"
        printf "${GREEN}Found: ${_tg_chat_id}${RESET}\n" >/dev/tty
    else
        printf "${RED}Could not auto-detect${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}You can enter it manually:${RESET}\n" >/dev/tty
        printf "  ${CYAN}────────────────────────────${RESET}\n" >/dev/tty
        printf "  Option 1: Press Enter to retry detection\n" >/dev/tty
        printf "  Option 2: Find your chat ID via ${BOLD}@userinfobot${RESET} on Telegram\n\n" >/dev/tty

        local _manual_chatid=""
        read -rp "  Enter chat ID (or Enter to retry): " _manual_chatid </dev/tty >/dev/tty || true

        if [[ -z "$_manual_chatid" ]]; then
            # Retry
            printf "\n  Retrying detection... " >/dev/tty
            _attempts=0
            while (( _attempts < 5 )) && [[ -z "$_TG_DETECTED_CHAT_ID" ]]; do
                _telegram_get_chat_id "$_tg_token" || true
                if [[ -n "$_TG_DETECTED_CHAT_ID" ]]; then break; fi
                (( ++_attempts ))
                sleep 2
            done
            if [[ -n "$_TG_DETECTED_CHAT_ID" ]]; then
                _tg_chat_id="$_TG_DETECTED_CHAT_ID"
                printf "${GREEN}Found: ${_tg_chat_id}${RESET}\n" >/dev/tty
            fi
        elif [[ "$_manual_chatid" =~ ^-?[0-9]+$ ]]; then
            _tg_chat_id="$_manual_chatid"
        else
            printf "  ${RED}Invalid chat ID. Must be a number.${RESET}\n" >/dev/tty
        fi

        if [[ -z "$_tg_chat_id" ]]; then
            printf "  ${RED}Could not get chat ID. Setup cancelled.${RESET}\n" >/dev/tty
            _press_any_key || true; trap - INT; return 0
        fi
    fi

    # ── Step 3: Save and test ──
    config_set "TELEGRAM_BOT_TOKEN" "$_tg_token"
    config_set "TELEGRAM_CHAT_ID" "$_tg_chat_id"
    config_set "TELEGRAM_ENABLED" "true"
    save_settings || true

    printf "\n  Sending test message... " >/dev/tty
    if telegram_test 2>/dev/null; then
        printf "${GREEN}Success!${RESET}\n" >/dev/tty
        printf "\n  ${GREEN}Telegram notifications are now active.${RESET}\n" >/dev/tty
    else
        printf "${RED}Failed to send.${RESET}\n" >/dev/tty
        printf "  ${YELLOW}Token/chat ID saved but test failed — check credentials.${RESET}\n" >/dev/tty
    fi

    _press_any_key || true
    trap - INT
    return 0
}

# ── Notification message builders ──

_notify_tunnel_start() {
    local name="$1" tunnel_type="${2:-tunnel}" pid="${3:-}"
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    local _nts_obfs=""
    local -A _nts_prof=()
    if load_profile "$name" _nts_prof 2>/dev/null; then
        if [[ "${_nts_prof[OBFS_MODE]:-none}" != "none" ]]; then
            _nts_obfs=$(printf '\nObfuscation: %s (port %s)' "${_nts_prof[OBFS_MODE]}" "${_nts_prof[OBFS_PORT]:-443}")
        fi
        if [[ -n "${_nts_prof[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_nts_prof[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
            _nts_obfs="${_nts_obfs}$(printf '\nInbound TLS: port %s (PSK)' "${_nts_prof[OBFS_LOCAL_PORT]}")"
        fi
    fi
    _telegram_notify "$(printf '✅ Tunnel Started\n\nName: %s\nType: %s\nHost: %s\nPID: %s%s\nTime: %s' \
        "$name" "$tunnel_type" "$hostname" "${pid:-?}" "$_nts_obfs" "$(date '+%H:%M:%S')")"
    return 0
}

_notify_tunnel_stop() {
    local name="$1"
    _telegram_notify "$(printf '⛔ Tunnel Stopped\n\nName: %s\nTime: %s' \
        "$name" "$(date '+%H:%M:%S')")"
    return 0
}

_notify_tunnel_fail() {
    local name="$1"
    _telegram_notify "$(printf '❌ Tunnel Failed\n\nName: %s\nTime: %s\nCheck logs for details.' \
        "$name" "$(date '+%H:%M:%S')")"
    return 0
}

_notify_reconnect() {
    local name="$1" reason="${2:-unknown}"
    _telegram_notify "$(printf '🔄 Tunnel Reconnect\n\nName: %s\nReason: %s\nTime: %s' \
        "$name" "$reason" "$(date '+%H:%M:%S')")"
    return 0
}


# Generate a periodic status report (with timestamp dedup to prevent repeats)
telegram_send_status() {
    if ! _telegram_enabled; then return 0; fi
    if [[ "$(config_get TELEGRAM_PERIODIC_STATUS false)" != "true" ]]; then return 0; fi

    # Dedup: check last send timestamp to prevent repeat sends
    local _ts_file="${CONFIG_DIR}/tg_last_report"
    local _interval
    _interval=$(config_get TELEGRAM_STATUS_INTERVAL 3600)
    if [[ -f "$_ts_file" ]]; then
        local _last_ts _now_ts
        _last_ts=$(cat "$_ts_file" 2>/dev/null) || true
        _now_ts=$(date +%s 2>/dev/null) || true
        if [[ "$_last_ts" =~ ^[0-9]+$ ]] && [[ "$_now_ts" =~ ^[0-9]+$ ]]; then
            if (( _now_ts - _last_ts < _interval )); then
                return 0  # Too soon, skip
            fi
        fi
    fi

    local hostname running=0 stopped=0 total=0
    hostname=$(hostname 2>/dev/null || echo "unknown")

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        ((++total))
        if is_tunnel_running "$name"; then
            ((++running))
        else
            ((++stopped))
        fi
    done < <(list_profiles)

    (( total > 0 )) || return 0

    local public_ip
    public_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    : "${public_ip:=unknown}"

    local msg
    msg=$(printf '📊 Status Report\n\nHost: %s\nIP: %s\nTunnels: %d running / %d stopped / %d total\nTime: %s' \
        "$hostname" "$public_ip" "$running" "$stopped" "$total" "$(date '+%Y-%m-%d %H:%M:%S')")

    if _telegram_send "$msg"; then
        # Record send timestamp only on success
        date +%s > "$_ts_file" 2>/dev/null || true
    fi
    return 0
}

# ── Telegram Bot Command Handler ──
# Polls getUpdates, processes /tf_* commands, responds via sendMessage.
# Call periodically (e.g., from dashboard loop). Uses offset tracking to avoid repeats.

_tg_cmd_response() {
    local _cmd="$1" _chat="$2" _token="$3"

    local _resp=""
    case "$_cmd" in
        /tf_help|/tf_help@*)
            _resp="$(printf '🤖 TunnelForge Bot Commands

/tf_help    - Show this help
/tf_status  - Tunnel status overview
/tf_list    - List all tunnels
/tf_ip      - Show server IP
/tf_config  - Get client configs (PSK)
/tf_uptime  - Server uptime
/tf_report  - Full status report')"
            ;;
        /tf_status|/tf_status@*)
            local _r=0 _s=0 _t=0 _n
            while IFS= read -r _n; do
                [[ -z "$_n" ]] && continue
                (( ++_t ))
                if is_tunnel_running "$_n" 2>/dev/null; then (( ++_r )); else (( ++_s )); fi
            done < <(list_profiles 2>/dev/null)
            _resp="$(printf '📊 Tunnel Status\n\nRunning: %d\nStopped: %d\nTotal: %d\nTime: %s' \
                "$_r" "$_s" "$_t" "$(date '+%H:%M:%S')")"
            ;;
        /tf_list|/tf_list@*)
            local _lines="" _n
            while IFS= read -r _n; do
                [[ -z "$_n" ]] && continue
                if is_tunnel_running "$_n" 2>/dev/null; then
                    _lines="${_lines}✅ ${_n} [ALIVE]\n"
                else
                    _lines="${_lines}⛔ ${_n} [STOPPED]\n"
                fi
            done < <(list_profiles 2>/dev/null)
            [[ -z "$_lines" ]] && _lines="(no tunnels configured)\n"
            _resp="$(printf '📋 Tunnel List\n\n%b' "$_lines")"
            ;;
        /tf_ip|/tf_ip@*)
            local _ip
            _ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
            : "${_ip:=unknown}"
            _resp="$(printf '🌐 Server IP: %s\nHostname: %s' "$_ip" "$(hostname 2>/dev/null || echo unknown)")"
            ;;
        /tf_config|/tf_config@*)
            # Send config for all profiles with inbound TLS
            local _cfg_lines="" _n
            while IFS= read -r _n; do
                [[ -z "$_n" ]] && continue
                local -A _cp=()
                if load_profile "$_n" _cp 2>/dev/null; then
                    local _olp="${_cp[OBFS_LOCAL_PORT]:-}"
                    if [[ -n "$_olp" ]] && [[ "$_olp" != "0" ]]; then
                        local _h="${_cp[SSH_HOST]:-localhost}"
                        local _pub
                        _pub=$(hostname -I 2>/dev/null | awk '{print $1}') || true
                        [[ -n "$_pub" ]] && _h="$_pub"
                        local _st="STOPPED"
                        is_tunnel_running "$_n" 2>/dev/null && _st="ALIVE"
                        _cfg_lines="${_cfg_lines}$(printf '┌── %s [%s]\n│ Server: %s\n│ Port: %s\n│ SOCKS5: 127.0.0.1:%s\n│ PSK: %s\n└──\n\n' \
                            "$_n" "$_st" "$_h" "$_olp" "${_cp[LOCAL_PORT]:-1080}" "${_cp[OBFS_PSK]:-N/A}")"
                    fi
                fi
            done < <(list_profiles 2>/dev/null)
            if [[ -z "$_cfg_lines" ]]; then
                _resp="No profiles with inbound TLS configured."
            else
                _resp="$(printf '🔐 Client Configs\n\n%s' "$_cfg_lines")"
            fi
            ;;
        /tf_uptime|/tf_uptime@*)
            local _up
            _up=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "unknown")
            _resp="$(printf '⏱ Server Uptime\n\n%s\nTime: %s' "$_up" "$(date '+%Y-%m-%d %H:%M:%S')")"
            ;;
        /tf_report|/tf_report@*)
            local _r=0 _s=0 _t=0 _n _tlist=""
            while IFS= read -r _n; do
                [[ -z "$_n" ]] && continue
                (( ++_t ))
                if is_tunnel_running "$_n" 2>/dev/null; then
                    (( ++_r ))
                    _tlist="${_tlist}  ✅ ${_n}\n"
                else
                    (( ++_s ))
                    _tlist="${_tlist}  ⛔ ${_n}\n"
                fi
            done < <(list_profiles 2>/dev/null)
            local _ip
            _ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
            local _up
            _up=$(uptime -p 2>/dev/null || echo "N/A")
            _resp="$(printf '📊 Full Status Report\n\n🖥 %s (%s)\n⏱ %s\n\n📡 Tunnels: %d running / %d stopped\n%b\n🕐 %s' \
                "$(hostname 2>/dev/null || echo unknown)" "${_ip:-unknown}" "$_up" "$_r" "$_s" "$_tlist" "$(date '+%Y-%m-%d %H:%M:%S')")"
            ;;
        /start|/start@*)
            _resp="$(printf '🤖 TunnelForge Bot Active\n\nSend /tf_help for available commands.')"
            ;;
        *)
            # Unknown command — ignore
            return 0
            ;;
    esac

    if [[ -n "$_resp" ]]; then
        # Send response via _telegram_send (uses proxy automatically)
        if _telegram_send "$_resp"; then
            log_info "TG bot: replied to '${_cmd}'"
        else
            log_warn "TG bot: failed to send reply for '${_cmd}'"
        fi
    fi
    return 0
}

# Poll for and process Telegram bot commands (one-shot)
_tg_process_commands() {
    if ! _telegram_enabled; then return 0; fi

    local _token _chat_id
    _token=$(config_get TELEGRAM_BOT_TOKEN "")
    _chat_id=$(config_get TELEGRAM_CHAT_ID "")
    [[ -n "$_token" ]] && [[ -n "$_chat_id" ]] || return 0

    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    if [[ ${#_TG_PROXY_ARGS[@]} -eq 0 ]]; then
        log_debug "TG poll: no SOCKS5 proxy, trying direct"
    fi

    local _offset
    _offset=$(_tg_get_offset) || true

    local _curl_cfg _url_str
    _curl_cfg=$(mktemp "${TMP_DIR}/tg_poll.XXXXXX") || return 0
    chmod 600 "$_curl_cfg" 2>/dev/null || true
    if [[ "$_offset" -gt 0 ]] 2>/dev/null; then
        _url_str=$(printf '%s/bot%s/getUpdates?offset=%s&timeout=0' "$_TG_API" "$_token" "$_offset")
    else
        _url_str=$(printf '%s/bot%s/getUpdates?timeout=0' "$_TG_API" "$_token")
    fi
    printf 'url = "%s"\n' "$_url_str" > "$_curl_cfg"
    local response
    response=$(curl -s --max-time 20 "${_TG_PROXY_ARGS[@]}" --max-filesize 1048576 -K "$_curl_cfg" 2>/dev/null) || true
    rm -f "$_curl_cfg" 2>/dev/null || true
    if [[ -z "$response" ]]; then
        log_debug "TG poll: empty response from getUpdates"
        return 0
    fi
    if ! printf '%s' "$response" | grep -qF '"ok":true'; then
        log_debug "TG poll: API error: ${response:0:200}"
        return 0
    fi

    # Parse updates with python3 (fast, reliable JSON parsing)
    if ! command -v python3 &>/dev/null; then
        log_debug "TG poll: python3 not found"
        return 0
    fi

    # Validate chat_id is numeric to prevent injection
    if ! [[ "$_chat_id" =~ ^[0-9]+$ ]]; then
        log_warn "TG poll: invalid chat_id, skipping"
        return 0
    fi

    local _updates
    _updates=$(TF_CHAT_ID="$_chat_id" python3 -c "
import json,sys,os
try:
    cid=os.environ.get('TF_CHAT_ID','')
    d=json.loads(sys.stdin.read())
    for u in d.get('result',[]):
        uid=u.get('update_id',0)
        msg=u.get('message',{})
        text=msg.get('text','')
        chat_id=msg.get('chat',{}).get('id',0)
        if text.startswith('/') and str(chat_id)==cid:
            cmd=text.split()[0].lower()
            print(str(uid)+'|'+cmd)
        else:
            print(str(uid)+'|')
except: pass
" <<< "$response" 2>/dev/null) || true

    local _max_uid=0
    local _line _uid _cmd
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _uid="${_line%%|*}"
        _cmd="${_line#*|}"
        if [[ "$_uid" =~ ^[0-9]+$ ]] && (( _uid > _max_uid )); then
            _max_uid=$_uid
        fi
        # Process command if present
        if [[ -n "$_cmd" ]]; then
            log_info "TG bot: received command '${_cmd}'"
            _tg_cmd_response "$_cmd" "$_chat_id" "$_token" || true
        fi
    done <<< "$_updates"

    # Advance offset to skip processed updates
    if (( _max_uid > 0 )); then
        _tg_set_offset "$(( _max_uid + 1 ))"
        log_debug "TG poll: offset advanced to $(( _max_uid + 1 ))"
    fi
    return 0
}

# Non-blocking wrapper: runs _tg_process_commands in background
# Uses lock file to prevent concurrent polls
_tg_process_commands_bg() {
    local _lock="${TMP_DIR}/tg_cmd.lock"
    # Skip if previous poll still running
    if [[ -f "$_lock" ]]; then
        local _lpid
        _lpid=$(cat "$_lock" 2>/dev/null) || true
        if [[ -n "$_lpid" ]] && kill -0 "$_lpid" 2>/dev/null; then
            return 0
        fi
        rm -f "$_lock" 2>/dev/null || true
    fi
    (
        printf '%s' "$BASHPID" > "$_lock" 2>/dev/null || true
        _tg_process_commands 2>/dev/null || true
        rm -f "$_lock" 2>/dev/null || true
    ) &>/dev/null &
    disown 2>/dev/null || true
    return 0
}

# Send a file via Telegram bot API (sendDocument).
# Args: file_path [caption]
_telegram_send_file() {
    local _file="$1" _caption="${2:-}"
    local _token _chat_id
    _token=$(config_get TELEGRAM_BOT_TOKEN "")
    _chat_id=$(config_get TELEGRAM_CHAT_ID "")
    [[ -n "$_token" ]] && [[ -n "$_chat_id" ]] || return 1
    [[ -f "$_file" ]] || return 1

    local _tg_url="${_TG_API}/bot${_token}/sendDocument"
    local _tg_cfg
    _tg_cfg=$(mktemp "${TMP_DIR}/tg_cfg.XXXXXX") || return 1
    printf 'url = "%s"\n' "$_tg_url" > "$_tg_cfg" 2>/dev/null || { rm -f "$_tg_cfg" 2>/dev/null || true; return 1; }
    chmod 600 "$_tg_cfg" 2>/dev/null || true

    local -a _TG_PROXY_ARGS=()
    _tg_proxy_args || true

    local -a curl_args=(
        -s --max-time 30
        "${_TG_PROXY_ARGS[@]}"
        -X POST
        -F "chat_id=${_chat_id}"
        -F "document=@${_file}"
    )
    if [[ -n "$_caption" ]]; then
        curl_args+=(-F "caption=${_caption}")
    fi

    local _rc=0
    curl --config "$_tg_cfg" "${curl_args[@]}" >/dev/null 2>&1 || _rc=$?
    rm -f "$_tg_cfg" 2>/dev/null || true
    return "$_rc"
}

# Share client connection info + scripts via Telegram.
# Args: profile_name
telegram_share_client() {
    local _name="${1:-}"

    if ! _telegram_enabled; then
        log_error "Telegram is not configured. Run: tunnelforge telegram setup"
        return 1
    fi

    if [[ -z "$_name" ]]; then
        # Pick from running profiles with inbound TLS
        local _profiles="" _found=0
        while IFS= read -r _pn; do
            [[ -z "$_pn" ]] && continue
            local -A _tp=()
            if load_profile "$_pn" _tp 2>/dev/null; then
                if [[ -n "${_tp[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_tp[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
                    _profiles="${_profiles}${_pn}\n"
                    ((++_found))
                fi
            fi
        done < <(list_profiles)

        if (( _found == 0 )); then
            log_error "No profiles with inbound TLS found"
            return 1
        fi

        printf "\n${BOLD}Profiles with inbound TLS:${RESET}\n"
        local -a _parr=() _pi=0
        while IFS= read -r _pn; do
            [[ -z "$_pn" ]] && continue
            ((++_pi))
            _parr+=("$_pn")
            printf "  ${CYAN}%d${RESET}) %s\n" "$_pi" "$_pn"
        done < <(printf '%b' "$_profiles")

        printf "\n"
        local _sel=""
        read -rp "  Select profile [1-${_pi}]: " _sel </dev/tty || true
        if [[ -z "$_sel" ]] || ! [[ "$_sel" =~ ^[0-9]+$ ]] || (( _sel < 1 || _sel > _pi )); then
            log_error "Invalid selection"
            return 1
        fi
        _name="${_parr[$((_sel - 1))]}"
    fi

    local -A _sp=()
    load_profile "$_name" _sp || { log_error "Cannot load profile '$_name'"; return 1; }

    local _olport="${_sp[OBFS_LOCAL_PORT]:-}"
    local _psk="${_sp[OBFS_PSK]:-}"
    local _lport="${_sp[LOCAL_PORT]:-}"

    if [[ -z "$_olport" ]] || [[ "$_olport" == "0" ]]; then
        log_error "Profile '$_name' has no inbound TLS configured"
        return 1
    fi

    # Determine server IP
    local _host="${_sp[SSH_HOST]:-localhost}"
    local _pub_ip=""
    _pub_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2) || true
    if [[ -n "$_pub_ip" ]]; then _host="$_pub_ip"; fi

    log_info "Sharing client info for '${_name}' via Telegram..."

    # Determine running status
    local _status_txt="STOPPED"
    if is_tunnel_running "$_name" 2>/dev/null; then _status_txt="ALIVE"; fi

    # 1. Send connection info message (clean, formatted like the menu display)
    local _msg
    _msg=$(printf '🔐 TunnelForge Client Config

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📡 %s [%s]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Server:     %s
Port:       %s
SOCKS5:     127.0.0.1:%s
PSK Key:    %s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚡ Quick Start (Windows)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Install stunnel from stunnel.org
2. Save the .bat file below
3. Edit the SERVER, PORT, PSK values
4. Double-click to connect
5. Set browser proxy: 127.0.0.1:%s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🐧 Quick Start (Linux/Mac)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Install stunnel: apt install stunnel4
2. Save the .sh file below
3. chmod +x tunnelforge-connect.sh
4. ./tunnelforge-connect.sh
5. Set browser proxy: 127.0.0.1:%s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 Manual stunnel Config
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
stunnel.conf:
[tunnelforge]
client = yes
accept = 127.0.0.1:%s
connect = %s:%s
PSKsecrets = psk.txt
ciphers = PSK

psk.txt:
tunnelforge:%s

━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🌐 Browser Setup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Firefox:
  Settings → Proxy → Manual
  SOCKS Host: 127.0.0.1
  Port: %s
  SOCKS v5 ✓
  Proxy DNS ✓

Chrome:
  chrome --proxy-server="socks5://127.0.0.1:%s"' \
        "$_name" "$_status_txt" \
        "$_host" "$_olport" "$_lport" "$_psk" \
        "$_lport" \
        "$_lport" \
        "$_lport" "$_host" "$_olport" \
        "$_psk" \
        "$_lport" "$_lport")

    if _telegram_send "$_msg"; then
        log_success "Connection info sent"
    else
        log_error "Failed to send connection info"
        return 1
    fi

    # 2. Generate and send Linux script
    local _sh_file="${TMP_DIR}/tunnelforge-connect.sh"
    if _obfs_generate_client_script "$_name" _sp "$_sh_file" 2>/dev/null; then
        if _telegram_send_file "$_sh_file" "Linux/Mac client — chmod +x and run"; then
            log_success "Linux script sent"
        else
            log_warn "Failed to send Linux script"
        fi
    fi
    rm -f "$_sh_file" 2>/dev/null || true

    # 3. Send Windows bat file if it exists in the install dir
    local _bat_file=""
    for _bp in "${INSTALL_DIR}/tunnelforge-client.bat" \
               "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/tunnelforge-client.bat" \
               "/opt/tunnelforge/tunnelforge-client.bat"; do
        if [[ -f "$_bp" ]]; then _bat_file="$_bp"; break; fi
    done

    if [[ -n "$_bat_file" ]]; then
        if _telegram_send_file "$_bat_file" "Windows client — double-click to run"; then
            log_success "Windows script sent"
        else
            log_warn "Failed to send Windows script"
        fi
    else
        log_info "Windows .bat not found — place tunnelforge-client.bat in /opt/tunnelforge/"
    fi

    printf "\n${GREEN}Client setup shared via Telegram.${RESET}\n"
    printf "${DIM}Users in the chat can see the info and download the scripts.${RESET}\n\n"
    return 0
}

# ── Telegram interactive menu ──

_menu_telegram() {
    while true; do
        clear >/dev/tty 2>/dev/null || true
        printf "\n${BOLD_CYAN}═══ Telegram Notifications ═══${RESET}\n\n" >/dev/tty

        local _tg_status_icon="${RED}●${RESET}"
        if _telegram_enabled; then
            _tg_status_icon="${GREEN}●${RESET}"
        fi

        printf "  Status: %b %s\n\n" "$_tg_status_icon" \
            "$(if _telegram_enabled; then echo 'Connected'; else echo 'Not configured'; fi)" >/dev/tty

        printf "    ${CYAN}1${RESET}) Setup / reconfigure\n" >/dev/tty
        printf "    ${CYAN}2${RESET}) Send test message\n" >/dev/tty
        printf "    ${CYAN}3${RESET}) Toggle alerts      : ${BOLD}%s${RESET}\n" "$(config_get TELEGRAM_ALERTS true)" >/dev/tty
        printf "    ${CYAN}4${RESET}) Toggle status reports: ${BOLD}%s${RESET}\n" "$(config_get TELEGRAM_PERIODIC_STATUS false)" >/dev/tty
        printf "    ${CYAN}5${RESET}) Status interval    : ${BOLD}%s${RESET}s\n" "$(config_get TELEGRAM_STATUS_INTERVAL 3600)" >/dev/tty
        printf "    ${CYAN}6${RESET}) Show full status\n" >/dev/tty
        printf "    ${CYAN}7${RESET}) Share client setup (scripts + PSK)\n" >/dev/tty
        printf "    ${CYAN}8${RESET}) Disable Telegram\n" >/dev/tty
        printf "    ${YELLOW}0${RESET}) Back\n\n" >/dev/tty

        local _tg_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _tg_choice </dev/tty || true
        _drain_esc _tg_choice
        printf "\n" >/dev/tty

        case "$_tg_choice" in
            1) telegram_setup || true ;;
            2) telegram_test || true; _press_any_key ;;
            3)
                if [[ "$(config_get TELEGRAM_ALERTS true)" == "true" ]]; then
                    config_set "TELEGRAM_ALERTS" "false"
                    log_info "Telegram alerts disabled"
                else
                    config_set "TELEGRAM_ALERTS" "true"
                    log_info "Telegram alerts enabled"
                fi
                save_settings || true ;;
            4)
                if [[ "$(config_get TELEGRAM_PERIODIC_STATUS false)" == "true" ]]; then
                    config_set "TELEGRAM_PERIODIC_STATUS" "false"
                    log_info "Periodic status reports disabled"
                else
                    config_set "TELEGRAM_PERIODIC_STATUS" "true"
                    log_info "Periodic status reports enabled"
                fi
                save_settings || true ;;
            5)
                local _tg_int
                _read_tty "  Status interval (seconds)" _tg_int "$(config_get TELEGRAM_STATUS_INTERVAL 3600)"
                if [[ "$_tg_int" =~ ^[0-9]+$ ]] && (( _tg_int >= 60 )); then
                    config_set "TELEGRAM_STATUS_INTERVAL" "$_tg_int"
                    save_settings || true
                    log_info "Status interval set to ${_tg_int}s"
                else
                    log_error "Invalid interval (minimum 60 seconds)"
                fi
                _press_any_key ;;
            6) telegram_status || true; _press_any_key ;;
            7) telegram_share_client "" || true; _press_any_key ;;
            8)
                config_set "TELEGRAM_ENABLED" "false"
                save_settings || true
                log_info "Telegram notifications disabled" ;;
            0|q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── Log rotation ──

_rotate_dir_logs() {
    local dir="$1" max_size="$2" max_count="$3"
    local log_f
    while IFS= read -r log_f; do
        [[ -f "$log_f" ]] || continue
        local fsize
        fsize=$(stat -c %s "$log_f" 2>/dev/null || stat -f %z "$log_f" 2>/dev/null) || true
        : "${fsize:=0}"
        if (( fsize > max_size )); then
            local ri
            for (( ri=max_count; ri>=1; ri-- )); do
                local prev=$(( ri - 1 ))
                local src="${log_f}"
                if [[ $prev -gt 0 ]]; then src="${log_f}.${prev}"; fi
                if [[ -f "$src" ]]; then mv -f "$src" "${log_f}.${ri}" 2>/dev/null || true; fi
            done
            : > "$log_f" 2>/dev/null || true
            log_debug "Rotated log: $(basename "$log_f")"
        fi
    done < <(find "$dir" -maxdepth 1 -name "*.log" -type f 2>/dev/null || true)
    return 0
}

rotate_logs() {
    local max_size max_count
    max_size=$(config_get LOG_MAX_SIZE 10485760)
    max_count=$(config_get LOG_ROTATE_COUNT 5)
    _rotate_dir_logs "$LOG_DIR" "$max_size" "$max_count"
    _rotate_dir_logs "$RECONNECT_LOG_DIR" "$max_size" "$max_count"
    return 0
}

# ── Connection quality indicator ──
# Returns a quality rating based on latency to the SSH host

_get_ns_timestamp() {
    local _ts
    _ts=$(date +%s%N 2>/dev/null) || true
    if [[ "$_ts" =~ ^[0-9]+$ ]]; then printf '%s' "$_ts"; return 0; fi
    # macOS fallback: try perl for sub-second precision
    _ts=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000000000' 2>/dev/null) || true
    if [[ "$_ts" =~ ^[0-9]+$ ]]; then printf '%s' "$_ts"; return 0; fi
    # Last resort: second-level precision
    _ts=$(date +%s 2>/dev/null) || true
    if [[ "$_ts" =~ ^[0-9]+$ ]]; then printf '%s' "$(( _ts * 1000000000 ))"; return 0; fi
    printf '0'
}

_connection_quality() {
    local host="$1" port="${2:-22}"
    local start_ms end_ms

    # Validate host/port to prevent injection in bash -c /dev/tcp
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then printf 'unknown'; return 0; fi
    if ! [[ "$host" =~ ^[a-zA-Z0-9._:-]+$ ]]; then printf 'unknown'; return 0; fi

    # Quick TCP connect test with 2s timeout (kills hangs from iptables DROP)
    start_ms=$(_get_ns_timestamp)

    local _cq_ok=false
    if command -v timeout &>/dev/null; then
        if timeout 2 bash -c ": </dev/tcp/${host}/${port}" 2>/dev/null; then
            _cq_ok=true
        fi
    elif command -v nc &>/dev/null; then
        if nc -z -w2 "$host" "$port" 2>/dev/null; then _cq_ok=true; fi
    fi

    if [[ "$_cq_ok" == true ]]; then
        end_ms=$(_get_ns_timestamp)

        if (( start_ms > 0 && end_ms > 0 )); then
            local latency_ms=$(( (end_ms - start_ms) / 1000000 ))
            if (( latency_ms < 50 )); then
                printf "excellent"
            elif (( latency_ms < 150 )); then
                printf "good"
            elif (( latency_ms < 300 )); then
                printf "fair"
            else
                printf "poor"
            fi
            return 0
        fi
    fi
    printf "unknown"
    return 0
}

# Map quality to visual indicator
_quality_icon() {
    case "$1" in
        excellent) printf "${GREEN}▁▃▅▇${RESET}" ;;
        good)      printf "${GREEN}▁▃▅${RESET}${DIM}▇${RESET}" ;;
        fair)      printf "${YELLOW}▁▃${RESET}${DIM}▅▇${RESET}" ;;
        poor)      printf "${RED}▁${RESET}${DIM}▃▅▇${RESET}" ;;
        *)         printf "${DIM}▁▃▅▇${RESET}" ;;
    esac
}

# ============================================================================
# DISPLAY HELPERS
# ============================================================================

show_banner() {
    printf "${BOLD_CYAN}"
    cat <<'BANNER'

  ╔════════════════════════════════════════════════════════════════╗
  ║  ▀▀█▀▀ █  █ █▄ █ █▄ █ █▀▀ █   █▀▀ █▀█ █▀█ █▀▀ █▀▀              ║
  ║    █   █  █ █ ▀█ █ ▀█ █▀▀ █   █▀  █ █ █▀█ █ █ █▀▀              ║
  ║    █    ▀▀  █  █ █  █ ▀▀▀ ▀▀▀ █   ▀▀▀ █ █ ▀▀▀ ▀▀▀              ║
  ╚════════════════════════════════════════════════════════════════╝
BANNER
    printf "${RESET}"
    printf "${DIM}  SSH Tunnel Manager v%s${RESET}\n\n" "$VERSION"
}

show_help() {
    show_banner
    printf '%b\n' "${BOLD}USAGE:${RESET}
    tunnelforge [command] [options]

${BOLD}TUNNEL COMMANDS:${RESET}
    start <name>         Start a tunnel
    stop <name>          Stop a tunnel
    restart <name>       Restart a tunnel
    start-all            Start all autostart tunnels
    stop-all             Stop all running tunnels
    status               Show all tunnel statuses
    dashboard, dash      Live TUI dashboard
    logs [name]          Tail tunnel logs

${BOLD}PROFILE COMMANDS:${RESET}
    list, ls             List all profiles
    create, new          Create new tunnel (wizard)
    delete <name>        Delete a profile

${BOLD}SECURITY COMMANDS:${RESET}
    audit                Run security audit
    key-gen [type]       Generate SSH key (ed25519/rsa)
    key-deploy <name>    Deploy SSH key to profile's server
    fingerprint <host>   Check SSH host fingerprint

${BOLD}TELEGRAM COMMANDS:${RESET}
    telegram setup       Configure Telegram bot
    telegram test        Send test message
    telegram status      Show notification config
    telegram send <msg>  Send a message via Telegram
    telegram report      Send status report now

${BOLD}SERVICE COMMANDS:${RESET}
    service <name>           Generate systemd service file
    service <name> enable    Enable + start service
    service <name> disable   Disable + stop service
    service <name> status    Show service status
    service <name> remove    Remove service file

${BOLD}SYSTEM COMMANDS:${RESET}
    menu                 Interactive TUI menu
    install              Install TunnelForge
    health               Run health check
    server-setup         Harden server for receiving tunnels
    obfs-setup <name>    Set up TLS obfuscation (stunnel) on server
    client-config <name> Show client connection config (TLS+PSK)
    client-script <name> Generate client scripts (Linux + Windows)
    backup               Backup profiles + keys
    restore [file]       Restore from backup
    uninstall            Remove everything
    version              Show version
    help                 Show this help

${BOLD}EXAMPLES:${RESET}
    tunnelforge create                   # Interactive wizard
    tunnelforge start office-proxy       # Start a tunnel
    tunnelforge dashboard                # Live monitoring
    tunnelforge service myproxy enable   # Autostart on boot
    tunnelforge backup                   # Backup everything
"
}

show_version() { printf "%s v%s\n" "$APP_NAME" "$VERSION"; }

show_status() {
    local profiles name
    profiles=$(list_profiles)

    if [[ -z "$profiles" ]]; then
        log_info "No profiles configured. Run 'tunnelforge create' to get started."
        return 0
    fi

    local _st_width
    _st_width=$(get_term_width)
    if (( _st_width > 120 )); then _st_width=120; fi
    if (( _st_width < 82 )); then _st_width=82; fi
    local _name_col=$(( _st_width - 62 ))
    if (( _name_col < 18 )); then _name_col=18; fi
    printf "\n${BOLD}%-${_name_col}s %-8s %-10s %-22s %-12s %-10s${RESET}\n" \
        "NAME" "TYPE" "STATUS" "LOCAL" "TRAFFIC" "UPTIME"
    print_line "─" "$_st_width"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue

        unset _st 2>/dev/null || true
        local -A _st=()
        load_profile "$name" _st 2>/dev/null || continue

        local ttype="${_st[TUNNEL_TYPE]:-?}"
        local addr="${_st[LOCAL_BIND_ADDR]:-}:${_st[LOCAL_PORT]:-}"

        if is_tunnel_running "$name"; then
            local up_s up_str traffic rchar wchar total traf_str
            up_s=$(get_tunnel_uptime "$name" 2>/dev/null || true)
            : "${up_s:=0}"
            up_str=$(format_duration "$up_s")
            traffic=$(get_tunnel_traffic "$name" 2>/dev/null || true)
            : "${traffic:=0 0}"
            read -r rchar wchar <<< "$traffic"
            [[ "$rchar" =~ ^[0-9]+$ ]] || rchar=0
            [[ "$wchar" =~ ^[0-9]+$ ]] || wchar=0
            total=$(( rchar + wchar ))
            traf_str=$(format_bytes "$total")

            local _nd=$(( _name_col - 2 ))
            printf "  %-${_nd}s %-8s %s %-7s %-22s %-12s %-10s\n" \
                "$name" "${ttype^^}" "${GREEN}●${RESET}" "${GREEN}ALIVE${RESET}" \
                "$addr" "$traf_str" "$up_str"
        else
            local _nd=$(( _name_col - 2 ))
            printf "  %-${_nd}s %-8s %s %-7s ${DIM}%-22s %-12s %-10s${RESET}\n" \
                "$name" "${ttype^^}" "${DIM}■${RESET}" "${DIM}STOP${RESET}" \
                "$addr" "0 B" "-"
        fi

    done <<< "$profiles"
    printf "\n"
}

# ============================================================================
# SETUP WIZARD  (Phase 2)
# ============================================================================

# Read a line from the terminal (works even when stdin is piped)
_read_tty() {
    local _prompt="$1" _var_name="$2" _default="${3:-}"
    local _input

    if [[ -n "$_default" ]]; then
        printf "${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$_prompt" "$_default" >/dev/tty
    else
        printf "${BOLD}%s${RESET}: " "$_prompt" >/dev/tty
    fi

    if ! read -r _input </dev/tty; then
        # EOF on /dev/tty — use default if available, otherwise signal EOF
        if [[ -n "$_default" ]]; then
            _input="$_default"
        else
            printf -v "$_var_name" '%s' ""
            return 1
        fi
    fi
    _input="${_input:-$_default}"
    printf -v "$_var_name" '%s' "$_input"
}

_read_secret_tty() {
    local _prompt="$1" _var_name="$2" _default="${3:-}"
    local _input

    if [[ -n "$_default" ]]; then
        printf "${BOLD}%s${RESET} ${DIM}[****]${RESET}: " "$_prompt" >/dev/tty
    else
        printf "${BOLD}%s${RESET}: " "$_prompt" >/dev/tty
    fi

    if ! read -rs _input </dev/tty; then
        if [[ -n "$_default" ]]; then
            _input="$_default"
        else
            printf "\n" >/dev/tty
            printf -v "$_var_name" '%s' ""
            return 1
        fi
    fi
    printf "\n" >/dev/tty
    _input="${_input:-$_default}"
    printf -v "$_var_name" '%s' "$_input"
}

# Read a yes/no answer; returns 0=yes, 1=no
_read_yn() {
    local _prompt="$1" _default="${2:-n}"
    local _input _hint="y/N"
    if [[ "$_default" == "y" ]]; then _hint="Y/n"; fi

    printf "${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$_prompt" "$_hint" >/dev/tty
    read -r _input </dev/tty || true
    _input="${_input:-$_default}"
    [[ "${_input,,}" == "y" || "${_input,,}" == "yes" ]]
}

# Display a numbered selection menu and return 0-based index
_select_option() {
    if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
        log_error "Interactive terminal required"
        return 1
    fi
    local _title="$1"
    shift
    local _options=("$@")
    local _count=${#_options[@]}

    printf "\n${BOLD}%s${RESET}\n" "$_title" >/dev/tty
    local _sep=""
    for (( _si=0; _si<40; _si++ )); do _sep+="─"; done
    printf "  %s\n" "$_sep" >/dev/tty

    local _oi
    for (( _oi=0; _oi<_count; _oi++ )); do
        printf "  ${CYAN}%d${RESET}) %s\n" "$((_oi+1))" "${_options[$_oi]}" >/dev/tty
    done
    printf "\n" >/dev/tty

    local _choice
    while true; do
        printf "${BOLD}Select [1-%d]${RESET} ${DIM}(q=quit, b=back)${RESET}: " "$_count" >/dev/tty
        if ! read -r _choice </dev/tty; then return 1; fi
        if [[ "${_choice,,}" == "q" || "${_choice,,}" == "quit" ]]; then
            _WIZ_NAV="quit"; echo "q"; return 1
        fi
        if [[ "${_choice,,}" == "b" || "${_choice,,}" == "back" ]]; then
            _WIZ_NAV="back"; echo "b"; return 1
        fi
        if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= _count )); then
            _WIZ_NAV=""
            echo "$((_choice - 1))"
            return 0
        fi
        printf "  ${RED}Invalid choice. Try again.${RESET}\n" >/dev/tty
    done
}

# Wait for keypress
_press_any_key() {
    printf "\n${DIM}Press any key to continue...${RESET}" >/dev/tty 2>/dev/null || true
    read -rsn1 _ </dev/tty || true
    _drain_esc _
    printf "\n" >/dev/tty 2>/dev/null || true
}

# Test SSH connectivity
test_ssh_connection() {
    local host="$1" port="$2" user="$3" key="${4:-}" password="${5:-}"

    printf "\n${CYAN}Testing SSH connection to %s@%s:%s...${RESET}\n" \
        "$user" "$host" "$port" >/dev/tty

    local -a ssh_args=(-o "ConnectTimeout=10" -p "$port")
    # Use accept-new for test: accepts host key on first connect (saves to known_hosts),
    # rejects if key changes later. Subsequent tunnel connections use strict=yes.
    ssh_args+=(-o "StrictHostKeyChecking=accept-new")
    if [[ -n "$key" ]] && [[ -f "$key" ]]; then ssh_args+=(-i "$key"); fi

    local -a cmd_prefix=()
    if [[ -n "$password" ]]; then
        if ! command -v sshpass &>/dev/null; then
            printf "  ${DIM}Installing sshpass...${RESET}\n" >/dev/tty
            if [[ -n "${PKG_UPDATE:-}" ]]; then ${PKG_UPDATE} &>/dev/null || true; fi
            install_package "sshpass" 2>/dev/null || true
        fi
        if command -v sshpass &>/dev/null; then
            cmd_prefix=(env "SSHPASS=${password}" sshpass -e)
            ssh_args+=(-o "BatchMode=no")
        else
            # No sshpass — let SSH prompt interactively on /dev/tty
            ssh_args+=(-o "BatchMode=no")
            printf "  ${DIM}(sshpass unavailable — SSH will prompt for password)${RESET}\n" >/dev/tty
        fi
    else
        ssh_args+=(-o "BatchMode=yes")
    fi

    local _test_output _test_rc=0
    _test_output=$("${cmd_prefix[@]}" ssh "${ssh_args[@]}" "${user}@${host}" "echo ok" 2>&1 </dev/tty) || _test_rc=$?

    if [[ "$_test_rc" -eq 0 ]] && [[ "$_test_output" == *"ok"* ]]; then
        printf "  ${GREEN}● Authentication successful${RESET}\n" >/dev/tty
        return 0
    else
        printf "  ${RED}✗ Authentication failed${RESET}\n" >/dev/tty
        if [[ -n "$_test_output" ]]; then
            printf "  ${DIM}%s${RESET}\n" "$_test_output" >/dev/tty
        fi
        return 1
    fi
}

# ── Wizard navigation helpers ──

declare -g _WIZ_NAV=""

_wiz_read() {
    _WIZ_NAV=""
    local _wr_prompt="$1" _wr_var="$2" _wr_default="${3:-}"
    local _wr_input
    if [[ -n "$_wr_default" ]]; then
        printf "${BOLD}%s${RESET} ${DIM}[%s]${RESET} ${DIM}(q/b)${RESET}: " "$_wr_prompt" "$_wr_default" >/dev/tty
    else
        printf "${BOLD}%s${RESET} ${DIM}(q/b)${RESET}: " "$_wr_prompt" >/dev/tty
    fi
    if ! read -r _wr_input </dev/tty; then
        if [[ -n "$_wr_default" ]]; then _wr_input="$_wr_default"
        else printf -v "$_wr_var" '%s' ""; return 0; fi
    fi
    _wr_input="${_wr_input:-$_wr_default}"
    printf -v "$_wr_var" '%s' "$_wr_input"
    if [[ "${_wr_input,,}" == "q" || "${_wr_input,,}" == "quit" ]]; then
        _WIZ_NAV="quit"; printf -v "$_wr_var" '%s' ""
    elif [[ "${_wr_input,,}" == "b" || "${_wr_input,,}" == "back" ]]; then
        _WIZ_NAV="back"; printf -v "$_wr_var" '%s' ""
    fi
}

_wiz_yn() {
    _WIZ_NAV=""
    local _prompt="$1" _default="${2:-n}"
    local _input _hint="y/N"
    if [[ "$_default" == "y" ]]; then _hint="Y/n"; fi
    printf "${BOLD}%s${RESET} ${DIM}[%s] (q/b)${RESET}: " "$_prompt" "$_hint" >/dev/tty
    read -r _input </dev/tty || true
    if [[ "${_input,,}" == "q" || "${_input,,}" == "quit" ]]; then
        _WIZ_NAV="quit"; return 1
    fi
    if [[ "${_input,,}" == "b" || "${_input,,}" == "back" ]]; then
        _WIZ_NAV="back"; return 1
    fi
    _input="${_input:-$_default}"
    [[ "${_input,,}" == "y" || "${_input,,}" == "yes" ]]
}

_wiz_quit() { [[ "$_WIZ_NAV" == "quit" ]]; }
_wiz_back() { [[ "$_WIZ_NAV" == "back" ]]; }
_wiz_nav()  { [[ "$_WIZ_NAV" == "quit" || "$_WIZ_NAV" == "back" ]]; }

_wiz_header() {
    printf "\n${BOLD_CYAN}── %s ──${RESET}  ${DIM}(q=quit, b=back)${RESET}\n\n" "$1" >/dev/tty
}

# ── Per-type sub-wizards ──

wizard_socks5() {
    local -n _ws_prof="$1"
    local _ss=1 bind="" port=""

    while (( _ss >= 1 )); do
    case $_ss in
    1)
        printf "\n${BOLD_MAGENTA}── SOCKS5 Proxy Configuration ──${RESET}  ${DIM}(q=quit, b=back)${RESET}\n\n" >/dev/tty
        cat >/dev/tty <<'DIAGRAM'
    ┌──────────┐          ┌──────────┐          ┌──────────┐
    │  Client  │──SOCKS5──│ SSH Host │──────────│ Internet │
    │ (local)  │  :1080   │ (proxy)  │          │          │
    └──────────┘          └──────────┘          └──────────┘
      ssh -D 1080 user@host
DIAGRAM
        printf "\n" >/dev/tty
        printf "${DIM}  Your apps connect to a local SOCKS5 port and${RESET}\n" >/dev/tty
        printf "${DIM}  all traffic routes through the SSH server.${RESET}\n" >/dev/tty
        printf "${DIM}  After setup: set your browser proxy to this${RESET}\n" >/dev/tty
        printf "${DIM}  address and port.${RESET}\n\n" >/dev/tty
        printf "${DIM}  Tip: 127.0.0.1 = local only${RESET}\n" >/dev/tty
        printf "${DIM}        0.0.0.0 = allow LAN devices${RESET}\n" >/dev/tty
        _wiz_read "Local bind address" bind "${_ws_prof[LOCAL_BIND_ADDR]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then return 2; fi
        if ! { validate_ip "$bind" || validate_ip6 "$bind" || [[ "$bind" == "localhost" ]] || [[ "$bind" == "*" ]]; }; then
            printf "  ${RED}Invalid bind address: ${bind}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_ss )) ;;
    2)
        printf "${DIM}  Tip: Common ports: 1080 (standard), 9050 (Tor-style). Avoid ports < 1024${RESET}\n" >/dev/tty
        _wiz_read "Local SOCKS5 port" port "${_ws_prof[LOCAL_PORT]:-1080}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_ss )); continue; fi
        if ! validate_port "$port"; then
            printf "  ${RED}Invalid port: ${port}${RESET}\n" >/dev/tty; continue
        fi
        if ! _check_port_conflict "$port"; then continue; fi
        _ws_prof[LOCAL_BIND_ADDR]="$bind"
        _ws_prof[LOCAL_PORT]="$port"
        _ws_prof[REMOTE_HOST]=""
        _ws_prof[REMOTE_PORT]=""
        return 0 ;;
    esac
    done
}

wizard_local_forward() {
    local -n _wlf_prof="$1"
    local _ls=1 bind="" lport="" rhost="" rport=""

    while (( _ls >= 1 )); do
    case $_ls in
    1)
        printf "\n${BOLD_MAGENTA}── Local Port Forward Configuration ──${RESET}  ${DIM}(q=quit, b=back)${RESET}\n\n" >/dev/tty
        cat >/dev/tty <<'DIAGRAM'
    ┌──────────┐          ┌──────────┐          ┌──────────┐
    │  Client  │──Local───│ SSH Host │──────────│  Remote  │
    │  :8080   │  Fwd     │ (relay)  │          │  :8080   │
    └──────────┘          └──────────┘          └──────────┘
      ssh -L 8080:127.0.0.1:8080 user@host
DIAGRAM
        printf "\n" >/dev/tty
        printf "${DIM}  A port opens on THIS machine and connects${RESET}\n" >/dev/tty
        printf "${DIM}  through SSH to a service on the remote side.${RESET}\n" >/dev/tty
        printf "${DIM}  Example: VPS port 3306 (MySQL) → localhost:3306${RESET}\n\n" >/dev/tty
        printf "${DIM}  Tip: 127.0.0.1 = local only${RESET}\n" >/dev/tty
        printf "${DIM}        0.0.0.0 = allow LAN devices${RESET}\n" >/dev/tty
        _wiz_read "Local bind address" bind "${_wlf_prof[LOCAL_BIND_ADDR]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then return 2; fi
        if ! { validate_ip "$bind" || validate_ip6 "$bind" || [[ "$bind" == "localhost" ]] || [[ "$bind" == "*" ]]; }; then
            printf "  ${RED}Invalid bind address: ${bind}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_ls )) ;;
    2)
        printf "${DIM}  Tip: The port you will connect to on THIS machine (e.g. 8080, 3306, 5432)${RESET}\n" >/dev/tty
        _wiz_read "Local port" lport "${_wlf_prof[LOCAL_PORT]:-8080}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_ls )); continue; fi
        if ! validate_port "$lport"; then
            printf "  ${RED}Invalid port: ${lport}${RESET}\n" >/dev/tty; continue
        fi
        if ! _check_port_conflict "$lport"; then continue; fi
        (( ++_ls )) ;;
    3)
        printf "${DIM}  Tip: 127.0.0.1 = service on the SSH server${RESET}\n" >/dev/tty
        printf "${DIM}  Or use another IP for a different machine.${RESET}\n" >/dev/tty
        _wiz_read "Remote target host" rhost "${_wlf_prof[REMOTE_HOST]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_ls )); continue; fi
        (( ++_ls )) ;;
    4)
        printf "${DIM}  Tip: The port of the service on the remote side (e.g. 8080, 3306, 443)${RESET}\n" >/dev/tty
        _wiz_read "Remote target port" rport "${_wlf_prof[REMOTE_PORT]:-8080}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_ls )); continue; fi
        if ! validate_port "$rport"; then
            printf "  ${RED}Invalid port: ${rport}${RESET}\n" >/dev/tty; continue
        fi
        _wlf_prof[LOCAL_BIND_ADDR]="$bind"
        _wlf_prof[LOCAL_PORT]="$lport"
        _wlf_prof[REMOTE_HOST]="$rhost"
        _wlf_prof[REMOTE_PORT]="$rport"
        return 0 ;;
    esac
    done
}

wizard_remote_forward() {
    local -n _wrf_prof="$1"
    local _rs=1 bind="" rport="" lhost="" lport=""

    while (( _rs >= 1 )); do
    case $_rs in
    1)
        printf "\n${BOLD_MAGENTA}── Remote (Reverse) Forward Configuration ──${RESET}  ${DIM}(q=quit, b=back)${RESET}\n\n" >/dev/tty
        cat >/dev/tty <<'DIAGRAM'
    ┌──────────────┐          ┌──────────────┐          ┌──────────┐
    │ THIS machine │──Reverse─│  SSH Server  │──Listen──│  Users   │
    │   :3000      │  Fwd     │    :9090     │          │          │
    └──────────────┘          └──────────────┘          └──────────┘
      ssh -R 9090:127.0.0.1:3000 user@host
DIAGRAM
        printf "\n" >/dev/tty
        printf "${DIM}  A port opens on the SSH SERVER and connects${RESET}\n" >/dev/tty
        printf "${DIM}  back to a service on THIS machine.${RESET}\n" >/dev/tty
        printf "${DIM}  Example: local :3000 → reachable at VPS:9090${RESET}\n\n" >/dev/tty
        printf "${DIM}  Tip: 127.0.0.1 = SSH server only${RESET}\n" >/dev/tty
        printf "${DIM}        0.0.0.0 = public (needs GatewayPorts=yes)${RESET}\n" >/dev/tty
        _wiz_read "Remote bind address (on SSH server)" bind "${_wrf_prof[LOCAL_BIND_ADDR]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then return 2; fi
        if ! { validate_ip "$bind" || validate_ip6 "$bind" || [[ "$bind" == "localhost" ]] || [[ "$bind" == "*" ]]; }; then
            printf "  ${RED}Invalid bind address: ${bind}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_rs )) ;;
    2)
        printf "${DIM}  Tip: Port to open on the SSH server.${RESET}\n" >/dev/tty
        printf "${DIM}  Example: 9090, 8080, 443${RESET}\n" >/dev/tty
        _wiz_read "Remote listen port (on SSH server)" rport "${_wrf_prof[REMOTE_PORT]:-9090}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_rs )); continue; fi
        if ! validate_port "$rport"; then
            printf "  ${RED}Invalid port: ${rport}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_rs )) ;;
    3)
        printf "${DIM}  Tip: 127.0.0.1 = this machine, or another${RESET}\n" >/dev/tty
        printf "${DIM}  IP for a LAN device.${RESET}\n" >/dev/tty
        _wiz_read "Local service host" lhost "${_wrf_prof[REMOTE_HOST]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_rs )); continue; fi
        (( ++_rs )) ;;
    4)
        printf "${DIM}  Tip: What port is your local service running on? (e.g. 3000, 8080, 22)${RESET}\n" >/dev/tty
        _wiz_read "Local service port" lport "${_wrf_prof[LOCAL_PORT]:-3000}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_rs )); continue; fi
        if ! validate_port "$lport"; then
            printf "  ${RED}Invalid port: ${lport}${RESET}\n" >/dev/tty; continue
        fi
        _wrf_prof[LOCAL_BIND_ADDR]="$bind"
        _wrf_prof[LOCAL_PORT]="$lport"
        _wrf_prof[REMOTE_HOST]="$lhost"
        _wrf_prof[REMOTE_PORT]="$rport"
        return 0 ;;
    esac
    done
}

wizard_jump_host() {
    local -n _wjh_prof="$1"
    local _js=1 jumps="" _jh_ttype="" bind="" port="" lport="" rhost="" rport=""

    while (( _js >= 1 )); do
    case $_js in
    1)
        printf "\n${BOLD_MAGENTA}── Jump Host (Multi-Hop) Configuration ──${RESET}  ${DIM}(q=quit, b=back)${RESET}\n\n" >/dev/tty
        cat >/dev/tty <<'DIAGRAM'
    ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
    │  Client  │─────│  Jump 1  │─────│  Jump 2  │─────│  Target  │
    │ (local)  │     │ (relay)  │     │ (relay)  │     │ (final)  │
    └──────────┘     └──────────┘     └──────────┘     └──────────┘
      ssh -J jump1,jump2 user@target -D 1080
DIAGRAM
        printf "\n" >/dev/tty
        printf "${DIM}  SSH hops through intermediate servers${RESET}\n" >/dev/tty
        printf "${DIM}  to reach the final target.${RESET}\n" >/dev/tty
        printf "${DIM}  Use when target is behind a firewall.${RESET}\n\n" >/dev/tty
        printf "${DIM}  Tip: Comma-separated, in hop order.${RESET}\n" >/dev/tty
        printf "${DIM}  Format: user@host:port or just host${RESET}\n" >/dev/tty
        printf "${DIM}  e.g. admin@bastion:22,10.0.0.5${RESET}\n\n" >/dev/tty
        _wiz_read "Jump hosts (comma-separated)" jumps "${_wjh_prof[JUMP_HOSTS]:-}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then return 2; fi
        if [[ -z "$jumps" ]]; then
            printf "  ${RED}At least one jump host is required${RESET}\n" >/dev/tty; continue
        fi
        (( ++_js )) ;;
    2)
        # Select tunnel type at destination
        printf "\n${BOLD}Choose tunnel type at destination:${RESET}\n" >/dev/tty
        printf "${DIM}  SOCKS5 = route all traffic (VPN-like)${RESET}\n" >/dev/tty
        printf "${DIM}  Local Forward = access a specific port${RESET}\n" >/dev/tty
        local _jh_types=("SOCKS5 Proxy" "Local Port Forward")
        local _jh_choice
        _jh_choice=$(_select_option "Tunnel type at destination" "${_jh_types[@]}") || true
        # _select_option echoes "q"/"b" for nav (since _WIZ_NAV is lost in subshell)
        if [[ "$_jh_choice" == "q" ]]; then _WIZ_NAV="quit"; return 1; fi
        if [[ "$_jh_choice" == "b" ]]; then (( --_js )); continue; fi
        case "$_jh_choice" in
            0) _jh_ttype="socks5" ;;
            1) _jh_ttype="local" ;;
            *) continue ;;
        esac
        (( ++_js )) ;;
    3)
        printf "${DIM}  Tip: 127.0.0.1 = local only${RESET}\n" >/dev/tty
        printf "${DIM}        0.0.0.0 = allow LAN devices${RESET}\n" >/dev/tty
        if [[ "$_jh_ttype" == "socks5" ]]; then
            _wiz_read "Local SOCKS5 bind address" bind "${_wjh_prof[LOCAL_BIND_ADDR]:-127.0.0.1}"
        else
            _wiz_read "Local bind address" bind "${_wjh_prof[LOCAL_BIND_ADDR]:-127.0.0.1}"
        fi
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_js )); continue; fi
        if ! { validate_ip "$bind" || validate_ip6 "$bind" || [[ "$bind" == "localhost" ]] || [[ "$bind" == "*" ]]; }; then
            printf "  ${RED}Invalid bind address: ${bind}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_js )) ;;
    4)
        if [[ "$_jh_ttype" == "socks5" ]]; then
            printf "${DIM}  Tip: Common ports: 1080 (standard), 9050 (Tor-style). Avoid ports < 1024${RESET}\n" >/dev/tty
            _wiz_read "Local SOCKS5 port" port "${_wjh_prof[LOCAL_PORT]:-1080}"
            if _wiz_quit; then return 1; fi
            if _wiz_back; then (( --_js )); continue; fi
            if ! validate_port "$port"; then
                printf "  ${RED}Invalid port: ${port}${RESET}\n" >/dev/tty; continue
            fi
            if ! _check_port_conflict "$port"; then continue; fi
            # Save SOCKS5 config
            _wjh_prof[JUMP_HOSTS]="$jumps"
            _wjh_prof[TUNNEL_TYPE]="socks5"
            _wjh_prof[LOCAL_BIND_ADDR]="$bind"
            _wjh_prof[LOCAL_PORT]="$port"
            _wjh_prof[REMOTE_HOST]=""
            _wjh_prof[REMOTE_PORT]=""
            return 0
        else
            printf "${DIM}  Tip: The port you will connect to on THIS machine (e.g. 8080, 3306, 5432)${RESET}\n" >/dev/tty
            _wiz_read "Local port" lport "${_wjh_prof[LOCAL_PORT]:-8080}"
            if _wiz_quit; then return 1; fi
            if _wiz_back; then (( --_js )); continue; fi
            if ! validate_port "$lport"; then
                printf "  ${RED}Invalid port: ${lport}${RESET}\n" >/dev/tty; continue
            fi
            if ! _check_port_conflict "$lport"; then continue; fi
            (( ++_js ))
        fi ;;
    5)
        printf "${DIM}  Tip: The host the final SSH server connects to (127.0.0.1 = the target itself)${RESET}\n" >/dev/tty
        _wiz_read "Remote target host" rhost "${_wjh_prof[REMOTE_HOST]:-127.0.0.1}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_js )); continue; fi
        (( ++_js )) ;;
    6)
        printf "${DIM}  Tip: The port of the service on the remote side (e.g. 8080, 3306, 443)${RESET}\n" >/dev/tty
        _wiz_read "Remote target port" rport "${_wjh_prof[REMOTE_PORT]:-8080}"
        if _wiz_quit; then return 1; fi
        if _wiz_back; then (( --_js )); continue; fi
        if ! validate_port "$rport"; then
            printf "  ${RED}Invalid port: ${rport}${RESET}\n" >/dev/tty; continue
        fi
        # Save Local Forward config
        _wjh_prof[JUMP_HOSTS]="$jumps"
        _wjh_prof[TUNNEL_TYPE]="local"
        _wjh_prof[LOCAL_BIND_ADDR]="$bind"
        _wjh_prof[LOCAL_PORT]="$lport"
        _wjh_prof[REMOTE_HOST]="$rhost"
        _wjh_prof[REMOTE_PORT]="$rport"
        return 0 ;;
    esac
    done
}

# ── Main wizard flow ──

wizard_create_profile() {
    if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
        log_error "Interactive terminal required for wizard"
        return 1
    fi

    _WIZ_NAV=""
    local _step=1
    local name="" ssh_host="" ssh_port="" ssh_user="" ssh_password="" identity_key=""
    local tunnel_type="" type_choice="" desc=""
    local -A _new_profile=()

    while (( _step >= 1 )); do
    case $_step in

    1) # ── Profile name ──
        show_banner >/dev/tty
        _wiz_header "New Tunnel Profile"
        printf "${DIM}  A profile saves all settings for one tunnel connection.${RESET}\n" >/dev/tty
        printf "${DIM}  Tip: Use a short descriptive name (e.g. 'work-vpn', 'db-tunnel', 'home-proxy')${RESET}\n" >/dev/tty
        _wiz_read "Profile name" name ""
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then log_info "Already at first step"; continue; fi
        if [[ -z "$name" ]]; then
            printf "  ${RED}Name cannot be empty${RESET}\n" >/dev/tty; continue
        fi
        if ! validate_profile_name "$name"; then
            printf "  ${RED}Invalid name. Use letters, numbers, hyphens, underscores (max 64 chars)${RESET}\n" >/dev/tty; continue
        fi
        if [[ -f "$(_profile_path "$name")" ]]; then
            printf "  ${RED}Profile '%s' already exists${RESET}\n" "$name" >/dev/tty; continue
        fi
        (( ++_step )) ;;

    2) # ── Tunnel type selection ──
        _wiz_header "Choose Tunnel Type"
        printf "${DIM}  What type of tunnel do you need?${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}SOCKS5 Proxy${RESET}    ${DIM}Route all traffic through${RESET}\n" >/dev/tty
        printf "  ${DIM}                the remote server (VPN-like)${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}Local Forward${RESET}   ${DIM}Access a remote service${RESET}\n" >/dev/tty
        printf "  ${DIM}                on your local machine${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}Remote Forward${RESET}  ${DIM}Expose a local service${RESET}\n" >/dev/tty
        printf "  ${DIM}                to the remote server${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}Jump Host${RESET}       ${DIM}Connect through relay${RESET}\n" >/dev/tty
        printf "  ${DIM}                servers to the target${RESET}\n\n" >/dev/tty
        local _wz_types=("SOCKS5 Proxy (-D)" "Local Port Forward (-L)" "Remote/Reverse Forward (-R)" "Jump Host / Multi-hop (-J)")
        type_choice=$(_select_option "Select tunnel type" "${_wz_types[@]}") || true
        # _select_option echoes "q"/"b" for nav (since _WIZ_NAV is lost in subshell)
        if [[ "$type_choice" == "q" ]]; then log_info "Wizard cancelled"; return 0; fi
        if [[ "$type_choice" == "b" ]]; then (( --_step )); continue; fi
        case "$type_choice" in
            0) tunnel_type="socks5" ;;
            1) tunnel_type="local" ;;
            2) tunnel_type="remote" ;;
            3) tunnel_type="jump" ;;
            *) continue ;;
        esac
        (( ++_step )) ;;

    3) # ── SSH host ──
        _wiz_header "SSH Connection Details"
        printf "${DIM}  Enter the details of the SSH server you want to connect to.${RESET}\n\n" >/dev/tty
        case "$tunnel_type" in
            socks5)  printf "${DIM}  Tip: This server will proxy your traffic${RESET}\n" >/dev/tty ;;
            local)   printf "${DIM}  Tip: Server with the service you want to access${RESET}\n" >/dev/tty ;;
            remote)  printf "${DIM}  Tip: Server where your local service will be exposed${RESET}\n" >/dev/tty ;;
            jump)    printf "${DIM}  Tip: FINAL target server (jump hosts configured next)${RESET}\n" >/dev/tty ;;
        esac
        _wiz_read "SSH host (IP or hostname)" ssh_host "${ssh_host:-}"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then (( --_step )); continue; fi
        if [[ -z "$ssh_host" ]]; then
            printf "  ${RED}SSH host is required${RESET}\n" >/dev/tty; continue
        fi
        if ! validate_hostname "$ssh_host"; then
            printf "  ${RED}Invalid hostname: ${ssh_host}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_step )) ;;

    4) # ── SSH port ──
        printf "${DIM}  Tip: Default SSH port is 22. Change only if your server uses a custom port${RESET}\n" >/dev/tty
        _wiz_read "SSH port" ssh_port "${ssh_port:-$(config_get SSH_DEFAULT_PORT 22)}"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then (( --_step )); continue; fi
        if ! validate_port "$ssh_port"; then
            printf "  ${RED}Invalid port: ${ssh_port}${RESET}\n" >/dev/tty; continue
        fi
        (( ++_step )) ;;

    5) # ── SSH user ──
        printf "${DIM}  Tip: The username to log in with (e.g. root, ubuntu, admin)${RESET}\n" >/dev/tty
        if [[ "$tunnel_type" == "jump" ]]; then
            printf "${DIM}  Note: This is the user on the FINAL target, not the jump host.${RESET}\n" >/dev/tty
        fi
        _wiz_read "SSH user" ssh_user "${ssh_user:-$(config_get SSH_DEFAULT_USER root)}"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then (( --_step )); continue; fi
        (( ++_step )) ;;

    6) # ── SSH password ──
        printf "${DIM}  Tip: Enter your SSH password, or press Enter to skip if using SSH keys.${RESET}\n" >/dev/tty
        printf "${DIM}  The password is stored securely and used for automatic login.${RESET}\n" >/dev/tty
        if [[ "$tunnel_type" == "jump" ]]; then
            printf "${DIM}  Note: This is for the FINAL target, not the jump host.${RESET}\n" >/dev/tty
        fi
        _read_secret_tty "SSH password (Enter to skip)" ssh_password "$ssh_password" || true
        # No q/b detection for passwords — password could literally be "q" or "b"
        (( ++_step )) ;;

    7) # ── Identity key ──
        printf "${DIM}  Tip: Path to your SSH private key file (e.g. ~/.ssh/id_rsa, ~/.ssh/id_ed25519)${RESET}\n" >/dev/tty
        printf "${DIM}  Press Enter to skip if you entered a password above.${RESET}\n" >/dev/tty
        if [[ "$tunnel_type" == "jump" ]]; then
            printf "${DIM}  Note: This key is for the FINAL target, not the jump host.${RESET}\n" >/dev/tty
        fi
        _wiz_read "Identity key path (optional)" identity_key "${identity_key:-$(config_get SSH_DEFAULT_KEY)}"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then (( --_step )); continue; fi
        if [[ -n "$identity_key" ]] && [[ ! -f "$identity_key" ]]; then
            log_warn "Key file not found: ${identity_key}"
            if ! _wiz_yn "Continue anyway?"; then
                if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
                if _wiz_back; then (( --_step )); continue; fi
                continue  # "no" → re-ask for key path
            fi
        fi
        (( ++_step )) ;;

    8) # ── Auth test ──
        _wiz_header "Testing Authentication"
        printf "${DIM}  Verifying SSH connection to ${ssh_user}@${ssh_host}:${ssh_port}...${RESET}\n" >/dev/tty
        if [[ "$tunnel_type" == "jump" ]]; then
            printf "${DIM}  Note: Direct test only — jump hosts are configured next.${RESET}\n" >/dev/tty
        fi
        if ! test_ssh_connection "$ssh_host" "$ssh_port" "$ssh_user" "$identity_key" "$ssh_password"; then
            printf "\n${DIM}  Common fixes: wrong password, wrong user,${RESET}\n" >/dev/tty
            printf "${DIM}  host unreachable, or SSH key not accepted.${RESET}\n" >/dev/tty
            if [[ "$tunnel_type" == "jump" ]]; then
                printf "${DIM}  For jump hosts, this test may fail if the${RESET}\n" >/dev/tty
                printf "${DIM}  target is only reachable via relay servers.${RESET}\n" >/dev/tty
            fi
            printf "${DIM}  'no' takes you back to edit details.${RESET}\n\n" >/dev/tty
            if ! _wiz_yn "Authentication failed. Continue anyway?"; then
                if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
                _step=5; continue  # back to user/password/key
            fi
        fi
        (( ++_step )) ;;

    9) # ── Type-specific sub-wizard ──
        _new_profile=(
            [PROFILE_NAME]="$name"
            [TUNNEL_TYPE]="$tunnel_type"
            [SSH_HOST]="$ssh_host"
            [SSH_PORT]="$ssh_port"
            [SSH_USER]="$ssh_user"
            [SSH_PASSWORD]="$ssh_password"
            [IDENTITY_KEY]="$identity_key"
            [LOCAL_BIND_ADDR]="127.0.0.1"
            [LOCAL_PORT]=""
            [REMOTE_HOST]=""
            [REMOTE_PORT]=""
            [JUMP_HOSTS]=""
            [SSH_OPTIONS]=""
            [AUTOSSH_ENABLED]="$(config_get AUTOSSH_ENABLED true)"
            [AUTOSSH_MONITOR_PORT]="0"
            [DNS_LEAK_PROTECTION]="false"
            [KILL_SWITCH]="false"
            [AUTOSTART]="false"
            [OBFS_MODE]="none"
            [OBFS_PORT]="443"
            [OBFS_LOCAL_PORT]=""
            [OBFS_PSK]=""
            [DESCRIPTION]=""
        )
        local _sub_rc=0
        case "$tunnel_type" in
            socks5)  wizard_socks5 _new_profile || _sub_rc=$? ;;
            local)   wizard_local_forward _new_profile || _sub_rc=$? ;;
            remote)  wizard_remote_forward _new_profile || _sub_rc=$? ;;
            jump)    wizard_jump_host _new_profile || _sub_rc=$? ;;
        esac
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back || (( _sub_rc == 2 )); then _step=2; continue; fi
        if (( _sub_rc != 0 )); then return 1; fi
        (( ++_step )) ;;

    10) # ── Connection mode: Regular SSH or TLS encrypted ──
        _wiz_header "Connection Mode"
        printf "${DIM}  Choose how your SSH connection reaches the server.${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}1)${RESET} ${GREEN}Regular SSH${RESET} — standard SSH connection (default)\n" >/dev/tty
        printf "     ${DIM}Works everywhere SSH is not blocked.${RESET}\n" >/dev/tty
        printf "  ${BOLD}2)${RESET} ${CYAN}TLS Encrypted (stunnel)${RESET} — SSH wrapped in HTTPS\n" >/dev/tty
        printf "     ${DIM}Bypasses DPI firewalls (Iran, China, etc.)${RESET}\n" >/dev/tty
        printf "     ${DIM}Traffic looks like normal HTTPS on port 443.${RESET}\n\n" >/dev/tty
        printf "     Regular:                        TLS Encrypted:\n" >/dev/tty
        printf "     ┌──────┐ SSH:22 ┌──────┐       ┌──────┐ TLS:443 ┌────────┐\n" >/dev/tty
        printf "     │Client├────────┤Server│       │Client├─────────┤stunnel │\n" >/dev/tty
        printf "     └──────┘        └──────┘       └──────┘  HTTPS  │→SSH :22│\n" >/dev/tty
        printf "                                                      └────────┘\n" >/dev/tty
        printf "\n" >/dev/tty
        local _conn_mode=""
        _wiz_read "Connection mode [1=Regular, 2=TLS]" _conn_mode "1"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then _step=2; continue; fi
        case "$_conn_mode" in
            2)
                _new_profile[OBFS_MODE]="stunnel"
                local _obfs_port=""
                printf "\n${DIM}  Port 443 mimics HTTPS (most effective).${RESET}\n" >/dev/tty
                printf "${DIM}  Only change if 443 is already in use on the server.${RESET}\n" >/dev/tty
                _wiz_read "TLS port" _obfs_port "${_new_profile[OBFS_PORT]:-443}"
                if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
                if _wiz_back; then continue; fi
                if ! validate_port "$_obfs_port"; then
                    printf "  ${RED}Invalid port: ${_obfs_port}${RESET}\n" >/dev/tty
                    continue
                fi
                # Check if port is available on the remote server
                printf "\n${DIM}  Checking port ${_obfs_port} on ${ssh_host}...${RESET}\n" >/dev/tty
                local _port_check_rc=0
                _obfs_remote_ssh _new_profile || _port_check_rc=1
                if (( _port_check_rc == 0 )); then
                    local _port_in_use=""
                    _port_in_use=$("${_OBFS_SSH_CMD[@]}" "ss -tln 2>/dev/null | grep -E ':${_obfs_port}[[:space:]]' | head -1" 2>/dev/null) || true
                    unset SSHPASS 2>/dev/null || true
                    if [[ -n "$_port_in_use" ]]; then
                        printf "  ${YELLOW}Port ${_obfs_port} is in use on ${ssh_host}:${RESET}\n" >/dev/tty
                        printf "  ${DIM}${_port_in_use}${RESET}\n" >/dev/tty
                        local _alt_port="8443"
                        if [[ "$_obfs_port" == "8443" ]]; then _alt_port="8444"; fi
                        printf "  ${DIM}Suggested alternative: ${_alt_port}${RESET}\n\n" >/dev/tty
                        _wiz_read "TLS port (try ${_alt_port})" _obfs_port "$_alt_port"
                        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
                        if _wiz_back; then continue; fi
                        if ! validate_port "$_obfs_port"; then
                            printf "  ${RED}Invalid port: ${_obfs_port}${RESET}\n" >/dev/tty
                            continue
                        fi
                    else
                        printf "  ${GREEN}Port ${_obfs_port} is available${RESET}\n" >/dev/tty
                    fi
                else
                    unset SSHPASS 2>/dev/null || true
                    printf "  ${DIM}Could not check (SSH failed) — will verify during setup${RESET}\n" >/dev/tty
                fi
                _new_profile[OBFS_PORT]="$_obfs_port"

                printf "\n${DIM}  TunnelForge can install stunnel on your server automatically.${RESET}\n" >/dev/tty
                printf "${DIM}  This requires SSH access (using the credentials above).${RESET}\n" >/dev/tty
                if _wiz_yn "Set up stunnel on server now?"; then
                    _obfs_setup_stunnel_direct _new_profile || true
                fi
                printf "\n" >/dev/tty
                ;;
            *)
                _new_profile[OBFS_MODE]="none"
                ;;
        esac
        (( ++_step )) ;;

    11) # ── Inbound TLS protection (for VPS deployments) ──
        _wiz_header "Inbound Protection"
        printf "${DIM}  If this server is a VPS (not your home PC), users connecting${RESET}\n" >/dev/tty
        printf "${DIM}  from their devices need TLS protection too — otherwise DPI${RESET}\n" >/dev/tty
        printf "${DIM}  can detect the SOCKS5 traffic entering the VPS.${RESET}\n\n" >/dev/tty
        printf "     User PC ──TLS+PSK──→ This VPS ──tunnel──→ Exit VPS ──→ Internet\n\n" >/dev/tty
        printf "  ${BOLD}1)${RESET} ${GREEN}No inbound protection${RESET} — direct SOCKS5 access (default)\n" >/dev/tty
        printf "     ${DIM}Fine for home server or trusted LAN.${RESET}\n" >/dev/tty
        printf "  ${BOLD}2)${RESET} ${CYAN}TLS + PSK inbound${RESET} — encrypted + authenticated access\n" >/dev/tty
        printf "     ${DIM}Users need stunnel client + pre-shared key to connect.${RESET}\n" >/dev/tty
        printf "     ${DIM}Recommended for VPS in censored networks.${RESET}\n\n" >/dev/tty
        local _inbound_mode=""
        _wiz_read "Inbound protection [1=None, 2=TLS+PSK]" _inbound_mode "1"
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        if _wiz_back; then (( --_step )); continue; fi
        case "$_inbound_mode" in
            2)
                local _ol_port=""
                printf "\n${DIM}  Choose a port for client TLS connections.${RESET}\n" >/dev/tty
                printf "${DIM}  Use 443 or 8443 to look like HTTPS traffic.${RESET}\n" >/dev/tty
                _wiz_read "Inbound TLS port" _ol_port "1443"
                if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
                if _wiz_back; then continue; fi
                if ! validate_port "$_ol_port"; then
                    printf "  ${RED}Invalid port: ${_ol_port}${RESET}\n" >/dev/tty
                    continue
                fi
                _new_profile[OBFS_LOCAL_PORT]="$_ol_port"

                # Auto-generate PSK
                printf "\n${DIM}  Generating pre-shared key...${RESET}\n" >/dev/tty
                local _gen_psk=""
                _gen_psk=$(_obfs_generate_psk) || true
                if [[ -z "$_gen_psk" ]]; then
                    printf "  ${RED}Failed to generate PSK${RESET}\n" >/dev/tty
                    continue
                fi
                _new_profile[OBFS_PSK]="$_gen_psk"
                printf "  ${GREEN}PSK generated${RESET} ${DIM}(will be shown after tunnel starts)${RESET}\n" >/dev/tty

                # Force 127.0.0.1 binding
                _new_profile[LOCAL_BIND_ADDR]="127.0.0.1"
                printf "  ${DIM}Bind address forced to 127.0.0.1 (stunnel handles external access)${RESET}\n" >/dev/tty
                printf "\n" >/dev/tty
                ;;
            *)
                _new_profile[OBFS_LOCAL_PORT]=""
                _new_profile[OBFS_PSK]=""
                ;;
        esac
        (( ++_step )) ;;

    12) # ── Optional settings ──
        _wiz_header "Optional Settings"
        printf "${DIM}  Tip: A short note to help you remember${RESET}\n" >/dev/tty
        printf "${DIM}  e.g. 'MySQL access', 'browsing proxy'${RESET}\n" >/dev/tty
        _wiz_read "Description (optional)" desc ""
        if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
        # Go back to tunnel type selection (step 9 reinits _new_profile, so skip it)
        if _wiz_back; then _step=2; continue; fi
        _new_profile[DESCRIPTION]="$desc"

        printf "\n${DIM}  AutoSSH auto-reconnects if the tunnel drops.${RESET}\n" >/dev/tty
        printf "${DIM}  Recommended for long-running tunnels.${RESET}\n" >/dev/tty
        if _wiz_yn "Enable AutoSSH reconnection?" "y"; then
            _new_profile[AUTOSSH_ENABLED]="true"
        else
            if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
            if _wiz_back; then continue; fi
            _new_profile[AUTOSSH_ENABLED]="false"
        fi

        printf "\n${DIM}  Creates a systemd service so this tunnel${RESET}\n" >/dev/tty
        printf "${DIM}  starts automatically on boot.${RESET}\n" >/dev/tty
        if _wiz_yn "Auto-start on system boot?"; then
            _new_profile[AUTOSTART]="true"
        else
            if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
            if _wiz_back; then continue; fi
        fi
        (( ++_step )) ;;

    13) # ── Summary + save ──
        printf "\n${BOLD_CYAN}── Profile Summary ──${RESET}\n\n" >/dev/tty
        printf "  ${BOLD}Name:${RESET}        %s\n" "$name" >/dev/tty
        printf "  ${BOLD}Type:${RESET}        %s\n" "${_new_profile[TUNNEL_TYPE]^^}" >/dev/tty
        printf "  ${BOLD}SSH Host:${RESET}    %s@%s:%s\n" "$ssh_user" "$ssh_host" "$ssh_port" >/dev/tty
        if [[ -n "$ssh_password" ]]; then
            printf "  ${BOLD}Password:${RESET}    ****\n" >/dev/tty
        fi
        if [[ -n "$identity_key" ]]; then
            printf "  ${BOLD}Key:${RESET}         %s\n" "$identity_key" >/dev/tty
        fi
        if [[ -n "${_new_profile[LOCAL_PORT]}" ]]; then
            printf "  ${BOLD}Local:${RESET}       %s:%s\n" "${_new_profile[LOCAL_BIND_ADDR]}" "${_new_profile[LOCAL_PORT]}" >/dev/tty
        fi
        if [[ -n "${_new_profile[REMOTE_HOST]}" ]]; then
            printf "  ${BOLD}Remote:${RESET}      %s:%s\n" "${_new_profile[REMOTE_HOST]}" "${_new_profile[REMOTE_PORT]}" >/dev/tty
        fi
        if [[ -n "${_new_profile[JUMP_HOSTS]}" ]]; then
            printf "  ${BOLD}Jump Hosts:${RESET}  %s\n" "${_new_profile[JUMP_HOSTS]}" >/dev/tty
        fi
        if [[ "${_new_profile[OBFS_MODE]:-none}" != "none" ]]; then
            printf "  ${BOLD}Obfuscation:${RESET} %s (port %s)\n" "${_new_profile[OBFS_MODE]}" "${_new_profile[OBFS_PORT]}" >/dev/tty
        fi
        if [[ -n "${_new_profile[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_new_profile[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
            printf "  ${BOLD}Inbound TLS:${RESET} port %s (PSK protected)\n" "${_new_profile[OBFS_LOCAL_PORT]}" >/dev/tty
        fi
        printf "  ${BOLD}AutoSSH:${RESET}     %s\n" "${_new_profile[AUTOSSH_ENABLED]}" >/dev/tty
        printf "  ${BOLD}Autostart:${RESET}   %s\n" "${_new_profile[AUTOSTART]}" >/dev/tty
        if [[ -n "$desc" ]]; then
            printf "  ${BOLD}Description:${RESET} %s\n" "$desc" >/dev/tty
        fi
        printf "\n" >/dev/tty

        if ! _wiz_yn "Save this profile?" "y"; then
            if _wiz_quit; then log_info "Wizard cancelled"; return 0; fi
            if _wiz_back; then (( --_step )); continue; fi
            log_info "Profile creation cancelled"
            return 0
        fi

        local _wz_pfile
        _wz_pfile=$(_profile_path "$name")
        if ! _save_profile_data "$_wz_pfile" _new_profile; then
            log_error "Failed to save profile '${name}'"
            return 1
        fi
        log_success "Profile '${name}' created successfully"

        printf "\n${DIM}  You can start/stop tunnels from the main menu.${RESET}\n" >/dev/tty
        if _read_yn "Start tunnel now?"; then
            start_tunnel "$name" || true
            # Show "What's Next?" guide based on tunnel type
            local _wn_bind="${_new_profile[LOCAL_BIND_ADDR]}"
            local _wn_lport="${_new_profile[LOCAL_PORT]}"
            local _wn_rhost="${_new_profile[REMOTE_HOST]}"
            local _wn_rport="${_new_profile[REMOTE_PORT]}"
            local _wn_shost="${_new_profile[SSH_HOST]}"
            printf "\n${BOLD_CYAN}── What's Next? ──${RESET}\n\n" >/dev/tty
            case "${_new_profile[TUNNEL_TYPE]}" in
                socks5)
                    printf "  ${BOLD}Configure your apps to use the proxy:${RESET}\n\n" >/dev/tty
                    printf "  ${DIM}Browser (Firefox):${RESET}\n" >/dev/tty
                    printf "    Settings → Proxy → Manual config\n" >/dev/tty
                    printf "    SOCKS Host: ${BOLD}%s${RESET}  Port: ${BOLD}%s${RESET}\n" "$_wn_bind" "$_wn_lport" >/dev/tty
                    printf "    Select SOCKS v5, enable Proxy DNS\n\n" >/dev/tty
                    printf "  ${DIM}Test from command line:${RESET}\n" >/dev/tty
                    printf "    curl --socks5 %s:%s https://ifconfig.me\n\n" "$_wn_bind" "$_wn_lport" >/dev/tty
                    if [[ "$_wn_bind" == "0.0.0.0" ]]; then
                        printf "  ${DIM}From other devices on your LAN, use${RESET}\n" >/dev/tty
                        printf "  ${DIM}this machine's IP instead of 0.0.0.0${RESET}\n\n" >/dev/tty
                    fi ;;
                local)
                    printf "  ${BOLD}Access the remote service locally:${RESET}\n\n" >/dev/tty
                    printf "  ${DIM}Open in browser or connect to:${RESET}\n" >/dev/tty
                    printf "    http://%s:%s\n\n" "$_wn_bind" "$_wn_lport" >/dev/tty
                    printf "  ${DIM}This reaches %s:%s on the remote side${RESET}\n" "$_wn_rhost" "$_wn_rport" >/dev/tty
                    printf "  ${DIM}through the SSH tunnel.${RESET}\n\n" >/dev/tty
                    if [[ "$_wn_bind" == "0.0.0.0" ]]; then
                        printf "  ${DIM}From other devices on your LAN, use${RESET}\n" >/dev/tty
                        printf "  ${DIM}this machine's IP instead of 0.0.0.0${RESET}\n\n" >/dev/tty
                    fi ;;
                remote)
                    printf "  ${BOLD}Before using this tunnel:${RESET}\n\n" >/dev/tty
                    printf "  ${DIM}1. Make sure a service is running on${RESET}\n" >/dev/tty
                    printf "     ${BOLD}%s:%s${RESET} (this machine)\n\n" "$_wn_rhost" "$_wn_lport" >/dev/tty
                    printf "  ${DIM}2. The service is now reachable at:${RESET}\n" >/dev/tty
                    printf "     ${BOLD}%s:%s${RESET} (on the SSH server)\n\n" "$_wn_bind" "$_wn_rport" >/dev/tty
                    printf "  ${DIM}Test from the SSH server:${RESET}\n" >/dev/tty
                    printf "    curl http://localhost:%s\n\n" "$_wn_rport" >/dev/tty ;;
                jump)
                    printf "  ${DIM}Same as the tunnel type you chose${RESET}\n" >/dev/tty
                    printf "  ${DIM}(SOCKS5 or Local Forward) but routed${RESET}\n" >/dev/tty
                    printf "  ${DIM}through the jump host(s).${RESET}\n\n" >/dev/tty ;;
            esac
        fi
        return 0 ;;

    esac
    done
}

setup_wizard() {
    wizard_create_profile || true
}

# ============================================================================
# INTERACTIVE MENUS  (Phase 2)
# ============================================================================

# Clear screen and show banner for menus
_menu_header() {
    local title="${1:-}"
    clear >/dev/tty 2>/dev/null || true
    show_banner >/dev/tty
    if [[ -n "$title" ]]; then
        printf "  ${BOLD_CYAN}%s${RESET}\n" "$title" >/dev/tty
        local _mh_sep=""
        for (( _mhi=0; _mhi<60; _mhi++ )); do _mh_sep+="─"; done
        printf "  %s\n\n" "$_mh_sep" >/dev/tty
    fi
}

# ── Settings menu ──

show_settings_menu() {
    while true; do
        _menu_header "Settings"

        printf "  ${BOLD}Current Defaults:${RESET}\n\n" >/dev/tty
        printf "    ${CYAN}1${RESET}) SSH User           : ${BOLD}%s${RESET}\n"  "$(config_get SSH_DEFAULT_USER root)" >/dev/tty
        printf "    ${CYAN}2${RESET}) SSH Port           : ${BOLD}%s${RESET}\n"  "$(config_get SSH_DEFAULT_PORT 22)" >/dev/tty
        printf "    ${CYAN}3${RESET}) SSH Key            : ${BOLD}%s${RESET}\n"  "$(config_get SSH_DEFAULT_KEY '(none)')" >/dev/tty
        printf "    ${CYAN}4${RESET}) Connect Timeout    : ${BOLD}%s${RESET}s\n" "$(config_get SSH_CONNECT_TIMEOUT 10)" >/dev/tty
        printf "    ${CYAN}5${RESET}) AutoSSH Enabled    : ${BOLD}%s${RESET}\n"  "$(config_get AUTOSSH_ENABLED true)" >/dev/tty
        printf "    ${CYAN}6${RESET}) AutoSSH Poll       : ${BOLD}%s${RESET}s\n" "$(config_get AUTOSSH_POLL 30)" >/dev/tty
        printf "    ${CYAN}7${RESET}) ControlMaster      : ${BOLD}%s${RESET}\n"  "$(config_get CONTROLMASTER_ENABLED false)" >/dev/tty
        printf "    ${CYAN}8${RESET}) Log Level          : ${BOLD}%s${RESET}\n"  "$(config_get LOG_LEVEL info)" >/dev/tty
        printf "    ${CYAN}9${RESET}) Dashboard Refresh  : ${BOLD}%s${RESET}s\n" "$(config_get DASHBOARD_REFRESH 3)" >/dev/tty
        printf "\n    ${YELLOW}0${RESET}) Back\n\n" >/dev/tty

        local _sm_choice
        printf "  ${BOLD}Select [0-9]${RESET}: " >/dev/tty
        read -rsn1 _sm_choice </dev/tty || true
        _drain_esc _sm_choice
        printf "\n" >/dev/tty

        case "$_sm_choice" in
            1)  local val; _read_tty "  SSH default user" val "$(config_get SSH_DEFAULT_USER root)" || true
                if [[ -n "$val" ]]; then
                    config_set "SSH_DEFAULT_USER" "$val"; save_settings || true
                else
                    log_error "User cannot be empty"; _press_any_key
                fi ;;
            2)  local val; _read_tty "  SSH default port" val "$(config_get SSH_DEFAULT_PORT 22)" || true
                if validate_port "$val"; then
                    config_set "SSH_DEFAULT_PORT" "$val"; save_settings || true
                else
                    log_error "Invalid port"; _press_any_key
                fi ;;
            3)  local val; _read_tty "  SSH default key path" val "$(config_get SSH_DEFAULT_KEY)" || true
                config_set "SSH_DEFAULT_KEY" "$val"; save_settings || true ;;
            4)  local val; _read_tty "  Connect timeout (seconds)" val "$(config_get SSH_CONNECT_TIMEOUT 10)" || true
                if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 )); then
                    config_set "SSH_CONNECT_TIMEOUT" "$val"; save_settings || true
                else
                    log_error "Must be a positive number"; _press_any_key
                fi ;;
            5)  local cur; cur=$(config_get AUTOSSH_ENABLED true)
                if [[ "$cur" == "true" ]]; then
                    config_set "AUTOSSH_ENABLED" "false"
                    log_success "AutoSSH disabled"
                else
                    config_set "AUTOSSH_ENABLED" "true"
                    log_success "AutoSSH enabled"
                fi
                save_settings || true ;;
            6)  local val; _read_tty "  AutoSSH poll interval (seconds)" val "$(config_get AUTOSSH_POLL 30)" || true
                if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 )); then
                    config_set "AUTOSSH_POLL" "$val"; save_settings || true
                else
                    log_error "Must be a positive number"; _press_any_key
                fi ;;
            7)  local cur; cur=$(config_get CONTROLMASTER_ENABLED false)
                if [[ "$cur" == "true" ]]; then
                    config_set "CONTROLMASTER_ENABLED" "false"
                    log_success "ControlMaster disabled"
                else
                    config_set "CONTROLMASTER_ENABLED" "true"
                    log_success "ControlMaster enabled"
                fi
                save_settings || true ;;
            8)  local _ll_opts=("debug" "info" "warn" "error")
                local _ll_idx
                if _ll_idx=$(_select_option "  Log level" "${_ll_opts[@]}"); then
                    config_set "LOG_LEVEL" "${_ll_opts[$_ll_idx]}"
                    save_settings || true
                fi ;;
            9)  local val; _read_tty "  Dashboard refresh rate (seconds)" val "$(config_get DASHBOARD_REFRESH 3)" || true
                if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 )); then
                    config_set "DASHBOARD_REFRESH" "$val"; save_settings || true
                else
                    log_error "Must be a positive number"; _press_any_key
                fi ;;
            0|q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── Edit profile sub-menu ──

_edit_profile_menu() {
    local _ep_name="$1"
    local -A _eprof
    load_profile "$_ep_name" _eprof || { log_error "Cannot load profile"; return 1; }
    # Snapshot original values for dirty-check on discard
    local -A _eprof_orig
    local _ep_fld
    for _ep_fld in "${!_eprof[@]}"; do _eprof_orig[$_ep_fld]="${_eprof[$_ep_fld]}"; done

    while true; do
        _menu_header "Edit Profile: ${_ep_name}"

        printf "    ${CYAN}1${RESET}) SSH Host        : ${BOLD}%s${RESET}\n" "${_eprof[SSH_HOST]:-}" >/dev/tty
        printf "    ${CYAN}2${RESET}) SSH Port        : ${BOLD}%s${RESET}\n" "${_eprof[SSH_PORT]:-22}" >/dev/tty
        printf "    ${CYAN}3${RESET}) SSH User        : ${BOLD}%s${RESET}\n" "${_eprof[SSH_USER]:-}" >/dev/tty
        printf "    ${CYAN}4${RESET}) Identity Key    : ${BOLD}%s${RESET}\n" "${_eprof[IDENTITY_KEY]:-none}" >/dev/tty
        printf "    ${CYAN}5${RESET}) Local Bind      : ${BOLD}%s:%s${RESET}\n" "${_eprof[LOCAL_BIND_ADDR]:-}" "${_eprof[LOCAL_PORT]:-}" >/dev/tty
        printf "    ${CYAN}6${RESET}) Remote Target   : ${BOLD}%s:%s${RESET}\n" "${_eprof[REMOTE_HOST]:-}" "${_eprof[REMOTE_PORT]:-}" >/dev/tty
        printf "    ${CYAN}7${RESET}) AutoSSH         : ${BOLD}%s${RESET}\n" "${_eprof[AUTOSSH_ENABLED]:-true}" >/dev/tty
        printf "    ${CYAN}8${RESET}) Autostart       : ${BOLD}%s${RESET}\n" "${_eprof[AUTOSTART]:-false}" >/dev/tty
        printf "    ${CYAN}9${RESET}) Description     : ${BOLD}%s${RESET}\n" "${_eprof[DESCRIPTION]:-}" >/dev/tty
        printf "\n" >/dev/tty
        printf "    ${CYAN}a${RESET}) Kill Switch     : ${BOLD}%s${RESET}\n" "${_eprof[KILL_SWITCH]:-false}" >/dev/tty
        printf "    ${CYAN}b${RESET}) DNS Leak Prot.  : ${BOLD}%s${RESET}\n" "${_eprof[DNS_LEAK_PROTECTION]:-false}" >/dev/tty
        printf "    ${CYAN}c${RESET}) TLS Obfuscation : ${BOLD}%s${RESET}\n" "${_eprof[OBFS_MODE]:-none}" >/dev/tty
        printf "    ${CYAN}d${RESET}) TLS Port        : ${BOLD}%s${RESET}\n" "${_eprof[OBFS_PORT]:-443}" >/dev/tty
        printf "    ${CYAN}e${RESET}) Jump Hosts      : ${BOLD}%s${RESET}\n" "${_eprof[JUMP_HOSTS]:-none}" >/dev/tty
        printf "\n    ${GREEN}s${RESET}) Save changes\n" >/dev/tty
        printf "    ${YELLOW}0${RESET}) Back (discard)\n\n" >/dev/tty

        local _ep_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _ep_choice </dev/tty || true
        _drain_esc _ep_choice
        printf "\n" >/dev/tty

        case "$_ep_choice" in
            1)  local val; _read_tty "  SSH host" val "${_eprof[SSH_HOST]:-}" || true
                if validate_hostname "$val" || validate_ip "$val"; then
                    _eprof[SSH_HOST]="$val"
                else
                    log_error "Invalid hostname or IP"; _press_any_key
                fi ;;
            2)  local val; _read_tty "  SSH port" val "${_eprof[SSH_PORT]:-22}" || true
                if validate_port "$val"; then
                    _eprof[SSH_PORT]="$val"
                else
                    log_error "Invalid port"; _press_any_key
                fi ;;
            3)  local val; _read_tty "  SSH user" val "${_eprof[SSH_USER]:-}" || true
                if [[ -n "$val" ]] && [[ "$val" =~ ^[a-zA-Z0-9._@-]+$ ]]; then
                    _eprof[SSH_USER]="$val"
                elif [[ -z "$val" ]]; then
                    log_warn "SSH user cleared — will use default ($(config_get SSH_DEFAULT_USER root))"
                    _eprof[SSH_USER]=""
                else
                    log_error "Invalid SSH user"; _press_any_key
                fi ;;
            4)  local val; _read_tty "  Identity key path" val "${_eprof[IDENTITY_KEY]:-}" || true
                _eprof[IDENTITY_KEY]="$val" ;;
            5)  local bval pval
                _read_tty "  Bind address" bval "${_eprof[LOCAL_BIND_ADDR]:-127.0.0.1}" || true
                _read_tty "  Local port" pval "${_eprof[LOCAL_PORT]:-}" || true
                if ! { validate_ip "$bval" || validate_ip6 "$bval" || [[ "$bval" == "localhost" ]] || [[ "$bval" == "*" ]]; }; then
                    log_error "Invalid bind address — changes discarded"; _press_any_key
                elif ! validate_port "$pval"; then
                    log_error "Invalid port — changes discarded"; _press_any_key
                else
                    _eprof[LOCAL_BIND_ADDR]="$bval"
                    _eprof[LOCAL_PORT]="$pval"
                fi ;;
            6)  local hval pval
                _read_tty "  Remote host" hval "${_eprof[REMOTE_HOST]:-}" || true
                _read_tty "  Remote port" pval "${_eprof[REMOTE_PORT]:-}" || true
                if [[ -z "$pval" ]] && [[ "${_eprof[TUNNEL_TYPE]:-}" == "socks5" ]]; then
                    # SOCKS5 doesn't use remote host/port — allow clearing
                    _eprof[REMOTE_HOST]=""
                    _eprof[REMOTE_PORT]=""
                elif [[ -n "$pval" ]] && validate_port "$pval"; then
                    _eprof[REMOTE_HOST]="$hval"
                    _eprof[REMOTE_PORT]="$pval"
                else
                    log_error "Invalid port — changes discarded"; _press_any_key
                fi ;;
            7)  if [[ "${_eprof[AUTOSSH_ENABLED]:-true}" == "true" ]]; then
                    _eprof[AUTOSSH_ENABLED]="false"
                else
                    _eprof[AUTOSSH_ENABLED]="true"
                fi ;;
            8)  if [[ "${_eprof[AUTOSTART]:-false}" == "true" ]]; then
                    _eprof[AUTOSTART]="false"
                else
                    _eprof[AUTOSTART]="true"
                fi ;;
            9)  local val; _read_tty "  Description" val "${_eprof[DESCRIPTION]:-}" || true
                _eprof[DESCRIPTION]="$val" ;;
            a|A)  if [[ "${_eprof[KILL_SWITCH]:-false}" == "true" ]]; then
                    _eprof[KILL_SWITCH]="false"
                    log_info "Kill switch disabled"
                else
                    _eprof[KILL_SWITCH]="true"
                    log_warn "Kill switch enabled — blocks traffic if tunnel drops (requires root)"
                fi ;;
            b|B)  if [[ "${_eprof[DNS_LEAK_PROTECTION]:-false}" == "true" ]]; then
                    _eprof[DNS_LEAK_PROTECTION]="false"
                    log_info "DNS leak protection disabled"
                else
                    _eprof[DNS_LEAK_PROTECTION]="true"
                    log_warn "DNS leak protection enabled — rewrites resolv.conf (requires root)"
                fi ;;
            c|C)  if [[ "${_eprof[OBFS_MODE]:-none}" == "none" ]]; then
                    _eprof[OBFS_MODE]="stunnel"
                    log_info "TLS obfuscation enabled (stunnel)"
                else
                    _eprof[OBFS_MODE]="none"
                    log_info "TLS obfuscation disabled"
                fi ;;
            d|D)  local val; _read_tty "  TLS obfuscation port" val "${_eprof[OBFS_PORT]:-443}" || true
                if validate_port "$val"; then
                    _eprof[OBFS_PORT]="$val"
                else
                    log_error "Invalid port"; _press_any_key
                fi ;;
            e|E)  local val; _read_tty "  Jump hosts (user@host:port or blank)" val "${_eprof[JUMP_HOSTS]:-}" || true
                _eprof[JUMP_HOSTS]="$val" ;;
            s|S)
                if save_profile "$_ep_name" _eprof; then
                    log_success "Profile '${_ep_name}' saved"
                else
                    log_error "Failed to save profile '${_ep_name}'"
                fi
                _press_any_key
                return 0 ;;
            0|q)
                # Check if any field was modified
                local _ep_dirty=false _ep_ck
                for _ep_ck in "${!_eprof[@]}"; do
                    if [[ "${_eprof[$_ep_ck]}" != "${_eprof_orig[$_ep_ck]:-}" ]]; then
                        _ep_dirty=true; break
                    fi
                done
                if [[ "$_ep_dirty" == true ]]; then
                    if confirm_action "Discard unsaved changes?"; then
                        return 0
                    fi
                else
                    return 0
                fi ;;
            *) true ;;
        esac
    done
}

# ── Profile management menu ──

show_profiles_menu() {
    while true; do
        _menu_header "Profile Management"

        local _pm_profiles
        _pm_profiles=$(list_profiles)

        local _pm_names=()
        if [[ -z "$_pm_profiles" ]]; then
            printf "  ${DIM}No profiles configured.${RESET}\n\n" >/dev/tty
        else
            printf "  ${BOLD}%-4s %-18s %-8s %-12s %-22s${RESET}\n" \
                "#" "NAME" "TYPE" "STATUS" "LOCAL" >/dev/tty
            local _pm_sep=""
            for (( _pmi=0; _pmi<66; _pmi++ )); do _pm_sep+="─"; done
            printf "  %s\n" "$_pm_sep" >/dev/tty

            local _pm_idx=0
            while IFS= read -r _pm_name; do
                [[ -z "$_pm_name" ]] && continue
                (( ++_pm_idx ))
                _pm_names+=("$_pm_name")
                local _pm_type _pm_status _pm_local
                _pm_type=$(get_profile_field "$_pm_name" "TUNNEL_TYPE" 2>/dev/null) || true
                _pm_local="$(get_profile_field "$_pm_name" "LOCAL_BIND_ADDR" 2>/dev/null || true):$(get_profile_field "$_pm_name" "LOCAL_PORT" 2>/dev/null || true)"
                if is_tunnel_running "$_pm_name"; then
                    _pm_status="${GREEN}● running  ${RESET}"
                else
                    _pm_status="${DIM}■ stopped  ${RESET}"
                fi
                printf "  ${CYAN}%-4s${RESET} %-18s %-8s %b%-22s\n" \
                    "${_pm_idx}" "$_pm_name" "${_pm_type:-?}" "$_pm_status" "$_pm_local" >/dev/tty
            done <<< "$_pm_profiles"
        fi

        printf "\n" >/dev/tty
        printf "    ${CYAN}c${RESET}) Create new profile\n" >/dev/tty
        printf "    ${CYAN}d${RESET}) Delete a profile\n" >/dev/tty
        printf "    ${CYAN}e${RESET}) Edit a profile\n" >/dev/tty
        printf "    ${YELLOW}0${RESET}) Back\n\n" >/dev/tty

        local _pm_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _pm_choice </dev/tty || true
        _drain_esc _pm_choice
        printf "\n" >/dev/tty

        case "$_pm_choice" in
            c|C) wizard_create_profile || true; _press_any_key ;;
            d|D)
                local _pm_dinput _pm_dname
                _read_tty "  Profile # or name to delete" _pm_dinput "" || true
                if [[ "$_pm_dinput" =~ ^[0-9]+$ ]] && (( _pm_dinput >= 1 && _pm_dinput <= ${#_pm_names[@]} )); then
                    _pm_dname="${_pm_names[$((_pm_dinput-1))]}"
                else
                    _pm_dname="$_pm_dinput"
                fi
                if [[ -n "$_pm_dname" ]] && validate_profile_name "$_pm_dname"; then
                    if confirm_action "Delete profile '${_pm_dname}'?"; then
                        delete_profile "$_pm_dname" || true
                    fi
                fi
                _press_any_key ;;
            e|E)
                local _pm_einput _pm_ename
                _read_tty "  Profile # or name to edit" _pm_einput "" || true
                if [[ "$_pm_einput" =~ ^[0-9]+$ ]] && (( _pm_einput >= 1 && _pm_einput <= ${#_pm_names[@]} )); then
                    _pm_ename="${_pm_names[$((_pm_einput-1))]}"
                else
                    _pm_ename="$_pm_einput"
                fi
                if [[ -n "$_pm_ename" ]] && validate_profile_name "$_pm_ename" && [[ -f "$(_profile_path "$_pm_ename")" ]]; then
                    _edit_profile_menu "$_pm_ename" || true
                else
                    log_error "Profile not found: ${_pm_ename}"
                    _press_any_key
                fi ;;
            0|q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── About screen ──

show_about() {
    _menu_header ""
    local _ab_os _ab_w=58
    _ab_os="$(uname -s 2>/dev/null || echo unknown) $(uname -m 2>/dev/null || echo unknown)"
    local _ab_max_os=$(( _ab_w - 2 - 5 - 11 ))
    if (( ${#_ab_os} > _ab_max_os )); then _ab_os="${_ab_os:0:_ab_max_os}"; fi

    local _ab_border="" _abi
    for (( _abi=0; _abi < _ab_w - 2; _abi++ )); do _ab_border+="═"; done

    printf "\n  ${BOLD_CYAN}╔%s╗${RESET}\n" "$_ab_border" >/dev/tty
    printf "  ${BOLD_CYAN}║%-*s║${RESET}\n" "$((_ab_w - 2))" "" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${BOLD_WHITE}TunnelForge${RESET}  — SSH Tunnel Manager%*s${BOLD_CYAN}║${RESET}\n" \
        "$((_ab_w - 38))" "" >/dev/tty
    printf "  ${BOLD_CYAN}║%-*s║${RESET}\n" "$((_ab_w - 2))" "" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "Version  : ${VERSION}" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "Author   : SamNet Technologies, LLC" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "License  : GPL v3.0" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "Platform : ${_ab_os}" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "GitHub   : github.com/SamNet-dev/tunnelforge" >/dev/tty
    printf "  ${BOLD_CYAN}║%-*s║${RESET}\n" "$((_ab_w - 2))" "" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "A single-file SSH tunnel manager with TUI menu," >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "live dashboard, DNS leak protection, kill switch," >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "server hardening, and Telegram notifications." >/dev/tty
    printf "  ${BOLD_CYAN}║%-*s║${RESET}\n" "$((_ab_w - 2))" "" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "This program is free software under the GNU GPL" >/dev/tty
    printf "  ${BOLD_CYAN}║${RESET}   ${DIM}%-*s${RESET}${BOLD_CYAN}║${RESET}\n" "$((_ab_w - 5))" "v3. See LICENSE file or gnu.org/licenses/gpl-3.0" >/dev/tty
    printf "  ${BOLD_CYAN}║%-*s║${RESET}\n" "$((_ab_w - 2))" "" >/dev/tty
    printf "  ${BOLD_CYAN}╚%s╝${RESET}\n\n" "$_ab_border" >/dev/tty
    _press_any_key
}

# ── Learn: SSH tunnel explanations ──

show_learn_menu() {
    while true; do
        _menu_header "Learn: SSH Tunnels"

        printf "    ${BOLD}── SSH Fundamentals ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}1${RESET}) What is an SSH Tunnel?\n" >/dev/tty
        printf "    ${CYAN}2${RESET}) SOCKS5 Dynamic Proxy (-D)\n" >/dev/tty
        printf "    ${CYAN}3${RESET}) Local Port Forwarding (-L)\n" >/dev/tty
        printf "    ${CYAN}4${RESET}) Remote/Reverse Forwarding (-R)\n" >/dev/tty
        printf "    ${CYAN}5${RESET}) Jump Hosts & Multi-hop (-J)\n" >/dev/tty
        printf "    ${CYAN}6${RESET}) ControlMaster Multiplexing\n" >/dev/tty
        printf "    ${CYAN}7${RESET}) AutoSSH & Reconnection\n" >/dev/tty
        printf "\n    ${BOLD}── TLS Obfuscation ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}8${RESET}) What is TLS Obfuscation?\n" >/dev/tty
        printf "    ${CYAN}9${RESET}) PSK Authentication\n" >/dev/tty
        printf "\n    ${YELLOW}0${RESET}) Back\n\n" >/dev/tty

        local _lm_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _lm_choice </dev/tty || true
        _drain_esc _lm_choice
        printf "\n" >/dev/tty

        case "$_lm_choice" in
            1) _learn_what_is_tunnel || true ;;
            2) _learn_socks5 || true ;;
            3) _learn_local_forward || true ;;
            4) _learn_remote_forward || true ;;
            5) _learn_jump_host || true ;;
            6) _learn_controlmaster || true ;;
            7) _learn_autossh || true ;;
            8) _learn_tls_obfuscation || true ;;
            9) _learn_psk_auth || true ;;
            0|q) return 0 ;;
            *) true ;;
        esac
    done
}

_learn_what_is_tunnel() {
    _menu_header "What is an SSH Tunnel?"
    cat >/dev/tty <<'EOF'

  An SSH tunnel creates an encrypted channel between your local
  machine and a remote server. Network traffic is forwarded through
  this encrypted tunnel, protecting it from eavesdropping.

  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   ┌────────┐    Encrypted SSH Tunnel    ┌────────────┐       │
  │   │  Your  │ ══════════════════════════ │   Remote   │       │
  │   │Machine │       (port 22)            │   Server   │       │
  │   └────────┘                            └────────────┘       │
  │                                                              │
  │   All traffic inside the tunnel is encrypted and secure.     │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘

  Common use cases:
    • Bypass firewalls and NAT
    • Secure access to remote services
    • Create encrypted SOCKS proxies
    • Expose local services to the internet

EOF
    _press_any_key
}

_learn_socks5() {
    _menu_header "SOCKS5 Dynamic Proxy (-D)"
    cat >/dev/tty <<'EOF'

  A SOCKS5 proxy creates a dynamic forwarding tunnel. Any application
  configured to use the SOCKS proxy will route traffic through the
  SSH server.

  ┌──────────┐     ┌─────────────┐     ┌───────────┐
  │ Browser  │────>│  SSH Server │────>│  Website  │
  │  :1080   │     │  (proxy)    │     │           │
  └──────────┘     └─────────────┘     └───────────┘

  Command:  ssh -D 1080 user@server

  Configure your browser/app to use:
    SOCKS5 proxy: 127.0.0.1:1080

  Benefits:
    • Route ALL TCP traffic through the tunnel
    • Appears to browse from the server's IP
    • Supports DNS resolution through proxy
    • Works with any SOCKS5-aware application

EOF
    _press_any_key
}

_learn_local_forward() {
    _menu_header "Local Port Forwarding (-L)"
    cat >/dev/tty <<'EOF'

  Local forwarding maps a port on your local machine to a port on
  a remote machine, through the SSH server.

  ┌──────────┐     ┌─────────────┐     ┌───────────┐
  │  Local   │────>│  SSH Server │────>│  Target   │
  │  :8080   │     │  (relay)    │     │  :80      │
  └──────────┘     └─────────────┘     └───────────┘

  Command:  ssh -L 8080:target:80 user@server

  Now http://localhost:8080 → target:80 via SSH server

  Use cases:
    • Access a database behind a firewall
    • Reach internal web apps securely
    • Connect to services on a private network

EOF
    _press_any_key
}

_learn_remote_forward() {
    _menu_header "Remote/Reverse Forwarding (-R)"
    cat >/dev/tty <<'EOF'

  Remote forwarding exposes a local service on the remote SSH server.
  Users connecting to the server's port reach your local machine.

  ┌──────────┐     ┌─────────────┐     ┌───────────┐
  │  Local   │<────│  SSH Server │<────│  Users    │
  │  :3000   │     │  :9090      │     │           │
  └──────────┘     └─────────────┘     └───────────┘

  Command:  ssh -R 9090:localhost:3000 user@server

  Now server:9090 → your localhost:3000

  Use cases:
    • Expose local dev server to the internet
    • Webhook development & testing
    • Remote access to services behind NAT
    • Demo local apps to clients

EOF
    _press_any_key
}

_learn_jump_host() {
    _menu_header "Jump Hosts & Multi-hop (-J)"
    cat >/dev/tty <<'EOF'

  Jump hosts let you reach a target through one or more intermediate
  SSH servers. Useful when the target is not directly accessible.

  ┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐
  │ Local  │───>│ Jump 1 │───>│ Jump 2 │───>│ Target │
  │        │    │        │    │        │    │        │
  └────────┘    └────────┘    └────────┘    └────────┘

  Command:  ssh -J jump1,jump2 user@target

  Combined with tunnel:
    ssh -J jump1,jump2 -D 1080 user@target

  Use cases:
    • Reach servers in isolated networks
    • Multi-tier security environments
    • Bastion/jump box architectures
    • Chain through multiple datacenters

EOF
    _press_any_key
}

_learn_controlmaster() {
    _menu_header "ControlMaster Multiplexing"
    cat >/dev/tty <<'EOF'

  ControlMaster allows multiple SSH sessions to share a single
  network connection. Subsequent connections reuse the existing
  TCP connection and skip authentication.

  First connection (creates socket):
    ┌────────┐ ═══TCP═══ ┌────────┐
    │ Local  │──socket──>│ Server │
    └────────┘           └────────┘

  Subsequent connections (reuse socket):
    ┌────────┐ ──socket──>
    │ Local  │ ──socket──>  (instant, no auth)
    └────────┘ ──socket──>

  Config:
    ControlMaster  auto
    ControlPath    ~/.ssh/sockets/%r@%h:%p
    ControlPersist 600

  Benefits:
    • Instant connection for subsequent sessions
    • Reduced server authentication load
    • Shared connection for tunnels + shell

EOF
    _press_any_key
}

_learn_autossh() {
    _menu_header "AutoSSH & Reconnection"
    cat >/dev/tty <<'EOF'

  AutoSSH monitors an SSH connection and automatically restarts
  it if the connection drops. Essential for persistent tunnels.

  ┌──────────┐          ┌──────────┐
  │ AutoSSH  │──watch──>│  SSH     │
  │ (monitor)│──restart>│ (tunnel) │
  └──────────┘          └──────────┘

  How it works:
    1. AutoSSH launches SSH with your tunnel config
    2. It monitors the connection health
    3. If SSH dies, AutoSSH restarts it automatically
    4. Exponential backoff prevents rapid reconnection loops

  TunnelForge config:
    AUTOSSH_POLL      = 30   (seconds between health checks)
    AUTOSSH_GATETIME  = 30   (min uptime before restart)
    AUTOSSH_MONITOR   = 0    (use ServerAlive instead)

  Tip: Combined with systemd, AutoSSH gives you a tunnel
       that survives reboots AND network outages.

EOF
    _press_any_key
}

_learn_tls_obfuscation() {
    _menu_header "TLS Obfuscation (stunnel)"
    printf >/dev/tty '%s\n' \
'' \
'  THE PROBLEM:' \
'    Some countries (Iran, China, Russia) use Deep Packet' \
'    Inspection (DPI) to detect and block SSH connections.' \
'    Even though SSH is encrypted, DPI can identify the' \
'    SSH protocol by its handshake pattern.' \
'' \
'  THE SOLUTION — TLS WRAPPING:' \
'    Wrap SSH inside a TLS (HTTPS) connection using stunnel.' \
'    DPI sees standard HTTPS traffic — the same protocol' \
'    used by every website. It cannot tell SSH is inside.' \
'' \
'  WITHOUT OBFUSCATION:' \
'    ┌──────┐  SSH:22  ┌──────┐' \
'    │Client├─────────>│Server│    DPI: "This is SSH → BLOCK"' \
'    └──────┘          └──────┘' \
'' \
'  WITH TLS OBFUSCATION:' \
'    ┌──────┐ TLS:443 ┌────────┐' \
'    │Client├────────>│stunnel │   DPI: "This is HTTPS → ALLOW"' \
'    └──────┘ (HTTPS) │→SSH :22│' \
'                     └────────┘' \
'' \
'  HOW STUNNEL WORKS:' \
'    Server side:' \
'      stunnel listens on port 443 (TLS)' \
'      → unwraps TLS → forwards to SSH on port 22' \
'' \
'    Client side (TunnelForge handles this):' \
'      SSH uses ProxyCommand with openssl to connect' \
'      through the TLS tunnel instead of directly' \
'' \
'  WHY PORT 443?' \
'    Port 443 is the standard HTTPS port. Every website' \
'    uses it. Blocking port 443 would break the internet,' \
'    so censors cannot block it.' \
'' \
'  SETUP IN TUNNELFORGE:' \
'    In the wizard, at "Connection Mode", pick:' \
'    2) TLS Encrypted (stunnel)' \
'    TunnelForge auto-installs stunnel on your server.' \
'' \
'  TWO TYPES OF TLS IN TUNNELFORGE:' \
'    Outbound TLS — wraps SSH going TO a remote server' \
'    Inbound TLS  — wraps SOCKS5 port for clients coming IN' \
'    Both can be active at once for full-chain encryption.' \
''
    _press_any_key
}

_learn_psk_auth() {
    _menu_header "PSK Authentication"
    printf >/dev/tty '%s\n' \
'' \
'  WHAT IS PSK?' \
'    Pre-Shared Key — a shared secret between server and' \
'    client. Both sides know the same key. Only clients' \
'    with the correct key can connect.' \
'' \
'  WHY USE PSK?' \
'    When TunnelForge runs on a VPS and accepts connections' \
'    from user PCs, the SOCKS5 port needs protection:' \
'    - Without PSK: anyone who finds the port can use it' \
'    - With PSK: only authorized users can connect' \
'' \
'  HOW IT WORKS:' \
'    ┌──────────┐    TLS + PSK    ┌──────────────┐' \
'    │ User PC  ├────────────────>│ VPS stunnel  │' \
'    │ stunnel  │  "I know the    │ verifies PSK │' \
'    │ (client) │   secret key"   │ → SOCKS5     │' \
'    └──────────┘                 └──────────────┘' \
'' \
'    1. Server stunnel has a PSK secrets file' \
'    2. Client stunnel has the SAME PSK' \
'    3. During TLS handshake, they prove they share' \
'       the same key — no certificates needed' \
'    4. If key doesn'"'"'t match → connection refused' \
'' \
'  PSK FORMAT:' \
'    identity:hexkey' \
'    Example: tunnelforge:a1b2c3d4e5f6....' \
'' \
'  IN TUNNELFORGE:' \
'    PSK is auto-generated when you enable "Inbound TLS+PSK"' \
'    in the wizard (step 11). 32-byte random hex key.' \
'' \
'    View PSK:    tunnelforge client-config <profile>' \
'    Share setup: tunnelforge client-script <profile>' \
'' \
'  REVOKING ACCESS:' \
'    To block a user: change the PSK in the profile,' \
'    restart the tunnel, and send the new script only' \
'    to authorized users. Old PSK stops working.' \
''
    _press_any_key
}

# ── Example Scenarios ──

show_scenarios_menu() {
    while true; do
        _menu_header "Example Scenarios"

        printf "    ${BOLD}── Basic SSH Tunnels ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}1${RESET}) SOCKS5 Proxy — Browse privately\n" >/dev/tty
        printf "    ${CYAN}2${RESET}) Local Forward — Access remote database\n" >/dev/tty
        printf "    ${CYAN}3${RESET}) Remote Forward — Share local website\n" >/dev/tty
        printf "    ${CYAN}4${RESET}) Jump Host — Reach a hidden server\n" >/dev/tty
        printf "\n    ${BOLD}── TLS Obfuscation (Anti-Censorship) ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}5${RESET}) Client → VPS (single server, bypass DPI)\n" >/dev/tty
        printf "    ${CYAN}6${RESET}) Client → VPS → VPS (double TLS, full chain)\n" >/dev/tty
        printf "    ${CYAN}7${RESET}) Share tunnel with others (client script)\n" >/dev/tty
        printf "\n    ${YELLOW}0${RESET}) Back\n\n" >/dev/tty

        local _sc_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _sc_choice </dev/tty || true
        _drain_esc _sc_choice
        printf "\n" >/dev/tty

        case "$_sc_choice" in
            1) _scenario_socks5 || true ;;
            2) _scenario_local_forward || true ;;
            3) _scenario_remote_forward || true ;;
            4) _scenario_jump_host || true ;;
            5) _scenario_tls_single_vps || true ;;
            6) _scenario_tls_double_vps || true ;;
            7) _scenario_tls_share_tunnel || true ;;
            0|q) return 0 ;;
            *) true ;;
        esac
    done
}

_scenario_socks5() {
    _menu_header "Scenario: Browse Privately via SOCKS5 Proxy"
    cat >/dev/tty <<'EOF'

  GOAL: Route your browser traffic through a VPS so websites
        see the VPS IP instead of your real IP.

  WHAT YOU NEED:
    • A VPS or remote server with SSH access
    • A browser (Firefox, Chrome, etc.)

  NETWORK DIAGRAM:

    ┌──────────┐          ┌──────────┐          ┌──────────┐
    │  Your PC │──SOCKS5──│   VPS    │──────────│ Internet │
    │  :1080   │  tunnel  │ (proxy)  │          │          │
    └──────────┘          └──────────┘          └──────────┘

  WIZARD SETTINGS:
    Tunnel type ......... SOCKS5 Proxy
    SSH host ............ Your VPS IP   (e.g. 45.33.32.10)
    SSH port ............ 22
    SSH user ............ root
    Bind address ........ 127.0.0.1     (local only)
                          0.0.0.0       (share with LAN)
    SOCKS port .......... 1080

  AFTER TUNNEL STARTS — CONFIGURE YOUR BROWSER:

    Firefox:
      1. Settings → search "proxy" → Manual proxy
      2. SOCKS Host: 127.0.0.1   Port: 1080
      3. Select "SOCKS v5"
      4. Check "Proxy DNS when using SOCKS v5"
      5. Click OK

    Chrome (command line):
      google-chrome --proxy-server="socks5://127.0.0.1:1080"

  TEST IT WORKS:
    From the command line:
      curl --socks5 127.0.0.1:1080 https://ifconfig.me
    → Should show your VPS IP, not your real IP

    If you used 0.0.0.0 as bind, other devices on your
    LAN can use it too:
      curl --socks5 <server-lan-ip>:1080 https://ifconfig.me

EOF
    _press_any_key
}

_scenario_local_forward() {
    _menu_header "Scenario: Access a Remote Database Locally"
    cat >/dev/tty <<'EOF'

  GOAL: Access a MySQL database running on your VPS as if it
        were on your local machine.

  WHAT YOU NEED:
    • A VPS with MySQL running on port 3306
    • An SSH account on that VPS

  NETWORK DIAGRAM:

    ┌──────────┐          ┌──────────┐
    │  Your PC │──Local───│   VPS    │
    │  :3306   │  Forward │  MySQL   │
    │          │          │  :3306   │
    └──────────┘          └──────────┘

  WIZARD SETTINGS:
    Tunnel type ......... Local Port Forward
    SSH host ............ Your VPS IP   (e.g. 45.33.32.10)
    SSH port ............ 22
    SSH user ............ root
    Local bind .......... 127.0.0.1     (local only)
                          0.0.0.0       (share with LAN)
    Local port .......... 3306          (port on YOUR PC)
    Remote host ......... 127.0.0.1     (means "on the VPS")
    Remote port ......... 3306          (MySQL on VPS)

  AFTER TUNNEL STARTS — CONNECT:

    MySQL client:
      mysql -h 127.0.0.1 -P 3306 -u dbuser -p

    Web app (e.g. phpMyAdmin, DBeaver):
      Host: 127.0.0.1   Port: 3306

    Web service (e.g. a web server on VPS port 8080):
      Change remote port to 8080, then open:
        http://127.0.0.1:8080
      in your browser.

  TEST IT WORKS:
    If forwarding a web service:
      curl http://127.0.0.1:<local-port>

    If using 0.0.0.0 as bind, other LAN devices connect:
      http://<server-lan-ip>:<local-port>

  COMMON VARIATIONS:
    • Forward port 5432 for PostgreSQL
    • Forward port 6379 for Redis
    • Forward port 8080 for a web admin panel
    • Remote host can be another IP on the VPS network
      (e.g. 10.0.0.5:3306 for a DB on a private subnet)

EOF
    _press_any_key
}

_scenario_remote_forward() {
    _menu_header "Scenario: Share a Local Website with the World"
    cat >/dev/tty <<'EOF'

  GOAL: You have a website running on your local machine
        (e.g. port 3000) and want to make it accessible
        from the internet through your VPS.

  WHAT YOU NEED:
    • A local service running (e.g. Node.js on port 3000)
    • A VPS with SSH access and a public IP

  NETWORK DIAGRAM:

    ┌──────────────┐          ┌──────────────┐
    │  Your PC     │──Reverse─│     VPS      │
    │  localhost    │  Forward │   public IP  │
    │    :3000     │          │    :9090     │
    └──────────────┘          └──────────────┘
                                    ↑
                              Anyone can access
                              http://VPS-IP:9090

  WIZARD SETTINGS:
    Tunnel type ......... Remote/Reverse Forward
    SSH host ............ Your VPS IP   (e.g. 45.33.32.10)
    SSH port ............ 22
    SSH user ............ root
    Remote bind ......... 127.0.0.1     (VPS localhost only)
                          0.0.0.0       (public, needs
                                         GatewayPorts yes)
    Remote port ......... 9090          (port on VPS)
    Local host .......... 127.0.0.1     (your machine)
    Local port .......... 3000          (your service)

  BEFORE STARTING — MAKE SURE:
    1. Your local service is running:
         python3 -m http.server 3000
         (or node app.js, etc.)

    2. If using 0.0.0.0 bind, your VPS sshd_config
       needs: GatewayPorts yes
       Then restart sshd: systemctl restart sshd

  AFTER TUNNEL STARTS — TEST FROM VPS:
      ssh root@<vps-ip>
      curl http://localhost:9090
    → Should show your local website content

  TEST FROM ANYWHERE (if bind is 0.0.0.0):
      curl http://<vps-public-ip>:9090
    → Same content, accessible from the internet

  COMMON VARIATIONS:
    • Share a dev server for client demos
    • Receive webhooks from services like GitHub/Stripe
    • Remote access to a home service behind NAT
    • Expose port 22 to allow SSH into your home PC

EOF
    _press_any_key
}

_scenario_jump_host() {
    _menu_header "Scenario: Reach a Server Behind a Firewall"
    cat >/dev/tty <<'EOF'

  GOAL: You need to access a server that is NOT directly
        reachable from the internet. You have SSH access
        to an intermediate "jump" server that CAN reach it.

  WHAT YOU NEED:
    • A jump server (bastion) you can SSH into
    • A target server the jump server can reach
    • SSH credentials for both servers

  NETWORK DIAGRAM:

    ┌──────────┐     ┌──────────┐     ┌──────────┐
    │  Your PC │────>│   Jump   │────>│  Target  │
    │          │     │ (bastion)│     │ (hidden) │
    └──────────┘     └──────────┘     └──────────┘
     You can't reach Target directly,
     but Jump can reach it.

  WIZARD SETTINGS (example with SOCKS5 at target):
    Tunnel type ......... Jump Host
    SSH host ............ Target IP    (e.g. 10.0.0.50)
    SSH port ............ 22
    SSH user ............ admin        (user on TARGET)
    SSH password ........ ****         (for TARGET)
    Jump hosts .......... root@bastion.example.com:22
    Dest tunnel type .... SOCKS5 Proxy
    Bind address ........ 127.0.0.1
    SOCKS port .......... 1080

  WIZARD SETTINGS (example with Local Forward):
    Tunnel type ......... Jump Host
    SSH host ............ 10.0.0.50    (target)
    SSH user ............ admin
    Jump hosts .......... root@45.33.32.10:22
    Dest tunnel type .... Local Port Forward
    Local bind .......... 0.0.0.0
    Local port .......... 8080
    Remote host ......... 127.0.0.1    (on the target)
    Remote port ......... 80           (web server)

  STEP-BY-STEP LOGIC:
    1. TunnelForge connects to the JUMP server first
    2. Through the jump server, it connects to TARGET
    3. Then it sets up your chosen tunnel (SOCKS5 or
       Local Forward) at the target

  AFTER TUNNEL STARTS:
    SOCKS5 mode:
      Set browser proxy to 127.0.0.1:1080
      curl --socks5 127.0.0.1:1080 https://ifconfig.me

    Local Forward mode:
      Open http://127.0.0.1:8080 in your browser
      → Shows the web server on the hidden target

  MULTIPLE JUMP HOSTS:
    You can chain through several servers:
      Jump hosts: user1@hop1:22,user2@hop2:22

    ┌────┐  ┌──────┐  ┌──────┐  ┌────────┐
    │ PC │─>│ Hop1 │─>│ Hop2 │─>│ Target │
    └────┘  └──────┘  └──────┘  └────────┘

  TIPS:
    • The SSH host/user/password are for the TARGET
    • Jump host credentials go in the jump hosts field
      (e.g. root@bastion:22)
    • Auth test may fail for the target — that's OK,
      the connection goes through the jump host

EOF
    _press_any_key
}

_scenario_tls_single_vps() {
    _menu_header "Scenario: Bypass Censorship (Single VPS)"
    printf >/dev/tty '%s\n' \
'' \
'  GOAL: You are in a censored country (Iran, China, etc.)' \
'        and your ISP blocks or detects SSH connections.' \
'        You want to browse freely using a VPS outside.' \
'' \
'  WHAT YOU NEED:' \
'    - 1 VPS outside the censored country (e.g. US, Europe)' \
'    - SSH access to that VPS' \
'' \
'  HOW IT WORKS:' \
'    SSH is wrapped in TLS so it looks like normal HTTPS.' \
'    Your ISP sees encrypted HTTPS traffic — not SSH.' \
'' \
'  NETWORK DIAGRAM:' \
'' \
'    Your PC (Iran)         VPS (Outside)' \
'    ┌──────────┐  TLS:443  ┌─────────────┐' \
'    │TunnelForge├──────────>│  stunnel    │' \
'    │ SOCKS5   │  (HTTPS)  │  → SSH :22  │──> Internet' \
'    │ :1080    │           └─────────────┘' \
'    └──────────┘' \
'     DPI sees: HTTPS traffic (allowed)' \
'' \
'  STEP-BY-STEP SETUP:' \
'    1. Install TunnelForge on your PC (Linux/WSL)' \
'    2. Run: tunnelforge wizard' \
'    3. Enter VPS connection details (host, user, password)' \
'    4. Pick tunnel type: SOCKS5 Proxy' \
'    5. At "Connection Mode": choose TLS Encrypted' \
'       - Port: 443 (or 8443 if 443 is busy)' \
'       - Say YES to "Set up stunnel on server now?"' \
'       - TunnelForge auto-installs stunnel on VPS' \
'    6. At "Inbound Protection": choose No (not needed,' \
'       you are connecting directly from your own PC)' \
'    7. Save and start the tunnel' \
'' \
'  AFTER TUNNEL STARTS:' \
'    Set browser SOCKS5 proxy: 127.0.0.1:1080' \
'    Test: curl --socks5 127.0.0.1:1080 https://ifconfig.me' \
'    → Should show VPS IP' \
'' \
'  WHAT DPI SEES:' \
'    Your PC ──HTTPS:443──> VPS IP' \
'    Looks like you are browsing a normal website.' \
''
    _press_any_key
}

_scenario_tls_double_vps() {
    _menu_header "Scenario: Double TLS Chain (Two VPS)"
    printf >/dev/tty '%s\n' \
'' \
'  GOAL: You run a shared proxy for multiple users.' \
'        One VPS is inside the censored country (relay),' \
'        one is outside (exit). Users connect to the relay' \
'        and traffic exits through the outside VPS.' \
'' \
'  WHAT YOU NEED:' \
'    - VPS-A: Inside censored country (e.g. Iran datacenter)' \
'    - VPS-B: Outside (e.g. US, Europe)' \
'' \
'  HOW IT WORKS:' \
'    Both legs are TLS-wrapped. Users connect with PSK.' \
'' \
'  NETWORK DIAGRAM:' \
'' \
'    Users           VPS-A (Iran)               VPS-B (Outside)' \
'    ┌──────┐ TLS+PSK ┌──────────────┐  TLS:443  ┌──────────┐' \
'    │ PC 1 ├────────>│ TunnelForge  ├──────────>│ stunnel  │' \
'    ├──────┤ :1443   │ stunnel+PSK  │  (HTTPS)  │ → SSH:22 │─> Net' \
'    │ PC 2 ├────────>│ → SOCKS5:1080│           └──────────┘' \
'    └──────┘         └──────────────┘' \
'     DPI sees: HTTPS     DPI sees: HTTPS' \
'' \
'  STEP-BY-STEP SETUP ON VPS-A:' \
'    1. Install TunnelForge on VPS-A' \
'    2. Run: tunnelforge wizard' \
'    3. SSH host = VPS-B IP, enter credentials' \
'    4. Tunnel type: SOCKS5 Proxy' \
'    5. Bind address: 0.0.0.0 (auto-forced to 127.0.0.1)' \
'    6. At "Connection Mode": choose TLS Encrypted' \
'       - Port: 443 (auto-installs stunnel on VPS-B)' \
'    7. At "Inbound Protection": choose TLS + PSK' \
'       - Port: 1443 (users connect here)' \
'       - PSK auto-generated' \
'    8. Save and start' \
'' \
'  AFTER TUNNEL STARTS:' \
'    TunnelForge shows the client config + PSK.' \
'    Generate a connect script for users:' \
'      tunnelforge client-script <profile>' \
'' \
'  USER SETUP (on each user PC):' \
'    Option A: Run the generated script:' \
'      ./tunnelforge-connect.sh' \
'      → Auto-installs stunnel, connects, done' \
'' \
'    Option B: Manual stunnel config:' \
'      tunnelforge client-config <profile>' \
'      → Shows stunnel.conf + psk.txt to copy' \
'' \
'    Then set browser proxy: 127.0.0.1:1080' \
'' \
'  WHAT DPI SEES:' \
'    User PC ──HTTPS:1443──> VPS-A (normal TLS)' \
'    VPS-A   ──HTTPS:443───> VPS-B (normal TLS)' \
'    No SSH protocol visible anywhere in the chain.' \
''
    _press_any_key
}

_scenario_tls_share_tunnel() {
    _menu_header "Scenario: Share Your Tunnel with Others"
    printf >/dev/tty '%s\n' \
'' \
'  GOAL: You have a working TLS tunnel on a VPS and want' \
'        to let friends/family use it from their own PCs.' \
'' \
'  WHAT YOU NEED:' \
'    - A running TunnelForge tunnel with Inbound TLS+PSK' \
'    - Friends who need to connect' \
'' \
'  HOW IT WORKS:' \
'    TunnelForge generates a one-file script. Users run it' \
'    and it auto-installs stunnel, configures everything,' \
'    and connects. No technical knowledge needed.' \
'' \
'  STEP 1 — GENERATE THE SCRIPT (on the server):' \
'' \
'    tunnelforge client-script <profile>' \
'' \
'    This creates: tunnelforge-connect.sh' \
'    The script contains the server address, port,' \
'    and the PSK — everything needed to connect.' \
'' \
'  STEP 2 — SEND IT TO USERS:' \
'    Share tunnelforge-connect.sh via:' \
'    - Telegram, WhatsApp, email, USB drive' \
'    - Any method that can transfer a small file' \
'' \
'  STEP 3 — USER RUNS THE SCRIPT:' \
'' \
'    chmod +x tunnelforge-connect.sh' \
'    ./tunnelforge-connect.sh' \
'' \
'    The script will:' \
'    1. Install stunnel if not present (apt/dnf/brew)' \
'    2. Write config files to ~/.tunnelforge-client/' \
'    3. Start stunnel and create a local SOCKS5 proxy' \
'    4. Print browser setup instructions' \
'' \
'  USER COMMANDS:' \
'    ./tunnelforge-connect.sh          Connect' \
'    ./tunnelforge-connect.sh stop     Disconnect' \
'    ./tunnelforge-connect.sh status   Check connection' \
'' \
'  AFTER CONNECTING:' \
'    Browser proxy: 127.0.0.1:<socks-port>' \
'    All traffic routes through your tunnel.' \
'' \
'  SECURITY NOTES:' \
'    - The script contains the PSK (shared secret)' \
'    - Only share with trusted people' \
'    - To revoke access: change PSK in profile,' \
'      regenerate script, and restart tunnel' \
'    - Each user gets their own local SOCKS5 proxy' \
'    - The server stunnel handles multiple connections' \
'' \
'  OTHER USEFUL COMMANDS:' \
'    tunnelforge client-config <profile>' \
'      → Show connection details + PSK (for manual setup)' \
'    tunnelforge client-script <profile> /path/to/output.sh' \
'      → Save script to specific location' \
''
    _press_any_key
}

# ── Menu helpers for start/stop ──

_menu_start_tunnel() {
    local _ms_profiles
    _ms_profiles=$(list_profiles)
    if [[ -z "$_ms_profiles" ]]; then
        log_info "No profiles found. Create one first."
        return 0
    fi

    printf "\n${BOLD}Available tunnels:${RESET}\n" >/dev/tty
    local _ms_names=() _ms_idx=0
    while IFS= read -r _ms_pn; do
        [[ -z "$_ms_pn" ]] && continue
        (( ++_ms_idx ))
        _ms_names+=("$_ms_pn")
        local _ms_st
        if is_tunnel_running "$_ms_pn"; then
            _ms_st="${GREEN}● running${RESET}"
        else
            _ms_st="${DIM}■ stopped${RESET}"
        fi
        printf "  ${CYAN}%d${RESET}) %-20s %b\n" "$_ms_idx" "$_ms_pn" "$_ms_st" >/dev/tty
    done <<< "$_ms_profiles"

    printf "\n" >/dev/tty
    local _ms_choice
    if ! _read_tty "Select tunnel # (or name)" _ms_choice ""; then return 0; fi

    local _ms_target
    if [[ "$_ms_choice" =~ ^[0-9]+$ ]] && (( _ms_choice >= 1 && _ms_choice <= ${#_ms_names[@]} )); then
        _ms_target="${_ms_names[$((_ms_choice-1))]}"
    else
        _ms_target="$_ms_choice"
    fi

    if [[ -n "$_ms_target" ]]; then
        start_tunnel "$_ms_target" || true
    fi
}

_menu_stop_tunnel() {
    local _mt_profiles
    _mt_profiles=$(list_profiles)
    if [[ -z "$_mt_profiles" ]]; then
        log_info "No profiles found. Create one first."
        return 0
    fi

    local _mt_names=() _mt_idx=0 _mt_header_shown=false
    while IFS= read -r _mt_pn; do
        [[ -z "$_mt_pn" ]] && continue
        if is_tunnel_running "$_mt_pn"; then
            if [[ "$_mt_header_shown" == false ]]; then
                printf "\n${BOLD}Running tunnels:${RESET}\n" >/dev/tty
                _mt_header_shown=true
            fi
            (( ++_mt_idx ))
            _mt_names+=("$_mt_pn")
            printf "  ${CYAN}%d${RESET}) %s\n" "$_mt_idx" "$_mt_pn" >/dev/tty
        fi
    done <<< "$_mt_profiles"

    if [[ ${#_mt_names[@]} -eq 0 ]]; then
        log_info "No running tunnels."
        return 0
    fi

    printf "\n" >/dev/tty
    local _mt_choice
    if ! _read_tty "Select tunnel # (or name)" _mt_choice ""; then return 0; fi

    local _mt_target
    if [[ "$_mt_choice" =~ ^[0-9]+$ ]] && (( _mt_choice >= 1 && _mt_choice <= ${#_mt_names[@]} )); then
        _mt_target="${_mt_names[$((_mt_choice-1))]}"
    else
        _mt_target="$_mt_choice"
    fi

    if [[ -n "$_mt_target" ]]; then
        stop_tunnel "$_mt_target" || true
    fi
}

# ── Security sub-menus ──

_menu_ssh_keys() {
    while true; do
        clear >/dev/tty 2>/dev/null || true
        printf "\n${BOLD_CYAN}═══ SSH Key Management ═══${RESET}\n\n" >/dev/tty
        printf "  ${CYAN}1${RESET}) Generate new SSH key\n" >/dev/tty
        printf "  ${CYAN}2${RESET}) Deploy key to server\n" >/dev/tty
        printf "  ${CYAN}3${RESET}) Check key permissions\n" >/dev/tty
        printf "  ${YELLOW}q${RESET}) Back\n\n" >/dev/tty

        local _mk_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _mk_choice </dev/tty || true
        _drain_esc _mk_choice
        printf "\n" >/dev/tty

        case "$_mk_choice" in
            1)
                local _mk_type _mk_path
                _read_tty "Key type (ed25519/rsa/ecdsa)" _mk_type "ed25519" || true
                case "$_mk_type" in
                    ed25519|rsa|ecdsa) ;;
                    *) log_error "Unsupported key type: ${_mk_type} (use ed25519, rsa, or ecdsa)" ;;
                esac
                if [[ "$_mk_type" =~ ^(ed25519|rsa|ecdsa)$ ]]; then
                    _mk_path="${HOME}/.ssh/id_${_mk_type}"
                    generate_ssh_key "$_mk_type" "$_mk_path" || true
                fi
                _press_any_key ;;
            2)
                local _mk_name
                _read_tty "Profile name" _mk_name "" || true
                if [[ -n "$_mk_name" ]] && validate_profile_name "$_mk_name"; then
                    deploy_ssh_key "$_mk_name" || true
                elif [[ -n "$_mk_name" ]]; then
                    log_error "Invalid profile name: ${_mk_name}"
                fi
                _press_any_key ;;
            3)
                local _mk_kpath
                _read_tty "Key path" _mk_kpath "${HOME}/.ssh/id_ed25519" || true
                check_key_permissions "$_mk_kpath" || true
                _press_any_key ;;
            q|Q) return 0 ;;
            *) true ;;
        esac
    done
}

_menu_service_select() {
    local _msv_profiles
    _msv_profiles=$(list_profiles)
    if [[ -z "$_msv_profiles" ]]; then
        log_info "No profiles found. Create one first."
        return 0
    fi

    printf "\n${BOLD}Available profiles:${RESET}\n" >/dev/tty
    local _msv_names=() _msv_idx=0
    while IFS= read -r _msv_pn; do
        [[ -z "$_msv_pn" ]] && continue
        (( ++_msv_idx ))
        _msv_names+=("$_msv_pn")
        printf "  ${CYAN}%d${RESET}) %s\n" "$_msv_idx" "$_msv_pn" >/dev/tty
    done <<< "$_msv_profiles"

    printf "\n" >/dev/tty
    local _msv_choice
    if ! _read_tty "Select profile # (or name)" _msv_choice ""; then return 0; fi

    local _msv_target
    if [[ "$_msv_choice" =~ ^[0-9]+$ ]] && (( _msv_choice >= 1 && _msv_choice <= ${#_msv_names[@]} )); then
        _msv_target="${_msv_names[$((_msv_choice-1))]}"
    else
        _msv_target="$_msv_choice"
    fi

    if [[ -n "$_msv_target" ]]; then
        _menu_service "$_msv_target" || true
    fi
    return 0
}

_menu_fingerprint() {
    while true; do
        clear >/dev/tty 2>/dev/null || true
        printf "\n${BOLD_CYAN}═══ SSH Host Fingerprint Verification ═══${RESET}\n\n" >/dev/tty

        local _mf_choice
        printf "  ${CYAN}1${RESET}) Enter host manually\n" >/dev/tty
        printf "  ${CYAN}2${RESET}) Check from profile\n" >/dev/tty
        printf "  ${YELLOW}q${RESET}) Back\n\n" >/dev/tty

        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _mf_choice </dev/tty || true
        _drain_esc _mf_choice
        printf "\n" >/dev/tty

        case "$_mf_choice" in
            1)
                local _mf_host _mf_port
                _read_tty "Host" _mf_host "" || true
                _read_tty "Port" _mf_port "22" || true
                if [[ -n "$_mf_host" ]]; then
                    if validate_port "$_mf_port"; then
                        verify_host_fingerprint "$_mf_host" "$_mf_port" || true
                    else
                        log_error "Invalid port: ${_mf_port}"
                    fi
                else
                    log_error "Host cannot be empty"
                fi
                _press_any_key ;;
            2)
                local _mf_name
                _read_tty "Profile name" _mf_name "" || true
                if [[ -n "$_mf_name" ]]; then
                    local -A _mf_prof
                    if load_profile "$_mf_name" _mf_prof 2>/dev/null; then
                        local _mf_h="${_mf_prof[SSH_HOST]:-}"
                        local _mf_p="${_mf_prof[SSH_PORT]:-22}"
                        if [[ -n "$_mf_h" ]]; then
                            verify_host_fingerprint "$_mf_h" "$_mf_p" || true
                        else
                            log_error "No SSH host in profile '${_mf_name}'"
                        fi
                    else
                        log_error "Cannot load profile '${_mf_name}'"
                    fi
                fi
                _press_any_key ;;
            q|Q) return 0 ;;
            *) true ;;
        esac
    done
}

# ── Main interactive menu ──

show_menu() {
    while true; do
        _menu_header ""

        # Quick status summary
        local _mm_profiles _mm_total=0 _mm_running=0
        _mm_profiles=$(list_profiles)
        if [[ -n "$_mm_profiles" ]]; then
            while IFS= read -r _mm_pn; do
                [[ -z "$_mm_pn" ]] && continue
                (( ++_mm_total ))
                if is_tunnel_running "$_mm_pn"; then
                    (( ++_mm_running ))
                fi
            done <<< "$_mm_profiles"
        fi

        printf "  ${DIM}Tunnels: ${RESET}${GREEN}%d running${RESET} ${DIM}/ %d total${RESET}\n\n" \
            "$_mm_running" "$_mm_total" >/dev/tty

        printf "  ${BOLD}── Tunnel Operations ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}1${RESET}) ${BOLD}Create${RESET} new tunnel          ${DIM}Setup wizard${RESET}\n" >/dev/tty
        printf "    ${CYAN}2${RESET}) ${BOLD}Start${RESET} a tunnel             ${DIM}Launch SSH tunnel${RESET}\n" >/dev/tty
        printf "    ${CYAN}3${RESET}) ${BOLD}Stop${RESET} a tunnel              ${DIM}Terminate tunnel${RESET}\n" >/dev/tty
        printf "    ${CYAN}4${RESET}) ${BOLD}Start All${RESET} tunnels          ${DIM}Launch autostart tunnels${RESET}\n" >/dev/tty
        printf "    ${CYAN}5${RESET}) ${BOLD}Stop All${RESET} tunnels           ${DIM}Terminate all${RESET}\n" >/dev/tty

        printf "\n  ${BOLD}── Monitoring ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}6${RESET}) ${BOLD}Status${RESET}                     ${DIM}Show tunnel statuses${RESET}\n" >/dev/tty
        printf "    ${CYAN}7${RESET}) ${BOLD}Dashboard${RESET}                  ${DIM}Live TUI dashboard${RESET}\n" >/dev/tty

        printf "\n  ${BOLD}── Management ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}8${RESET}) ${BOLD}Profiles${RESET}                   ${DIM}Manage tunnel profiles${RESET}\n" >/dev/tty
        printf "    ${CYAN}9${RESET}) ${BOLD}Settings${RESET}                   ${DIM}Configure defaults${RESET}\n" >/dev/tty
        printf "    ${CYAN}s${RESET}) ${BOLD}Services${RESET}                   ${DIM}Systemd service manager${RESET}\n" >/dev/tty
        printf "    ${CYAN}b${RESET}) ${BOLD}Backup / Restore${RESET}           ${DIM}Manage backups${RESET}\n" >/dev/tty

        printf "\n  ${BOLD}── Security & Notifications ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}x${RESET}) ${BOLD}Security Audit${RESET}             ${DIM}Check security posture${RESET}\n" >/dev/tty
        printf "    ${CYAN}k${RESET}) ${BOLD}SSH Key Management${RESET}         ${DIM}Generate & deploy keys${RESET}\n" >/dev/tty
        printf "    ${CYAN}f${RESET}) ${BOLD}Fingerprint Check${RESET}          ${DIM}Verify host fingerprints${RESET}\n" >/dev/tty
        printf "    ${CYAN}t${RESET}) ${BOLD}Telegram${RESET}                   ${DIM}Notification settings${RESET}\n" >/dev/tty
        printf "    ${CYAN}c${RESET}) ${BOLD}Client Configs${RESET}             ${DIM}TLS+PSK connection info${RESET}\n" >/dev/tty

        printf "\n  ${BOLD}── Information ──${RESET}\n" >/dev/tty
        printf "    ${CYAN}e${RESET}) ${BOLD}Examples${RESET}                   ${DIM}Real-world scenarios${RESET}\n" >/dev/tty
        printf "    ${CYAN}l${RESET}) ${BOLD}Learn${RESET}                      ${DIM}SSH tunnel concepts${RESET}\n" >/dev/tty
        printf "    ${CYAN}a${RESET}) ${BOLD}About${RESET}                      ${DIM}Version & info${RESET}\n" >/dev/tty
        printf "    ${CYAN}h${RESET}) ${BOLD}Help${RESET}                       ${DIM}CLI reference${RESET}\n" >/dev/tty

        printf "\n    ${RED}u${RESET}) ${BOLD}Uninstall${RESET}                  ${DIM}Remove everything${RESET}\n" >/dev/tty
        printf "    ${YELLOW}q${RESET}) ${BOLD}Quit${RESET}\n\n" >/dev/tty

        local _mm_choice
        printf "  ${BOLD}Select${RESET}: " >/dev/tty
        read -rsn1 _mm_choice </dev/tty || true
        _drain_esc _mm_choice
        printf "\n" >/dev/tty

        case "$_mm_choice" in
            1) wizard_create_profile || true; _press_any_key ;;
            2) _menu_start_tunnel || true; _press_any_key ;;
            3) _menu_stop_tunnel || true; _press_any_key ;;
            4) start_all_tunnels || true; _press_any_key ;;
            5) stop_all_tunnels || true; _press_any_key ;;
            6) show_status || true; _press_any_key ;;
            7) show_dashboard || true ;;
            8) show_profiles_menu || true ;;
            9) show_settings_menu || true ;;
            e|E) show_scenarios_menu || true ;;
            l|L) show_learn_menu || true ;;
            a|A) show_about || true ;;
            h|H) show_help || true; _press_any_key ;;
            x|X) security_audit || true; _press_any_key ;;
            k|K) _menu_ssh_keys || true ;;
            f|F) _menu_fingerprint || true ;;
            t|T) _menu_telegram || true ;;
            c|C) _menu_client_configs || true; _press_any_key ;;
            s|S) _menu_service_select || true ;;
            b|B) _menu_backup_restore || true ;;
            u|U) if confirm_action "Uninstall TunnelForge completely?"; then
                     clear >/dev/tty 2>/dev/null || true
                     uninstall_tunnelforge || true
                     return 0
                 fi ;;
            q|Q) clear >/dev/tty 2>/dev/null || true
                 printf "  ${DIM}Goodbye!${RESET}\n\n" >/dev/tty
                 return 0 ;;
            *) true ;;
        esac
    done
}

# ============================================================================
# DASHBOARD & LIVE MONITORING  (Phase 3)
# ============================================================================

# Sparkline block characters (8 levels)
readonly SPARK_CHARS=( "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" )

# Dashboard caches (avoid expensive re-computation each render)
declare -gA _DASH_LATENCY=()         # cached quality string per tunnel
declare -gA _DASH_LATENCY_TS=()      # epoch of last latency check
declare -gA _DASH_LAT_HOST=()        # latency cache by host:port (shared across tunnels)
declare -gA _DASH_LAT_HOST_TS=()     # epoch of last check per host:port
declare -g  _DASH_SS_CACHE=""        # cached ss -tn output per render cycle
declare -g  _DASH_SYSRES=""           # cached system resources line
declare -g  _DASH_SYSRES_TS=0         # epoch of last sysres check
declare -g  _DASH_LAST_SPEED=""       # last speed test result string
declare -gi _DASH_PAGE=0              # current page (0-indexed)
declare -gi _DASH_PER_PAGE=4          # tunnels per page
declare -gi _DASH_TOTAL_PAGES=1       # computed per render

# Record a bandwidth sample to history
_bw_record() {
    local name="$1" rx="$2" tx="$3"
    local bw_file="${BW_HISTORY_DIR}/${name}.dat"
    mkdir -p "$BW_HISTORY_DIR" 2>/dev/null || true

    # Light mkdir lock for append+trim
    local _bw_lock="${bw_file}.lck"
    local _bw_try=0
    while ! mkdir "$_bw_lock" 2>/dev/null; do
        local _bw_stale_pid=""
        _bw_stale_pid=$(cat "${_bw_lock}/pid" 2>/dev/null) || true
        if [[ -n "$_bw_stale_pid" ]] && ! kill -0 "$_bw_stale_pid" 2>/dev/null; then
            rm -f "${_bw_lock}/pid" 2>/dev/null || true
            rmdir "$_bw_lock" 2>/dev/null || true
            continue
        fi
        if (( ++_bw_try >= 5 )); then return 0; fi
        sleep 0.1
    done
    printf '%s' "$$" > "${_bw_lock}/pid" 2>/dev/null || true

    printf "%d %d %d\n" "$(date +%s)" "$rx" "$tx" >> "$bw_file" 2>/dev/null || true

    # Keep last 120 samples (10 min at 5s interval)
    if [[ -f "$bw_file" ]]; then
        local lines
        lines=$(wc -l < "$bw_file" 2>/dev/null || echo 0)
        if (( lines > 120 )); then
            local tmp_bw_file="${bw_file}.tmp"
            if tail -n 120 "$bw_file" > "$tmp_bw_file" 2>/dev/null; then
                mv "$tmp_bw_file" "$bw_file" 2>/dev/null || rm -f "$tmp_bw_file" 2>/dev/null
            else
                rm -f "$tmp_bw_file" 2>/dev/null
            fi
        fi
    fi

    rm -f "${_bw_lock}/pid" 2>/dev/null || true
    rmdir "$_bw_lock" 2>/dev/null || true
}

# Read last N bandwidth deltas from history
_bw_read_deltas() {
    local name="$1" count="${2:-30}"
    local bw_file="${BW_HISTORY_DIR}/${name}.dat"
    [[ -f "$bw_file" ]] || return 0

    local -a timestamps rx_vals tx_vals
    local ts rx tx
    while read -r ts rx tx; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        [[ "$rx" =~ ^[0-9]+$ ]] || continue
        [[ "$tx" =~ ^[0-9]+$ ]] || continue
        timestamps+=("$ts")
        rx_vals+=("$rx")
        tx_vals+=("$tx")
    done < <(tail -n "$(( count + 1 ))" "$bw_file" 2>/dev/null)

    local total=${#timestamps[@]}
    if (( total < 2 )); then return 0; fi

    local _i
    for (( _i=1; _i<total; _i++ )); do
        local dt=$(( timestamps[_i] - timestamps[_i-1] ))
        if (( dt < 1 )); then dt=1; fi
        local drx=$(( (rx_vals[_i] - rx_vals[_i-1]) / dt ))
        local dtx=$(( (tx_vals[_i] - tx_vals[_i-1]) / dt ))
        if (( drx < 0 )); then drx=0; fi
        if (( dtx < 0 )); then dtx=0; fi
        echo "$drx $dtx"
    done
}

# Generate sparkline string from numeric values
_sparkline() {
    local -a vals=("$@")
    local count=${#vals[@]}
    if (( count == 0 )); then return 0; fi

    # Find max
    local max_val=0 v
    for v in "${vals[@]}"; do
        if (( v > max_val )); then max_val="$v"; fi
    done

    local spark="" _si
    if (( max_val == 0 )); then
        for (( _si=0; _si<count; _si++ )); do spark+="${SPARK_CHARS[0]}"; done
    else
        for v in "${vals[@]}"; do
            local idx
            if (( v >= max_val )); then
                idx=7
            else
                idx=$(( (v * 7 + max_val / 2) / max_val ))
            fi
            if (( idx > 7 )); then idx=7; fi
            if (( idx < 0 )); then idx=0; fi
            spark+="${SPARK_CHARS[$idx]}"
        done
    fi
    printf '%s' "$spark"
}

# Get reconnect stats for a tunnel
_reconnect_stats() {
    local name="$1"
    local rlog="${RECONNECT_LOG_DIR}/${name}.log"
    [[ -f "$rlog" ]] || { echo "0 -"; return 0; }

    local total last_ts
    total=$(wc -l < "$rlog" 2>/dev/null || echo 0)
    last_ts=$(tail -n 1 "$rlog" 2>/dev/null | cut -d'|' -f1 || true)
    echo "${total} ${last_ts:--}"
    return 0
}

# Simple speed test using curl (routes through SOCKS5 tunnel if available)
_speed_test() {
    local -a _test_urls=(
        "http://speedtest.tele2.net/1MB.zip"
        "http://proof.ovh.net/files/1Mb.dat"
        "http://ipv4.download.thinkbroadband.com/1MB.zip"
    )
    local test_size=1048576  # 1MB

    printf "\n  ${BOLD_CYAN}── Speed Test ──${RESET}\n\n" >/dev/tty

    if ! command -v curl &>/dev/null; then
        printf "  ${RED}curl is required for speed test${RESET}\n" >/dev/tty
        return 0
    fi

    # Route through SOCKS5 tunnel if available (measures tunnel throughput)
    local -a _proxy_args=()
    local _proxy_port
    _proxy_port=$(_tg_find_proxy 2>/dev/null) || true
    if [[ -n "$_proxy_port" ]]; then
        _proxy_args=(--socks5-hostname "127.0.0.1:${_proxy_port}")
        printf "  ${DIM}Testing through SOCKS5 tunnel (port %s)...${RESET}\n" "$_proxy_port" >/dev/tty
    else
        printf "  ${DIM}Testing direct connection...${RESET}\n" >/dev/tty
    fi

    printf "  ${DIM}Downloading 1MB test file...${RESET}\n" >/dev/tty

    local start_time end_time elapsed speed_bps speed_str
    local _test_ok=false

    for _turl in "${_test_urls[@]}"; do
        start_time=$(_get_ns_timestamp)
        if curl -s -o /dev/null --max-time 15 "${_proxy_args[@]}" "$_turl" 2>/dev/null; then
            end_time=$(_get_ns_timestamp)
            _test_ok=true
            break
        fi
    done

    if [[ "$_test_ok" == true ]] && (( start_time > 0 && end_time > 0 )); then
        elapsed=$(( (end_time - start_time) / 1000000 ))  # milliseconds
        if (( elapsed < 1 )); then elapsed=1; fi
        speed_bps=$(( test_size * 1000 / elapsed ))  # bytes/sec

        speed_str=$(format_bytes "$speed_bps")
        printf "  ${GREEN}●${RESET} Download speed: ${BOLD}%s/s${RESET}\n" "$speed_str" >/dev/tty
        printf "  ${DIM}Time: %d.%03ds${RESET}\n" "$((elapsed/1000))" "$((elapsed%1000))" >/dev/tty
        _DASH_LAST_SPEED="${speed_str}/s"
    else
        printf "  ${RED}✗${RESET} Speed test failed (check connection)\n" >/dev/tty
    fi
    return 0
}

# ── Dashboard renderer ──

_dash_box_top() {
    local width="$1"
    local line="╔"
    local _i
    for (( _i=0; _i<width-2; _i++ )); do line+="═"; done
    line+="╗"
    printf '%s' "$line"
}

_dash_box_bottom() {
    local width="$1"
    local line="╚"
    local _i
    for (( _i=0; _i<width-2; _i++ )); do line+="═"; done
    line+="╝"
    printf '%s' "$line"
}

_dash_box_mid() {
    local width="$1"
    local line="╠"
    local _i
    for (( _i=0; _i<width-2; _i++ )); do line+="═"; done
    line+="╣"
    printf '%s' "$line"
}

# Pure-bash ANSI escape sequence stripping (avoids sed fork per call)
_strip_ansi() {
    local s="$1" out="" _esc=$'\033'
    while [[ -n "$s" ]]; do
        if [[ "$s" == "${_esc}["* ]]; then
            # Skip CSI sequence: ESC [ ... letter
            s="${s#"${_esc}["}"
            while [[ -n "$s" ]] && [[ "$s" != [a-zA-Z]* ]]; do
                s="${s:1}"
            done
            s="${s:1}"  # skip the final letter
        elif [[ "$s" == "${_esc}("* ]]; then
            s="${s:3}"  # skip ESC ( letter
        elif [[ "$s" == "${_esc}"* ]]; then
            s="${s:1}"  # unknown ESC, skip ESC char
        else
            out+="${s:0:1}"
            s="${s:1}"
        fi
    done
    printf '%s' "$out"
}

# ── Dashboard helper: system resources (cached 5s) ──
_dash_system_resources() {
    local now
    now=$(date +%s)
    if [[ -n "$_DASH_SYSRES" ]] && (( now - _DASH_SYSRES_TS < 5 )); then
        return 0
    fi

    # CPU% from /proc/stat (instantaneous idle delta would need 2 reads;
    # use /proc/loadavg instead for a lightweight single-read approach)
    local load_1="" load_5="" load_15=""
    if [[ -f /proc/loadavg ]]; then
        read -r load_1 load_5 load_15 _ _ < /proc/loadavg 2>/dev/null || true
    fi

    # Memory from /proc/meminfo
    local mem_total=0 mem_avail=0 mem_used=0 mem_pct=0
    if [[ -f /proc/meminfo ]]; then
        local _mt _ma
        _mt=$(grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}') || true
        _ma=$(grep -m1 '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}') || true
        if [[ "$_mt" =~ ^[0-9]+$ ]] && [[ "$_ma" =~ ^[0-9]+$ ]] && (( _mt > 0 )); then
            mem_total=$(( _mt / 1024 ))   # MB
            mem_avail=$(( _ma / 1024 ))
            mem_used=$(( mem_total - mem_avail ))
            mem_pct=$(( mem_used * 100 / mem_total ))
        fi
    fi

    local mem_str
    if (( mem_total >= 1024 )); then
        local _mu_g _mt_g
        _mu_g=$(awk "BEGIN{printf \"%.1f\", ${mem_used}/1024}") || true
        _mt_g=$(awk "BEGIN{printf \"%.1f\", ${mem_total}/1024}") || true
        mem_str="${_mu_g}G/${_mt_g}G (${mem_pct}%)"
    elif (( mem_total > 0 )); then
        mem_str="${mem_used}M/${mem_total}M (${mem_pct}%)"
    else
        mem_str="N/A"
    fi

    _DASH_SYSRES="MEM: ${mem_str}  │  Load: ${load_1:-?} ${load_5:-?} ${load_15:-?}"
    _DASH_SYSRES_TS=$now
    return 0
}

# ── Dashboard helper: active connections on a port ──
_dash_active_conns() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "0 clients"; return 0; }

    local -a _ips=()
    local _line _src
    # Use cached ss output if available (set by _dash_render), else run ss
    local _ss_data="${_DASH_SS_CACHE:-}"
    if [[ -z "$_ss_data" ]]; then
        _ss_data=$(ss -tn 2>/dev/null) || true
    fi
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        # ss output: State Recv-Q Send-Q Local:Port Peer:Port Process
        _src=$(echo "$_line" | awk '{print $5}') || true
        # Strip port: 192.168.1.5:43210 → 192.168.1.5
        _src="${_src%:*}"
        [[ -n "$_src" ]] && _ips+=("$_src")
    done < <(echo "$_ss_data" | grep -E "ESTAB.*:${port}[[:space:]]" || true)

    # Deduplicate IPs
    local -A _seen=()
    local -a _unique=()
    local _ip
    for _ip in "${_ips[@]}"; do
        if [[ -z "${_seen[$_ip]:-}" ]]; then
            _seen["$_ip"]=1
            _unique+=("$_ip")
        fi
    done

    local count=${#_unique[@]}
    if (( count == 0 )); then
        echo "0 clients"
    elif (( count <= 5 )); then
        local _joined
        _joined=$(IFS=, ; echo "${_unique[*]}")
        echo "${count} clients: ${_joined// /}"
    else
        local _first5
        _first5=$(IFS=, ; echo "${_unique[*]:0:5}")
        echo "${count} clients: ${_first5// /} (+$((count-5)))"
    fi
    return 0
}

# ── Dashboard helper: cached latency check (30s TTL) ──
# Result stored in _DASH_LATENCY[name] — caller reads directly (no subshell)
_dash_latency_cached() {
    local name="$1" host="$2" port="${3:-22}"
    local now
    now=$(date +%s)

    # Cache by host:port (not tunnel name) so multiple tunnels to same server share one check
    local _cache_key="${host}:${port}"
    if [[ -n "${_DASH_LAT_HOST[$_cache_key]:-}" ]] && [[ -n "${_DASH_LAT_HOST_TS[$_cache_key]:-}" ]] \
       && (( now - ${_DASH_LAT_HOST_TS[$_cache_key]} < 30 )); then
        _DASH_LATENCY["$name"]="${_DASH_LAT_HOST[$_cache_key]}"
        return 0
    fi

    local rating icon
    rating=$(_connection_quality "$host" "$port" 2>/dev/null) || true
    : "${rating:=unknown}"
    icon=$(_quality_icon "$rating" 2>/dev/null) || true
    : "${icon:=?}"

    local _result="${rating} ${icon}"
    _DASH_LAT_HOST["$_cache_key"]="$_result"
    _DASH_LAT_HOST_TS["$_cache_key"]=$now
    _DASH_LATENCY["$name"]="$_result"
    return 0
}

# Render the complete dashboard frame
_dash_render() {
    local LC_CTYPE=C.UTF-8
    local width=72

    # Cache ss output once per render cycle (used by get_tunnel_connections + _dash_active_conns)
    _DASH_SS_CACHE=$(ss -tn 2>/dev/null) || true

    # Load profiles + compute pagination (before header, so subtitle can show page)
    local profiles
    profiles=$(list_profiles)
    local has_tunnels=false
    local -A _dash_alive=()   # cache: name→1 for running tunnels
    local -A _dash_port=()    # cache: name→LOCAL_PORT for running tunnels
    local -A _dash_tls_port=() # cache: name→OBFS_LOCAL_PORT for running tunnels
    local -a _dash_page_names=()  # tunnels on current page (for active conns)

    local -a _all_profiles=()
    if [[ -n "$profiles" ]]; then
        while IFS= read -r _pname; do
            [[ -z "$_pname" ]] && continue
            _all_profiles+=("$_pname")
        done <<< "$profiles"
    fi
    local _total=${#_all_profiles[@]}

    # Auto-calculate tunnels per page based on terminal height
    # Fixed overhead: header(8) + colhdr(3) + sysres(3) + active_conn_hdr(2) + log(4)
    #   + reconnect(4) + sysinfo(2) + footer(3) = ~29 lines
    # Per tunnel on page: ~5 lines (status + sparkline + route + auth + active_conn_row)
    local _term_h
    _term_h=$(tput lines 2>/dev/null) || _term_h=40
    local _overhead=29
    _DASH_PER_PAGE=$(( (_term_h - _overhead) / 5 ))
    if (( _DASH_PER_PAGE < 2 )); then _DASH_PER_PAGE=2; fi
    if (( _DASH_PER_PAGE > 8 )); then _DASH_PER_PAGE=8; fi

    if (( _total > 0 )); then
        _DASH_TOTAL_PAGES=$(( (_total + _DASH_PER_PAGE - 1) / _DASH_PER_PAGE ))
    else
        _DASH_TOTAL_PAGES=1
    fi
    if (( _DASH_PAGE >= _DASH_TOTAL_PAGES )); then _DASH_PAGE=$(( _DASH_TOTAL_PAGES - 1 )); fi
    if (( _DASH_PAGE < 0 )); then _DASH_PAGE=0; fi
    local _pg_start=$(( _DASH_PAGE * _DASH_PER_PAGE ))
    local _pg_end=$(( _pg_start + _DASH_PER_PAGE ))
    if (( _pg_end > _total )); then _pg_end=$_total; fi

    # Header
    printf "${BOLD_GREEN}"
    _dash_box_top "$width"
    printf "${RESET}\n"

    # Title bar (3-row ASCII art)
    local _tr1="  ▀▀█▀▀ █  █ █▄ █ █▄ █ █▀▀ █   █▀▀ █▀█ █▀█ █▀▀ █▀▀"
    local _tr2="    █   █  █ █ ▀█ █ ▀█ █▀▀ █   █▀  █ █ █▀█ █ █ █▀▀"
    local _tr3="    █    ▀▀  █  █ █  █ ▀▀▀ ▀▀▀ █   ▀▀▀ █ █ ▀▀▀ ▀▀▀"
    local _tpad _tr
    for _tr in "$_tr1" "$_tr2" "$_tr3"; do
        _tpad=$(( width - ${#_tr} - 4 ))
        if (( _tpad < 0 )); then _tpad=0; fi
        printf "${BOLD_GREEN}║${RESET} ${BOLD_CYAN}%s${RESET}%*s ${BOLD_GREEN}║${RESET}\n" "$_tr" "$_tpad" ""
    done

    # Subtitle
    local now_ts
    now_ts=$(date '+%Y-%m-%d %H:%M:%S')
    local _page_ind=""
    if (( _DASH_TOTAL_PAGES > 1 )); then
        _page_ind="  │  Page $(( _DASH_PAGE + 1 ))/${_DASH_TOTAL_PAGES}"
    fi
    local sub_text="  Dashboard v${VERSION}${_page_ind}  │  ${now_ts}"
    printf "${BOLD_GREEN}║${RESET} ${DIM}%s${RESET}" "$sub_text"
    local sub_len=${#sub_text}
    local _sub_pad=$(( width - sub_len - 4 ))
    if (( _sub_pad < 0 )); then _sub_pad=0; fi
    printf '%*s' "$_sub_pad" ""
    printf " ${BOLD_GREEN}║${RESET}\n"

    printf "${BOLD_GREEN}"
    _dash_box_mid "$width"
    printf "${RESET}\n"

    # Column headers — fixed 70 inner width layout
    local hdr
    hdr=$(printf " ${BOLD}%-12s %-5s %-8s %-13s %-8s %-5s %-8s${RESET}" \
        "TUNNEL" "TYPE" "STATUS" "LOCAL" "TRAFFIC" "CONNS" "UPTIME")
    printf "${BOLD_GREEN}║${RESET}%s" "$hdr"
    local hdr_stripped
    hdr_stripped=$(_strip_ansi "$hdr")
    local hdr_len=${#hdr_stripped}
    local _hdr_pad=$(( width - hdr_len - 2 ))
    if (( _hdr_pad < 0 )); then _hdr_pad=0; fi
    printf '%*s' "$_hdr_pad" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    # Separator
    printf "${BOLD_GREEN}║${RESET}${DIM}"
    local _i
    for (( _i=0; _i<width-2; _i++ )); do printf "─"; done
    printf "${RESET}${BOLD_GREEN}║${RESET}\n"

    # Tunnel rows
    if (( _total > 0 )); then
        local _pidx
        for (( _pidx=0; _pidx<_total; _pidx++ )); do
            local _dname="${_all_profiles[$_pidx]}"
            has_tunnels=true

            # For ALL tunnels: track running status (needed by logs section)
            if is_tunnel_running "$_dname"; then
                _dash_alive["$_dname"]=1
            fi

            # Skip rendering + heavy work for tunnels not on current page
            if (( _pidx < _pg_start || _pidx >= _pg_end )); then
                continue
            fi
            _dash_page_names+=("$_dname")

            # Truncate long names for column alignment
            local _dname_display="$_dname"
            if (( ${#_dname_display} > 12 )); then
                _dname_display="${_dname_display:0:11}~"
            fi

            unset _dp 2>/dev/null || true
            local -A _dp=()
            load_profile "$_dname" _dp 2>/dev/null || true

            local dtype="${_dp[TUNNEL_TYPE]:-?}"
            local daddr="${_dp[LOCAL_BIND_ADDR]:-}:${_dp[LOCAL_PORT]:-}"

            # Populate port caches (for active connections on this page)
            local _is_running=false
            if [[ -n "${_dash_alive[$_dname]:-}" ]]; then
                _is_running=true
                _dash_port["$_dname"]="${_dp[LOCAL_PORT]:-}"
                local _olp_cache="${_dp[OBFS_LOCAL_PORT]:-0}"
                [[ "$_olp_cache" == "0" ]] && _olp_cache=""
                _dash_tls_port["$_dname"]="$_olp_cache"
            fi

            if [[ "$_is_running" == true ]]; then
                # Gather live stats
                local up_s up_str traffic rchar wchar total traf_str conns
                up_s=$(get_tunnel_uptime "$_dname" 2>/dev/null || true)
                : "${up_s:=0}"
                up_str=$(format_duration "$up_s")
                traffic=$(get_tunnel_traffic "$_dname" 2>/dev/null || true)
                : "${traffic:=0 0}"
                read -r rchar wchar <<< "$traffic"
                [[ "$rchar" =~ ^[0-9]+$ ]] || rchar=0
                [[ "$wchar" =~ ^[0-9]+$ ]] || wchar=0
                total=$(( rchar + wchar ))
                traf_str=$(format_bytes "$total")
                conns=$(get_tunnel_connections "$_dname" 2>/dev/null || true)
                : "${conns:=0}"

                # Record bandwidth for sparkline
                _bw_record "$_dname" "$rchar" "$wchar"

                local row
                row=$(printf " %-12s %-5s ${GREEN}● %-6s${RESET} %-13s %-8s %-5s %-8s" \
                    "$_dname_display" "${dtype^^}" "ALIVE" "$daddr" "$traf_str" "$conns" "$up_str")
                printf "${BOLD_GREEN}║${RESET}%s" "$row"
                local row_stripped
                row_stripped=$(_strip_ansi "$row")
                local row_len=${#row_stripped}
                local _row_pad=$(( width - row_len - 2 ))
                if (( _row_pad < 0 )); then _row_pad=0; fi
                printf '%*s' "$_row_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"

                # Sparkline row
                local -a rx_deltas=()
                local drx dtx
                while read -r drx dtx; do
                    rx_deltas+=("$drx")
                done < <(_bw_read_deltas "$_dname" 30)

                if [[ ${#rx_deltas[@]} -gt 2 ]]; then
                    local spark_str
                    spark_str=$(_sparkline "${rx_deltas[@]}")
                    local last_rate="${rx_deltas[-1]:-0}"
                    local rate_str
                    rate_str=$(format_bytes "$last_rate")

                    # [1] Peak speed from deltas
                    local _peak=0 _dv
                    for _dv in "${rx_deltas[@]}"; do
                        if (( _dv > _peak )); then _peak=$_dv; fi
                    done
                    local peak_str
                    peak_str=$(format_bytes "$_peak")

                    local spark_row
                    spark_row=$(printf " ${DIM}%-12s${RESET} ${CYAN}%s${RESET} ${DIM}%s/s${RESET}  ${DIM}│${RESET}  ${DIM}peak: %s/s${RESET}" \
                        "" "$spark_str" "$rate_str" "$peak_str")
                    printf "${BOLD_GREEN}║${RESET}%s" "$spark_row"
                    local spark_stripped
                    spark_stripped=$(_strip_ansi "$spark_row")
                    local spark_len=${#spark_stripped}
                    local _sp_pad=$(( width - spark_len - 2 ))
                    if (( _sp_pad < 0 )); then _sp_pad=0; fi
                    printf '%*s' "$_sp_pad" ""
                    printf "${BOLD_GREEN}║${RESET}\n"
                fi

                # [2] Route row — show hop chain
                local _route_str=""
                local _ssh_host="${_dp[SSH_HOST]:-}"
                local _jump="${_dp[JUMP_HOSTS]:-}"
                if [[ -n "$_jump" ]]; then
                    # Extract jump host IP (user@host:port → host)
                    local _jh="${_jump%%,*}"     # first jump host
                    _jh="${_jh#*@}"              # strip user@
                    _jh="${_jh%%:*}"             # strip :port
                    _route_str="route: → ${_jh} → ${_ssh_host}"
                elif [[ -n "$_ssh_host" ]]; then
                    _route_str="route: → ${_ssh_host}"
                fi
                if [[ -n "$_route_str" ]]; then
                    local _rr
                    _rr=$(printf " ${DIM}%-13s${RESET}${DIM}%s${RESET}" "" "$_route_str")
                    printf "${BOLD_GREEN}║${RESET}%s" "$_rr"
                    local _rr_s
                    _rr_s=$(_strip_ansi "$_rr")
                    local _rr_pad=$(( width - ${#_rr_s} - 2 ))
                    if (( _rr_pad < 0 )); then _rr_pad=0; fi
                    printf '%*s' "$_rr_pad" ""
                    printf "${BOLD_GREEN}║${RESET}\n"
                fi

                # [3] Auth + latency row
                local _auth_method="interactive"
                local _has_key=false _has_pass=false
                if [[ -n "${_dp[IDENTITY_KEY]:-}" ]] && [[ -f "${_dp[IDENTITY_KEY]:-}" ]]; then _has_key=true; fi
                if [[ -n "${_dp[SSH_PASSWORD]:-}" ]]; then _has_pass=true; fi
                if [[ "$_has_key" == true ]] && [[ "$_has_pass" == true ]]; then _auth_method="key+pass"
                elif [[ "$_has_key" == true ]]; then _auth_method="key"
                elif [[ "$_has_pass" == true ]]; then _auth_method="password"
                fi
                local _lat_rating="" _lat_icon=""
                if [[ "$_is_running" == true ]]; then
                    # Tunnel alive — skip slow TCP probe, show "active" directly
                    _lat_rating="active"
                    _lat_icon="${GREEN}▁▃▅▇${RESET}"
                else
                    _dash_latency_cached "$_dname" "${_dp[SSH_HOST]:-}" "${_dp[SSH_PORT]:-22}"
                    local _lat_info="${_DASH_LATENCY[$_dname]:-unknown ?}"
                    _lat_rating="${_lat_info%% *}"
                    _lat_icon="${_lat_info#* }"
                fi
                local _obfs_ind=""
                if [[ "${_dp[OBFS_MODE]:-none}" != "none" ]]; then
                    _obfs_ind="${DIM}│${RESET}${GREEN}tls${RESET}"
                    if [[ -n "${_dp[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_dp[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
                        _obfs_ind="${_obfs_ind}${DIM}+psk:${RESET}${GREEN}${_dp[OBFS_LOCAL_PORT]}${RESET}"
                    fi
                elif [[ -n "${_dp[OBFS_LOCAL_PORT]:-}" ]] && [[ "${_dp[OBFS_LOCAL_PORT]:-0}" != "0" ]]; then
                    _obfs_ind="${DIM}│${RESET}${GREEN}psk:${_dp[OBFS_LOCAL_PORT]}${RESET}"
                fi
                local _ar
                _ar=$(printf " ${DIM}%-13s${RESET}${DIM}auth:${RESET}${BOLD}%s${RESET} ${DIM}│${RESET}${DIM}lat:${RESET}%s${CYAN}%s${RESET} %s" \
                    "" "$_auth_method" "$_lat_rating" "$_lat_icon" "$_obfs_ind")
                printf "${BOLD_GREEN}║${RESET}%s" "$_ar"
                local _ar_s
                _ar_s=$(_strip_ansi "$_ar")
                local _ar_pad=$(( width - ${#_ar_s} - 2 ))
                if (( _ar_pad < 0 )); then _ar_pad=0; fi
                printf '%*s' "$_ar_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"

                # [4] Security row (only if dns or kill configured)
                local _show_sec=false
                if [[ "${_dp[DNS_LEAK_PROTECTION]:-}" == "true" ]] || [[ "${_dp[KILL_SWITCH]:-}" == "true" ]]; then
                    _show_sec=true
                fi
                if [[ "$_show_sec" == true ]]; then
                    local _dns_ind _kill_ind
                    if [[ "${_dp[DNS_LEAK_PROTECTION]:-}" == "true" ]]; then
                        _dns_ind="${GREEN}●${RESET}"
                    else
                        _dns_ind="${DIM}○${RESET}"
                    fi
                    if [[ "${_dp[KILL_SWITCH]:-}" == "true" ]]; then
                        _kill_ind="${GREEN}●${RESET}"
                    else
                        _kill_ind="${DIM}○${RESET}"
                    fi
                    local _sr
                    _sr=$(printf " ${DIM}%-13s${RESET}${DIM}security:${RESET} dns %s  kill %s" "" "$_dns_ind" "$_kill_ind")
                    printf "${BOLD_GREEN}║${RESET}%s" "$_sr"
                    local _sr_s
                    _sr_s=$(_strip_ansi "$_sr")
                    local _sr_pad=$(( width - ${#_sr_s} - 2 ))
                    if (( _sr_pad < 0 )); then _sr_pad=0; fi
                    printf '%*s' "$_sr_pad" ""
                    printf "${BOLD_GREEN}║${RESET}\n"
                fi
            else
                local row
                row=$(printf " ${DIM}%-12s %-5s ■ %-6s %-13s %-8s %-5s %-8s${RESET}" \
                    "$_dname_display" "${dtype^^}" "STOP" "$daddr" "-" "-" "-")
                printf "${BOLD_GREEN}║${RESET}%s" "$row"
                local row_stripped
                row_stripped=$(_strip_ansi "$row")
                local row_len=${#row_stripped}
                local _row_pad=$(( width - row_len - 2 ))
                if (( _row_pad < 0 )); then _row_pad=0; fi
                printf '%*s' "$_row_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"
            fi

        done
    fi

    if [[ "$has_tunnels" != true ]]; then
        local empty_msg=" No tunnels configured. Press 'c' to create one."
        printf "${BOLD_GREEN}║${RESET}${DIM}%s${RESET}" "$empty_msg"
        printf '%*s' "$(( width - ${#empty_msg} - 2 ))" ""
        printf "${BOLD_GREEN}║${RESET}\n"
    fi

    # [5] System Resources section
    printf "${BOLD_GREEN}"
    _dash_box_mid "$width"
    printf "${RESET}\n"

    local _sysres_hdr
    _sysres_hdr=$(printf " ${BOLD}System Resources${RESET}")
    printf "${BOLD_GREEN}║${RESET}%s" "$_sysres_hdr"
    local _sysres_hdr_s
    _sysres_hdr_s=$(_strip_ansi "$_sysres_hdr")
    local _sysres_hdr_pad=$(( width - ${#_sysres_hdr_s} - 2 ))
    if (( _sysres_hdr_pad < 0 )); then _sysres_hdr_pad=0; fi
    printf '%*s' "$_sysres_hdr_pad" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    _dash_system_resources
    local _sysres_data="$_DASH_SYSRES"
    local _sysres_row
    _sysres_row=$(printf "  ${DIM}%s${RESET}" "$_sysres_data")
    printf "${BOLD_GREEN}║${RESET}%s" "$_sysres_row"
    local _sysres_row_s
    _sysres_row_s=$(_strip_ansi "$_sysres_row")
    local _sysres_row_pad=$(( width - ${#_sysres_row_s} - 2 ))
    if (( _sysres_row_pad < 0 )); then _sysres_row_pad=0; fi
    printf '%*s' "$_sysres_row_pad" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    # [6] Active Connections section (current page only)
    if [[ "$has_tunnels" == true ]]; then
        local _any_alive=false _ac_lines=""
        local _acname
        for _acname in "${_dash_page_names[@]}"; do
            [[ -z "${_dash_alive[$_acname]:-}" ]] && continue
            _any_alive=true
            local _ac_port="${_dash_port[$_acname]:-}"
            if [[ -n "$_ac_port" ]]; then
                # Use cached TLS port from tunnel row loop (no re-load)
                local _ac_tls_port="${_dash_tls_port[$_acname]:-}"
                local _ac_data _ac_label
                if [[ -n "$_ac_tls_port" ]]; then
                    _ac_data=$(_dash_active_conns "$_ac_tls_port")
                    _ac_label=":${_ac_tls_port}"
                else
                    _ac_data=$(_dash_active_conns "$_ac_port")
                    _ac_label=":${_ac_port}"
                fi
                _ac_lines+="${_acname}|${_ac_label}|${_ac_data}"$'\n'
            fi
        done
        if [[ "$_any_alive" == true ]] && [[ -n "$_ac_lines" ]]; then
            printf "${BOLD_GREEN}"
            _dash_box_mid "$width"
            printf "${RESET}\n"

            local _ac_hdr
            _ac_hdr=$(printf " ${BOLD}Active Connections${RESET}")
            printf "${BOLD_GREEN}║${RESET}%s" "$_ac_hdr"
            local _ac_hdr_s
            _ac_hdr_s=$(_strip_ansi "$_ac_hdr")
            local _ac_hdr_pad=$(( width - ${#_ac_hdr_s} - 2 ))
            if (( _ac_hdr_pad < 0 )); then _ac_hdr_pad=0; fi
            printf '%*s' "$_ac_hdr_pad" ""
            printf "${BOLD_GREEN}║${RESET}\n"

            while IFS='|' read -r _ac_n _ac_p _ac_d; do
                [[ -z "$_ac_n" ]] && continue
                local _ac_row
                _ac_row=$(printf "  ${DIM}%s %s${RESET}  %s" "$_ac_n" "$_ac_p" "$_ac_d")
                printf "${BOLD_GREEN}║${RESET}%s" "$_ac_row"
                local _ac_row_s
                _ac_row_s=$(_strip_ansi "$_ac_row")
                local _ac_pad=$(( width - ${#_ac_row_s} - 2 ))
                if (( _ac_pad < 0 )); then _ac_pad=0; fi
                printf '%*s' "$_ac_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"
            done <<< "$_ac_lines"
        fi
    fi

    # [7] Recent Log section (last lines per active tunnel, max 2 total)
    if [[ "$has_tunnels" == true ]]; then
        local _log_lines="" _log_count=0
        local _lgname
        for _lgname in "${!_dash_alive[@]}"; do
            (( _log_count >= 2 )) && break
            local _lf
            _lf=$(_log_file "$_lgname")
            if [[ -f "$_lf" ]]; then
                local _ltail
                _ltail=$(tail -20 "$_lf" 2>/dev/null) || true
                while IFS= read -r _ll; do
                    [[ -z "$_ll" ]] && continue
                    (( _log_count >= 2 )) && break
                    # Skip normal SSH/SOCKS5 proxy noise
                    [[ "$_ll" == *"channel"*"open failed"* ]] && continue
                    [[ "$_ll" == *"Connection refused"* ]] && continue
                    [[ "$_ll" == *"Name or service not known"* ]] && continue
                    [[ "$_ll" == *"bind"*"Address already in use"* ]] && continue
                    [[ "$_ll" == *"cannot listen to"* ]] && continue
                    [[ "$_ll" == *"not request local forwarding"* ]] && continue
                    # Truncate long lines
                    local _ldisp="[${_lgname}] ${_ll}"
                    if (( ${#_ldisp} > width - 5 )); then
                        _ldisp="${_ldisp:0:$(( width - 8 ))}..."
                    fi
                    _log_lines+="${_ldisp}"$'\n'
                    ((++_log_count))
                done <<< "$_ltail"
            fi
        done
        if (( _log_count > 0 )); then
            printf "${BOLD_GREEN}"
            _dash_box_mid "$width"
            printf "${RESET}\n"

            local _lg_hdr
            _lg_hdr=$(printf " ${BOLD}Recent Log${RESET}")
            printf "${BOLD_GREEN}║${RESET}%s" "$_lg_hdr"
            local _lg_hdr_s
            _lg_hdr_s=$(_strip_ansi "$_lg_hdr")
            local _lg_hdr_pad=$(( width - ${#_lg_hdr_s} - 2 ))
            if (( _lg_hdr_pad < 0 )); then _lg_hdr_pad=0; fi
            printf '%*s' "$_lg_hdr_pad" ""
            printf "${BOLD_GREEN}║${RESET}\n"

            while IFS= read -r _lg_row; do
                [[ -z "$_lg_row" ]] && continue
                local _lgr
                _lgr=$(printf "  ${DIM}%s${RESET}" "$_lg_row")
                printf "${BOLD_GREEN}║${RESET}%s" "$_lgr"
                local _lgr_s
                _lgr_s=$(_strip_ansi "$_lgr")
                local _lgr_pad=$(( width - ${#_lgr_s} - 2 ))
                if (( _lgr_pad < 0 )); then _lgr_pad=0; fi
                printf '%*s' "$_lgr_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"
            done <<< "$_log_lines"
        fi
    fi

    # Reconnect summary section
    printf "${BOLD_GREEN}"
    _dash_box_mid "$width"
    printf "${RESET}\n"

    local rc_header
    rc_header=$(printf " ${BOLD}Reconnect Log${RESET}")
    printf "${BOLD_GREEN}║${RESET}%s" "$rc_header"
    local rc_hdr_stripped
    rc_hdr_stripped=$(_strip_ansi "$rc_header")
    printf '%*s' "$(( width - ${#rc_hdr_stripped} - 2 ))" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    if [[ -n "$profiles" ]]; then
        local _any_rc=false _rc_shown=0
        while IFS= read -r _rcname; do
            [[ -z "$_rcname" ]] && continue
            (( _rc_shown >= 2 )) && break
            local rc_total rc_last
            read -r rc_total rc_last <<< "$(_reconnect_stats "$_rcname")"
            if (( rc_total > 0 )); then
                _any_rc=true
                (( ++_rc_shown )) || true
                local rc_row
                local _rc_display="$_rcname"
                if (( ${#_rc_display} > 12 )); then _rc_display="${_rc_display:0:11}~"; fi
                rc_row=$(printf " ${DIM}%-12s${RESET}  reconnects: ${YELLOW}%d${RESET}  last: ${DIM}%s${RESET}" \
                    "$_rc_display" "$rc_total" "$rc_last")
                printf "${BOLD_GREEN}║${RESET}%s" "$rc_row"
                local rc_stripped
                rc_stripped=$(_strip_ansi "$rc_row")
                local _rc_pad=$(( width - ${#rc_stripped} - 2 ))
                if (( _rc_pad < 0 )); then _rc_pad=0; fi
                printf '%*s' "$_rc_pad" ""
                printf "${BOLD_GREEN}║${RESET}\n"
            fi
        done <<< "$profiles"
        if [[ "$_any_rc" != true ]]; then
            local no_rc=" ${DIM}No reconnections recorded${RESET}"
            printf "${BOLD_GREEN}║${RESET}%s" "$no_rc"
            local no_rc_stripped
            no_rc_stripped=$(_strip_ansi "$no_rc")
            printf '%*s' "$(( width - ${#no_rc_stripped} - 2 ))" ""
            printf "${BOLD_GREEN}║${RESET}\n"
        fi
    fi

    # System info row
    printf "${BOLD_GREEN}"
    _dash_box_mid "$width"
    printf "${RESET}\n"

    local pub_ip="${_DASH_PUB_IP:-unknown}"
    local _tg_indicator=""
    if _telegram_enabled; then
        _tg_indicator="  ${DIM}│${RESET}  ${DIM}TG:${RESET} ${GREEN}●${RESET}"
    fi
    local _speed_indicator=""
    if [[ -n "${_DASH_LAST_SPEED:-}" ]]; then
        _speed_indicator="  ${DIM}│${RESET}  ${CYAN}${_DASH_LAST_SPEED}${RESET}"
    fi
    local sys_row
    sys_row=$(printf " ${DIM}IP:${RESET} ${BOLD}%s${RESET}  ${DIM}│${RESET}  ${DIM}Refresh:${RESET} %ss%s%s  ${DIM}│${RESET}  ${DIM}%s${RESET}" \
        "$pub_ip" "$(config_get DASHBOARD_REFRESH 3)" "$_tg_indicator" "$_speed_indicator" "$(date '+%H:%M:%S')")
    printf "${BOLD_GREEN}║${RESET}%s" "$sys_row"
    local sys_stripped
    sys_stripped=$(_strip_ansi "$sys_row")
    local _sys_pad=$(( width - ${#sys_stripped} - 2 ))
    if (( _sys_pad < 0 )); then _sys_pad=0; fi
    printf '%*s' "$_sys_pad" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    # Footer with controls
    printf "${BOLD_GREEN}"
    _dash_box_mid "$width"
    printf "${RESET}\n"

    local ctrl_row
    local _pg_hint=""
    if (( _DASH_TOTAL_PAGES > 1 )); then
        _pg_hint=" ${DIM}│${RESET} ${CYAN}1${RESET}-${CYAN}${_DASH_TOTAL_PAGES}${RESET}${DIM}=page${RESET}"
    fi
    ctrl_row=$(printf " ${CYAN}s${RESET}=start ${CYAN}t${RESET}=stop ${CYAN}r${RESET}=restart ${CYAN}c${RESET}=create ${CYAN}p${RESET}=speed ${CYAN}g${RESET}=qlty ${CYAN}q${RESET}=quit%s" "$_pg_hint")
    printf "${BOLD_GREEN}║${RESET}%s" "$ctrl_row"
    local ctrl_stripped
    ctrl_stripped=$(_strip_ansi "$ctrl_row")
    local _ctrl_pad=$(( width - ${#ctrl_stripped} - 2 ))
    if (( _ctrl_pad < 0 )); then _ctrl_pad=0; fi
    printf '%*s' "$_ctrl_pad" ""
    printf "${BOLD_GREEN}║${RESET}\n"

    printf "${BOLD_GREEN}"
    _dash_box_bottom "$width"
    printf "${RESET}\n"
}

# ── Main dashboard loop ──

show_dashboard() {
    local refresh
    refresh=$(config_get DASHBOARD_REFRESH 3)
    if (( refresh < 1 )); then refresh=1; fi

    # Enter alternate screen buffer
    tput smcup 2>/dev/null || true
    # Hide cursor
    tput civis 2>/dev/null || true

    # Frame buffer for flicker-free rendering
    local _frame_file="${TMPDIR:-/tmp}/tf-dash-$$"
    : > "$_frame_file" 2>/dev/null || _frame_file="/tmp/tf-dash-$$"
    : > "$_frame_file"

    # Restore terminal on exit (normal return, Ctrl+C, or TERM)
    local _dash_cleanup_done=false
    _dash_exit() {
        if [[ "$_dash_cleanup_done" == true ]]; then return 0; fi
        _dash_cleanup_done=true
        rm -f "$_frame_file" "${TMP_DIR}/tg_cmd.lock" 2>/dev/null || true
        tput cnorm 2>/dev/null || true   # show cursor
        tput rmcup 2>/dev/null || true   # leave alternate screen
        trap - TSTP CONT
        trap cleanup INT TERM HUP QUIT   # restore global traps
    }
    trap '_dash_exit' RETURN
    local _dash_interrupted=false
    trap '_dash_exit; _dash_interrupted=true' INT
    trap '_dash_exit; _dash_interrupted=true' TERM
    trap '_dash_exit; _dash_interrupted=true' HUP
    trap '_dash_exit; _dash_interrupted=true' QUIT
    trap 'tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true' TSTP
    trap 'tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true' CONT

    # Get local IP once (instant, no network call)
    local _DASH_PUB_IP=""
    _DASH_PUB_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [[ -z "$_DASH_PUB_IP" ]]; then
        _DASH_PUB_IP=$(ip -4 route get 1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}') || true
    fi
    : "${_DASH_PUB_IP:=unknown}"
    local _dash_rot_count=0
    local _dash_tg_count=0

    while true; do
        if [[ "$_dash_interrupted" == true ]]; then break; fi
        # Periodic log rotation (~5 min at default 3s refresh)
        if (( ++_dash_rot_count >= 100 )); then
            rotate_logs 2>/dev/null || true
            _dash_rot_count=0
        fi
        # Poll Telegram bot commands in background (~every 3 refreshes ≈ 9s)
        if (( ++_dash_tg_count >= 3 )); then
            _tg_process_commands_bg || true
            _dash_tg_count=0
        fi
        # Buffered render: compute frame to file, then flush to screen in one shot
        _dash_render > "$_frame_file" 2>/dev/null || true
        tput cup 0 0 2>/dev/null || printf '\033[H'
        cat "$_frame_file" 2>/dev/null
        tput ed 2>/dev/null || true  # clear stale content below frame

        # Non-blocking read with timeout for refresh
        local key=""
        read -rsn1 -t "$refresh" key </dev/tty || true
        _drain_esc key

        case "$key" in
            q|Q)
                return 0 ;;
            s|S)
                # Start a tunnel (mini-selector)
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                _menu_start_tunnel || true
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            t|T)
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                _menu_stop_tunnel || true
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            r|R)
                # Restart all running tunnels
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                local _dr_profiles
                _dr_profiles=$(list_profiles)
                if [[ -n "$_dr_profiles" ]]; then
                    while IFS= read -r _dr_name; do
                        [[ -z "$_dr_name" ]] && continue
                        if is_tunnel_running "$_dr_name"; then
                            restart_tunnel "$_dr_name" || true
                        fi
                    done <<< "$_dr_profiles"
                fi
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            c|C)
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                wizard_create_profile || true
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            p|P)
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                _speed_test || true
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            g|G)
                tput cnorm 2>/dev/null || true
                tput rmcup 2>/dev/null || true
                printf "\n  ${BOLD}Connection Quality Check${RESET}\n\n" >/dev/tty
                local _gq_profiles
                _gq_profiles=$(list_profiles)
                if [[ -n "$_gq_profiles" ]]; then
                    while IFS= read -r _gq_name; do
                        [[ -z "$_gq_name" ]] && continue
                        local _gq_host
                        _gq_host=$(get_profile_field "$_gq_name" "SSH_HOST" 2>/dev/null) || true
                        local _gq_port
                        _gq_port=$(get_profile_field "$_gq_name" "SSH_PORT" 2>/dev/null) || true
                        : "${_gq_port:=22}"
                        if [[ -n "$_gq_host" ]]; then
                            local _gq_rating
                            _gq_rating=$(_connection_quality "$_gq_host" "$_gq_port" 2>/dev/null) || true
                            : "${_gq_rating:=unknown}"
                            printf "  %-16s %s  %s → %s:%s\n" "$_gq_name" "$(_quality_icon "$_gq_rating")" "$_gq_rating" "$_gq_host" "$_gq_port" >/dev/tty
                        fi
                    done <<< "$_gq_profiles"
                else
                    printf "  ${DIM}No profiles configured${RESET}\n" >/dev/tty
                fi
                printf "\n" >/dev/tty
                _press_any_key || true
                tput smcup 2>/dev/null || true
                tput civis 2>/dev/null || true
                ;;
            \[|,)
                # Previous page
                if (( _DASH_PAGE > 0 )); then _DASH_PAGE=$(( _DASH_PAGE - 1 )); fi
                ;;
            \]|.)
                # Next page
                if (( _DASH_PAGE < _DASH_TOTAL_PAGES - 1 )); then _DASH_PAGE=$(( _DASH_PAGE + 1 )); fi
                ;;
            [1-9])
                # Jump to page N
                local _target_pg=$(( key - 1 ))
                if (( _target_pg < _DASH_TOTAL_PAGES )); then
                    _DASH_PAGE=$_target_pg
                fi
                ;;
            *) true ;;
        esac
    done
}

# ============================================================================
# INSTALLER
# ============================================================================

install_tunnelforge() {
    show_banner >/dev/tty
    log_info "Installing ${APP_NAME} v${VERSION}..."

    check_root "install" || return 1
    detect_os

    init_directories || { log_error "Failed to create directories"; return 1; }

    # Copy script
    local script_path dest
    script_path="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)/$(basename "$0")"
    dest="${INSTALL_DIR}/tunnelforge.sh"

    if [[ "$script_path" != "$dest" ]]; then
        cp "$script_path" "$dest"
        chmod +x "$dest"
        log_success "Installed to ${dest}"
    fi

    if ln -sf "$dest" "$BIN_LINK" 2>/dev/null; then
        log_success "Created symlink: ${BIN_LINK}"
    else
        log_warn "Could not create symlink: ${BIN_LINK}"
    fi

    check_dependencies || log_warn "Some dependencies could not be installed"

    if [[ ! -f "$MAIN_CONFIG" ]]; then
        if save_settings; then
            log_success "Created config: ${MAIN_CONFIG}"
        else
            log_warn "Could not create config file — using defaults"
        fi
    fi

    printf "\n"
    printf "${BOLD_GREEN}"
    printf "  ╔══════════════════════════════════════════════════════════╗\n"
    printf "  ║         %s installed successfully!            ║\n" "$APP_NAME"
    printf "  ╠══════════════════════════════════════════════════════════╣\n"
    printf "  ║                                                        ║\n"
    printf "  ║  Commands:                                             ║\n"
    printf "  ║    tunnelforge menu       Interactive menu             ║\n"
    printf "  ║    tunnelforge create     Create a tunnel              ║\n"
    printf "  ║    tunnelforge help       Show all commands            ║\n"
    printf "  ║                                                        ║\n"
    printf "  ╚══════════════════════════════════════════════════════════╝\n"
    printf "${RESET}\n"

    # Offer to launch interactive menu
    local _ans=""
    printf "  Launch interactive menu now? [y/N] " >/dev/tty
    read -rsn1 _ans </dev/tty || true
    printf "\n" >/dev/tty
    if [[ "$_ans" == "y" || "$_ans" == "Y" ]]; then
        detect_os; load_settings
        show_menu || true
    fi
}

# ============================================================================
# CLI ENTRY POINT
# ============================================================================

is_installed() {
    [[ -f "${INSTALL_DIR}/tunnelforge.sh" && -f "$MAIN_CONFIG" ]]
}

cli_main() {
    local command="${1:-}"
    shift 2>/dev/null || true

    # Ensure runtime directories exist for all commands
    init_directories 2>/dev/null || true

    case "$command" in
        # ── Tunnel commands ──
        start)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge start <name>"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            detect_os; load_settings; start_tunnel "$1" ;;
        stop)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge stop <name>"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            load_settings; stop_tunnel "$1" || true ;;
        restart)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge restart <name>"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            detect_os; load_settings; restart_tunnel "$1" || true ;;
        start-all)
            detect_os; load_settings; start_all_tunnels || true ;;
        stop-all)
            load_settings; stop_all_tunnels || true ;;
        status)
            load_settings; show_status || true ;;

        # ── Profile commands ──
        list|ls)
            load_settings
            local profiles
            profiles=$(list_profiles)
            if [[ -z "$profiles" ]]; then
                log_info "No profiles found. Run 'tunnelforge create' to get started."
            else
                printf "\n${BOLD}Tunnel Profiles:${RESET}\n"
                print_line "─" 50
                while IFS= read -r _ls_name; do
                    local _ls_ptype _ls_status
                    _ls_ptype=$(get_profile_field "$_ls_name" "TUNNEL_TYPE" 2>/dev/null) || true
                    if is_tunnel_running "$_ls_name"; then
                        _ls_status="${GREEN}● running${RESET}"
                    else
                        _ls_status="${DIM}■ stopped${RESET}"
                    fi
                    printf "  %-20s %-10s %b\n" "$_ls_name" "${_ls_ptype:-?}" "$_ls_status"
                done <<< "$profiles"
                printf "\n"
            fi ;;
        create|new)
            detect_os; load_settings
            setup_wizard || true ;;
        delete)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge delete <name>"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            load_settings
            if confirm_action "Delete profile '${1}'?"; then
                delete_profile "$1" || true
            fi ;;

        # ── Display commands ──
        dashboard|dash)
            if ! : >/dev/tty 2>/dev/null; then
                log_error "Dashboard requires an interactive terminal (/dev/tty not available)"
                return 1
            fi
            load_settings
            show_dashboard || true ;;
        menu)
            detect_os; load_settings
            show_menu ;;
        logs)
            load_settings
            local target="${1:-}"
            if [[ -n "$target" ]]; then
                validate_profile_name "$target" || { log_error "Invalid profile name"; return 1; }
                local lf; lf=$(_log_file "$target")
                if [[ -f "$lf" ]]; then
                    tail -f "$lf" || true
                else
                    log_error "No logs for '${target}'"
                fi
            else
                local ml="${LOG_DIR}/${APP_NAME_LOWER}.log"
                if [[ -f "$ml" ]]; then
                    tail -f "$ml" || true
                else
                    log_info "No logs found"
                fi
            fi ;;

        # ── Security commands ──
        audit|security)
            load_settings; security_audit || true ;;
        key-gen)
            load_settings
            local ktype="${1:-ed25519}"
            case "$ktype" in
                ed25519|rsa|ecdsa) ;;
                *) log_error "Unsupported key type '${ktype}' (use: ed25519, rsa, ecdsa)"; return 1 ;;
            esac
            generate_ssh_key "$ktype" "${HOME}/.ssh/id_${ktype}" || true ;;
        key-deploy)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge key-deploy <name>"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            load_settings; deploy_ssh_key "$1" || true ;;
        fingerprint)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge fingerprint <host> [port]"; return 1; }
            load_settings; verify_host_fingerprint "$1" "${2:-22}" || true ;;

        # ── Telegram commands ──
        telegram|tg)
            load_settings
            local tg_action="${1:-status}"
            case "$tg_action" in
                setup)   telegram_setup || true ;;
                test)    telegram_test || true ;;
                status)  telegram_status || true ;;
                send)    shift; [[ -z "$*" ]] && { log_error "Usage: tunnelforge telegram send <message>"; return 1; }; _telegram_send "$*" || { log_error "Send failed (is Telegram configured?)"; return 1; } ;;
                report)  telegram_send_status || true ;;
                share)   shift; telegram_share_client "${1:-}" || true ;;
                *)       log_error "Usage: tunnelforge telegram [setup|test|status|send|report|share]"; return 1 ;;
            esac ;;

        # ── System commands ──
        health)
            load_settings; security_audit || true ;;
        server-setup)
            detect_os; load_settings
            server_setup || true ;;
        obfs-setup|obfuscate)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge obfs-setup <profile>"; return 1; }
            detect_os; load_settings
            _obfs_setup_stunnel "$1" || true ;;
        client-config)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge client-config <profile>"; return 1; }
            detect_os; load_settings
            local -A _cc_prof=()
            load_profile "$1" _cc_prof || { log_error "Cannot load profile '$1'"; return 1; }
            if [[ -z "${_cc_prof[OBFS_LOCAL_PORT]:-}" ]] || [[ "${_cc_prof[OBFS_LOCAL_PORT]:-0}" == "0" ]]; then
                log_error "Profile '$1' has no inbound TLS configured"
                printf "${DIM}Enable it in the wizard or set OBFS_LOCAL_PORT and OBFS_PSK in the profile.${RESET}\n"
                return 1
            fi
            _obfs_show_client_config "$1" _cc_prof || true ;;
        client-script)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge client-script <profile> [output-file]"; return 1; }
            detect_os; load_settings
            local -A _cs_prof=()
            load_profile "$1" _cs_prof || { log_error "Cannot load profile '$1'"; return 1; }
            _obfs_generate_client_script "$1" _cs_prof "${2:-}" || true
            _obfs_generate_client_script_win "$1" _cs_prof "" || true ;;
        service)
            [[ -z "${1:-}" ]] && { log_error "Usage: tunnelforge service <name> [enable|disable|status|remove]"; return 1; }
            validate_profile_name "$1" || { log_error "Invalid profile name"; return 1; }
            detect_os; load_settings
            local svc_name="$1" svc_action="${2:-}"
            case "$svc_action" in
                enable)  enable_service "$svc_name" || true ;;
                disable) disable_service "$svc_name" || true ;;
                status)  service_status "$svc_name" || true ;;
                remove)  remove_service "$svc_name" || true ;;
                "")      generate_service "$svc_name" || true ;;
                *)       log_error "Unknown action: ${svc_action}"; return 1 ;;
            esac ;;
        backup)
            load_settings
            backup_tunnelforge || true ;;
        restore)
            load_settings
            restore_tunnelforge "${1:-}" || true ;;
        uninstall)
            detect_os; load_settings
            uninstall_tunnelforge ;;
        install)
            install_tunnelforge ;;

        # ── Info commands ──
        version|-v|--version)
            show_version ;;
        help|-h|--help)
            show_help ;;

        # ── Default: first run or menu ──
        "")
            if is_installed; then
                detect_os; load_settings
                show_menu
            else
                install_tunnelforge
                if is_installed; then
                    _press_any_key
                    detect_os; load_settings
                    show_menu
                fi
            fi ;;

        *)
            log_error "Unknown command: ${command}"
            log_info  "Run 'tunnelforge help' for available commands"
            return 1 ;;
    esac
}

# ============================================================================
# MAIN
# ============================================================================

main() { cli_main "$@"; }
main "$@"
