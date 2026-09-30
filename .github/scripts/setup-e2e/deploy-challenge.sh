#!/usr/bin/env bash
# Deploys and terminates a real challenge instance through the Galvanize API,
# the way Zync does from a player's browser: JWT signed with ZYNC_JWT_SECRET,
# Ansible over SSH to this host, Traefik routing to the instance.
#
# Usage: deploy-challenge.sh TEAM_ID

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

team_id="${1:?Usage: $0 TEAM_ID}"
category="web"
challenge="ci-http"

instancer_domain="$(env_value INSTANCER_DOMAIN)"
jwt_secret="$(env_value ZYNC_JWT_SECRET)"
[[ -n "$instancer_domain" && -n "$jwt_secret" ]] || fail ".env has no INSTANCER_DOMAIN or ZYNC_JWT_SECRET"

# ── Test challenge ──────────────────────────────────────────────────────────
# Galvanize indexes deploy/data/galvanize/challenges recursively; directories
# named "example" are skipped, so the challenge lives under ci/.

section "Test challenge"

challenge_dir="$DEPLOY_DIR/data/galvanize/challenges/ci/$category/$challenge"
sudo mkdir -p "$challenge_dir"
sudo tee "$challenge_dir/challenge.yml" >/dev/null <<EOF
name: $challenge
category: $category
type: zync
playbook_name: http
deploy_parameters:
  image: nginx:alpine
  unique: false
EOF
sudo chown -R 1000:1000 "$DEPLOY_DIR/data/galvanize/challenges/ci"
pass "Wrote $challenge_dir/challenge.yml"

# ── Galvanize API client ────────────────────────────────────────────────────

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# jwt ROLE — HS256 token with the claims Zync sends
jwt() {
    local header payload signature
    header="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)"
    payload="$(jq -cjn \
        --arg team "$team_id" --arg chall "$challenge" --arg cat "$category" --arg role "$1" \
        --argjson exp "$(($(date +%s) + 3600))" \
        '{team_id: $team, challenge_name: $chall, category: $cat, role: $role, exp: $exp}' | b64url)"
    signature="$(printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -hmac "$jwt_secret" -binary | b64url)"
    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

player_token="$(jwt player)"
admin_token="$(jwt admin)"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# api METHOD PATH TOKEN [JSON] — prints the HTTP status, body in $body_file
api() {
    local -a args=(-s -o "$body_file" -w '%{http_code}' -X "$1"
        -H "Host: ${instancer_domain}" -H "Authorization: Bearer $3")
    [[ -n "${4:-}" ]] && args+=(-H "Content-Type: application/json" -d "$4")
    curl "${args[@]}" "http://${SERVER_IP}$2"
}

request="$(jq -cn --arg c "$category" --arg n "$challenge" '{category: $c, challenge_name: $n}')"

show_errors() {
    api GET /admin/error-deployments "$admin_token" >/dev/null || true
    echo "Galvanize error deployments:" >&2
    jq . "$body_file" >&2 || cat "$body_file" >&2
}

# ── Deploy ──────────────────────────────────────────────────────────────────

section "Deploy ($category/$challenge for $team_id)"

code="$(api POST /admin/reload-challs "$admin_token")"
[[ "$code" == 200 ]] || fail "/admin/reload-challs returned HTTP $code: $(cat "$body_file")"
pass "Challenge index reloaded"

code="$(api POST /deploy "$player_token" "$request")"
[[ "$code" == 202 ]] || fail "/deploy returned HTTP $code: $(cat "$body_file")"
pass "Deployment accepted"

connection_info=""
deploy_finished() {
    local code status
    code="$(api GET /status "$player_token")"
    case "$code" in
        200)
            status="$(jq -r .status "$body_file")"
            [[ "$status" == running ]] || { echo "  ..  status: $status"; return 1; }
            connection_info="$(jq -r .connection_info "$body_file")"
            ;;
        500) show_errors; fail "Deployment failed (see Galvanize error deployments above)" ;;
        *)   fail "/status returned HTTP $code: $(cat "$body_file")" ;;
    esac
}
wait_for "the deployment to be running" 300 deploy_finished
pass "Deployment is running: $connection_info"

# ── Reach the instance through Traefik ──────────────────────────────────────

section "Instance"

instance_host="$(sed -E 's|^https?://([^/:]+).*|\1|' <<< "$connection_info")"
[[ "$instance_host" == *".${SERVER_IP//:/-}.sslip.io" ]] \
    || fail "Unexpected connection info: $connection_info"

instance_serves_nginx() {
    curl -fsSk --resolve "${instance_host}:443:${SERVER_IP}" "https://${instance_host}/" 2>/dev/null \
        | grep -q "Welcome to nginx"
}
wait_for "Traefik to route https://${instance_host}/" 60 instance_serves_nginx
pass "https://${instance_host}/ serves the challenge through Traefik"

project="${instance_host%%.*}"
docker network inspect ctfd_infra_challenges \
    -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | grep -q "^${project}-" \
    || fail "The instance is not attached to the challenges network"
pass "The instance is on the challenges network"

# ── Terminate ───────────────────────────────────────────────────────────────

section "Terminate"

code="$(api POST /terminate "$player_token" "$request")"
[[ "$code" == 200 ]] || fail "/terminate returned HTTP $code: $(cat "$body_file")"
pass "Termination accepted"

terminate_finished() {
    local code
    code="$(api GET /status "$player_token")"
    case "$code" in
        404) return 0 ;;
        200) echo "  ..  status: $(jq -r .status "$body_file")"; return 1 ;;
        500) show_errors; fail "Termination failed (see Galvanize error deployments above)" ;;
        *)   fail "/status returned HTTP $code: $(cat "$body_file")" ;;
    esac
}
wait_for "the deployment to be removed" 180 terminate_finished

[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=${project}")" ]] \
    || fail "Containers of ${project} are still present after termination"
pass "Instance removed"

echo
echo "Challenge deploy/terminate cycle passed."
