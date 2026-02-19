#!/bin/bash
# CTFd Restore Script
# Restores MariaDB database and CTFd uploads from backup

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
readonly CONTAINER_NAME="maria-db"

LOG_FILE="${BACKUP_BASE_DIR}/restore.log"
RESTORE_TEMP_DIR="${BACKUP_BASE_DIR}/restore_temp"

# ============================================================================
# Functions
# ============================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Read a value from the .env file (same logic as backup script)
read_env_value() {
    local key="$1"
    local value=""

    if [[ -f "${ENV_FILE}" ]]; then
        value=$(grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"\r")
    fi

    if [[ -z "$value" ]] && command -v docker &>/dev/null; then
        value=$(docker compose -f "${DOCKER_COMPOSE_PATH}" config 2>/dev/null \
            | grep -A0 "${key}" | head -n1 | sed 's/.*: //' | tr -d "'\"\r" || true)
    fi

    echo "$value"
}

cleanup() {
    if [[ -d "${RESTORE_TEMP_DIR}" ]]; then
        log_message "Cleaning up temporary files..."
        rm -rf "${RESTORE_TEMP_DIR}"
    fi
}

usage() {
    cat <<EOF
Usage: $0 <backup_file>

Examples:
  $0 ${BACKUP_BASE_DIR}/ctfd_backup_20240101_120000.tar.gz
  $0 latest    # Restore the most recent backup

This script must be run as root (or via sudo).
EOF
    exit 1
}

# ============================================================================
# Pre-flight: root check FIRST, before any prompts or work
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Re-executing with sudo..." >&2
    exec sudo bash "$0" "$@"
fi

# ============================================================================
# Argument parsing
# ============================================================================

if [[ $# -eq 0 ]]; then
    usage
fi

BACKUP_FILE="$1"

# Handle 'latest' keyword
if [[ "${BACKUP_FILE}" == "latest" ]]; then
    if [[ -L "${BACKUP_BASE_DIR}/latest_backup.tar.gz" ]]; then
        BACKUP_FILE="$(readlink -f "${BACKUP_BASE_DIR}/latest_backup.tar.gz")"
        echo "Using latest backup: ${BACKUP_FILE}"
    else
        echo "ERROR: No latest backup symlink found" >&2
        exit 1
    fi
fi

# Verify backup file exists
if [[ ! -f "${BACKUP_FILE}" ]]; then
    echo "ERROR: Backup file not found: ${BACKUP_FILE}" >&2
    exit 1
fi

# ============================================================================
# Confirmation prompt (runs AFTER root escalation so it only asks once)
# ============================================================================

mkdir -p "${BACKUP_BASE_DIR}"
trap cleanup EXIT

log_message "========== Starting CTFd Restore =========="
log_message "Backup file: ${BACKUP_FILE}"

echo ""
echo "WARNING: This will REPLACE all current CTFd data with the backup!"
echo "  - Database will be dropped and restored"
echo "  - Uploads directory will be replaced"
echo ""
read -rp "Are you sure you want to continue? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    log_message "Restore cancelled by user"
    exit 0
fi

# ============================================================================
# Extract backup archive
# ============================================================================

log_message "Extracting backup archive..."
mkdir -p "${RESTORE_TEMP_DIR}"
if ! tar -xzf "${BACKUP_FILE}" -C "${RESTORE_TEMP_DIR}"; then
    log_message "ERROR: Failed to extract backup archive"
    exit 1
fi

BACKUP_DIR="$(find "${RESTORE_TEMP_DIR}" -maxdepth 1 -type d -name "ctfd_backup_*" | head -n 1)"

if [[ -z "${BACKUP_DIR}" ]]; then
    log_message "ERROR: Could not find backup directory in extracted archive"
    exit 1
fi

log_message "SUCCESS: Backup extracted to temporary directory"

# ============================================================================
# Read database credentials
# ============================================================================

log_message "Reading database credentials..."

DB_ROOT_PASSWORD="$(read_env_value "MARIADB_ROOT_PASSWORD")"
DB_NAME="$(read_env_value "MARIADB_DATABASE")"
DB_NAME="${DB_NAME:-ctfd}"

if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
    log_message "ERROR: Failed to read MARIADB_ROOT_PASSWORD from ${ENV_FILE}"
    exit 1
fi

# Sanitize database name to prevent SQL injection
if [[ ! "${DB_NAME}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    log_message "ERROR: Invalid database name: ${DB_NAME}"
    exit 1
fi

log_message "SUCCESS: Credentials obtained"

# ============================================================================
# Pre-checks
# ============================================================================

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_message "ERROR: Container ${CONTAINER_NAME} is not running"
    log_message "Please start your CTFd stack first: docker compose -f ${DOCKER_COMPOSE_PATH} up -d"
    exit 1
fi

# Verify database connection (use MYSQL_PWD to avoid password in ps output)
log_message "Verifying database connection..."
if ! docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
    mysql -u root -e "SELECT 1;" &>/dev/null; then
    log_message "ERROR: Cannot connect to database. Password may be incorrect."
    exit 1
fi

# ============================================================================
# Step 1: Restore MariaDB database
# ============================================================================

log_message "Step 1/2: Restoring MariaDB database..."

if [[ ! -f "${BACKUP_DIR}/database.sql.gz" ]]; then
    log_message "ERROR: Database backup file not found in archive"
    exit 1
fi

log_message "  Dropping existing database..."
if ! docker exec -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
    mysql -u root -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\`;" 2>/dev/null; then
    log_message "ERROR: Failed to drop/create database"
    exit 1
fi

log_message "  Restoring database from backup..."
if gunzip < "${BACKUP_DIR}/database.sql.gz" \
    | docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${CONTAINER_NAME}" \
        mysql -u root "${DB_NAME}" 2>/dev/null; then
    log_message "SUCCESS: Database restored successfully"
else
    log_message "ERROR: Database restore failed"
    exit 1
fi

# ============================================================================
# Step 2: Restore CTFd uploads
# ============================================================================

log_message "Step 2/2: Restoring CTFd uploads..."

if [[ -f "${BACKUP_DIR}/no_uploads.txt" ]]; then
    log_message "INFO: Backup contained no uploads, skipping"
elif [[ -f "${BACKUP_DIR}/ctfd_uploads.tar.gz" ]]; then
    # Backup existing uploads if they exist
    if [[ -d "${CTFD_UPLOADS_PATH}" ]] && compgen -G "${CTFD_UPLOADS_PATH}/*" >/dev/null 2>&1; then
        UPLOADS_BACKUP="${CTFD_UPLOADS_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
        log_message "  Backing up existing uploads to: ${UPLOADS_BACKUP}"
        mv "${CTFD_UPLOADS_PATH}" "${UPLOADS_BACKUP}"
    else
        rm -rf "${CTFD_UPLOADS_PATH}" 2>/dev/null || true
    fi

    log_message "  Extracting uploads..."
    mkdir -p "$(dirname "${CTFD_UPLOADS_PATH}")"

    if tar --same-owner -xzf "${BACKUP_DIR}/ctfd_uploads.tar.gz" -C "$(dirname "${CTFD_UPLOADS_PATH}")"; then
        # Set appropriate permissions (not 755 — uploads should not be world-executable)
        find "${CTFD_UPLOADS_PATH}" -type d -exec chmod 750 {} \;
        find "${CTFD_UPLOADS_PATH}" -type f -exec chmod 640 {} \;
        chown -R 1001:1001 "${CTFD_UPLOADS_PATH}"

        UPLOAD_COUNT="$(find "${CTFD_UPLOADS_PATH}" -type f 2>/dev/null | wc -l)"
        log_message "SUCCESS: CTFd uploads restored (${UPLOAD_COUNT} files)"
    else
        log_message "ERROR: Failed to extract uploads"
        exit 1
    fi
else
    log_message "WARNING: No uploads found in backup"
fi

# ============================================================================
# Done
# ============================================================================

log_message "========== CTFd Restore Completed Successfully =========="
log_message "Please restart CTFd to apply changes:"
log_message "  docker compose -f ${DOCKER_COMPOSE_PATH} restart"

exit 0