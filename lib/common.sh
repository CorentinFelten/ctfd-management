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
    rm -f /tmp/ctf_build_*.log /tmp/ctf_status_*.txt 2>/dev/null || true
    [[ -n "${_CHALL_YAML_CACHE_DIR:-}" ]] && rm -rf "$_CHALL_YAML_CACHE_DIR" 2>/dev/null || true

    if [[ "$_SCRIPT_COMPLETED" != "true" && $exit_code -ne 0 ]]; then
        printf '\n%b[FATAL]%b Script exited unexpectedly (exit code %d).\n' \
            "$RED" "$NC" "$exit_code" >&2
        printf '%b[FATAL]%b Last executed near: %s\n' \
            "$RED" "$NC" "${BASH_COMMAND:-unknown}" >&2
    fi
}
trap _run_cleanup EXIT INT TERM

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

is_git_url() {
    local input="$1"
    [[ $input =~ ^(https?|git|ssh):// || $input =~ \.git$ || $input =~ ^git@ ]]
}
