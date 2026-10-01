#!/usr/bin/env bash
# Runs a command as the "ci" user inside the VM started by vm-start.sh, from
# the repository copy, with the e2e variables passed through. stdin is
# closed and no terminal is attached, as on the runner.
#
# Usage: vm-run.sh COMMAND [ARGS...]

set -euo pipefail
: "${VM_NAME:?VM_NAME must be set (see vm-start.sh)}"

declare -a vars=(HOME=/home/ci USER=ci LOGNAME=ci)
for v in DEPLOY_DIR SERVER_IP DOMAIN SETUP_ARGS INSTANCER INSTANCER_URL FRESH_INSTALL CA_FILE \
         CTFD_ADMIN_NAME CTFD_ADMIN_PASSWORD EXPECT_USER_MODE EXPECT_CTF_NAME EXPECT_TEAM_SIZE; do
    if [[ -n "${!v:-}" ]]; then
        vars+=("$v=${!v}")
    fi
done

# sudo -u (not -i) keeps the argument quoting intact; it still loads the
# user's groups, so docker access granted by setup.sh applies
exec sudo incus exec --force-noninteractive "$VM_NAME" -- \
    sudo -u ci env "${vars[@]}" bash -c 'cd /home/ci/repo && exec "$@"' bash "$@" < /dev/null
