#!/usr/bin/env bash
# Re-runs setup.sh with SETUP_ARGS and checks that re-runs are safe: the
# generated secrets are kept, and when the re-run has a local instancer
# (INSTANCER=local, the default), --yes recreates the Ansible SSH key pair
# (the default answer to its prompt).
#
# Run from the repository root. Extra arguments are appended to SETUP_ARGS.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
: "${SETUP_ARGS:?SETUP_ARGS must be set}"

before="$(mktemp -d)"
trap 'rm -rf "$before"' EXIT

grep -v '^#' "$DEPLOY_DIR/.secrets" > "$before/secrets"
key="$DEPLOY_DIR/ansible-ssh/ansible_rsa.pub"
[[ -f "$key" ]] && sha256sum "$key" > "$before/key"

# stdin is /dev/null so any prompt that --yes misses fails the run
# shellcheck disable=SC2086
./setup.sh $SETUP_ARGS "$@" < /dev/null

section "Re-run"

grep -v '^#' "$DEPLOY_DIR/.secrets" | diff -u "$before/secrets" - \
    || fail "Re-running setup.sh changed the generated secrets"
pass "Generated secrets are unchanged"

if [[ "${INSTANCER:-local}" == local && -f "$before/key" ]]; then
    if sha256sum -c --quiet "$before/key" >/dev/null 2>&1; then
        fail "Re-running setup.sh --yes did not recreate the Ansible SSH key pair"
    fi
    pass "The Ansible SSH key pair was recreated (--yes default)"
fi
