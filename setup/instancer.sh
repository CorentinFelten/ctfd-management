#!/usr/bin/env bash
# setup/instancer.sh — Create the Ansible service user and configure Galvanize.
# Requires: lib/common.sh, lib/env.sh

[[ -n "${_SETUP_INSTANCER_LOADED:-}" ]] && return 0
readonly _SETUP_INSTANCER_LOADED=1

readonly ANSIBLE_USER="ansible-user"

setup_ansible_user() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local ssh_key_dir="$working_dir/ansible-ssh"
    local private_key_path="$ssh_key_dir/ansible_rsa"
    local public_key_path="${private_key_path}.pub"

    log_info "Setting up Ansible user: $ANSIBLE_USER"

    if id "$ANSIBLE_USER" &>/dev/null; then
        log_warning "User $ANSIBLE_USER already exists"
        read -rp "Do you want to recreate the SSH keys? (y/N): " -n 1
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Ansible user setup"
            return 0
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

    log_info "Generating SSH key pair for Ansible..."
    (
        umask 077
        ssh-keygen -t rsa -b 4096 -f "$private_key_path" -N "" \
            -C "ansible@galvanize-instancer" -q
    )
    setup_env_key SSH_KEY_PATH "$private_key_path"

    if [[ ! -f "$private_key_path" || ! -f "$public_key_path" ]]; then
        error_exit "Failed to generate SSH keys"
    fi
    log_success "SSH key pair generated"

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
        "$ssh_key_dir" "$private_key_path" "$public_key_path"

    log_success "Ansible user setup complete!"
    log_info "SSH private key: $private_key_path"
    log_info "SSH public key:  $public_key_path"
    log_info ""
    log_info "To use this user with Ansible, configure your inventory with:"
    log_info "  ansible_user: $ANSIBLE_USER"
    log_info "  ansible_ssh_private_key_file: $private_key_path"
}

configure_instancer() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local config_path="$working_dir/data/galvanize/config.yaml"

    sed -i "s|your-secret-key-here|${CONFIG[JWT_SECRET_KEY]}|g"  "$config_path" # Setting up JWT
    sed -i "s|your-ssh-user|$ANSIBLE_USER|g"                     "$config_path" # Setting up Ansible user
    sed -i "s|your-server-ip,|${CONFIG[CTFD_URL]},|g"            "$config_path" # Setting up server IP / base domain
    sed -i "s|challs.example.com|${CONFIG[CTFD_URL]}|g"          "$config_path" # Setting up public hostname of the deployer 
    sed -i "s|localhost:6379|redis:6379|g"                       "$config_path" # Setting up redis connection for instancer

    log_success "Local instancer setup complete"
}
