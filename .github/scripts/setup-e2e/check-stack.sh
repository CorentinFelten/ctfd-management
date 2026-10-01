#!/usr/bin/env bash
# Checks a deployment made by setup.sh with a local instancer, in no-HTTPS or
# HTTPS mode: containers, TLS, Traefik routing, generated files, Ansible SSH
# access, data ownership, backups.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

instancer_domain="instancer.${INSTANCER_HOST}"
echo "Mode: ${SCHEME}, domain: ${DOMAIN}, server: ${SERVER_IP}"

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

# ── TLS (HTTPS mode) ─────────────────────────────────────────────────────────

if [[ "$SCHEME" == https ]]; then
    section "TLS"
    [[ -n "$CA_FILE" ]] || fail "HTTPS mode needs CA_FILE to verify the issued certificate"

    # Traefik requests the certificate in the background after it starts
    cert_is_trusted() { fetch "https://${DOMAIN}/" -o /dev/null 2>/dev/null; }
    wait_for "Traefik to serve a certificate trusted by $CA_FILE" 240 cert_is_trusted
    pass "https://${DOMAIN}/ serves a certificate that verifies against $(basename "$CA_FILE")"

    sans="$(openssl s_client -connect "${SERVER_IP}:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null)"
    for name in "$DOMAIN" "*.${DOMAIN}"; do
        grep -qF "DNS:${name}" <<< "$sans" || fail "The certificate does not cover ${name}: ${sans}"
    done
    pass "The certificate covers ${DOMAIN} and *.${DOMAIN}"

    read -r code location < <(fetch "http://${DOMAIN}/" -o /dev/null -w '%{http_code} %{redirect_url}')
    [[ "$code" =~ ^30[1278]$ && "$location" == "https://${DOMAIN}/"* ]] \
        || fail "http://${DOMAIN}/ should redirect to HTTPS (got HTTP $code to '$location')"
    pass "Plain HTTP redirects to HTTPS"

    fetch "https://${DOMAIN}/" -o /dev/null -D - | grep -qi '^strict-transport-security:' \
        || fail "CTFd responses have no Strict-Transport-Security header"
    pass "HSTS header is set"

    if curl -s -o /dev/null --max-time 5 "http://${SERVER_IP}:9090/"; then
        fail "The Traefik dashboard port 9090 is open in HTTPS mode"
    fi
    pass "Traefik dashboard port 9090 is closed"
fi

# ── Routing through Traefik ─────────────────────────────────────────────────

section "Routing"

fetch "${SCHEME}://${DOMAIN}/" -fL | grep -qi "ctfd" \
    || fail "CTFd is not served at ${SCHEME}://${DOMAIN}/"
pass "CTFd answers at ${SCHEME}://${DOMAIN}/"

health="$(fetch "${SCHEME}://${instancer_domain}/health" -f)" \
    || fail "Galvanize /health is not reachable through Traefik at ${SCHEME}://${instancer_domain}"
[[ "$(jq -r .status <<< "$health")" == ok ]] || fail "Unexpected /health response: $health"
pass "Galvanize answers at ${SCHEME}://${instancer_domain}/health"

code="$(fetch "${SCHEME}://${instancer_domain}/metrics" -o /dev/null -w '%{http_code}')"
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
expect_env BASE_DOMAIN       "$DOMAIN"
expect_env CTFD_URL          "${SCHEME}://${DOMAIN}"
expect_env INSTANCER_DOMAIN  "$instancer_domain"
expect_env ZYNC_DEPLOYER_URL "${SCHEME}://${instancer_domain}"
expect_env INSTANCER_MODE    local
expect_env COMPOSE_PROFILES  instancer
if [[ "$SCHEME" == https ]]; then
    expect_env TRAEFIK_STATIC_CONFIG ./traefik-config/traefik.yml
else
    expect_env TRAEFIK_STATIC_CONFIG ./traefik-config/traefik-local.yml
fi
pass ".env has the expected ${SCHEME} settings"

for f in .secrets traefik.env; do
    [[ "$(sudo stat -c %a "$DEPLOY_DIR/$f")" == 600 ]] || fail "$f is not chmod 600"
done
pass ".secrets and traefik.env are chmod 600"

if [[ "$SCHEME" == https ]]; then
    provider="$(env_value DNS_PROVIDER)"
    traefik_cfg="$DEPLOY_DIR/traefik-config/traefik.yml"
    sudo grep -q "^CF_DNS_API_TOKEN=." "$DEPLOY_DIR/traefik.env" \
        || fail "traefik.env has no DNS provider credentials"
    for key in SECRET_KEY MARIADB_PASSWORD MARIADB_ROOT_PASSWORD ZYNC_JWT_SECRET; do
        ! sudo grep -q "^${key}=" "$DEPLOY_DIR/traefik.env" || fail "traefik.env leaks $key to Traefik"
    done
    pass "traefik.env holds the DNS credentials (${provider}) and no application secrets"

    sudo grep -q '__[A-Z_]*__' "$traefik_cfg" && fail "traefik.yml still has unpatched placeholders"
    [[ "$(sudo yq -r '.entryPoints.websecure.http.tls.domains[0].main' "$traefik_cfg")" == "$DOMAIN" ]] \
        || fail "traefik.yml does not request a certificate for ${DOMAIN}"
    [[ "$(sudo yq -r '.certificatesResolvers.letsencrypt.acme.email' "$traefik_cfg")" == "$(env_value ACME_EMAIL)" ]] \
        || fail "traefik.yml has the wrong ACME email"
    pass "traefik.yml is patched with the domain and ACME email"

    ! grep -q '9090' "$DEPLOY_DIR/docker-compose.yml" || fail "docker-compose.yml still publishes the dashboard port"
    pass "docker-compose.yml does not publish the dashboard port"
fi

galvanize_config="$DEPLOY_DIR/data/galvanize/config.yaml"
expect_yaml() {
    local path="$1" want="$2" got
    got="$(sudo yq -r "$path" "$galvanize_config")"
    [[ "$got" == "$want" ]] || fail "Galvanize config $path is '$got', expected '$want'"
}
expect_yaml .auth.jwt_secret                                       "$(env_value ZYNC_JWT_SECRET)"
expect_yaml .instancer.ansible.inventory                           "${DOMAIN},"
expect_yaml .instancer.ansible.user                                ansible-user
expect_yaml .instancer.instancer_host                              "$INSTANCER_HOST"
expect_yaml .instancer.redis.db                                    1
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

# Same target as the Galvanize inventory, so a domain must resolve here too
sudo ssh -i "$DEPLOY_DIR/ansible-ssh/ansible_rsa" \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "ansible-user@${DOMAIN}" docker ps >/dev/null \
    || fail "ansible-user cannot SSH to ${DOMAIN} with the generated key and run docker"
pass "ansible-user can SSH to ${DOMAIN} with the generated key and use Docker"

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
