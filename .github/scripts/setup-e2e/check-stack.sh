#!/usr/bin/env bash
# Checks a deployment made by setup.sh, in no-HTTPS or HTTPS mode, with a
# local, external or no instancer: containers, TLS, Traefik routing,
# generated files, Ansible SSH access, data ownership, backups.
#
# Besides common.sh's variables:
#   INSTANCER      expected instancer mode: local (default), none or external
#   INSTANCER_URL  the --instancer-url given to setup.sh (external mode)
#   FRESH_INSTALL  false when the deployment previously had a local instancer:
#                  its files are then legitimately left behind

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INSTANCER="${INSTANCER:-local}"
FRESH_INSTALL="${FRESH_INSTALL:-true}"
case "$INSTANCER" in
    local|none) ;;
    external) : "${INSTANCER_URL:?INSTANCER_URL must be set for an external instancer}" ;;
    *) fail "Unknown INSTANCER mode: $INSTANCER" ;;
esac

instancer_domain="instancer.${INSTANCER_HOST}"
echo "Mode: ${SCHEME}, instancer: ${INSTANCER}, domain: ${DOMAIN}, server: ${SERVER_IP}"

# ── Containers ───────────────────────────────────────────────────────────────

section "Containers"

container_state() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}
is_healthy() { [[ "$(container_state "$1")" == healthy ]]; }

healthy_containers=(ctfd maria-db redis)
[[ "$INSTANCER" == local ]] && healthy_containers+=(galvanize-instancer)
for c in "${healthy_containers[@]}"; do
    wait_for "$c to be healthy" 300 is_healthy "$c"
    pass "$c is healthy"
done
if [[ "$INSTANCER" != local ]]; then
    ! docker inspect galvanize-instancer >/dev/null 2>&1 \
        || fail "A galvanize-instancer container exists without a local instancer"
    pass "No instancer container"
fi
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

    read -r code location < <(fetch "http://${DOMAIN}/" -o /dev/null -w '%{http_code} %{redirect_url}\n')
    [[ "$code" =~ ^30[1278]$ && "$location" == "https://${DOMAIN}/"* ]] \
        || fail "http://${DOMAIN}/ should redirect to HTTPS (got HTTP $code to '$location')"
    pass "Plain HTTP redirects to HTTPS"

    fetch "https://${DOMAIN}/" -o /dev/null -D - | grep -i '^strict-transport-security:' >/dev/null \
        || fail "CTFd responses have no Strict-Transport-Security header"
    pass "HSTS header is set"
fi

# ── Routing through Traefik ─────────────────────────────────────────────────

section "Routing"

# Traefik only routes to a container with a healthcheck once it is healthy,
# and applies that a moment after Docker reports it: a container that setup
# just recreated (e.g. CTFd after an .env change) can briefly be unrouted.
ctfd_is_served() { fetch "${SCHEME}://${DOMAIN}/" -fL 2>/dev/null | grep -i "ctfd" >/dev/null; }
wait_for "Traefik to serve CTFd at ${SCHEME}://${DOMAIN}/" 60 ctfd_is_served
pass "CTFd answers at ${SCHEME}://${DOMAIN}/"

if [[ "$INSTANCER" == local ]]; then
    instancer_is_served() { fetch "${SCHEME}://${instancer_domain}/health" -f -o /dev/null 2>/dev/null; }
    wait_for "Traefik to serve Galvanize at ${SCHEME}://${instancer_domain}" 60 instancer_is_served
    health="$(fetch "${SCHEME}://${instancer_domain}/health" -f)" \
        || fail "Galvanize /health is not reachable through Traefik at ${SCHEME}://${instancer_domain}"
    [[ "$(jq -r .status <<< "$health")" == ok ]] || fail "Unexpected /health response: $health"
    pass "Galvanize answers at ${SCHEME}://${instancer_domain}/health"

    code="$(fetch "${SCHEME}://${instancer_domain}/metrics" -o /dev/null -w '%{http_code}')"
    [[ "$code" == 404 ]] || fail "Galvanize /metrics should not be routed by Traefik (got HTTP $code)"
    pass "Galvanize /metrics is not routed"
else
    code="$(fetch "${SCHEME}://${instancer_domain}/health" -o /dev/null -w '%{http_code}')"
    [[ "$code" == 404 ]] || fail "${instancer_domain} should not be routed without a local instancer (got HTTP $code)"
    pass "Nothing is routed at ${instancer_domain}"
fi

# ── Traefik dashboard ───────────────────────────────────────────────────────
# Unauthenticated, so never reachable from outside; the HTTP-only config
# serves it on the loopback interface (SSH tunnel)

section "Traefik dashboard"

if curl -s -o /dev/null --max-time 5 "http://${SERVER_IP}:9090/"; then
    fail "The Traefik dashboard port 9090 is reachable at ${SERVER_IP}"
fi
pass "Port 9090 is not reachable at ${SERVER_IP}"

if [[ "$SCHEME" == http ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:9090/dashboard/")"
    [[ "$code" == 200 ]] || fail "The Traefik dashboard does not answer on 127.0.0.1:9090 (HTTP $code)"
    pass "The Traefik dashboard answers on 127.0.0.1:9090"
fi

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
case "$INSTANCER" in
    local)
        expect_env ZYNC_DEPLOYER_URL "${SCHEME}://${instancer_domain}"
        expect_env INSTANCER_MODE    local
        expect_env COMPOSE_PROFILES  instancer ;;
    none)
        # The default instancer address, for a Galvanize deployed separately later
        expect_env ZYNC_DEPLOYER_URL "${SCHEME}://${instancer_domain}"
        expect_env INSTANCER_MODE    none
        expect_env COMPOSE_PROFILES  "" ;;
    external)
        expect_env ZYNC_DEPLOYER_URL "$INSTANCER_URL"
        expect_env INSTANCER_MODE    external
        expect_env COMPOSE_PROFILES  "" ;;
esac
if [[ "$SCHEME" == https ]]; then
    expect_env TRAEFIK_STATIC_CONFIG  ./traefik-config/traefik.yml
else
    expect_env TRAEFIK_STATIC_CONFIG  ./traefik-config/traefik-local.yml
fi
expect_env TRAEFIK_DASHBOARD_BIND 127.0.0.1:9090
expect_env DATA_DIR ./data
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
fi

if [[ "$INSTANCER" == local ]]; then
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
elif [[ "$FRESH_INSTALL" == true ]]; then
    [[ ! -e "$DEPLOY_DIR/data/galvanize" ]] || fail "data/galvanize was created without a local instancer"
    [[ ! -e "$DEPLOY_DIR/ansible-ssh" ]]    || fail "ansible-ssh/ was created without a local instancer"
    ! id ansible-user >/dev/null 2>&1        || fail "ansible-user was created without a local instancer"
    [[ -z "$(env_value GALVANIZE_CONFIG_PATH)" ]] || fail ".env has GALVANIZE_CONFIG_PATH without a local instancer"
    pass "No Galvanize data, Ansible user or SSH key without a local instancer"
fi

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

if [[ "$INSTANCER" == local ]]; then
    section "Ansible SSH"

    # Same target as the Galvanize inventory, so a domain must resolve here too
    sudo ssh -i "$DEPLOY_DIR/ansible-ssh/ansible_rsa" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "ansible-user@${DOMAIN}" docker ps >/dev/null \
        || fail "ansible-user cannot SSH to ${DOMAIN} with the generated key and run docker"
    pass "ansible-user can SSH to ${DOMAIN} with the generated key and use Docker"
fi

# ── Backups ─────────────────────────────────────────────────────────────────

section "Backups"

backup_script="$DEPLOY_DIR/backup/backup_db.sh"
sudo crontab -u "$USER" -l | grep -F "$backup_script" >/dev/null \
    || fail "No backup cron job for $USER"
pass "Backup cron job is installed for $USER"

# Off-site upload (setup.sh --backup-remote): EXPECT_BACKUP_REMOTE is the
# remote, and with CHECK_REMOTE_RETENTION=true an archive dated 2001 is
# planted there first and must be deleted by the retention cleanup
remote="${EXPECT_BACKUP_REMOTE:-}"
old_archive="ctfd_backup_20010101_000000.tar.gz"
rclone_cmd=(rclone)
if [[ -n "$remote" ]]; then
    expect_env BACKUP_REMOTE "$remote"
    expect_env BACKUP_REMOTE_RETENTION_DAYS 30
    [[ -f "$DEPLOY_DIR/backup/rclone.conf" ]] && rclone_cmd+=(--config "$DEPLOY_DIR/backup/rclone.conf")
    if [[ "${CHECK_REMOTE_RETENTION:-}" == true ]]; then
        "${rclone_cmd[@]}" touch --timestamp 2001-01-01T00:00:00 "${remote%/}/$old_archive" \
            || fail "Could not plant an old archive on $remote"
    fi
fi

DEPLOY_DIR="$DEPLOY_DIR" "$backup_script" >/dev/null \
    || fail "backup_db.sh failed (see $(dirname "$DEPLOY_DIR")/backups/backup.log)"
latest="$(dirname "$DEPLOY_DIR")/backups/latest_backup.tar.gz"
tar -tzf "$latest" | grep '/database.sql$' >/dev/null \
    || fail "$latest has no database dump"
pass "backup_db.sh produced $(readlink -f "$latest")"

if [[ -n "$remote" ]]; then
    uploaded="$("${rclone_cmd[@]}" lsf --files-only "$remote")" || fail "Could not list $remote"
    archive="$(basename "$(readlink -f "$latest")")"
    grep -Fx "$archive" <<< "$uploaded" >/dev/null || fail "$archive was not uploaded to $remote: $uploaded"
    pass "The backup was uploaded to $remote"
    if [[ "${CHECK_REMOTE_RETENTION:-}" == true ]]; then
        ! grep -Fx "$old_archive" <<< "$uploaded" >/dev/null \
            || fail "The archive dated 2001 is still on $remote (retention: 30 days)"
        pass "Uploaded backups older than the retention were deleted"
    fi
fi

echo
echo "All stack checks passed."
