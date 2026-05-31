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

    # Fallback: render the compose config and read the variable from a service's
    # environment. Prefer JSON + jq (handles both map and list env forms); fall
    # back to an anchored awk scan of the rendered YAML when jq is unavailable.
    if [[ -z "$value" && -f "${DOCKER_COMPOSE_PATH}" ]] && command -v docker &>/dev/null; then
        if command -v jq &>/dev/null; then
            value=$(docker compose -f "${DOCKER_COMPOSE_PATH}" config --format json 2>/dev/null \
                | jq -r --arg k "$key" '
                    [ .services[]?.environment
                      | if type == "object" then .[$k]
                        elif type == "array" then (.[] | select(startswith($k + "=")) | sub("^[^=]+="; ""))
                        else empty end ]
                    | map(select(. != null and . != "")) | first // ""' 2>/dev/null)
        else
            value=$(docker compose -f "${DOCKER_COMPOSE_PATH}" config 2>/dev/null \
                | awk -v k="$key" '$0 ~ "^[[:space:]]*"k":[[:space:]]" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
        fi
        value="$(printf '%s' "$value" | tr -d "'\"\r")"
    fi

    printf '%s' "$value"
}
