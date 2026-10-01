#!/usr/bin/env bash
# lib/env.sh — Helpers for reading/writing .env files and loading config files.
# Requires: lib/common.sh

[[ -n "${_LIB_ENV_LOADED:-}" ]] && return 0
readonly _LIB_ENV_LOADED=1

# ── Write or update keys in a KEY=VALUE env file ────────────────────────────

# _write_env_keys FILE KEY VALUE [KEY VALUE...]
#   Sets every KEY in one pass over FILE: existing KEY= lines are updated in
#   place, other lines are kept as they are (including keys added by hand),
#   and keys not in FILE yet are appended in the order given. Values must not
#   contain newlines.
_write_env_keys() {
    local env_file="$1"; shift
    (( $# % 2 == 0 )) || { log_error "_write_env_keys: KEY VALUE pairs expected"; return 1; }

    # Values go through a file read by awk, not `-v`, so awk does not
    # interpret backslash escapes in them. umask 077: both files hold secrets.
    local updates="${env_file}.updates" tmp="${env_file}.tmp"
    (
        umask 077
        : > "$updates"
        while (( $# )); do
            printf '%s=%s\n' "$1" "$2" >> "$updates"
            shift 2
        done
        awk '
            NR == FNR {
                i = index($0, "="); k = substr($0, 1, i - 1)
                if (!(k in value)) order[++n] = k
                value[k] = substr($0, i + 1)
                next
            }
            {
                i = index($0, "=")
                if (i > 1) {
                    k = substr($0, 1, i - 1)
                    if (k in value) {
                        if (!(k in done)) print k "=" value[k]
                        done[k] = 1
                        next
                    }
                }
                print
            }
            END {
                for (j = 1; j <= n; j++)
                    if (!(order[j] in done)) print order[j] "=" value[order[j]]
            }
        ' "$updates" "$env_file" > "$tmp"
    )
    # cat (not mv) keeps the target's inode, owner and permissions
    cat "$tmp" > "$env_file"
    rm -f "$tmp" "$updates"
}

# ── Write or update keys in the deployment .env file ─────────────────────────

# setup_env_keys KEY VALUE [KEY VALUE...] — creates .env from the template
# for the deployment mode if needed, then sets all the keys in one pass
setup_env_keys() {
    local env_file="${CONFIG[DEPLOY_DIR]}/.env"

    if [[ ! -f "$env_file" ]]; then
        mkdir -p "${CONFIG[DEPLOY_DIR]}"
        cp "${SCRIPT_DIR}/config/${CONFIG[DOCKER_ENV_FILE]}" "$env_file"
    fi

    _write_env_keys "$env_file" "$@"
}

setup_env_key() { setup_env_keys "$1" "$2"; }

# env_file_value FILE KEY — value of KEY in FILE, quotes stripped (empty if absent)
env_file_value() {
    grep "^${2}=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"\r" || true
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

# setup_traefik_env_keys KEY VALUE [KEY VALUE...]
setup_traefik_env_keys() {
    ensure_traefik_env_file
    _write_env_keys "$(traefik_env_file)" "$@"
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
