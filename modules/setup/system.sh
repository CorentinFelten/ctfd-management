#!/usr/bin/env bash
# modules/setup/system.sh — OS identification and base package installation.
# Requires: lib/common.sh

[[ -n "${_SETUP_SYSTEM_LOADED:-}" ]] && return 0
readonly _SETUP_SYSTEM_LOADED=1

identify_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case $ID in
            ubuntu) echo "ubuntu" ;;
            debian) echo "debian" ;;
            *)      error_exit "Unsupported OS: $ID. Check the official Docker docs." ;;
        esac
    else
        error_exit "Unable to identify the OS."
    fi
}

update_system() {
    log_info "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get upgrade -y -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
        apt-transport-https \
        ca-certificates \
        curl \
        software-properties-common \
        net-tools \
        zip \
        git \
        jq \
        python3-pip \
        python3-yaml \
        wget

    log_success "System packages updated"

    install_yq
}

# ── Install Mike Farah's yq (Go binary) from GitHub ─────────────────────────
# The Ubuntu/Debian 'yq' package is kislyuk's Python wrapper (different tool).
# We install the Go binary to /usr/local/bin so it takes precedence in PATH.

install_yq() {
    # Skip if Mike Farah's yq is already present
    if command -v yq &>/dev/null; then
        local ver
        ver="$(yq --version 2>&1 || true)"
        if [[ "$ver" == *mikefarah* ]]; then
            log_info "Mike Farah's yq already installed: $ver"
            return 0
        fi
        log_warning "Found non-standard yq ($(which yq)); installing Mike Farah's yq to /usr/local/bin"
    fi

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        amd64|x86_64)  arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)             log_warning "Unsupported architecture for yq: $arch — skipping yq install"; return 0 ;;
    esac

    local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}"
    local yq_dest="/usr/local/bin/yq"

    log_info "Installing Mike Farah's yq (linux/${arch}) to ${yq_dest}..."

    if curl -fsSL "$yq_url" -o "$yq_dest"; then
        chmod +x "$yq_dest"
        log_success "yq installed: $("$yq_dest" --version 2>&1)"
    else
        log_warning "Failed to download yq — challenge ingestion will fall back to python3+PyYAML"
    fi
}
