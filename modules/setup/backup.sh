#!/usr/bin/env bash
# modules/setup/backup.sh — Make backup scripts executable and install cron job.
# Requires: lib/common.sh

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
