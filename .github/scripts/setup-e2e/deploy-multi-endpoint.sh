#!/usr/bin/env bash
# Deploys a challenge with two user-facing services (galvanize-e2e.yml only;
# needs a Galvanize newer than v0.7.3): a web front end routed by Traefik and
# an SSH-like service on a published port, both declared with compose
# expose:. The connection info must list both endpoints, one per line,
# ordered by service (shell, then web), and each must answer.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/galvanize-api.sh"

team_id="ci-team-multi"
category="web"
challenge="ci-multi"

player_token="$(galvanize_jwt player "$team_id" "$category" "$challenge")"
admin_token="$(galvanize_jwt admin "$team_id" "$category" "$challenge")"
request="$(jq -cn --arg c "$category" --arg n "$challenge" '{category: $c, challenge_name: $n}')"

# ── Test challenge ──────────────────────────────────────────────────────────

section "Multi-service challenge ($category/$challenge for $team_id)"

challenge_dir="$DEPLOY_DIR/data/galvanize/challenges/ci/$category/$challenge"
sudo mkdir -p "$challenge_dir"
sudo tee "$challenge_dir/challenge.yml" >/dev/null <<EOF
name: $challenge
category: $category
type: zync
playbook_name: custom_compose
deploy_parameters:
  unique: false
  expose:
    - service: web
      port: 80
      type: http
    - service: shell
      port: 80
      type: tcp
      scheme: ssh
EOF
# Both serve nginx's page, so either endpoint can be checked over HTTP
sudo tee "$challenge_dir/docker-compose.yml" >/dev/null <<EOF
services:
  web:
    image: nginx:alpine
  shell:
    image: nginx:alpine
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
pass "Deployment is running"

# ── Both endpoints ──────────────────────────────────────────────────────────

section "Endpoints"

mapfile -t lines <<< "$connection_info"
printf '      %s\n' "${lines[@]}"
((${#lines[@]} == 2)) || fail "Expected 2 endpoints, one per line, got: $connection_info"
[[ "${lines[0]}" =~ ^ssh://${INSTANCER_HOST//./\\.}:([0-9]+)$ ]] \
    || fail "First endpoint is not the shell service's ssh:// port: ${lines[0]}"
port="${BASH_REMATCH[1]}"
[[ "${lines[1]}" =~ ^https://([^/]+\.${INSTANCER_HOST//./\\.})/$ ]] \
    || fail "Second endpoint is not the web service's https:// URL: ${lines[1]}"
web_host="${BASH_REMATCH[1]}"
pass "Both endpoints are reported: ssh:// on port $port, then https://$web_host/"

web_answers() { fetch "https://${web_host}/" -f 2>/dev/null | grep "Welcome to nginx" >/dev/null; }
wait_for "Traefik to route https://${web_host}/" 60 web_answers
pass "https://${web_host}/ answers through Traefik"

shell_answers() { curl -fsS --max-time 5 "http://${SERVER_IP}:${port}/" 2>/dev/null | grep "Welcome to nginx" >/dev/null; }
wait_for "the shell service to answer on port $port" 60 shell_answers
pass "The shell service answers on ${SERVER_IP}:${port}"

project="${web_host%%.*}"

# ── Terminate ───────────────────────────────────────────────────────────────

section "Terminate"

code="$(galvanize_api POST /terminate "$player_token" "$request")"
[[ "$code" == 200 ]] || fail "/terminate returned HTTP $code: $(cat "$GALVANIZE_BODY")"
removed() {
    local code
    code="$(galvanize_api GET /status "$player_token")"
    case "$code" in
        404) return 0 ;;
        200) echo "  ..  status: $(jq -r .status "$GALVANIZE_BODY")"; return 1 ;;
        500) galvanize_errors; fail "Termination failed (see Galvanize error deployments above)" ;;
        *)   fail "/status returned HTTP $code: $(cat "$GALVANIZE_BODY")" ;;
    esac
}
wait_for "the deployment to be removed" 180 removed
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=${project}")" ]] \
    || fail "Containers of ${project} are still present after termination"
pass "Both services removed"

echo
echo "Multi-endpoint challenge passed."
