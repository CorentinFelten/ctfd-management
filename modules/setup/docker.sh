#!/usr/bin/env bash
# modules/setup/docker.sh — Install Docker CE and the Compose v2 plugin if missing.
# Requires: lib/common.sh, modules/setup/system.sh (identify_os, os_codename)

[[ -n "${_SETUP_DOCKER_LOADED:-}" ]] && return 0
readonly _SETUP_DOCKER_LOADED=1

readonly DOCKER_KEYRING="/usr/share/keyrings/docker-archive-keyring.gpg"

# Add Docker's official APT repository (idempotent).
_add_docker_apt_repo() {
    local distro codename
    distro="$(identify_os)"
    codename="$(os_codename)"

    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
        | gpg --dearmor --yes -o "$DOCKER_KEYRING"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] \
https://download.docker.com/linux/${distro} ${codename} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
}

# Docker installed without Compose v2 (e.g. the distribution's docker.io
# package): add only the plugin, since docker-ce conflicts with docker.io.
_ensure_docker_compose() {
    docker compose version >/dev/null 2>&1 && return 0

    log_warning "Docker is installed but the Compose v2 plugin ('docker compose') is missing"
    log_info "Installing docker-compose-plugin from Docker's repository..."
    _add_docker_apt_repo
    apt-get install -qq -y docker-compose-plugin \
        || error_exit "Could not install docker-compose-plugin. Install Docker Compose v2 manually: https://docs.docker.com/compose/install/linux/"

    docker compose version >/dev/null 2>&1 \
        || error_exit "'docker compose' is still unavailable after installing docker-compose-plugin. Install Docker Compose v2 manually: https://docs.docker.com/compose/install/linux/"
    log_success "Docker Compose plugin installed: $(docker compose version --short 2>/dev/null)"
}

# The invoking user needs Docker access for challenges.sh and the backup cron
# job (which runs as that user), whether or not setup installed Docker.
ensure_user_in_docker_group() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" || "$user" == "root" ]]; then
        log_debug "No non-root invoking user — skipping docker group membership"
        return 0
    fi

    getent group docker >/dev/null 2>&1 || groupadd docker

    # No `| grep -q` here: with pipefail, grep exiting early can fail the pipe
    local user_groups
    user_groups=" $(id -nG "$user") "
    if [[ "$user_groups" == *" docker "* ]]; then
        log_info "$user is already in the docker group"
        return 0
    fi

    usermod -aG docker "$user"
    log_success "Added $user to the docker group"
    log_info "Log out and back in (or run 'newgrp docker') to use Docker from your shell; cron jobs pick it up right away"
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        _ensure_docker_compose
    else
        log_info "Installing Docker..."
        _add_docker_apt_repo
        apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

        systemctl enable --now docker
        log_info "Docker service enabled to start on boot"
        log_success "Docker installed successfully"
    fi

    ensure_user_in_docker_group
}
