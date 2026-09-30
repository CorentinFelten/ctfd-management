#!/usr/bin/env bash
# lib/common.sh — Shared fundamentals: bash guard, colors, logging, error handling, utilities.
# Source this file at the top of every entry-point script.

# Bash 4.4+ required for associative arrays and nameref
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    echo "Error: This script requires Bash 4.4 or newer (found: ${BASH_VERSION})" >&2
    exit 1
fi

# Guard against double-sourcing
[[ -n "${_LIB_COMMON_LOADED:-}" ]] && return 0
readonly _LIB_COMMON_LOADED=1

# ── Colors (only when stderr is a terminal) ──────────────────────────────────

if [[ -t 2 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' NC=''
fi

# ── Logging (all output to stderr) ───────────────────────────────────────────

log_info()    { printf '%b[INFO]%b %s\n'    "$BLUE"   "$NC" "$*" >&2; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$GREEN"  "$NC" "$*" >&2; }
log_warning() { printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error()   { printf '%b[ERROR]%b %s\n'   "$RED"    "$NC" "$*" >&2; }

log_debug() {
    [[ "${_DEBUG:-false}" == "true" ]] && printf '%b[DEBUG]%b %s\n' "$PURPLE" "$NC" "$*" >&2
    return 0
}

error_exit() {
    log_error "$1"
    _SCRIPT_COMPLETED=true
    exit "${2:-1}"
}

# ── Cleanup trap ─────────────────────────────────────────────────────────────

_cleanup_files=()
_SCRIPT_COMPLETED=false

mark_completed() { _SCRIPT_COMPLETED=true; }

_run_cleanup() {
    local exit_code=$?
    local f
    for f in "${_cleanup_files[@]}"; do
        rm -rf "$f" 2>/dev/null || true
    done
    # Build logs are not removed here: successful builds delete their own, and
    # a failed build's log is what the error message points the user to.
    rm -f /tmp/ctf_status_*.txt 2>/dev/null || true
    [[ -n "${_CHALL_YAML_CACHE_DIR:-}" ]] && rm -rf "$_CHALL_YAML_CACHE_DIR" 2>/dev/null || true

    if [[ "$_SCRIPT_COMPLETED" != "true" && $exit_code -ne 0 ]]; then
        printf '\n%b[FATAL]%b Script exited unexpectedly (exit code %d).\n' \
            "$RED" "$NC" "$exit_code" >&2
        printf '%b[FATAL]%b Last executed near: %s\n' \
            "$RED" "$NC" "${BASH_COMMAND:-unknown}" >&2
    fi
}
trap _run_cleanup EXIT INT TERM

# ── Prompts ──────────────────────────────────────────────────────────────────

# Set to "true" by --yes: every prompt takes its default answer.
_ASSUME_YES="${_ASSUME_YES:-false}"

# require_terminal WHAT — exit with a clear message when a prompt cannot be
# shown (no terminal on stdin, e.g. CI or cron), instead of letting `read`
# hit end of input and trip `set -e`.
require_terminal() {
    [[ -t 0 ]] && return 0
    error_exit "Cannot ask for $1: no terminal is attached. Re-run with --yes to accept the default answers."
}

# ask_yes_no QUESTION DEFAULT — DEFAULT is y or n. Returns 0 for yes.
# With --yes the default is taken without asking.
ask_yes_no() {
    local question="$1" default="${2,,}" hint reply
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"

    if [[ "$_ASSUME_YES" == "true" ]]; then
        log_info "$question $hint → $default (--yes)"
        [[ "$default" == "y" ]]
        return
    fi

    require_terminal "\"$question\""
    while true; do
        read -rp "$question $hint " -n 1 reply || reply=""
        [[ -n "$reply" ]] && echo >&2
        case "${reply:-$default}" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
        esac
        log_warning "Please answer y or n."
    done
}

# ── Utility helpers ──────────────────────────────────────────────────────────

generate_password() {
    local length="${1:-15}"
    # Capture into a variable and slice, rather than piping into `head -c`.
    # Under `set -o pipefail`, head closing the pipe early can surface openssl's
    # SIGPIPE (141) as the function's exit status and trip `set -e` in callers.
    local raw
    raw="$(openssl rand -base64 256 | tr -d '+/=\n')"
    printf '%s' "${raw:0:length}"
}

# invoking_user_home — home directory of the user who ran the script (the sudo
# caller when escalated), read from the passwd database. Running directly as
# root therefore gives /root rather than a made-up /home/root.
invoking_user_home() {
    local user="${SUDO_USER:-${USER:-$(id -un)}}" home=""
    if command -v getent &>/dev/null; then
        home="$(getent passwd "$user" | cut -d: -f6)"
    fi
    # No passwd entry (or no getent, e.g. macOS): $HOME is right unless sudo changed it
    [[ -z "$home" && -z "${SUDO_USER:-}" ]] && home="${HOME:-}"
    printf '%s' "${home:-/home/$user}"
}

# sed_escape_replacement STRING — escape STRING for use as the replacement of
# an `s|pattern|replacement|` sed command (backslash, the | delimiter and &,
# which would otherwise insert the matched text).
sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

is_ip_address() {
    local input="$1"

    # IPv4
    if [[ $input =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local -a octets
        IFS='.' read -ra octets <<< "$input"
        local octet
        for octet in "${octets[@]}"; do
            ((octet > 255)) && return 1
        done
        return 0
    fi

    # IPv6
    if [[ $input =~ ^[0-9a-fA-F:]+$ && $input == *:* ]]; then
        return 0
    fi

    return 1
}

# is_loopback_or_unspecified HOST — true for localhost names, 127.0.0.0/8,
# ::1 and the unspecified addresses 0.0.0.0 / ::, none of which name this
# server from anywhere else (players, or containers on this host).
is_loopback_or_unspecified() {
    local host="${1,,}"
    host="${host#[}"; host="${host%]}"

    [[ "$host" == "localhost" || "$host" == *.localhost ]] && return 0
    [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "::1" ]] && return 0
    is_ip_address "$host" && [[ "$host" == 127.* ]]
}

is_git_url() {
    local input="$1"
    [[ $input =~ ^(https?|git|ssh):// || $input =~ \.git$ || $input =~ ^git@ ]]
}
