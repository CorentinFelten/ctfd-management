#!/usr/bin/env bash
# lib/env.sh — Helpers for reading/writing .env files and loading config files.
# Requires: lib/common.sh

[[ -n "${_LIB_ENV_LOADED:-}" ]] && return 0
readonly _LIB_ENV_LOADED=1

# ── Write or update a key in the .env file ──────────────────────────────────

setup_env_key() {
    local key="$1" value="$2"
    local env_file="${CONFIG[DEPLOY_DIR]}/.env"

    if [[ ! -f "$env_file" ]]; then
        mkdir -p "${CONFIG[DEPLOY_DIR]}"
        cp "${SCRIPT_DIR}/config/${CONFIG[DOCKER_ENV_FILE]}" "$env_file"
    fi

    if grep -q "^${key}=" "$env_file"; then
        awk -v k="$key" -v v="$value" '{
            if (index($0, k "=") == 1) print k "=" v
            else print
        }' "$env_file" > "${env_file}.tmp"
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

    # Fallback: render the compose config and read the variable from a service's
    # environment. Prefer JSON + jq (handles both map and list env forms); fall
    # back to an anchored awk scan of the rendered YAML when jq is unavailable.
    if [[ -z "$value" && -n "$compose_file" && -f "$compose_file" ]] && command -v docker &>/dev/null; then
        if command -v jq &>/dev/null; then
            value=$(docker compose -f "$compose_file" config --format json 2>/dev/null \
                | jq -r --arg k "$key" '
                    [ .services[]?.environment
                      | if type == "object" then .[$k]
                        elif type == "array" then (.[] | select(startswith($k + "=")) | sub("^[^=]+="; ""))
                        else empty end ]
                    | map(select(. != null and . != "")) | first // ""' 2>/dev/null)
        else
            value=$(docker compose -f "$compose_file" config 2>/dev/null \
                | awk -v k="$key" '$0 ~ "^[[:space:]]*"k":[[:space:]]" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
        fi
        value="$(printf '%s' "$value" | tr -d "'\"\r")"
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
