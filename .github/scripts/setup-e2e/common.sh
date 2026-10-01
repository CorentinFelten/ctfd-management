#!/usr/bin/env bash
# Shared helpers for the setup end-to-end checks.
# Requires:
#   DEPLOY_DIR  setup's <working-folder>/deploy
#   SERVER_IP   address of this host; every request is sent there
#   DOMAIN      what was passed to setup.sh --domain (defaults to SERVER_IP)
#   CA_FILE     optional: CA bundle that the stack's TLS certificates must
#               verify against (HTTPS mode). Without it, TLS is not verified,
#               since the no-HTTPS stack serves Traefik's self-signed default.

set -euo pipefail

: "${DEPLOY_DIR:?DEPLOY_DIR must be set}"
: "${SERVER_IP:?SERVER_IP must be set}"
DOMAIN="${DOMAIN:-$SERVER_IP}"
CA_FILE="${CA_FILE:-}"

fail() {
    echo "::error::$*" >&2
    exit 1
}

pass() { echo "  ok  $*"; }

section() { echo; echo "== $*"; }

# env_value KEY — value of KEY in the deployment .env
env_value() {
    grep "^$1=" "$DEPLOY_DIR/.env" | head -n1 | cut -d= -f2-
}

# Deployment mode, as setup.sh recorded it
if [[ "$(env_value CTFD_URL)" == https://* ]]; then
    SCHEME="https"
else
    SCHEME="http"
fi

# Domain under which Galvanize and challenge instances get subdomains:
# --domain itself, or <ip>.sslip.io for IP deployments (as setup.sh does)
if [[ "$DOMAIN" =~ ^[0-9.]+$ || "$DOMAIN" == *:* ]]; then
    INSTANCER_HOST="${DOMAIN//:/-}.sslip.io"
else
    INSTANCER_HOST="$DOMAIN"
fi

# fetch URL [CURL_ARGS...] — curl URL on SERVER_IP whatever its host name
# resolves to, verifying TLS against CA_FILE when it is set.
fetch() {
    local url="$1"; shift
    local host port
    host="$(sed -E 's|^[a-z]+://([^/:]+).*|\1|' <<< "$url")"
    [[ "$url" == https://* ]] && port=443 || port=80
    local -a args=(-sS --resolve "${host}:${port}:${SERVER_IP}")
    if [[ -n "$CA_FILE" ]]; then
        args+=(--cacert "$CA_FILE")
    else
        args+=(-k)
    fi
    curl "${args[@]}" "$@" "$url"
}

# wait_for DESCRIPTION TIMEOUT_SECONDS COMMAND... — retry COMMAND every 5s
wait_for() {
    local what="$1" timeout="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    until "$@"; do
        ((SECONDS < deadline)) || fail "Timed out after ${timeout}s waiting for: $what"
        sleep 5
    done
}
