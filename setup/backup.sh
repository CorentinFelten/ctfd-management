#!/usr/bin/env bash
# setup/backup.sh — Make backup scripts executable and install cron job.
# Requires: lib/common.sh

[[ -n "${_SETUP_BACKUP_LOADED:-}" ]] && return 0
readonly _SETUP_BACKUP_LOADED=1

setup_backup_script() {
    local backup_script="$SCRIPT_DIR/backup/backup_db.sh"

    log_info "Setting up database backup script..."

    if [[ ! -f "$backup_script" ]]; then
        log_error "Backup script not found at: $backup_script"
        log_warning "Skipping backup script setup"
        return 1
    fi

    chmod +x "$backup_script"
    chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$backup_script"

    local restore_script="$SCRIPT_DIR/backup/restore_db.sh"
    if [[ -f "$restore_script" ]]; then
        chmod +x "$restore_script"
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$restore_script"
    fi

    log_success "Backup scripts setup at: $(dirname "$backup_script")/"
}

setup_backup_cron() {
    local backup_script="$SCRIPT_DIR/backup/backup_db.sh"
    local working_dir="${CONFIG[WORKING_DIR]}"
    local cron_log="$working_dir/cron_backup.log"
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

    local cron_entry="$cron_schedule $backup_script >> $cron_log 2>&1"

    if crontab -u "$user" -l 2>/dev/null | grep -Fq "$backup_script"; then
        log_warning "Cron job for backup script already exists, skipping..."
        return 0
    fi

    (crontab -u "$user" -l 2>/dev/null || true; echo "$cron_entry") | crontab -u "$user" -

    touch "$cron_log"
    chown "$user:$user" "$cron_log"

    case "$schedule" in
        daily)  log_success "Cron job added: Daily backup at 4:00 AM"                   ;;
        hourly) log_success "Cron job added: Hourly backups at the top of each hour"    ;;
        10min)  log_success "Cron job added: Backups every 10 minutes"                  ;;
    esac
    log_info "Backup logs will be written to: $cron_log"
}
