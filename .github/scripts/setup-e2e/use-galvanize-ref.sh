#!/usr/bin/env bash
# Manual CI runs only: builds Galvanize from GALVANIZE_REPOSITORY at
# GALVANIZE_REF (e.g. a fork branch with a fix to test) and points the
# checkout's compose template and Galvanize playbooks at it, so setup.sh
# deploys that version instead of ghcr.io/28pollux28/galvanize:latest and
# the vendored playbooks. setup.sh itself is unchanged; like the Pebble
# job's Traefik patch, only the checkout's templates are edited.
#
# Run from the repository root, before setup.sh.

set -euo pipefail

: "${GALVANIZE_REPOSITORY:?GALVANIZE_REPOSITORY must be set (owner/repo)}"
: "${GALVANIZE_REF:?GALVANIZE_REF must be set (branch, tag or commit)}"

[[ "$GALVANIZE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || { echo "::error::Invalid repository: $GALVANIZE_REPOSITORY (expected owner/repo)"; exit 1; }
[[ "$GALVANIZE_REF" =~ ^[A-Za-z0-9_./-]+$ && "$GALVANIZE_REF" != -* ]] \
    || { echo "::error::Invalid ref: $GALVANIZE_REF"; exit 1; }

src="${RUNNER_TEMP:-/tmp}/galvanize-under-test"
image="galvanize-under-test:ci"

rm -rf "$src"
git clone --quiet --filter=blob:none "https://github.com/${GALVANIZE_REPOSITORY}" "$src"
git -C "$src" -c advice.detachedHead=false checkout --quiet "$GALVANIZE_REF"
commit="$(git -C "$src" log -1 --format='%h %s')"
echo "Galvanize under test: ${GALVANIZE_REPOSITORY}@${GALVANIZE_REF} (${commit})"

docker build --quiet -f "$src/galvanize-instancer/Dockerfile" -t "$image" "$src" >/dev/null
echo "Built $image"

# The instancer runs the image built above; pull_policy never makes setup's
# `docker compose pull` skip it instead of looking it up in a registry
I="$image" yq -i '
    .services.instancer.image = strenv(I) |
    .services.instancer.pull_policy = "never"
' config/docker-compose.yml

# That version's own playbooks replace the vendored ones (and their
# workarounds), so the deployment really exercises the code under test
rm -f config/galvanize/playbooks/*.yaml
cp "$src"/data/playbooks/*.yaml config/galvanize/playbooks/

git --no-pager diff --stat -- config/docker-compose.yml config/galvanize/playbooks
echo "::notice::Testing Galvanize ${GALVANIZE_REPOSITORY}@${GALVANIZE_REF} (${commit}) instead of the published image"
