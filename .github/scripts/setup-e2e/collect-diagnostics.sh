#!/usr/bin/env bash
# Collects logs and redacted configs of a deployment made by setup.sh into
# OUT_DIR, for upload as a CI artifact. Best effort: never fails.
#
# Usage: collect-diagnostics.sh OUT_DIR

set -uo pipefail
: "${DEPLOY_DIR:?DEPLOY_DIR must be set}"
out="${1:?Usage: $0 OUT_DIR}"
mkdir -p "$out"

docker ps -a > "$out/docker-ps.txt" 2>&1
if [[ -f "$DEPLOY_DIR/docker-compose.yml" ]]; then
    (cd "$DEPLOY_DIR" && docker compose logs --no-color --timestamps) > "$out/compose.log" 2>&1
    cp "$DEPLOY_DIR/docker-compose.yml" "$out/"
    # letsencrypt/ holds the certificate private keys
    sudo cp -r "$DEPLOY_DIR/traefik-config" "$out/" && sudo rm -rf "$out/traefik-config/letsencrypt"
fi
for c in $(docker ps -aq --filter "label=com.docker.compose.project" --filter "network=ctfd_infra_challenges"); do
    docker logs "$c" > "$out/instance-$c.log" 2>&1
done
docker inspect pebble >/dev/null 2>&1 && docker logs pebble > "$out/pebble.log" 2>&1

# Secrets are throwaway, but keep them out of the artifact anyway
sudo sed -E 's/^((SECRET_KEY|MARIADB_PASSWORD|MARIADB_ROOT_PASSWORD|ZYNC_JWT_SECRET)=).*/\1***/' \
    "$DEPLOY_DIR/.env" > "$out/env.redacted" 2>/dev/null
sudo sed -E 's/^(\s*jwt_secret:).*/\1 "***"/' \
    "$DEPLOY_DIR/data/galvanize/config.yaml" > "$out/galvanize-config.redacted.yaml" 2>/dev/null
sudo journalctl -u ssh --no-pager -n 200 > "$out/sshd.log" 2>&1
sudo chown -R "$(id -un)" "$out"
exit 0
