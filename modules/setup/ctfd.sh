#!/usr/bin/env bash
# modules/setup/ctfd.sh — Copy config templates to DEPLOY_DIR, clone plugins, generate secrets, pull/build images.
# Requires: lib/common.sh, lib/env.sh, modules/setup/instancer.sh, modules/setup/theme.sh,
#           modules/setup/ctfd_admin.sh

[[ -n "${_SETUP_CTFD_LOADED:-}" ]] && return 0
readonly _SETUP_CTFD_LOADED=1

readonly DOCKER_PLUGIN_REPO="https://github.com/28Pollux28/zync"

# _existing_secret DEPLOY_DIR ENV_KEY [SECRETS_KEY]
#   Echoes a previously generated secret: from .env, or else from .secrets
#   (the plaintext copy written at the end of every setup run), so a lost or
#   recreated .env does not silently get fresh secrets. Placeholders from the
#   .env templates do not count.
_existing_secret() {
    local deploy_dir="$1" key="$2" secrets_key="${3:-$2}" value=""
    value="$(grep "^${key}=" "$deploy_dir/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    [[ "$value" == "SecretKeyHere" ]] && value=""
    if [[ -z "$value" && -f "$deploy_dir/.secrets" ]]; then
        value="$(grep "^${secrets_key}=" "$deploy_dir/.secrets" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
        [[ -n "$value" ]] && log_info "Recovered $key from $deploy_dir/.secrets"
    fi
    printf '%s' "$value"
}

# Number of config backups kept per kind (traefik-config, ctfd, compose file)
readonly CONFIG_BACKUPS_KEPT=3

# _prune_config_backups DEPLOY_DIR
#   Keeps only the most recent config backups made by previous setup runs
#   (their timestamped suffixes sort chronologically).
_prune_config_backups() {
    local deploy_dir="$1" prefix old
    for prefix in traefik-config ctfd docker-compose.yml; do
        while IFS= read -r old; do
            [[ -n "$old" ]] || continue
            rm -rf "$old"
            log_debug "Removed old config backup: $old"
        done < <(compgen -G "$deploy_dir/${prefix}.backup_*" | sort -r | tail -n +$((CONFIG_BACKUPS_KEPT + 1)))
    done
}

# _render_traefik_configs DIR NETWORK DOMAIN ACME_EMAIL DNS_PROVIDER
#   Sets the Docker provider network in both static configs, and fills the
#   __BASE_DOMAIN__, __ACME_EMAIL__ and __DNS_PROVIDER__ placeholders of the
#   Let's Encrypt one, in one yq pass per file. Values go through the
#   environment (strenv), so they are never parsed as yq. A template value
#   that is not a placeholder is left as it is.
_render_traefik_configs() {
    local dir="$1"
    T_NETWORK="$2" yq -i '.providers.docker.network = strenv(T_NETWORK)' "$dir/traefik-local.yml"
    T_NETWORK="$2" T_DOMAIN="$3" T_EMAIL="$4" T_PROVIDER="$5" yq -i '
        .providers.docker.network = strenv(T_NETWORK) |
        (.. | select(tag == "!!str")) |= (
            sub("__BASE_DOMAIN__"; strenv(T_DOMAIN)) |
            sub("__ACME_EMAIL__"; strenv(T_EMAIL)) |
            sub("__DNS_PROVIDER__"; strenv(T_PROVIDER))
        )
    ' "$dir/traefik.yml"
}

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
        # Config only: the certificate store (setup never modifies it, and it
        # holds private keys), the plugin clones and the themes are left out
        if [[ -d "$deploy_dir/traefik-config" ]]; then
            cp -r "$deploy_dir/traefik-config" "$deploy_dir/traefik-config.${backup_suffix}"
            rm -rf "$deploy_dir/traefik-config.${backup_suffix}/letsencrypt"
        fi
        if [[ -d "$deploy_dir/ctfd" ]]; then
            cp -r "$deploy_dir/ctfd" "$deploy_dir/ctfd.${backup_suffix}"
            rm -rf "$deploy_dir/ctfd.${backup_suffix}/plugins" "$deploy_dir/ctfd.${backup_suffix}/themes"
        fi
        cp "$deploy_dir/docker-compose.yml" "$deploy_dir/docker-compose.yml.${backup_suffix}"
        log_success "Backed up existing configs with suffix: $backup_suffix"
        _prune_config_backups "$deploy_dir"
    fi

    # Copy directory *contents* ("/."): with a plain `cp -r src dest`, an existing
    # dest would receive a nested src/ subfolder and the live configs would never
    # be refreshed on re-runs. letsencrypt/ and plugins/ are left untouched.
    mkdir -p "$deploy_dir/traefik-config" "$deploy_dir/ctfd"
    cp -r "$SCRIPT_DIR/config/traefik/." "$deploy_dir/traefik-config/"
    cp -r "$SCRIPT_DIR/config/ctfd/."    "$deploy_dir/ctfd/"
    cp    "$SCRIPT_DIR/config/docker-compose.yml" "$deploy_dir/docker-compose.yml"
    # Everything but data/, whose ownership create_and_set_owner and the
    # containers manage: a recursive chown of data/ on a re-run would hand
    # MariaDB's and Redis's files to the invoking user.
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$deploy_dir"
    find "$deploy_dir" -mindepth 1 -maxdepth 1 ! -name data \
        -exec chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" {} +
    log_success "Config templates copied to deploy dir"

    local compose_file="$deploy_dir/docker-compose.yml"
    local env_file="$deploy_dir/.env"

    # COMPOSE_PROJECT_NAME from the environment, else .env, else the default
    local compose_project_name="${COMPOSE_PROJECT_NAME:-$(env_file_value "$env_file" COMPOSE_PROJECT_NAME)}"
    compose_project_name="${compose_project_name:-ctfd_infra}"
    # Traefik's default Docker network: the one Galvanize attaches challenges to
    local challenge_network="${compose_project_name}_challenges"
    CONFIG[CHALLENGE_NETWORK]="$challenge_network"

    local jwt_secret_key
    jwt_secret_key="$(_existing_secret "$deploy_dir" ZYNC_JWT_SECRET JWT_SECRET_KEY)"
    if [[ -n "$jwt_secret_key" ]]; then
        log_info "Existing JWT secret found — preserving it"
    else
        jwt_secret_key="$(generate_password 48)"
    fi
    CONFIG[JWT_SECRET_KEY]="$jwt_secret_key"

    log_info "Installing CTFd..."

    # ── Clone / update plugin ──
    # A changed plugin needs a CTFd restart (plugins load at startup); the
    # container entrypoint then reinstalls requirements if they changed.
    local plugin_updated="false"
    mkdir -p "$deploy_dir/ctfd/plugins"
    if [[ ! -d "$plugin_path/.git" ]]; then
        log_info "Cloning zync instancer plugin..."
        git -C "$deploy_dir/ctfd/plugins" clone "$DOCKER_PLUGIN_REPO"
    else
        log_info "Zync plugin already exists, updating..."
        local rev_before rev_after
        rev_before="$(git -C "$plugin_path" rev-parse HEAD)"
        # Pull the branch the clone tracks (the repository default branch)
        if git -C "$plugin_path" pull --ff-only --quiet; then
            rev_after="$(git -C "$plugin_path" rev-parse HEAD)"
            if [[ "$rev_before" != "$rev_after" ]]; then
                plugin_updated="true"
                log_success "Zync plugin updated: ${rev_before:0:7} → ${rev_after:0:7}"
            else
                log_info "Zync plugin already up to date (${rev_after:0:7})"
            fi
        else
            log_warning "Could not fast-forward the zync plugin (local changes or diverged history?); keeping the current version"
        fi
    fi
    log_success "Instancer plugin configuration complete"

    # ── Generate or reuse secrets ──
    local secret_key db_password db_root_password
    secret_key="$(_existing_secret "$deploy_dir" SECRET_KEY)"
    db_password="$(_existing_secret "$deploy_dir" MARIADB_PASSWORD)"
    db_root_password="$(_existing_secret "$deploy_dir" MARIADB_ROOT_PASSWORD)"

    # MariaDB only applies its passwords when it initialises an empty data
    # directory: new ones would lock CTFd (and backups) out of existing data
    local mysql_data_dir="$deploy_dir/data/mysql"
    if [[ ( -z "$db_password" || -z "$db_root_password" ) \
          && -d "$mysql_data_dir" && -n "$(ls -A "$mysql_data_dir" 2>/dev/null)" ]]; then
        error_exit "MariaDB data already exists in $mysql_data_dir, but its passwords were not found in $deploy_dir/.env or $deploy_dir/.secrets.
  Generating new ones would lock CTFd out of the existing database. Either:
    • restore MARIADB_PASSWORD and MARIADB_ROOT_PASSWORD in $deploy_dir/.env, or
    • move $mysql_data_dir away to start with an empty database, then re-run setup."
    fi

    if [[ -n "$secret_key" && -n "$db_password" && -n "$db_root_password" ]]; then
        log_info "Existing secrets found — preserving them"
    else
        log_info "Generating secure secrets..."
        [[ -z "$secret_key" ]]        && secret_key="$(generate_password 32)"
        [[ -z "$db_password" ]]       && db_password="$(generate_password 16)"
        [[ -z "$db_root_password" ]]  && db_root_password="$(generate_password 16)"
    fi

    # ── Derived settings ──
    local scheme="https"
    [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]] && scheme="http"
    local ctfd_full_url="${scheme}://${CONFIG[DOMAIN]}"

    # Instancer URL: use --instancer-url if provided, otherwise the local instancer,
    # published by Traefik on its own subdomain. Zync calls it from players'
    # browsers, so it must be publicly reachable.
    local instancer_domain="instancer.${CONFIG[DOMAIN]}"
    if is_ip_address "${CONFIG[DOMAIN]}"; then
        # sslip.io wildcard DNS, same scheme Galvanize uses for challenge subdomains
        instancer_domain="instancer.${CONFIG[DOMAIN]//:/-}.sslip.io"
    fi
    local instancer_url="${CONFIG[INSTANCER_URL]:-${scheme}://${instancer_domain}}"

    # Recorded for challenges.sh: challenge images only need to be built on
    # this host when Galvanize deploys here (see is_local_instancer).
    local use_local_instancer="false" instancer_mode="local"
    if instancer_deployed_locally; then
        use_local_instancer="true"
    elif [[ -n "${CONFIG[INSTANCER_URL]:-}" ]]; then
        instancer_mode="external"
    else
        instancer_mode="none"
    fi

    # Basic-auth password of Galvanize's metrics server (port 5001, internal
    # network only; user "prometheus"). Generated for a local instancer, and
    # kept on every re-run, even one switching to another instancer mode, so
    # .secrets stays the same.
    local metrics_password
    metrics_password="$(_existing_secret "$deploy_dir" GALVANIZE_METRICS_PASSWORD)"
    if [[ -z "$metrics_password" && "$use_local_instancer" == "true" ]]; then
        metrics_password="$(generate_password 32)"
    fi
    CONFIG[GALVANIZE_METRICS_PASSWORD]="$metrics_password"

    # Docker Compose reads COMPOSE_PROFILES from .env, so a manual
    # `docker compose up -d`/`down`/`pull` in the deploy dir includes the
    # instancer exactly when it runs locally. Rewritten on every run so it
    # follows switches between local, external and no instancer.
    local compose_profiles=""
    [[ "$use_local_instancer" == "true" ]] && compose_profiles="instancer"

    # Traefik static config. The HTTP-only one serves Traefik's dashboard on
    # :9090 (the HTTPS one disables it). It has no authentication, so its port
    # is only published on the loopback interface, in both modes: reach it
    # with an SSH tunnel (ssh -L 9090:127.0.0.1:9090 <server>). Written on
    # every run, so .env files from older setups (all interfaces) are fixed.
    local traefik_static_config="./traefik-config/traefik.yml" dashboard_bind="127.0.0.1:9090"
    if [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]]; then
        traefik_static_config="./traefik-config/traefik-local.yml"
        log_info "HTTPS disabled — using the HTTP-only Traefik config"
    else
        log_info "HTTPS enabled — using the Let's Encrypt Traefik config"
    fi

    local dns_provider="${CONFIG[DNS_PROVIDER]:-cloudflare}"
    local acme_email="${CONFIG[ACME_EMAIL]}"

    # ── Local instancer setup ──
    # Skipped when --instancer-url (external) or --no-instancer is given.
    local instancer_config_path="$deploy_dir/data/galvanize/config.yaml"
    if [[ "$use_local_instancer" == "true" ]]; then
        log_info "Setting up local instancer..."

        mkdir -p "$deploy_dir/data/galvanize"
        cp "$SCRIPT_DIR/config/galvanize/config.yaml" "$instancer_config_path"

        # Ansible playbooks are shipped with this repo (config/galvanize/playbooks)
        # rather than extracted from the Galvanize image. The data/ bind mount
        # hides the playbooks baked into the image, so they must live on the host.
        local playbooks_dir="$deploy_dir/data/galvanize/playbooks"
        mkdir -p "$playbooks_dir"
        cp "$SCRIPT_DIR"/config/galvanize/playbooks/*.yaml "$playbooks_dir/"
        log_success "Galvanize playbooks copied to: $playbooks_dir"

        setup_instancer
        chown -R 1000:1000 "$deploy_dir/data/galvanize"
    fi

    # ── .env, written once ──
    local -a env_settings=(
        COMPOSE_PROJECT_NAME  "$compose_project_name"
        DATA_DIR              ./data
        SECRET_KEY            "$secret_key"
        MARIADB_PASSWORD      "$db_password"
        MARIADB_ROOT_PASSWORD "$db_root_password"
        BASE_DOMAIN           "${CONFIG[DOMAIN]}"
        CTFD_URL              "$ctfd_full_url"
        INSTANCER_DOMAIN      "$instancer_domain"
        ZYNC_DEPLOYER_URL     "$instancer_url"
        ZYNC_JWT_SECRET       "$jwt_secret_key"
        INSTANCER_MODE        "$instancer_mode"
        COMPOSE_PROFILES      "$compose_profiles"
        TRAEFIK_STATIC_CONFIG "$traefik_static_config"
        TRAEFIK_DASHBOARD_BIND "$dashboard_bind"
        DNS_PROVIDER          "$dns_provider"
        ACME_EMAIL            "$acme_email"
    )
    if [[ "$use_local_instancer" == "true" ]]; then
        env_settings+=(
            GALVANIZE_CONFIG_PATH "$instancer_config_path"
            SSH_KEY_PATH          "${CONFIG[SSH_KEY_PATH]}"
        )
    fi
    [[ -n "$metrics_password" ]] && env_settings+=(GALVANIZE_METRICS_PASSWORD "$metrics_password")
    setup_env_keys "${env_settings[@]}"
    log_success "Settings written to $env_file"

    # ── Traefik ──
    mkdir -p "$deploy_dir/traefik-config/letsencrypt"
    # Traefik's env_file must exist even when no DNS credentials were set.
    # Owned like the rest of the deploy dir, so the backup cron job, which
    # runs as that user, can archive it (Traefik reads it as root).
    ensure_traefik_env_file
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$(traefik_env_file)"
    _render_traefik_configs "$deploy_dir/traefik-config" "$challenge_network" \
        "${CONFIG[DOMAIN]}" "$acme_email" "$dns_provider"
    if [[ "${CONFIG[NO_HTTPS]:-}" == "true" ]]; then
        log_success "Traefik configured: HTTP only, challenge network $challenge_network"
    else
        log_success "Traefik configured: certificates for ${CONFIG[DOMAIN]} and *.${CONFIG[DOMAIN]} via $dns_provider, challenge network $challenge_network"
    fi

    # ── Build and pull Docker images ──
    local -a compose_cmd=(docker compose -p "$compose_project_name" -f "$compose_file")
    [[ "$use_local_instancer" == "true" ]] && compose_cmd+=(--profile instancer)

    # ── Custom themes (built into the CTFd image) ──
    setup_themes

    log_info "Building CTFd docker image... This may take a while"
    "${compose_cmd[@]}" build
    log_success "CTFd docker image successfully built"

    log_info "Pulling pre-built images (traefik, mariadb, redis${use_local_instancer:+, galvanize})..."
    "${compose_cmd[@]}" pull -q
    log_success "Docker images successfully pulled"

    # ── Start containers ──
    # A previously local instancer is no longer wanted: stop and remove it,
    # since `up -d` leaves containers of inactive profiles running.
    if [[ "$use_local_instancer" != "true" ]]; then
        docker compose -p "$compose_project_name" -f "$compose_file" --profile instancer \
            rm --stop --force instancer >/dev/null 2>&1 || true
    fi

    log_info "Starting CTFd containers..."
    "${compose_cmd[@]}" up -d
    log_success "CTFd containers started successfully"

    if [[ "${CONFIG[ANSIBLE_KEY_REGENERATED]:-}" == "true" ]]; then
        log_info "Recreating the instancer so it picks up the new Ansible SSH key..."
        "${compose_cmd[@]}" up -d --force-recreate --no-deps instancer
        log_success "Instancer recreated"
    fi

    if [[ "$plugin_updated" == "true" ]]; then
        log_info "Restarting CTFd to load the updated zync plugin..."
        "${compose_cmd[@]}" restart ctfd
        log_success "CTFd restarted"
    fi

    # First admin and event settings (new deployments), then the theme
    run_ctfd_first_setup compose_cmd
    apply_active_theme compose_cmd

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
        if [[ -n "$metrics_password" ]]; then
            echo "GALVANIZE_METRICS_PASSWORD=${metrics_password}" >> "$secrets_file"
        fi
    )
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$secrets_file"

    log_success "Generated secrets written to: ${secrets_file} (chmod 600)"
    log_warning "Review this file and store the credentials securely."
}
