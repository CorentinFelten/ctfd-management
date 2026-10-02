#!/usr/bin/env bash
# Runs the local Galvanize without Redis for a while, then restores it
# (galvanize-e2e.yml only; the published Galvanize image may predate what this
# checks). setup.sh always configures Redis, so the deployed config is patched
# and the instancer restarted, as a user would do:
#   - redis.addr empty: deployments and expiries run without the job queue,
#     at most max_concurrent_ansible (2) Ansible runs at a time;
#   - deployment_ttl 60s: the expiry scheduler must terminate the instance
#     itself, instead of marking it as an error for lack of a queue;
#   - randomized ports 42000-42099: the instance's port must be in that range;
#   - no traefik_network: TCP challenges must not need it.
# A TCP challenge is deployed, reached on its published port, and left to
# expire. The original config is then restored and Redis checked to be back.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/galvanize-api.sh"

team_id="ci-team-noredis"
category="pwn"
challenge="ci-tcp"
port_min=42000
port_max=42099
config="$DEPLOY_DIR/data/galvanize/config.yaml"
original="$(mktemp)"
sudo cp "$config" "$original"

player_token="$(galvanize_jwt player "$team_id" "$category" "$challenge")"
admin_token="$(galvanize_jwt admin "$team_id" "$category" "$challenge")"
request="$(jq -cn --arg c "$category" --arg n "$challenge" '{category: $c, challenge_name: $n}')"

galvanize_answers() { [[ "$(galvanize_api GET /health "$admin_token")" == 200 ]]; }

# restart_instancer — restarts Galvanize, prints the time it restarted at
restart_instancer() {
    local since
    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker restart galvanize-instancer >/dev/null
    wait_for "Galvanize to answer after its restart" 90 galvanize_answers
    echo "$since"
}

# logged SINCE PATTERN — whether Galvanize logged PATTERN since SINCE
logged() { docker logs --since "$1" galvanize-instancer 2>&1 | grep -E "$2" >/dev/null; }

# ── Without Redis ───────────────────────────────────────────────────────────

section "Galvanize without Redis"

sudo env PORT_MIN="$port_min" PORT_MAX="$port_max" yq -i '
    .instancer.redis.addr = "" |
    .instancer.deployment_ttl = "60s" |
    .instancer.max_concurrent_ansible = 2 |
    .instancer.randomized_port_min = env(PORT_MIN) |
    .instancer.randomized_port_max = env(PORT_MAX) |
    del(.instancer.extra_deployment_parameters.traefik_network)
' "$config"
sudo chown 1000:1000 "$config"
since="$(restart_instancer)"
logged "$since" "Redis not configured.*at most 2 Ansible runs" \
    || fail "Galvanize did not start without Redis, with max_concurrent_ansible 2"
pass "Galvanize runs without Redis, at most 2 Ansible runs at a time"

# ── TCP challenge ───────────────────────────────────────────────────────────

section "TCP challenge ($category/$challenge for $team_id)"

challenge_dir="$DEPLOY_DIR/data/galvanize/challenges/ci/$category/$challenge"
sudo mkdir -p "$challenge_dir"
sudo tee "$challenge_dir/challenge.yml" >/dev/null <<EOF
name: $challenge
category: $category
type: zync
playbook_name: tcp
deploy_parameters:
  image: nginx:alpine
  unique: false
  published_ports:
    - "80"
EOF
sudo chown -R 1000:1000 "$DEPLOY_DIR/data/galvanize/challenges/ci"

code="$(galvanize_api POST /admin/reload-challs "$admin_token")"
[[ "$code" == 200 ]] || fail "/admin/reload-challs returned HTTP $code: $(cat "$GALVANIZE_BODY")"
code="$(galvanize_api POST /deploy "$player_token" "$request")"
[[ "$code" == 202 ]] || fail "/deploy returned HTTP $code: $(cat "$GALVANIZE_BODY")"
pass "Deployment accepted"

connection_info=""
deploy_finished() {
    local code status
    code="$(galvanize_api GET /status "$player_token")"
    case "$code" in
        200)
            status="$(jq -r .status "$GALVANIZE_BODY")"
            [[ "$status" == running ]] || { echo "  ..  status: $status"; return 1; }
            connection_info="$(jq -r .connection_info "$GALVANIZE_BODY")"
            ;;
        500) galvanize_errors; fail "Deployment failed (see Galvanize error deployments above)" ;;
        *)   fail "/status returned HTTP $code: $(cat "$GALVANIZE_BODY")" ;;
    esac
}
wait_for "the deployment to be running" 300 deploy_finished
pass "Deployment is running: $connection_info"

[[ "$connection_info" =~ ^tcp://[^:]+:([0-9]+)$ ]] || fail "Unexpected connection info: $connection_info"
port="${BASH_REMATCH[1]}"
((port >= port_min && port <= port_max)) \
    || fail "Published port $port is outside randomized_port_min/max ($port_min-$port_max)"
pass "Published on port $port, within $port_min-$port_max"

instance_answers() { curl -fsS --max-time 5 "http://${SERVER_IP}:${port}/" 2>/dev/null | grep "Welcome to nginx" >/dev/null; }
wait_for "the instance to answer on port $port" 60 instance_answers
pass "The instance answers on ${SERVER_IP}:${port}"

project="$(docker ps --filter "publish=${port}" --format '{{.Label "com.docker.compose.project"}}' | head -n1)"
[[ -n "$project" ]] || fail "No container publishes port $port"

# ── Expiry ──────────────────────────────────────────────────────────────────

section "Expiry without Redis"

expired() {
    local code
    code="$(galvanize_api GET /status "$player_token")"
    case "$code" in
        404) return 0 ;;
        200) echo "  ..  status: $(jq -r .status "$GALVANIZE_BODY")"; return 1 ;;
        500) galvanize_errors; fail "The expired deployment failed instead of being terminated" ;;
        *)   fail "/status returned HTTP $code: $(cat "$GALVANIZE_BODY")" ;;
    esac
}
wait_for "the expiry scheduler to terminate the deployment" 240 expired
logged "$since" "terminated expired deployment" \
    || fail "Galvanize did not log the termination of the expired deployment"
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=${project}")" ]] \
    || fail "Containers of ${project} are still present after expiry"
pass "The expiry scheduler terminated the deployment and removed ${project}"

# ── Back to Redis ───────────────────────────────────────────────────────────

section "Galvanize with Redis again"

sudo cp "$original" "$config"
sudo chown 1000:1000 "$config"
sudo rm -f "$original"
since="$(restart_instancer)"
logged "$since" "Redis job queue enabled" || fail "Galvanize did not start with Redis again"
pass "The original config is restored and Galvanize uses Redis again"

echo
echo "Galvanize without Redis passed."
