#!/usr/bin/env bash
# setup/directories.sh — Create runtime directories and set ownership.
# Requires: lib/common.sh

[[ -n "${_SETUP_DIRS_LOADED:-}" ]] && return 0
readonly _SETUP_DIRS_LOADED=1

create_and_set_owner() {
    local working_dir="${CONFIG[WORKING_DIR]}"

    log_info "Creating necessary directories and setting ownership..."

    mkdir -p "$working_dir/data/CTFd/uploads"
    mkdir -p "$working_dir/data/CTFd/logs"
    mkdir -p "$working_dir/data/galvanize/challenges"
    mkdir -p "$working_dir/data/galvanize/playbooks"
    mkdir -p "$SCRIPT_DIR/traefik-config/letsencrypt"

    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$working_dir/data"

    # CTFd runs as UID 1001 inside the container
    chown -R 1001:1001 "$working_dir/data/CTFd/uploads"
    chown -R 1001:1001 "$working_dir/data/CTFd/logs"

    log_success "Directories created and ownership set"
}
