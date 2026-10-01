#!/usr/bin/env bash
# modules/setup/backup.sh — Deploy the backup scripts, configure the off-site
# bucket upload, and install the cron job.
# Requires: lib/common.sh, lib/env.sh

[[ -n "${_SETUP_BACKUP_LOADED:-}" ]] && return 0
readonly _SETUP_BACKUP_LOADED=1

setup_backup_script() {
    local deploy_backup_dir="${CONFIG[DEPLOY_DIR]}/backup"
    local src_dir="$SCRIPT_DIR/backup"

    log_info "Setting up database backup scripts..."

    if [[ ! -f "$src_dir/backup_db.sh" ]]; then
        log_error "Backup script not found at: $src_dir/backup_db.sh"
        log_warning "Skipping backup script setup"
        return 1
    fi

    mkdir -p "$deploy_backup_dir"

    local f
    for f in backup_db.sh restore_db.sh common.sh; do
        if [[ -f "$src_dir/$f" ]]; then
            cp "$src_dir/$f" "$deploy_backup_dir/$f"
            chmod +x "$deploy_backup_dir/$f"
        fi
    done

    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$deploy_backup_dir"

    log_success "Backup scripts deployed to: $deploy_backup_dir/"
}

# ── Off-site upload ─────────────────────────────────────────────────────────
#
# backup_db.sh uploads each archive with rclone, which speaks to most storage
# providers (S3 and S3-compatible, Google Cloud Storage, Azure Blob, B2,
# SFTP...). Settings live in .env (BACKUP_REMOTE, BACKUP_REMOTE_RETENTION_DAYS)
# and the remote's definition in deploy/backup/rclone.conf (chmod 600, owned
# by the user the cron job runs as). They are kept on re-runs until changed
# with --backup-remote / --backup-rclone-config or turned off with
# --no-backup-remote.

# _as_backup_user CMD... — runs CMD as the user the backup cron job runs as
_as_backup_user() {
    local user="${SUDO_USER:-$USER}"
    if [[ "$user" == root || "$(id -un)" == "$user" ]]; then
        "$@"
    else
        sudo -u "$user" -H "$@"
    fi
}

setup_backup_remote() {
    local deploy_dir="${CONFIG[DEPLOY_DIR]}" user="${SUDO_USER:-$USER}"
    local env_file="$deploy_dir/.env" conf="$deploy_dir/backup/rclone.conf"

    if [[ "${CONFIG[NO_BACKUP_REMOTE]:-}" == "true" ]]; then
        setup_env_keys BACKUP_REMOTE ""
        log_info "Off-site backup upload disabled"
        return 0
    fi

    if [[ -n "${CONFIG[BACKUP_RCLONE_CONFIG]:-}" ]]; then
        install -m 600 -o "$user" -g "$user" "${CONFIG[BACKUP_RCLONE_CONFIG]}" "$conf"
        log_info "rclone config installed: $conf"
    fi

    local remote retention
    remote="${CONFIG[BACKUP_REMOTE]:-$(env_file_value "$env_file" BACKUP_REMOTE)}"
    if [[ -z "$remote" ]]; then
        log_debug "No off-site backup remote configured"
        return 0
    fi
    retention="${CONFIG[BACKUP_REMOTE_RETENTION]:-$(env_file_value "$env_file" BACKUP_REMOTE_RETENTION_DAYS)}"
    retention="${retention:-30}"

    # A named remote must be defined in the config; an rclone connection
    # string (":backend,option=value:path") is self-contained
    if [[ "$remote" != :* && ! -f "$conf" ]]; then
        error_exit "The backup remote '${remote%%:*}' is not defined: pass --backup-rclone-config FILE (made with 'rclone config'),
  or use an rclone connection string, e.g. --backup-remote ':s3,provider=AWS,env_auth=true:my-bucket/ctfd'"
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        log_info "Installing rclone..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rclone >/dev/null \
            || error_exit "Could not install rclone"
    fi

    # Check access now, as the cron user, rather than at the first backup.
    # mkdir creates the bucket/folder if needed (a no-op when it exists).
    local -a rclone_cmd=(rclone)
    [[ -f "$conf" ]] && rclone_cmd+=(--config "$conf")
    log_info "Checking access to $remote..."
    local output
    if ! output="$(_as_backup_user "${rclone_cmd[@]}" mkdir "$remote" 2>&1 \
            && _as_backup_user "${rclone_cmd[@]}" lsf --max-depth 1 "$remote" 2>&1 >/dev/null)"; then
        error_exit "Cannot write to the backup remote $remote:
$output"
    fi

    setup_env_keys BACKUP_REMOTE "$remote" BACKUP_REMOTE_RETENTION_DAYS "$retention"
    if (( retention > 0 )); then
        log_success "Backups will be uploaded to $remote (kept there for $retention days)"
    else
        log_success "Backups will be uploaded to $remote (kept there indefinitely)"
    fi
}

setup_backup_cron() {
    local backup_script="${CONFIG[DEPLOY_DIR]}/backup/backup_db.sh"
    local cron_log="${CONFIG[DEPLOY_DIR]}/cron_backup.log"
    local user="${SUDO_USER:-$USER}"
    local schedule="${CONFIG[BACKUP_SCHEDULE]}"

    log_info "Setting up backup cron job with schedule: $schedule"

    local cron_schedule
    case "$schedule" in
        daily)  cron_schedule="0 4 * * *"    ;;
        hourly) cron_schedule="0 * * * *"    ;;
        10min)  cron_schedule="*/10 * * * *" ;;
        *)
            log_error "Invalid backup schedule: $schedule"
            return 1
            ;;
    esac

    local cron_entry="$cron_schedule DEPLOY_DIR=\"${CONFIG[DEPLOY_DIR]}\" $backup_script >> $cron_log 2>&1"

    local current_crontab
    current_crontab="$(crontab -u "$user" -l 2>/dev/null || true)"

    local action="added"
    if grep -Fxq -- "$cron_entry" <<< "$current_crontab"; then
        action="unchanged"
    else
        # Replace any previous entry for this script (e.g. another schedule),
        # keeping every unrelated crontab line as is
        grep -Fq -- "$backup_script" <<< "$current_crontab" && action="updated"
        {
            [[ -n "$current_crontab" ]] && { printf '%s\n' "$current_crontab" | grep -vF -- "$backup_script" || true; }
            printf '%s\n' "$cron_entry"
        } | crontab -u "$user" -
    fi

    touch "$cron_log"
    chown "$user:$user" "$cron_log"

    local description
    case "$schedule" in
        daily)  description="daily backup at 4:00 AM"               ;;
        hourly) description="hourly backups at the top of each hour" ;;
        10min)  description="backups every 10 minutes"              ;;
    esac
    case "$action" in
        added)     log_success "Cron job added: $description" ;;
        updated)   log_success "Cron job updated: $description" ;;
        unchanged) log_info "Cron job already up to date: $description" ;;
    esac
    log_info "Backup logs will be written to: $cron_log"
}
