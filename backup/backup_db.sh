#!/bin/bash
# CTFd Essential Backup Script
# Backs up the MariaDB database, CTFd uploads and the Galvanize instancer's
# database into ctfd_backup_<date>.tar.gz, optionally uploaded to an off-site
# bucket (setup.sh --backup-remote). The deployment's .env, .secrets and
# traefik.env go into a separate ctfd_config_<date>.tar.gz (chmod 600) that
# never leaves this server.
#
# Designed to run via cron. Uses flock to prevent concurrent executions.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# DEPLOY_DIR is injected by cron (set via modules/setup/backup.sh) and points to
# the deployment working directory ($WORKING_DIR/deploy) where .env and
# docker-compose.yml live.  Falls back to the parent of the repo for backwards
# compatibility with manually invoked runs.
readonly _DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
readonly ENV_FILE="${_DEPLOY_DIR}/.env"
readonly DOCKER_COMPOSE_PATH="${_DEPLOY_DIR}/docker-compose.yml"
readonly BACKUP_BASE_DIR="$(dirname "${_DEPLOY_DIR}")/backups"
readonly CTFD_UPLOADS_PATH="${_DEPLOY_DIR}/data/CTFd/uploads"
readonly GALVANIZE_DB_PATH="${_DEPLOY_DIR}/data/galvanize/deployer.sqlite"
# Deployment config and secrets, archived separately and never uploaded
readonly CONFIG_FILES=(.env .secrets traefik.env)
readonly MAX_BACKUPS=5
readonly CONTAINER_NAME="maria-db"
readonly LOCK_FILE="/tmp/ctfd_backup.lock"

# Runtime variables
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
BACKUP_DIR="${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_BASE_DIR}/backup.log"

# ============================================================================
# Shared utilities
# ============================================================================

# shellcheck source=backup/common.sh
source "${SCRIPT_DIR}/common.sh"

# ============================================================================
# Functions
# ============================================================================

cleanup() {
    # Remove incomplete backup directory on failure
    if [[ -d "${BACKUP_DIR}" ]]; then
        rm -rf "${BACKUP_DIR}"
    fi
}

# ============================================================================
# Lock — prevent concurrent backup runs
# ============================================================================

exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Another backup is already running (lock: ${LOCK_FILE})" >&2
    exit 1
fi

# ============================================================================
# Main
# ============================================================================

mkdir -p "${BACKUP_BASE_DIR}"
trap cleanup ERR

log_message "========== Starting CTFd Backup =========="

# Extract database credentials from .env
log_message "Reading database credentials..."
DB_ROOT_PASSWORD="$(read_env_value "MARIADB_ROOT_PASSWORD")"
DB_NAME="$(read_env_value "MARIADB_DATABASE")"

# MARIADB_DATABASE may not be in .env since it's hardcoded in compose; default to "ctfd"
DB_NAME="${DB_NAME:-ctfd}"

if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
    log_message "ERROR: Failed to read MARIADB_ROOT_PASSWORD from ${ENV_FILE}"
    exit 1
fi

# Validate DB name (only allow safe characters to prevent injection)
if [[ ! "${DB_NAME}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    log_message "ERROR: Invalid database name: ${DB_NAME}"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    log_message "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

# ---------- Step 1: Backup MariaDB database ----------
log_message "Step 1/3: Backing up MariaDB database..."
log_message "  Database contains: users, teams, challenges, submissions, solves, scores, flags, hints, settings, etc."

# Use MYSQL_PWD env var instead of -p flag to avoid password exposure in ps output
if docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
    mysqldump -u root --single-transaction --quick --lock-tables=false "${DB_NAME}" \
    > "${BACKUP_DIR}/database.sql"; then

    DB_SIZE="$(du -h "${BACKUP_DIR}/database.sql" | cut -f1)"
    log_message "SUCCESS: Database backup completed (${DB_SIZE})"
else
    log_message "ERROR: Database backup failed"
    exit 1
fi

# Verify: file exists, is non-empty, and dump looks complete
if [[ ! -s "${BACKUP_DIR}/database.sql" ]]; then
    log_message "ERROR: Database backup file is empty or missing"
    exit 1
fi

if ! tail -5 "${BACKUP_DIR}/database.sql" | grep -Fq "Dump completed"; then
    log_message "WARNING: Database dump may be incomplete (missing 'Dump completed' footer)"
fi

# ---------- Step 2: Backup CTFd uploads ----------
log_message "Step 2/3: Backing up CTFd uploads..."

if [[ -d "${CTFD_UPLOADS_PATH}" ]]; then
    # Check if directory has content (avoid ls -A parsing issues)
    if compgen -G "${CTFD_UPLOADS_PATH}/*" > /dev/null 2>&1; then
        tar -cf "${BACKUP_DIR}/ctfd_uploads.tar" \
            -C "$(dirname "${CTFD_UPLOADS_PATH}")" \
            "$(basename "${CTFD_UPLOADS_PATH}")"
        UPLOAD_SIZE="$(du -h "${BACKUP_DIR}/ctfd_uploads.tar" | cut -f1)"
        log_message "SUCCESS: CTFd uploads backed up (${UPLOAD_SIZE})"
    else
        log_message "INFO: Uploads directory is empty, skipping"
        touch "${BACKUP_DIR}/no_uploads.txt"
    fi
else
    log_message "WARNING: CTFd uploads directory not found at ${CTFD_UPLOADS_PATH}"
    log_message "  If you have challenge files or user uploads, verify the path is correct"
fi

# ---------- Step 3: Backup the Galvanize instancer's database ----------
# SQLite's online backup API (through Python, present on every supported
# server) gives a consistent copy while Galvanize keeps writing to it in WAL
# mode, which copying the file would not.
log_message "Step 3/3: Backing up the Galvanize instancer database..."

if [[ -f "${GALVANIZE_DB_PATH}" ]]; then
    mkdir -p "${BACKUP_DIR}/galvanize"
    if python3 - "${GALVANIZE_DB_PATH}" "${BACKUP_DIR}/galvanize/deployer.sqlite" <<'PY' >> "${LOG_FILE}" 2>&1
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=30)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
dst.close()
src.close()
PY
    then
        GALVANIZE_SIZE="$(du -h "${BACKUP_DIR}/galvanize/deployer.sqlite" | cut -f1)"
        log_message "SUCCESS: Galvanize database backed up (${GALVANIZE_SIZE})"
    else
        log_message "ERROR: Galvanize database backup failed"
        exit 1
    fi
else
    log_message "INFO: No local Galvanize instancer database, skipping"
fi

# ---------- Create compressed archive ----------
TOTAL_SIZE="$(du -sh "${BACKUP_DIR}" | cut -f1)"
log_message "Total backup size: ${TOTAL_SIZE}"

log_message "Creating compressed backup archive..."
tar -czf "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" \
    -C "${BACKUP_BASE_DIR}" "ctfd_backup_${TIMESTAMP}"
ARCHIVE_SIZE="$(du -h "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" | cut -f1)"
log_message "SUCCESS: Complete backup archive created (${ARCHIVE_SIZE})"

# Remove uncompressed backup directory
rm -rf "${BACKUP_DIR}"

# Create symlink to latest backup
ln -sf "${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz" "${BACKUP_BASE_DIR}/latest_backup.tar.gz"

# ---------- Config and secrets archive (local only) ----------
# The deployment's settings and generated secrets, needed to rebuild the
# server. Separate from the data archive so it is never uploaded, and
# readable only by its owner.
CONFIG_ARCHIVE="${BACKUP_BASE_DIR}/ctfd_config_${TIMESTAMP}.tar.gz"
config_present=()
for f in "${CONFIG_FILES[@]}"; do
    if [[ -r "${_DEPLOY_DIR}/${f}" ]]; then
        config_present+=("${f}")
    elif [[ -e "${_DEPLOY_DIR}/${f}" ]]; then
        log_message "WARNING: ${_DEPLOY_DIR}/${f} is not readable by $(id -un), not archived"
    fi
done
if (( ${#config_present[@]} > 0 )); then
    ( umask 077; tar -czf "${CONFIG_ARCHIVE}" -C "${_DEPLOY_DIR}" "${config_present[@]}" )
    ln -sf "${CONFIG_ARCHIVE}" "${BACKUP_BASE_DIR}/latest_config.tar.gz"
    log_message "SUCCESS: Config files archived (${config_present[*]}), kept on this server only"
fi

# ---------- Clean up old backups ----------
log_message "Cleaning up old backups, keeping only the ${MAX_BACKUPS} most recent..."

BACKUP_COUNT=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "ctfd_backup_*.tar.gz" -type f | wc -l)

if [[ "${BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]]; then
    # Sort by modification time (newest first), skip the first MAX_BACKUPS, delete the rest
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "ctfd_backup_*.tar.gz" -type f -printf '%T@ %p\n' \
        | sort -rn \
        | tail -n +"$((MAX_BACKUPS + 1))" \
        | cut -d' ' -f2- \
        | xargs rm -f
    log_message "Deleted $((BACKUP_COUNT - MAX_BACKUPS)) old backup(s)"
fi

REMAINING_COUNT=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "ctfd_backup_*.tar.gz" -type f | wc -l)
log_message "Retained ${REMAINING_COUNT} backup(s)"

# Config archives follow the same rotation
find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "ctfd_config_*.tar.gz" -type f -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +"$((MAX_BACKUPS + 1))" \
    | cut -d' ' -f2- \
    | xargs -r rm -f

# ---------- Upload to the off-site bucket ----------
# Configured by setup.sh --backup-remote (rclone: S3 and S3-compatible, GCS,
# Azure Blob, B2, SFTP...). The local archive is kept whatever happens; a
# failed upload makes the run fail, so it shows in the cron log.
BACKUP_REMOTE="$(read_env_value "BACKUP_REMOTE")"
if [[ -n "${BACKUP_REMOTE}" ]]; then
    ARCHIVE="${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}.tar.gz"
    RCLONE=(rclone --retries 3 --low-level-retries 10)
    [[ -f "${SCRIPT_DIR}/rclone.conf" ]] && RCLONE+=(--config "${SCRIPT_DIR}/rclone.conf")

    log_message "Uploading $(basename "${ARCHIVE}") to ${BACKUP_REMOTE}..."
    if ! command -v rclone >/dev/null 2>&1; then
        log_message "ERROR: rclone is not installed; re-run setup.sh with --backup-remote"
        exit 1
    fi
    if ! "${RCLONE[@]}" copy "${ARCHIVE}" "${BACKUP_REMOTE}" >> "${LOG_FILE}" 2>&1; then
        log_message "ERROR: Upload to ${BACKUP_REMOTE} failed (the local backup is kept)"
        exit 1
    fi
    log_message "SUCCESS: Uploaded to ${BACKUP_REMOTE}"

    RETENTION_DAYS="$(read_env_value "BACKUP_REMOTE_RETENTION_DAYS")"
    if [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ && "${RETENTION_DAYS}" -gt 0 ]]; then
        if "${RCLONE[@]}" delete "${BACKUP_REMOTE}" --max-depth 1 \
                --include "ctfd_backup_*.tar.gz" --min-age "${RETENTION_DAYS}d" >> "${LOG_FILE}" 2>&1; then
            log_message "Deleted uploaded backups older than ${RETENTION_DAYS} days"
        else
            log_message "WARNING: Could not delete uploaded backups older than ${RETENTION_DAYS} days"
        fi
    fi
fi

log_message "========== Backup Complete =========="
exit 0