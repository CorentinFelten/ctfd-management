#!/usr/bin/env bash
# modules/setup/ctfd.sh — Copy config templates to DEPLOY_DIR, clone plugins, generate secrets, pull/build images.
# Requires: lib/common.sh, lib/env.sh, modules/setup/instancer.sh, modules/setup/theme.sh

[[ -n "${_SETUP_CTFD_LOADED:-}" ]] && return 0
readonly _SETUP_CTFD_LOADED=1

readonly DOCKER_PLUGIN_REPO="https://github.com/28Pollux28/zync"

install_ctfd() {
    local working_dir="${CONFIG[WORKING_DIR]}"
    local deploy_dir="${CONFIG[DEPLOY_DIR]}"
    local plugin_name="zync"
    local plugin_path="$deploy_dir/ctfd/plugins/$plugin_name"

    # ── Copy config templates from repo to deploy dir ──
    log_info "Setting up deployment directory: $deploy_dir"
    mkdir -p "$deploy_dir"

    if [[ -f "$deploy_dir/docker-compose.yml" ]]; then
        local backup_suffix="backup_$(date +%Y%m%d_%H%M%S)"
        log_info "Existing deployment detected — backing up config files"
        [[ -d "$deploy_dir/traefik-config" ]] && cp -r "$deploy_dir/traefik-config" "$deploy_dir/traefik-config.${backup_suffix}"
        [[ -d "$deploy_dir/ctfd" ]]           && cp -r "$deploy_dir/ctfd" "$deploy_dir/ctfd.${backup_suffix}"
        cp "$deploy_dir/docker-compose.yml" "$deploy_dir/docker-compose.yml.${backup_suffix}"
        log_success "Backed up existing configs with suffix: $backup_suffix"
    fi

    cp -r "$SCRIPT_DIR/config/traefik" "$deploy_dir/traefik-config"
    cp -r "$SCRIPT_DIR/config/ctfd"    "$deploy_dir/ctfd"
    cp    "$SCRIPT_DIR/config/docker-compose.yml" "$deploy_dir/docker-compose.yml"
    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$deploy_dir"
    [[ -d "$deploy_dir/data/CTFd/uploads" ]] && chown -R 1001:1001 "$deploy_dir/data/CTFd/uploads"
    [[ -d "$deploy_dir/data/CTFd/logs" ]]    && chown -R 1001:1001 "$deploy_dir/data/CTFd/logs"
    log_success "Config templates copied to deploy dir"

    local compose_file="$deploy_dir/docker-compose.yml"

    setup_env_key COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME:-ctfd_infra}"

    local compose_project_name=""
    compose_project_name="$(grep '^COMPOSE_PROJECT_NAME=' "${deploy_dir}/.env" \
        | head -n1 | cut -d= -f2- | tr -d "'\"\r" || true)"
    compose_project_name="${compose_project_name:-ctfd_infra}"
    local docker_proxy_network="${compose_project_name}_proxy"

    local jwt_secret_key
    jwt_secret_key="$(grep '^ZYNC_JWT_SECRET=' "$deploy_dir/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    if [[ -n "$jwt_secret_key" ]]; then
        log_info "Existing JWT secret found — preserving it"
    else
        jwt_secret_key="$(generate_password 48)"
    fi
    CONFIG[JWT_SECRET_KEY]="$jwt_secret_key"

    log_info "Installing CTFd..."

    # ── Clone / update plugin ──
    mkdir -p "$deploy_dir/ctfd/plugins"
    if [[ ! -d "$plugin_path" ]]; then
        log_info "Cloning zync instancer plugin..."
        git -C "$deploy_dir/ctfd/plugins" clone "$DOCKER_PLUGIN_REPO"
    else
        log_info "Zync plugin already exists, updating..."
        git -C "$plugin_path" pull origin main \
            || log_warning "git pull failed for zync; continuing with existing code"
    fi
    log_success "Instancer plugin configuration complete"

    # ── Generate or reuse secrets ──
    local env_file="$deploy_dir/.env"
    local secret_key db_password db_root_password
    secret_key="$(grep '^SECRET_KEY=' "$env_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    db_password="$(grep '^MARIADB_PASSWORD=' "$env_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    db_root_password="$(grep '^MARIADB_ROOT_PASSWORD=' "$env_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"

    # Only treat non-placeholder values as existing secrets
    [[ "$secret_key" == "SecretKeyHere" ]] && secret_key=""
    [[ "$db_password" == "SecretKeyHere" ]] && db_password=""

    if [[ -n "$secret_key" && -n "$db_password" && -n "$db_root_password" ]]; then
        log_info "Existing secrets found in .env — preserving them"
    else
        log_info "Generating secure secrets..."
        [[ -z "$secret_key" ]]        && secret_key="$(generate_password 32)"
        [[ -z "$db_password" ]]       && db_password="$(generate_password 16)"
        [[ -z "$db_root_password" ]]  && db_root_password="$(generate_password 16)"
    fi

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

    # ── Local instancer setup ──
    # Skipped when --instancer-url (external) or --no-instancer is given.
    local use_local_instancer="false"
    if [[ -z "${CONFIG[INSTANCER_URL]:-}" && -z "${CONFIG[NO_INSTANCER]:-}" ]]; then
        use_local_instancer="true"
        local instancer_config_path="$deploy_dir/data/galvanize/config.yaml"
        log_info "Setting up local instancer..."

        mkdir -p "$deploy_dir/data/galvanize"
        cp "$SCRIPT_DIR/config/galvanize/config.yaml" "$instancer_config_path"
        chown -R 1000:1000 "$deploy_dir/data/galvanize"

        setup_env_key GALVANIZE_CONFIG_PATH "$instancer_config_path"

        setup_instancer
    fi

    # ── Traefik config selection + CA auto-switch ──
    # Operate on DEPLOY_DIR copies — never touch tracked repo files
    local traefik_cfg="$deploy_dir/traefik-config/traefik.yml"
    local traefik_local_cfg="$deploy_dir/traefik-config/traefik-local.yml"
    local staging_ca="https://acme-staging-v02.api.letsencrypt.org/directory"
    local production_ca="https://acme-v02.api.letsencrypt.org/directory"

    if [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]]; then
        log_info "HTTPS disabled — using local Traefik config (HTTP only)"
        setup_env_key TRAEFIK_STATIC_CONFIG "./traefik-config/traefik-local.yml"

        # Local deployment: switch to staging CA to avoid burning Let's Encrypt rate limits
        if ! grep -qE "^[[:space:]]*caServer:.*acme-staging-v02" "$traefik_cfg" 2>/dev/null; then
            log_info "Switching Traefik to Let's Encrypt staging CA for local deployment..."
            if grep -qE "^[[:space:]]*caServer:" "$traefik_cfg" 2>/dev/null; then
                sed -i "s|caServer:.*|caServer: \"${staging_ca}\"|" "$traefik_cfg"
            else
                sed -i "/storage:.*acme\.json/a\\      caServer: \"${staging_ca}\"" "$traefik_cfg"
            fi
            log_success "caServer set to staging: $staging_ca"
        else
            log_success "TLS CA verified: staging Let's Encrypt endpoint confirmed (local deployment)"
        fi
    else
        log_info "HTTPS enabled — using production Traefik config"
        setup_env_key TRAEFIK_STATIC_CONFIG "./traefik-config/traefik.yml"

        # Production deployment: ensure production CA is set
        if grep -qE "^[[:space:]]*caServer:.*acme-staging-v02" "$traefik_cfg" 2>/dev/null; then
            log_warning "Staging CA detected — switching to production automatically..."
            sed -i "s|caServer:.*acme-staging-v02\.api\.letsencrypt\.org.*|caServer: \"${production_ca}\"|" "$traefik_cfg"
            log_success "caServer updated to production: $production_ca"

        elif ! grep -qE "^[[:space:]]*caServer:" "$traefik_cfg" 2>/dev/null; then
            log_info "caServer not set — adding production CA explicitly..."
            sed -i "/storage:.*acme\.json/a\\      caServer: \"${production_ca}\"" "$traefik_cfg"
            log_success "caServer set to production: $production_ca"
        else
            log_success "TLS CA verified: production Let's Encrypt endpoint confirmed"
        fi

        # Production: remove dashboard port (dashboard is disabled in production traefik.yml)
        sed -i '/TRAEFIK_DASHBOARD_PORT.*9090/d' "$compose_file"
    fi

    mkdir -p "$deploy_dir/traefik-config/letsencrypt"

    # ── Patch Traefik static configs with runtime values ──
    log_info "Setting Traefik Docker provider network to: $docker_proxy_network"
    local traefik_file
    for traefik_file in "$traefik_cfg" "$traefik_local_cfg"; do
        if [[ -f "$traefik_file" ]]; then
            sed -i "s|network:.*_proxy|network: ${docker_proxy_network}|" "$traefik_file"
        fi
    done
    log_success "Traefik network configuration updated"

    # 2. Domain, DNS provider, and ACME email
    local domain="${CONFIG[DOMAIN]}"
    log_info "Patching Traefik production config with domain: $domain"
    sed -i "s|__BASE_DOMAIN__|${domain}|g" "$traefik_cfg"

    local dns_provider="${CONFIG[DNS_PROVIDER]:-cloudflare}"
    log_info "Setting ACME DNS-01 challenge provider to: $dns_provider"
    sed -i "s|__DNS_PROVIDER__|${dns_provider}|g" "$traefik_cfg"
    setup_env_key DNS_PROVIDER "$dns_provider"

    local acme_email="${CONFIG[ACME_EMAIL]}"
    log_info "Setting ACME email to: $acme_email"
    sed -i "s|__ACME_EMAIL__|${acme_email}|g" "$traefik_cfg"
    setup_env_key ACME_EMAIL "$acme_email"

    log_success "Traefik wildcard TLS configuration complete (domain: $domain, provider: $dns_provider)"

    # ── Build and pull Docker images ──
    local -a compose_cmd=(docker compose -p "$compose_project_name" -f "$compose_file")
    [[ "$use_local_instancer" == "true" ]] && compose_cmd+=(--profile instancer)

    log_info "Building CTFd docker image... This may take a while"
    "${compose_cmd[@]}" build
    log_success "CTFd docker image successfully built"

    log_info "Pulling pre-built images (traefik, mariadb, redis${use_local_instancer:+, galvanize})..."
    "${compose_cmd[@]}" pull -q
    log_success "Docker images successfully pulled"

    # ── Extract playbooks from galvanize image ──
    if [[ "$use_local_instancer" == "true" ]]; then
        local playbooks_dir="$deploy_dir/data/galvanize/playbooks"
        if [[ ! -d "$playbooks_dir" ]] || [[ -z "$(ls -A "$playbooks_dir" 2>/dev/null)" ]]; then
            log_info "Extracting playbooks from galvanize image..."
            mkdir -p "$playbooks_dir"
            local galvanize_image
            galvanize_image="$(yq '.services.instancer.image' "$compose_file" 2>/dev/null)"
            if [[ -n "$galvanize_image" && "$galvanize_image" != "null" ]]; then
                docker create --name galvanize-extract "$galvanize_image" >/dev/null 2>&1
                docker cp galvanize-extract:/app/data/playbooks/. "$playbooks_dir/" 2>/dev/null \
                    && log_success "Playbooks extracted to: $playbooks_dir" \
                    || log_warning "Could not extract playbooks from galvanize image"
                docker rm galvanize-extract >/dev/null 2>&1
                chown -R 1000:1000 "$playbooks_dir"
            else
                log_warning "Could not determine galvanize image name — skipping playbook extraction"
            fi
        else
            log_info "Playbooks directory already populated, skipping extraction"
        fi
    fi

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
    "${compose_cmd[@]}" up -d
    log_success "CTFd containers started successfully"
    log_success "CTFd installation complete!"
    log_info ""
    log_info "CTFd is now available at: ${ctfd_full_url}"
    log_info ""

    # ── Write secrets to secured file (in deploy dir, not the repo) ──
    local secrets_file="${deploy_dir}/.secrets"
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
