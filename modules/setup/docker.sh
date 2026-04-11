#!/usr/bin/env bash
# modules/setup/docker.sh — Install Docker CE if not already present.
# Requires: lib/common.sh, modules/setup/system.sh (identify_os)

[[ -n "${_SETUP_DOCKER_LOADED:-}" ]] && return 0
readonly _SETUP_DOCKER_LOADED=1

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed"
        return 0
    fi

    log_info "Installing Docker..."

    local distro
    distro="$(identify_os)"

    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
        | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/${distro} $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group"
    fi

    log_success "Docker installed successfully"
}
