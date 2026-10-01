#!/usr/bin/env bash
# modules/setup/directories.sh — Create runtime directories and set ownership.
# Requires: lib/common.sh, modules/setup/instancer.sh (instancer_deployed_locally)

[[ -n "${_SETUP_DIRS_LOADED:-}" ]] && return 0
readonly _SETUP_DIRS_LOADED=1

create_and_set_owner() {
    local deploy_dir="${CONFIG[DEPLOY_DIR]}"

    log_info "Creating necessary directories and setting ownership..."

    mkdir -p "$deploy_dir/data/CTFd/uploads"
    mkdir -p "$deploy_dir/data/CTFd/logs"
    # Galvanize data only exists for the bundled instancer. With an external
    # instancer or none, an empty data/galvanize/challenges would also make
    # challenges.sh clone challenge repositories there instead of the working dir.
    if instancer_deployed_locally; then
        mkdir -p "$deploy_dir/data/galvanize/challenges"
        mkdir -p "$deploy_dir/data/galvanize/playbooks"
    fi

    # Not recursive: on re-runs data/ also holds data/mysql and data/redis,
    # owned by the MariaDB and Redis container users. Re-owning them locks
    # the running database out of its own files until it restarts.
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$deploy_dir/data" "$deploy_dir/data/CTFd"

    # CTFd runs as UID 1001 inside the container
    chown -R 1001:1001 "$deploy_dir/data/CTFd/uploads"
    chown -R 1001:1001 "$deploy_dir/data/CTFd/logs"
    if instancer_deployed_locally; then
        chmod -R o+w "$deploy_dir/data/galvanize"
    fi

    log_success "Directories created and ownership set"
}
