#!/usr/bin/env bash
# lib/env.sh — Helpers for reading/writing .env files and loading config files.
# Requires: lib/common.sh

[[ -n "${_LIB_ENV_LOADED:-}" ]] && return 0
readonly _LIB_ENV_LOADED=1

# ── Write or update a key in a KEY=VALUE env file ───────────────────────────

_write_env_key() {
    local env_file="$1" key="$2" value="$3"

    if grep -q "^${key}=" "$env_file"; then
        # Pass the value via the environment (ENVIRON), not `-v v=`, so awk does
        # not interpret backslash escapes inside the value (e.g. a credential
        # containing a literal backslash would otherwise be mangled).
        # umask 077: the temp copy holds secrets too
        ( umask 077
          _ENV_VALUE="$value" awk -v k="$key" '{
              if (index($0, k "=") == 1) print k "=" ENVIRON["_ENV_VALUE"]
              else print
          }' "$env_file" > "${env_file}.tmp" )
        # cat (not mv) keeps the target's inode, owner and permissions
        cat "${env_file}.tmp" > "$env_file"
        rm -f "${env_file}.tmp"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

# ── Write or update a key in the deployment .env file ───────────────────────

setup_env_key() {
    local key="$1" value="$2"
    local env_file="${CONFIG[DEPLOY_DIR]}/.env"

    if [[ ! -f "$env_file" ]]; then
        mkdir -p "${CONFIG[DEPLOY_DIR]}"
        cp "${SCRIPT_DIR}/config/${CONFIG[DOCKER_ENV_FILE]}" "$env_file"
    fi

    _write_env_key "$env_file" "$key" "$value"
}

# ── Traefik's private env file ──────────────────────────────────────────────
#
# Traefik only needs the DNS-01 provider credentials, so it gets its own
# env file (chmod 600) instead of the whole .env, which also holds the
# database passwords, CTFd's SECRET_KEY and the Zync JWT secret.

traefik_env_file() {
    printf '%s' "${CONFIG[DEPLOY_DIR]}/traefik.env"
}

# Create the file if missing. Docker Compose refuses to start when an env_file
# is absent, so this also runs for HTTP-only deployments (empty file).
ensure_traefik_env_file() {
    local env_file
    env_file="$(traefik_env_file)"
    if [[ ! -f "$env_file" ]]; then
        mkdir -p "${CONFIG[DEPLOY_DIR]}"
        ( umask 077; printf '# DNS-01 provider credentials for Traefik (written by setup.sh)\n' > "$env_file" )
    fi
    chmod 600 "$env_file"
}

setup_traefik_env_key() {
    ensure_traefik_env_file
    _write_env_key "$(traefik_env_file)" "$1" "$2"
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

# ── Is the Galvanize instancer hosted on this machine? ──────────────────────
#
# is_local_instancer
#   Returns 0 when Galvanize deploys challenges on this host, i.e. when images
#   built here are the ones it will run. Detection order:
#     1. INSTANCER_MODE written to <working>/deploy/.env by setup.sh:
#        "local" → yes, "external" → no, "none" → keep looking (Galvanize may
#        have been deployed separately on this host later).
#     2. Deployments made before INSTANCER_MODE existed: GALVANIZE_CONFIG_PATH,
#        only set for a local instancer, pointing at an existing file.
#     3. A running galvanize-instancer container (standalone Galvanize).
#   Sets _INSTANCER_DETECTION to a human-readable reason for logging.

_INSTANCER_DETECTION=""

is_local_instancer() {
    local env_file="${CONFIG[WORKING_DIR]}/deploy/.env"
    local mode="" galvanize_config=""

    if [[ -f "$env_file" ]]; then
        mode="$(read_env_value "INSTANCER_MODE" "$env_file")"
        galvanize_config="$(read_env_value "GALVANIZE_CONFIG_PATH" "$env_file")"
    fi

    case "$mode" in
        local)
            _INSTANCER_DETECTION="INSTANCER_MODE=local in $env_file"
            return 0 ;;
        external)
            _INSTANCER_DETECTION="INSTANCER_MODE=external in $env_file"
            return 1 ;;
        "")
            if [[ -n "$galvanize_config" && -f "$galvanize_config" ]]; then
                _INSTANCER_DETECTION="local Galvanize config found at $galvanize_config"
                return 0
            fi
            ;;
    esac

    if command -v docker &>/dev/null \
        && [[ -n "$(docker ps -q --filter 'name=^/?galvanize-instancer$' 2>/dev/null)" ]]; then
        _INSTANCER_DETECTION="galvanize-instancer container running on this host"
        return 0
    fi

    _INSTANCER_DETECTION="no local Galvanize instancer detected"
    return 1
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
