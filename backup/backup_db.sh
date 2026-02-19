#!/bin/bash
# CTFd Essential Backup Script
# Backs up MariaDB database and CTFd uploads (everything needed for complete restoration)
#
# Designed to run via cron. Uses flock to prevent concurrent executions.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BASE_PATH="$(cd "$INFRA_DIR/.." && pwd)"
readonly ENV_FILE="${INFRA_DIR}/.env"
readonly DOCKER_COMPOSE_PATH="${INFRA_DIR}/docker-compose.yml"
readonly BACKUP_BASE_DIR="${BASE_PATH}/backups"
readonly CTFD_UPLOADS_PATH="${BASE_PATH}/data/CTFd/uploads"
readonly MAX_BACKUPS=5
readonly CONTAINER_NAME="maria-db"
readonly LOCK_FILE="/tmp/ctfd_backup.lock"

# Runtime variables
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
BACKUP_DIR="${BACKUP_BASE_DIR}/ctfd_backup_${TIMESTAMP}"
LOG_FILE="${BACKUP_BASE_DIR}/backup.log"

# ============================================================================
# Functions
# ============================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Read a value from the .env file (where setup.sh writes actual credentials).
# Falls back to a simple grep of docker-compose for the default value.
read_env_value() {
    local key="$1"
    local value=""

    # Primary: read from .env (contains actual generated secrets)
    if [[ -f "${ENV_FILE}" ]]; then
        value=$(grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"\r")
    fi

    # Fallback: try docker compose config (resolves all variables)
    if [[ -z "$value" ]] && command -v docker &>/dev/null; then
        value=$(docker compose -f "${DOCKER_COMPOSE_PATH}" config 2>/dev/null \
            | grep -A0 "${key}" | head -n1 | sed 's/.*: //' | tr -d "'\"\r" || true)
    fi

    echo "$value"
}

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
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_message "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

# ---------- Step 1: Backup MariaDB database ----------
log_message "Step 1/2: Backing up MariaDB database..."
log_message "  Database contains: users, teams, challenges, submissions, solves, scores, flags, hints, settings, etc."

# Use MYSQL_PWD env var instead of -p flag to avoid password exposure in ps output
if docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
    mysqldump -u root --single-transaction --quick --lock-tables=false "${DB_NAME}" \
    | gzip > "${BACKUP_DIR}/database.sql.gz"; then

    DB_SIZE="$(du -h "${BACKUP_DIR}/database.sql.gz" | cut -f1)"
    log_message "SUCCESS: Database backup completed (${DB_SIZE})"
else
    log_message "ERROR: Database backup failed"
    exit 1
fi

# Verify: file exists, is non-empty, and dump looks complete
if [[ ! -s "${BACKUP_DIR}/database.sql.gz" ]]; then
    log_message "ERROR: Database backup file is empty or missing"
    exit 1
fi

if ! gunzip -c "${BACKUP_DIR}/database.sql.gz" | tail -5 | grep -q "Dump completed"; then
    log_message "WARNING: Database dump may be incomplete (missing 'Dump completed' footer)"
fi

# ---------- Step 2: Backup CTFd uploads ----------
log_message "Step 2/2: Backing up CTFd uploads..."

if [[ -d "${CTFD_UPLOADS_PATH}" ]]; then
    # Check if directory has content (avoid ls -A parsing issues)
    if compgen -G "${CTFD_UPLOADS_PATH}/*" > /dev/null 2>&1; then
        tar -czf "${BACKUP_DIR}/ctfd_uploads.tar.gz" \
            -C "$(dirname "${CTFD_UPLOADS_PATH}")" \
            "$(basename "${CTFD_UPLOADS_PATH}")"
        UPLOAD_SIZE="$(du -h "${BACKUP_DIR}/ctfd_uploads.tar.gz" | cut -f1)"
        log_message "SUCCESS: CTFd uploads backed up (${UPLOAD_SIZE})"
    else
        log_message "INFO: Uploads directory is empty, skipping"
        touch "${BACKUP_DIR}/no_uploads.txt"
    fi
else
    log_message "WARNING: CTFd uploads directory not found at ${CTFD_UPLOADS_PATH}"
    log_message "  If you have challenge files or user uploads, verify the path is correct"
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
log_message "========== Backup Complete =========="
exit 0