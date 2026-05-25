#!/usr/bin/env bash
# CTFd Server Setup Script
# Automates installation and configuration of CTFd with Docker, Traefik, and the Galvanize instancer.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source shared libraries ──────────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/dns.sh"

# ── Source setup modules ─────────────────────────────────────────────────────

source "$SCRIPT_DIR/modules/setup/system.sh"
source "$SCRIPT_DIR/modules/setup/docker.sh"
source "$SCRIPT_DIR/modules/setup/directories.sh"
source "$SCRIPT_DIR/modules/setup/theme.sh"
source "$SCRIPT_DIR/modules/setup/instancer.sh"
source "$SCRIPT_DIR/modules/setup/ctfd.sh"
source "$SCRIPT_DIR/modules/setup/backup.sh"

# ── Configuration ────────────────────────────────────────────────────────────

declare -A CONFIG=(
    [CONFIGURE_DOCKER]="true"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [DEPLOY_DIR]=""
    [THEME]=""
    [BACKUP_SCHEDULE]="daily"
    [JWT_SECRET_KEY]=""
    [DOCKER_ENV_FILE]="env.production"
    [DNS_PROVIDER]="cloudflare"
    [NO_INSTANCER]=""
)

# ── Usage ────────────────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --domain URL          Set CTFd URL (mandatory)
                            Note: IP addresses automatically enable --no-https
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --theme PATH_OR_URL     Path to local theme folder or Git URL to clone
    --backup-schedule TYPE  Set backup schedule: daily, hourly, or 10min (default: daily)
    --instancer-url URL     Use an external Galvanize instancer (skips local setup)
    --no-instancer          Skip Galvanize setup entirely (deploy it separately later)
    --dns-provider NAME     DNS provider for wildcard TLS certs (default: cloudflare)
                            Supported: cloudflare, route53, digitalocean, hetzner,
                            ovh, gandiv5, gcloud, godaddy, namecheap, ionos
                            Or any lego provider (https://go-acme.github.io/lego/dns/)
    --no-https              Disable HTTPS configuration for CTFd
                            (automatically enabled for IP addresses)
    --help                  Show this help message

Directory structure:
    <working-folder>/deploy/                          Deployment working directory (configs, .env, compose)
    <working-folder>/deploy/traefik-config/           Traefik static & dynamic configs, letsencrypt
    <working-folder>/deploy/ctfd-config/              CTFd Dockerfile and custom entrypoint
    <working-folder>/deploy/ctfd-config/plugins/zync/ CTFd instancer plugin clone
    <working-folder>/deploy/ansible-ssh/              Ansible SSH key pair
    <working-folder>/deploy/data/                     Runtime data (database, uploads, galvanize)
    <working-folder>/deploy/cron_backup.log           Backup cron job log

Examples:
    $SCRIPT_NAME --domain example.com
    $SCRIPT_NAME --domain example.com --dns-provider cloudflare
    $SCRIPT_NAME --domain 192.168.1.100
    $SCRIPT_NAME --domain example.com --working-folder /opt/ctfd
    $SCRIPT_NAME --domain example.com --theme /home/user/my-custom-theme
    $SCRIPT_NAME --domain example.com --theme https://github.com/user/theme.git
    $SCRIPT_NAME --domain example.com --backup-schedule hourly
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain)
                [[ -n ${2:-} ]] || error_exit "Missing value for --domain"
                CONFIG[DOMAIN]="$2"; shift 2 ;;
            --working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"; shift 2 ;;
            --theme)
                [[ -n ${2:-} ]] || error_exit "Missing value for --theme"
                CONFIG[THEME]="$2"; shift 2 ;;
            --backup-schedule)
                [[ -n ${2:-} ]] || error_exit "Missing value for --backup-schedule"
                case ${2,,} in
                    daily|hourly|10min) CONFIG[BACKUP_SCHEDULE]="${2,,}" ;;
                    *) error_exit "Invalid backup schedule: $2. Must be: daily, hourly, or 10min" ;;
                esac
                shift 2 ;;
            --instancer-url)
                [[ -n ${2:-} ]] || error_exit "Missing value for --instancer-url"
                CONFIG[INSTANCER_URL]="$2"; shift 2 ;;
            --no-instancer)
                CONFIG[NO_INSTANCER]="true"; shift ;;
            --dns-provider)
                [[ -n ${2:-} ]] || error_exit "Missing value for --dns-provider"
                CONFIG[DNS_PROVIDER]="$2"; shift 2 ;;
            --no-https)
                CONFIG[NO_HTTPS]="true"
                CONFIG[DOCKER_ENV_FILE]="env.local"
                shift ;;
            --help) show_usage; exit 0 ;;
            *)      error_exit "Unknown parameter: $1" ;;
        esac
    done

    [[ -n ${CONFIG[DOMAIN]:-} ]] \
        || error_exit "Error: --domain is mandatory and must be specified."

    if [[ -n "${CONFIG[INSTANCER_URL]:-}" && -n "${CONFIG[NO_INSTANCER]:-}" ]]; then
        error_exit "--instancer-url and --no-instancer are mutually exclusive"
    fi

    CONFIG[DOMAIN]="${CONFIG[DOMAIN]#https://}"
    CONFIG[DOMAIN]="${CONFIG[DOMAIN]#http://}"
    CONFIG[DOMAIN]="${CONFIG[DOMAIN]%%/*}"

    CONFIG[DEPLOY_DIR]="${CONFIG[WORKING_DIR]}/deploy"

    if [[ -z ${CONFIG[NO_HTTPS]:-} ]] && is_ip_address "${CONFIG[DOMAIN]}"; then
        log_info "Detected IP address in --domain, automatically enabling --no-https"
        CONFIG[NO_HTTPS]="true"
        CONFIG[DOCKER_ENV_FILE]="env.local"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_info "Starting CTFd server setup..."

    update_system
    install_docker
    create_and_set_owner

    if [[ "${CONFIG[NO_HTTPS]:-}" != "true" ]]; then
        dns_setup_wizard
    fi

    install_ctfd

    setup_backup_script
    setup_backup_cron

    log_success "CTFd server setup completed successfully!"
}

# ── Entry point: root escalation first ───────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Re-executing with sudo..." >&2
        exec sudo bash "$0" "$@"
    fi
    parse_arguments "$@"
    main
fi
