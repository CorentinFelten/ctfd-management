#!/usr/bin/env bash
# lib/env.sh — Helpers for reading/writing .env files and loading config files.
# Requires: lib/common.sh

[[ -n "${_LIB_ENV_LOADED:-}" ]] && return 0
readonly _LIB_ENV_LOADED=1

# ── Write or update a key in the .env file ──────────────────────────────────

setup_env_key() {
    local key="$1" value="$2"
    local env_file="${SCRIPT_DIR}/.env"

    if [[ ! -f "$env_file" ]]; then
        cp "${SCRIPT_DIR}/${CONFIG[DOCKER_ENV_FILE]}" "$env_file"
    fi

    if grep -q "^${key}=" "$env_file"; then
        awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$2=v}{print}' \
            "$env_file" > "${env_file}.tmp"
        mv "${env_file}.tmp" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

# ── Read a value from the .env file (used by backup/restore) ────────────────

read_env_value() {
    local key="$1"
    local env_file="${2:-${ENV_FILE:-}}"
    local compose_file="${3:-${DOCKER_COMPOSE_PATH:-}}"
    local value=""

    # Primary: read from .env
    if [[ -n "$env_file" && -f "$env_file" ]]; then
        value=$(grep "^${key}=" "$env_file" 2>/dev/null \
            | head -n1 | cut -d= -f2- | tr -d "'\"\r")
    fi

    # Fallback: docker compose config
    if [[ -z "$value" && -n "$compose_file" ]] && command -v docker &>/dev/null; then
        value=$(docker compose -f "$compose_file" config 2>/dev/null \
            | grep -A0 "${key}" | head -n1 | sed 's/.*: //' | tr -d "'\"\r" || true)
    fi

    printf '%s' "$value"
}

# ── Load a KEY=VALUE config file into the CONFIG associative array ───────────

load_config_file() {
    local config_file="$1"
    [[ -f "$config_file" ]] || error_exit "Config file not found: $config_file"

    log_info "Loading config from: $config_file"

    local key value
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Strip surrounding quotes
        value="${value%\"}" ; value="${value#\"}"
        value="${value%\'}" ; value="${value#\'}"

        if [[ -n "${CONFIG[$key]+_}" ]]; then
            CONFIG[$key]="$value"
            log_debug "Config loaded: $key=$value"
        fi
    done < <(grep -v '^[[:space:]]*#' "$config_file" | grep -v '^[[:space:]]*$')
}
