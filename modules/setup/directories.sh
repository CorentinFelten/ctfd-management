#!/usr/bin/env bash
# modules/setup/directories.sh — Create runtime directories and set ownership.
# Requires: lib/common.sh

[[ -n "${_SETUP_DIRS_LOADED:-}" ]] && return 0
readonly _SETUP_DIRS_LOADED=1

create_and_set_owner() {
    local deploy_dir="${CONFIG[DEPLOY_DIR]}"

    log_info "Creating necessary directories and setting ownership..."

    mkdir -p "$deploy_dir/data/CTFd/uploads"
    mkdir -p "$deploy_dir/data/CTFd/logs"
    mkdir -p "$deploy_dir/data/galvanize/challenges"
    mkdir -p "$deploy_dir/data/galvanize/playbooks"

    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$deploy_dir/data"

    # CTFd runs as UID 1001 inside the container
    chown -R 1001:1001 "$deploy_dir/data/CTFd/uploads"
    chown -R 1001:1001 "$deploy_dir/data/CTFd/logs"
    chmod -R o+w "$deploy_dir/data/galvanize"

    setup_env_key DATA_DIR "./data"

    log_success "Directories created and ownership set"
}
