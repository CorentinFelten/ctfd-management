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
source "$SCRIPT_DIR/modules/setup/ctfd_admin.sh"
source "$SCRIPT_DIR/modules/setup/instancer.sh"
source "$SCRIPT_DIR/modules/setup/ctfd.sh"
source "$SCRIPT_DIR/modules/setup/backup.sh"

# ── Configuration ────────────────────────────────────────────────────────────

declare -A CONFIG=(
    [CONFIGURE_DOCKER]="true"
    [WORKING_DIR]="$(invoking_user_home)"
    [DEPLOY_DIR]=""
    [ACTIVE_THEME]=""
    [ADMIN_NAME]=""
    [ADMIN_EMAIL]=""
    [USER_MODE]=""
    [CTF_NAME]=""
    [CTF_DESCRIPTION]=""
    [TEAM_SIZE]=""
    [BACKUP_SCHEDULE]="daily"
    [BACKUP_REMOTE]=""
    [BACKUP_RCLONE_CONFIG]=""
    [BACKUP_REMOTE_RETENTION]=""
    [NO_BACKUP_REMOTE]=""
    [JWT_SECRET_KEY]=""
    [DOCKER_ENV_FILE]="env.production"
    [DNS_PROVIDER]="cloudflare"
    [ACME_EMAIL]=""
    [NO_INSTANCER]=""
)

# ── Usage ────────────────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    -d, --domain URL          Set CTFd URL (mandatory)
                                Note: IP addresses automatically enable --no-https

  CTFd first-run setup (mandatory on a new deployment; CTFd's web setup
  wizard is disabled, so the instance goes live already set up):
        --admin-name NAME       First admin's user name
        --admin-email EMAIL     First admin's email address
        --user-mode MODE        teams or users (cannot be changed later
                                without deleting every account)
                                The admin password is asked for (hidden, twice) at the
                                start of the run; with --yes it is read from the
                                CTFD_ADMIN_PASSWORD environment variable instead.
        --ctf-name NAME         Event name (default: "CTFd")
        --ctf-description TEXT  Event description
        --team-size N           Maximum team size (teams mode)

  Other options:
    -w, --working-folder DIR    Set working directory (default: your home directory)
    -t, --theme SOURCE          Install a custom CTFd theme (repeatable). SOURCE is a
                                local folder or a Git URL, optionally with #REF to
                                clone a branch or tag. Installed themes are kept on
                                re-runs; giving a theme again updates it.
        --remove-theme NAME     Remove an installed custom theme (repeatable)
        --active-theme NAME     Make NAME CTFd's active theme
    -b, --backup-schedule TYPE  Set backup schedule: daily, hourly, or 10min (default: daily)
        --backup-remote REMOTE:PATH
                                Also upload every backup to a bucket, with rclone (S3 and
                                S3-compatible, GCS, Azure Blob, B2, SFTP...). REMOTE is a
                                remote defined in --backup-rclone-config, or an rclone
                                connection string (:s3,provider=AWS,env_auth=true:bucket/ctfd)
        --backup-rclone-config FILE
                                rclone.conf defining the remote (from `rclone config`)
        --backup-remote-retention DAYS
                                Delete uploaded backups older than DAYS (default: 30,
                                0 keeps them all, e.g. to use the bucket's lifecycle rules)
        --no-backup-remote      Stop uploading backups
                                (the remote settings are kept on re-runs until changed)
    -i, --instancer-url URL     Use an external Galvanize instancer (skips local setup)
        --no-instancer          Skip Galvanize setup entirely (deploy it separately later)
    -p, --dns-provider NAME     DNS provider for wildcard TLS certs (default: cloudflare)
                                Supported: cloudflare, route53, digitalocean, hetzner,
                                ovh, gandiv5, gcloud, godaddy, namecheap, ionos
                                Or any lego provider (https://go-acme.github.io/lego/dns/)
    -e, --acme-email EMAIL      Email address for Let's Encrypt certificates
                                (required for HTTPS deployments)
        --no-https              Disable HTTPS configuration for CTFd
                                (automatically enabled for IP addresses)
    -y, --yes                   Answer every prompt with its default, for unattended
                                runs (recreates the Ansible SSH key pair on re-runs;
                                DNS credentials must already be in traefik.env)
    -h, --help                  Show this help message

Directory structure:
    <working-folder>/deploy/                          Deployment working directory (configs, .env, compose)
    <working-folder>/deploy/traefik-config/           Traefik static & dynamic configs, letsencrypt
    <working-folder>/deploy/ctfd/                     CTFd image build context (Dockerfile, entrypoint)
    <working-folder>/deploy/ctfd/plugins/zync/        CTFd instancer plugin clone
    <working-folder>/deploy/ctfd/themes/              Custom themes, built into the CTFd image
    <working-folder>/deploy/ansible-ssh/              Ansible SSH key pair
    <working-folder>/deploy/data/                     Runtime data (database, uploads, galvanize)
    <working-folder>/deploy/cron_backup.log           Backup cron job log

Examples:
    $SCRIPT_NAME --domain example.com --acme-email admin@example.com \
        --admin-name admin --admin-email admin@example.com --user-mode teams --ctf-name "PolyPwn"
    $SCRIPT_NAME --domain example.com --dns-provider cloudflare
    $SCRIPT_NAME --domain 192.168.1.100
    $SCRIPT_NAME --domain example.com --working-folder /opt/ctfd
    $SCRIPT_NAME --domain example.com --theme /home/user/my-custom-theme
    $SCRIPT_NAME --domain example.com --theme https://github.com/user/theme.git#v2.0 \
        --theme ./second-theme --active-theme theme
    $SCRIPT_NAME --domain example.com --acme-email admin@example.com
    $SCRIPT_NAME --domain example.com --backup-schedule hourly
    $SCRIPT_NAME --domain example.com --backup-remote r2:ctfd-backups/prod \
        --backup-rclone-config ./rclone.conf
    $SCRIPT_NAME --domain 192.168.1.100 --yes
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)
                [[ -n ${2:-} ]] || error_exit "Missing value for --domain"
                CONFIG[DOMAIN]="$2"; shift 2 ;;
            -w|--working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"; shift 2 ;;
            -t|--theme)
                [[ -n ${2:-} ]] || error_exit "Missing value for --theme"
                THEME_SOURCES+=("$2"); shift 2 ;;
            --remove-theme)
                [[ -n ${2:-} ]] || error_exit "Missing value for --remove-theme"
                THEMES_TO_REMOVE+=("$2"); shift 2 ;;
            --active-theme)
                [[ -n ${2:-} ]] || error_exit "Missing value for --active-theme"
                CONFIG[ACTIVE_THEME]="$2"; shift 2 ;;
            -b|--backup-schedule)
                [[ -n ${2:-} ]] || error_exit "Missing value for --backup-schedule"
                case ${2,,} in
                    daily|hourly|10min) CONFIG[BACKUP_SCHEDULE]="${2,,}" ;;
                    *) error_exit "Invalid backup schedule: $2. Must be: daily, hourly, or 10min" ;;
                esac
                shift 2 ;;
            --backup-remote)
                [[ -n ${2:-} ]] || error_exit "Missing value for --backup-remote"
                [[ "$2" == *:* ]] || error_exit "--backup-remote must be an rclone REMOTE:PATH, e.g. s3:my-bucket/ctfd"
                CONFIG[BACKUP_REMOTE]="$2"; shift 2 ;;
            --backup-rclone-config)
                [[ -n ${2:-} ]] || error_exit "Missing value for --backup-rclone-config"
                [[ -f "$2" ]] || error_exit "rclone config not found: $2"
                CONFIG[BACKUP_RCLONE_CONFIG]="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
            --backup-remote-retention)
                [[ "${2:-}" =~ ^[0-9]+$ ]] || error_exit "--backup-remote-retention needs a number of days (0 keeps everything)"
                CONFIG[BACKUP_REMOTE_RETENTION]="$2"; shift 2 ;;
            --no-backup-remote)
                CONFIG[NO_BACKUP_REMOTE]="true"; shift ;;
            -i|--instancer-url)
                [[ -n ${2:-} ]] || error_exit "Missing value for --instancer-url"
                CONFIG[INSTANCER_URL]="$2"; shift 2 ;;
            --no-instancer)
                CONFIG[NO_INSTANCER]="true"; shift ;;
            -p|--dns-provider)
                [[ -n ${2:-} ]] || error_exit "Missing value for --dns-provider"
                CONFIG[DNS_PROVIDER]="$2"; shift 2 ;;
            -e|--acme-email)
                [[ -n ${2:-} ]] || error_exit "Missing value for --acme-email"
                CONFIG[ACME_EMAIL]="$2"; shift 2 ;;
            --no-https)
                CONFIG[NO_HTTPS]="true"
                CONFIG[DOCKER_ENV_FILE]="env.local"
                shift ;;
            -y|--yes)
                _ASSUME_YES="true"; shift ;;
            --admin-name)
                [[ -n ${2:-} ]] || error_exit "Missing value for --admin-name"
                CONFIG[ADMIN_NAME]="$2"; shift 2 ;;
            --admin-email)
                [[ -n ${2:-} ]] || error_exit "Missing value for --admin-email"
                CONFIG[ADMIN_EMAIL]="$2"; shift 2 ;;
            --user-mode)
                case "${2:-}" in
                    teams|users) CONFIG[USER_MODE]="$2" ;;
                    *) error_exit "--user-mode must be teams or users" ;;
                esac
                shift 2 ;;
            --ctf-name)
                [[ -n ${2:-} ]] || error_exit "Missing value for --ctf-name"
                CONFIG[CTF_NAME]="$2"; shift 2 ;;
            --ctf-description)
                [[ -n ${2:-} ]] || error_exit "Missing value for --ctf-description"
                CONFIG[CTF_DESCRIPTION]="$2"; shift 2 ;;
            --team-size)
                [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || error_exit "--team-size needs a positive number"
                CONFIG[TEAM_SIZE]="$2"; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *)      error_exit "Unknown parameter: $1" ;;
        esac
    done

    [[ -n ${CONFIG[DOMAIN]:-} ]] \
        || error_exit "Error: --domain is mandatory and must be specified."

    if [[ -n "${CONFIG[BACKUP_REMOTE]}" && -n "${CONFIG[NO_BACKUP_REMOTE]}" ]]; then
        error_exit "--backup-remote and --no-backup-remote are mutually exclusive"
    fi

    if [[ -n "${CONFIG[INSTANCER_URL]:-}" && -n "${CONFIG[NO_INSTANCER]:-}" ]]; then
        error_exit "--instancer-url and --no-instancer are mutually exclusive"
    fi

    CONFIG[DOMAIN]="${CONFIG[DOMAIN]#https://}"
    CONFIG[DOMAIN]="${CONFIG[DOMAIN]#http://}"
    CONFIG[DOMAIN]="${CONFIG[DOMAIN]%%/*}"

    if is_loopback_or_unspecified "${CONFIG[DOMAIN]}"; then
        error_exit "--domain ${CONFIG[DOMAIN]} is a loopback address. Use this server's real IP address or domain name instead.
  Players must reach CTFd at this address, and the Galvanize instancer connects
  to it over SSH from inside its container, where ${CONFIG[DOMAIN]} is the container itself.
  This server's primary IP address is usually given by: ip -4 route get 1.1.1.1"
    fi

    CONFIG[DEPLOY_DIR]="${CONFIG[WORKING_DIR]}/deploy"

    if [[ -z ${CONFIG[NO_HTTPS]:-} ]] && is_ip_address "${CONFIG[DOMAIN]}"; then
        log_info "Detected IP address in --domain, automatically enabling --no-https"
        CONFIG[NO_HTTPS]="true"
        CONFIG[DOCKER_ENV_FILE]="env.local"
    fi

    if [[ -z "${CONFIG[NO_HTTPS]:-}" && -z "${CONFIG[ACME_EMAIL]}" ]]; then
        error_exit "Error: --acme-email is required for HTTPS deployments."
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
    setup_backup_remote
    setup_backup_cron

    log_success "CTFd server setup completed successfully!"
    mark_completed
}

# ── Entry point: root escalation first ───────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    for _arg in "$@"; do
        [[ "$_arg" == "-h" || "$_arg" == "--help" ]] && { show_usage; exit 0; }
    done
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Re-executing with sudo..." >&2
        exec sudo -- bash "$0" "$@"
    fi
    parse_arguments "$@"
    # Before any change to the system: a new deployment needs its first
    # admin, and the password is asked for now so the rest runs unattended
    prepare_ctfd_admin
    main
fi
