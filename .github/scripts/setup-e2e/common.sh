#!/usr/bin/env bash
# Shared helpers for the setup end-to-end checks.
# Requires DEPLOY_DIR (setup's <working-folder>/deploy) and SERVER_IP (the
# address passed to setup.sh --domain).

set -euo pipefail

: "${DEPLOY_DIR:?DEPLOY_DIR must be set}"
: "${SERVER_IP:?SERVER_IP must be set}"

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

# wait_for DESCRIPTION TIMEOUT_SECONDS COMMAND... — retry COMMAND every 5s
wait_for() {
    local what="$1" timeout="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    until "$@"; do
        ((SECONDS < deadline)) || fail "Timed out after ${timeout}s waiting for: $what"
        sleep 5
    done
}
