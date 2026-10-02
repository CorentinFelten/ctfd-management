#!/usr/bin/env bash
# modules/setup/instancer.sh — Create the Ansible service user and configure Galvanize.
# Requires: lib/common.sh, lib/env.sh

[[ -n "${_SETUP_INSTANCER_LOADED:-}" ]] && return 0
readonly _SETUP_INSTANCER_LOADED=1

readonly ANSIBLE_USER="ansible-user"

# instancer_deployed_locally — true unless --instancer-url (external) or
# --no-instancer was given, i.e. when Galvanize runs in this compose stack.
instancer_deployed_locally() {
    [[ -z "${CONFIG[INSTANCER_URL]:-}" && -z "${CONFIG[NO_INSTANCER]:-}" ]]
}

setup_ansible_user() {
    local ssh_key_dir="${CONFIG[DEPLOY_DIR]}/ansible-ssh"
    local private_key_path="$ssh_key_dir/ansible_rsa"
    local public_key_path="${private_key_path}.pub"

    log_info "Setting up Ansible user: $ANSIBLE_USER"

    # Recreating the key pair is the default so a re-run can start from
    # scratch; a missing pair is always generated.
    local regenerate="true"
    if id "$ANSIBLE_USER" &>/dev/null; then
        log_info "User $ANSIBLE_USER already exists"
        if [[ -f "$private_key_path" && -f "$public_key_path" ]]; then
            if ! ask_yes_no "Do you want to recreate the Ansible SSH key pair?" y; then
                regenerate="false"
                log_info "Keeping the existing SSH key pair"
            fi
        else
            log_info "No SSH key pair found in $ssh_key_dir — generating one"
        fi
    else
        log_info "Creating user: $ANSIBLE_USER"
        useradd -m -s /bin/bash "$ANSIBLE_USER"
        log_success "User $ANSIBLE_USER created successfully"
    fi

    local ansible_home="/home/$ANSIBLE_USER"
    local ansible_ssh_dir="$ansible_home/.ssh"

    mkdir -p "$ansible_ssh_dir"
    chmod 700 "$ansible_ssh_dir"
    mkdir -p "$ssh_key_dir"

    if [[ "$regenerate" == "true" ]]; then
        log_info "Generating SSH key pair for Ansible..."
        # Remove the old pair first: ssh-keygen would otherwise stop to ask
        # whether to overwrite it, and answering "n" aborted the setup.
        rm -f "$private_key_path" "$public_key_path"
        (
            umask 077
            ssh-keygen -t rsa -b 4096 -f "$private_key_path" -N "" \
                -C "ansible@galvanize-instancer" -q
        )
        [[ -f "$private_key_path" && -f "$public_key_path" ]] \
            || error_exit "Failed to generate SSH keys"
        # The instancer container bind-mounts the key file, so it must be
        # recreated to see the new one (see install_ctfd)
        CONFIG[ANSIBLE_KEY_REGENERATED]="true"
        log_success "SSH key pair generated"
    fi

    # Applied on every run, including when the key is kept: re-runs chown the
    # whole deploy dir to the invoking user, while the instancer container
    # reads the key as UID 1000.
    # Written to .env with the other settings by install_ctfd
    CONFIG[SSH_KEY_PATH]="$private_key_path"
    chown 1000:1000 "$private_key_path"
    chmod 600 "$private_key_path"

    local authorized_keys="$ansible_ssh_dir/authorized_keys"
    cat "$public_key_path" > "$authorized_keys"
    chmod 600 "$authorized_keys"
    chown -R "$ANSIBLE_USER:$ANSIBLE_USER" "$ansible_ssh_dir"
    log_success "SSH keys configured for $ANSIBLE_USER"

    log_info "Adding $ANSIBLE_USER to docker group..."
    if ! getent group docker > /dev/null 2>&1; then
        log_warning "Docker group doesn't exist, creating it..."
        groupadd docker
    fi
    usermod -aG docker "$ANSIBLE_USER"
    log_success "$ANSIBLE_USER added to docker group"

    chmod 644 "$public_key_path"
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" \
        "$ssh_key_dir" "$public_key_path"

    log_success "Ansible user setup complete!"
    log_info "SSH private key: $private_key_path"
    log_info "SSH public key:  $public_key_path"
}

configure_instancer() {
    local config_path="${CONFIG[DEPLOY_DIR]}/data/galvanize/config.yaml"

    local instancer_host="${CONFIG[DOMAIN]}"
    if is_ip_address "$instancer_host"; then
        # sslip.io requires dashes instead of colons for IPv6 addresses
        instancer_host="${instancer_host//:/-}.sslip.io"
        log_info "IP address detected — using sslip.io wildcard DNS: ${instancer_host}"
    fi

    # One pass over the file. Values go through the environment (strenv), so
    # they are never parsed as part of the yq expression.
    #   redis db 1: CTFd uses db 0 on the shared Redis
    #   traefik_network: shared only by challenge instances and Traefik
    #   metrics: basic auth on Galvanize's metrics server (port 5001)
    G_JWT_SECRET="${CONFIG[JWT_SECRET_KEY]}" \
    G_METRICS_PASSWORD="${CONFIG[GALVANIZE_METRICS_PASSWORD]}" \
    G_ANSIBLE_USER="$ANSIBLE_USER" \
    G_INVENTORY="${CONFIG[DOMAIN]}," \
    G_INSTANCER_HOST="$instancer_host" \
    G_TRAEFIK_NETWORK="${CONFIG[CHALLENGE_NETWORK]}" \
    yq -i '
        .auth.jwt_secret = strenv(G_JWT_SECRET) |
        .instancer.ansible.user = strenv(G_ANSIBLE_USER) |
        .instancer.ansible.inventory = strenv(G_INVENTORY) |
        .instancer.instancer_host = strenv(G_INSTANCER_HOST) |
        .instancer.redis.addr = "redis:6379" |
        .instancer.redis.db = 1 |
        .instancer.extra_deployment_parameters.traefik_network = strenv(G_TRAEFIK_NETWORK) |
        .instancer.metrics.username = "prometheus" |
        .instancer.metrics.password = strenv(G_METRICS_PASSWORD)
    ' "$config_path"

    log_success "Local instancer setup complete"
}

# ── Public entry point: run both steps in order ──────────────────────────────
# Callers (e.g. ctfd.sh) should use this wrapper so the instancer module can
# be replaced without modifying the caller.

setup_instancer() {
    setup_ansible_user
    configure_instancer
}
