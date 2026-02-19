#!/usr/bin/env bash
# setup/ctfd.sh — Clone plugin repo, seed instancer config, generate secrets, pull/build images.
# Requires: lib/common.sh, lib/env.sh, setup/instancer.sh, setup/theme.sh

[[ -n "${_SETUP_CTFD_LOADED:-}" ]] && return 0
readonly _SETUP_CTFD_LOADED=1

readonly DOCKER_PLUGIN_REPO="https://github.com/28Pollux28/zync"
readonly DOCKER_INSTANCER_REPO="https://github.com/28Pollux28/galvanize"  # cloned temporarily for config seed files

install_ctfd() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local infra_dir="$SCRIPT_DIR"
    local plugin_name="zync"
    local plugin_path="$working_dir/$plugin_name"
    local compose_file="$infra_dir/docker-compose.yml"

    local jwt_secret_key
    jwt_secret_key="$(generate_password 48)"
    CONFIG[JWT_SECRET_KEY]="$jwt_secret_key"

    log_info "Installing CTFd..."

    # ── Clone / update plugin ──
    if [[ ! -d "$plugin_path" ]]; then
        log_info "Cloning zync instancer plugin..."
        git -C "$working_dir" clone "$DOCKER_PLUGIN_REPO"
    else
        log_info "Zync plugin already exists, updating..."
        git -C "$plugin_path" pull origin main \
            || log_warning "git pull failed for zync; continuing with existing code"
    fi
    log_success "Instancer plugin configuration complete"

    # ── Local instancer setup ──
    if [[ -z "${CONFIG[INSTANCER_URL]:-}" ]]; then
        local instancer_tmp
        instancer_tmp="$(mktemp -d)"
        _cleanup_files+=("$instancer_tmp")
        local instancer_config_path="$working_dir/data/galvanize/config.yaml"
        log_info "Setting up local instancer..."

        log_info "Cloning galvanize instancer (temporary)..."
        git clone --depth 1 "$DOCKER_INSTANCER_REPO" "$instancer_tmp/galvanize"

        mkdir -p "$working_dir/data/galvanize"
        cp "$instancer_tmp/galvanize/config.example.yaml" "$instancer_config_path"
        cp -a "$instancer_tmp/galvanize/data/." "$working_dir/data/galvanize"
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$working_dir/data/galvanize"

        # Repo is no longer needed — image is pulled from ghcr.io
        rm -rf "$instancer_tmp"
        log_info "Temporary galvanize repo cleaned up"

        setup_env_key GALVANIZE_CONFIG_PATH "$instancer_config_path"

        setup_ansible_user
        configure_instancer
    fi

    # ── Backup compose file ──
    if [[ -f "$compose_file" ]]; then
        cp "$compose_file" "${compose_file}.backup.$(date +%Y%m%d%H%M%S)" \
            || log_warning "Compose file backup failed"
    fi

    # ── Generate secrets ──
    log_info "Generating secure secrets..."
    local secret_key db_password db_root_password
    secret_key="$(generate_password 32)"
    db_password="$(generate_password 16)"
    db_root_password="$(generate_password 16)"

    log_info "Updating configuration with new secrets..."
    setup_env_key SECRET_KEY            "$secret_key"
    setup_env_key MARIADB_PASSWORD      "$db_password"
    setup_env_key MARIADB_ROOT_PASSWORD "$db_root_password"
    setup_env_key BASE_DOMAIN           "${CONFIG[DOMAIN]}"

    # ── Build full URLs with scheme ──
    local scheme="https"
    [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]] && scheme="http"
    local ctfd_full_url="${scheme}://${CONFIG[DOMAIN]}"

    setup_env_key CTFD_URL              "$ctfd_full_url"

    # Instancer URL: use --instancer-url if provided, otherwise derive from local instancer
    local instancer_url="${CONFIG[INSTANCER_URL]:-${scheme}://${CONFIG[DOMAIN]}:8080}"
    setup_env_key ZYNC_DEPLOYER_URL     "$instancer_url"
    setup_env_key ZYNC_JWT_SECRET       "$jwt_secret_key"

    # ── Traefik config selection ──
    if [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]]; then
        log_info "HTTPS disabled — using local Traefik config (HTTP only)"
        setup_env_key TRAEFIK_STATIC_CONFIG "./traefik-config/traefik-local.yml"
    else
        log_info "HTTPS enabled — using production Traefik config"
        setup_env_key TRAEFIK_STATIC_CONFIG "./traefik-config/traefik.yml"
    fi

    # ── Ensure Let's Encrypt storage directory exists ──
    mkdir -p "$infra_dir/traefik-config/letsencrypt"

    # ── Build and pull Docker images ──
    log_info "Building CTFd docker image... This may take a while"
    docker compose -f "$compose_file" build
    log_success "CTFd docker image successfully built"

    log_info "Pulling pre-built images (galvanize, traefik, mariadb, redis)..."
    docker compose -f "$compose_file" pull -q
    log_success "Docker images successfully pulled"

    # ── Custom theme ──
    if [[ -n "${CONFIG[THEME]}" ]]; then
        log_info "Custom theme option enabled"

        if setup_custom_theme; then
            if sed -i 's|^[[:space:]]*#\(.*CTFd/themes.*\)|\1|' "$compose_file"; then
                log_success "Custom theme volume mount enabled in docker-compose.yml"
            else
                log_warning "Could not uncomment theme line in docker-compose.yml; enable it manually"
            fi
            setup_env_key THEME_NAME "${CONFIG[THEME_NAME]}"
            log_info "THEME_NAME set to: ${CONFIG[THEME_NAME]}"
        else
            log_warning "Theme setup failed, but continuing with setup"
        fi
    fi

    # ── Start containers ──
    log_info "Starting CTFd containers..."
    docker compose -f "$compose_file" up -d
    log_success "CTFd containers started successfully"
    log_success "CTFd installation complete!"

    # ── Write secrets to secured file ──
    local secrets_file="${infra_dir}/.secrets"
    (
        umask 077
        cat > "$secrets_file" <<EOF
# Generated by setup.sh on $(date -Iseconds)
# This file contains sensitive credentials. Keep it secure.
SECRET_KEY=${secret_key}
MARIADB_PASSWORD=${db_password}
MARIADB_ROOT_PASSWORD=${db_root_password}
JWT_SECRET_KEY=${jwt_secret_key}
EOF
    )
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$secrets_file"

    log_success "Generated secrets written to: ${secrets_file} (chmod 600)"
    log_warning "Review this file and store the credentials securely."
}
