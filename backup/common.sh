#!/usr/bin/env bash
# backup/common.sh — Shared utilities for backup and restore scripts.
#
# Source this file AFTER declaring ENV_FILE, DOCKER_COMPOSE_PATH, and LOG_FILE
# in the calling script.

[[ -n "${_BACKUP_COMMON_LOADED:-}" ]] && return 0
readonly _BACKUP_COMMON_LOADED=1

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Read a value from the .env file (where setup.sh writes actual credentials).
# Falls back to docker compose config for the default value.
read_env_value() {
    local key="$1"
    local value=""

    # Primary: read from .env (contains actual generated secrets)
    if [[ -f "${ENV_FILE}" ]]; then
        value=$(grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"\r")
    fi

    # Fallback: try docker compose config (resolves all variables)
    if [[ -z "$value" ]] && command -v docker &>/dev/null; then
        value=$(docker compose -f "${DOCKER_COMPOSE_PATH}" config 2>/dev/null \
            | grep -A0 "${key}" | head -n1 | sed 's/.*: //' | tr -d "'\"\r" || true)
    fi

    echo "$value"
}
