#!/usr/bin/env bash
# Checks a no-HTTPS deployment made by setup.sh with a local instancer:
# containers, Traefik routing, generated files, Ansible SSH access, backups.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

instancer_host="${SERVER_IP//:/-}.sslip.io"
instancer_domain="instancer.${instancer_host}"

# ── Containers ───────────────────────────────────────────────────────────────

section "Containers"

container_state() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}

is_healthy() { [[ "$(container_state "$1")" == healthy ]]; }

for c in ctfd maria-db redis galvanize-instancer; do
    wait_for "$c to be healthy" 300 is_healthy "$c"
    pass "$c is healthy"
done
[[ "$(container_state traefik)" == running ]] || fail "traefik is not running"
pass "traefik is running"

# ── Routing through Traefik ─────────────────────────────────────────────────

section "Routing"

http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

curl -fsSL "http://${SERVER_IP}/" | grep -qi "ctfd" \
    || fail "CTFd is not served at http://${SERVER_IP}/"
pass "CTFd answers at http://${SERVER_IP}/"

health="$(curl -fsS -H "Host: ${instancer_domain}" "http://${SERVER_IP}/health")" \
    || fail "Galvanize /health is not reachable through Traefik (Host: ${instancer_domain})"
[[ "$(jq -r .status <<< "$health")" == ok ]] || fail "Unexpected /health response: $health"
pass "Galvanize answers at http://${instancer_domain}/health"

code="$(http_code -H "Host: ${instancer_domain}" "http://${SERVER_IP}/metrics")"
[[ "$code" == 404 ]] || fail "Galvanize /metrics should not be routed by Traefik (got HTTP $code)"
pass "Galvanize /metrics is not routed"

# ── Generated files ─────────────────────────────────────────────────────────

section "Generated files"

for key in SECRET_KEY MARIADB_PASSWORD MARIADB_ROOT_PASSWORD ZYNC_JWT_SECRET; do
    [[ -n "$(env_value "$key")" ]] || fail ".env has no $key"
done
pass ".env holds the generated secrets"

expect_env() {
    local key="$1" want="$2" got
    got="$(env_value "$key")"
    [[ "$got" == "$want" ]] || fail ".env $key is '$got', expected '$want'"
}
expect_env BASE_DOMAIN           "$SERVER_IP"
expect_env CTFD_URL              "http://${SERVER_IP}"
expect_env INSTANCER_DOMAIN      "$instancer_domain"
expect_env ZYNC_DEPLOYER_URL     "http://${instancer_domain}"
expect_env INSTANCER_MODE        local
expect_env COMPOSE_PROFILES      instancer
expect_env TRAEFIK_STATIC_CONFIG ./traefik-config/traefik-local.yml
pass ".env has the expected no-HTTPS settings"

for f in .secrets traefik.env; do
    [[ "$(sudo stat -c %a "$DEPLOY_DIR/$f")" == 600 ]] || fail "$f is not chmod 600"
done
pass ".secrets and traefik.env are chmod 600"

galvanize_config="$DEPLOY_DIR/data/galvanize/config.yaml"
expect_yaml() {
    local path="$1" want="$2" got
    got="$(sudo yq -r "$path" "$galvanize_config")"
    [[ "$got" == "$want" ]] || fail "Galvanize config $path is '$got', expected '$want'"
}
expect_yaml .auth.jwt_secret                                     "$(env_value ZYNC_JWT_SECRET)"
expect_yaml .instancer.ansible.inventory                         "${SERVER_IP},"
expect_yaml .instancer.ansible.user                              ansible-user
expect_yaml .instancer.instancer_host                            "$instancer_host"
expect_yaml .instancer.redis.db                                  1
expect_yaml .instancer.extra_deployment_parameters.traefik_network ctfd_infra_challenges
pass "Galvanize config is filled in"

for pb in config/galvanize/playbooks/*.yaml; do
    sudo cmp -s "$pb" "$DEPLOY_DIR/data/galvanize/playbooks/$(basename "$pb")" \
        || fail "Playbook $(basename "$pb") was not copied to the deployment"
done
pass "Galvanize playbooks are deployed"

# ── Data ownership ──────────────────────────────────────────────────────────
# Re-runs must not re-own the containers' data (MariaDB then cannot read its
# own tables until it restarts).

section "Data ownership"

for d in mysql redis; do
    owned="$(sudo find "$DEPLOY_DIR/data/$d" -user "$USER" -print -quit)"
    [[ -z "$owned" ]] || fail "data/$d contains files owned by $USER (e.g. $owned)"
done
pass "data/mysql and data/redis are left to their containers"

# ── Ansible SSH access (what Galvanize uses to deploy challenges) ──────────

section "Ansible SSH"

sudo ssh -i "$DEPLOY_DIR/ansible-ssh/ansible_rsa" \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "ansible-user@${SERVER_IP}" docker ps >/dev/null \
    || fail "ansible-user cannot SSH to ${SERVER_IP} with the generated key and run docker"
pass "ansible-user can SSH in with the generated key and use Docker"

# ── Backups ─────────────────────────────────────────────────────────────────

section "Backups"

backup_script="$DEPLOY_DIR/backup/backup_db.sh"
sudo crontab -u "$USER" -l | grep -qF "$backup_script" \
    || fail "No backup cron job for $USER"
pass "Backup cron job is installed for $USER"

DEPLOY_DIR="$DEPLOY_DIR" "$backup_script" >/dev/null \
    || fail "backup_db.sh failed"
latest="$(dirname "$DEPLOY_DIR")/backups/latest_backup.tar.gz"
tar -tzf "$latest" | grep -q '/database.sql$' \
    || fail "$latest has no database dump"
pass "backup_db.sh produced $(readlink -f "$latest")"

echo
echo "All stack checks passed."
