#!/usr/bin/env bash
# Enhanced CTF Challenge Management Tool
# Builds, ingests, syncs, and manages CTF challenges for CTFd.
#
# This script is meant to be invoked from the WORKING directory, not from
# inside the infra/ folder.  It resolves its own location to source the
# shared libraries and challenge sub-modules.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="2.0.0"

# ── Source shared libraries ──────────────────────────────────────────────────

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/repo.sh"
source "$SCRIPT_DIR/lib/discovery.sh"
source "$SCRIPT_DIR/modules/ctfd/config.sh"
source "$SCRIPT_DIR/modules/ctfd/api.sh"
source "$SCRIPT_DIR/modules/ctfd/yaml.sh"
source "$SCRIPT_DIR/modules/ctfd/resources.sh"
source "$SCRIPT_DIR/modules/ctfd/challenge.sh"

# ── Source challenge modules ─────────────────────────────────────────────────

source "$SCRIPT_DIR/modules/challenges/deps.sh"
source "$SCRIPT_DIR/modules/challenges/build.sh"
source "$SCRIPT_DIR/modules/challenges/compose.sh"
source "$SCRIPT_DIR/modules/challenges/ingest.sh"
source "$SCRIPT_DIR/modules/challenges/sync.sh"
source "$SCRIPT_DIR/modules/challenges/status.sh"
source "$SCRIPT_DIR/modules/challenges/cleanup.sh"

# ── Configuration ────────────────────────────────────────────────────────────

declare -A CONFIG=(
    [DRY_RUN]="false"
    [WORKING_DIR]="/home/${SUDO_USER:-$USER}"
    [REPO]=""
    [REPO_PATH]=""
    [ACTION]="all"
    [CATEGORIES]=""
    [CHALLENGES]=""
    [FORCE]="false"
    [PARALLEL_BUILDS]="4"
    [DEBUG]="false"
    [SKIP_DOCKER_CHECK]="false"
    [CONFIG_FILE]=""
    [GIT_BRANCH]=""
)

# ── Usage & Version ──────────────────────────────────────────────────────────

show_usage() {
    cat << EOF
Enhanced CTF Challenge Management Tool v${VERSION}

Usage: $SCRIPT_NAME [OPTIONS]

ACTIONS:
    --action ACTION         Action to perform: all, build, ingest, sync, status, cleanup (default: all)

MAIN OPTIONS:
    --working-folder DIR    Set working directory (default: /home/\$USER)
    --repo REPO         Challenge repository — resolved in this priority order:
                              1. Folder name inside --working-folder (e.g. "MyCTF-Challenges")
                              2. Folder name inside <working-folder>/deploy/data/galvanize/challenges/
                              3. Git URL — cloned to --working-folder, or to
                                 <working-folder>/deploy/data/galvanize/challenges/ when galvanize
                                 is configured there (detected automatically)
                              4. Absolute or relative path to any existing folder
    --git-branch BRANCH     Git branch/tag to checkout after cloning (optional)
    --config FILE           Load configuration from file

FILTERING OPTIONS:
    --categories LIST       Comma-separated list of categories to process
    --challenges LIST       Comma-separated list of specific challenges to process

BEHAVIOR OPTIONS:
    --dry-run               Show what would be done without executing
    --force                 Force operations (rebuild images, overwrite challenges)
    --parallel-builds N     Number of parallel Docker builds (default: 4)

DEBUGGING:
    --debug                 Enable debug output
    --skip-docker-check     Skip Docker daemon availability check
    --help                  Show this help message
    --version               Show version information

EXAMPLES:
  # Folder already present in working dir
  $SCRIPT_NAME --repo CTF_Repo

  # Folder in data/galvanize/challenges/
  $SCRIPT_NAME --repo CTF_Repo

  # Git URL — auto-detect clone target
  $SCRIPT_NAME --repo https://github.com/org/CTF_Repo.git

  # Git URL with specific branch
  $SCRIPT_NAME --repo git@github.com:org/challenges.git --git-branch main

  # Absolute path
  $SCRIPT_NAME --repo /srv/ctf/challenges

  $SCRIPT_NAME --action build --repo CTF_Repo --categories "web,crypto"
  $SCRIPT_NAME --action ingest --repo CTF_Repo
  $SCRIPT_NAME --action sync --repo CTF_Repo --force
  $SCRIPT_NAME --repo CTF_Repo --dry-run

CONFIG FILE FORMAT:
  Create a .env file with KEY=VALUE pairs:
    REPO=CTF_Repo
    WORKING_DIR=/opt/ctf
    PARALLEL_BUILDS=8
    GIT_BRANCH=main
EOF
}

show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"; shift 2 ;;
            --repo)
                [[ -n ${2:-} ]] || error_exit "Missing value for --repo"
                CONFIG[REPO]="$2"; shift 2 ;;
            --git-branch)
                [[ -n ${2:-} ]] || error_exit "Missing value for --git-branch"
                CONFIG[GIT_BRANCH]="$2"; shift 2 ;;
            --action)
                [[ -n ${2:-} ]] || error_exit "Missing value for --action"
                case "$2" in
                    all|build|ingest|sync|status|cleanup) CONFIG[ACTION]="$2" ;;
                    *) error_exit "Invalid action: $2. Valid: all, build, ingest, sync, status, cleanup" ;;
                esac
                shift 2 ;;
            --categories)
                [[ -n ${2:-} ]] || error_exit "Missing value for --categories"
                CONFIG[CATEGORIES]="$2"; shift 2 ;;
            --challenges)
                [[ -n ${2:-} ]] || error_exit "Missing value for --challenges"
                CONFIG[CHALLENGES]="$2"; shift 2 ;;
            --parallel-builds)
                [[ -n ${2:-} ]] || error_exit "Missing value for --parallel-builds"
                [[ "$2" =~ ^[0-9]+$ ]] || error_exit "Invalid number for --parallel-builds: $2"
                CONFIG[PARALLEL_BUILDS]="$2"; shift 2 ;;
            --config)
                [[ -n ${2:-} ]] || error_exit "Missing value for --config"
                CONFIG[CONFIG_FILE]="$2"; shift 2 ;;
            --dry-run)           CONFIG[DRY_RUN]="true";         shift ;;
            --force)             CONFIG[FORCE]="true";           shift ;;
            --debug)             CONFIG[DEBUG]="true"; _DEBUG="true"; shift ;;
            --skip-docker-check) CONFIG[SKIP_DOCKER_CHECK]="true"; shift ;;
            --help)    show_usage;   exit 0 ;;
            --version) show_version        ;;
            *)         error_exit "Unknown parameter: $1" ;;
        esac
    done

    [[ -n "${CONFIG[CONFIG_FILE]}" ]] && load_config_file "${CONFIG[CONFIG_FILE]}"
    [[ -n "${CONFIG[REPO]}" ]]   || error_exit "Error: --repo is mandatory and must be specified."

    resolve_ctf_repo_path
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_info "Enhanced CTF Challenge Management Tool v${VERSION}"
    log_info "Action: ${CONFIG[ACTION]}"

    check_dependencies
    check_ctfd_api_deps
    get_challenges_path

    case "${CONFIG[ACTION]}" in
        all)
            local build_ok=true
            build_challenges || build_ok=false
            [[ "$build_ok" == "false" ]] \
                && log_warning "Some builds failed — continuing with ingestion for successfully built challenges"
            initialize_ctfd_config
            ingest_challenges
            ;;
        build)   build_challenges   ;;
        ingest)  initialize_ctfd_config; ingest_challenges ;;
        sync)    initialize_ctfd_config; sync_challenges    ;;
        status)  show_status        ;;
        cleanup) cleanup_docker     ;;
        *)       error_exit "Unknown action: ${CONFIG[ACTION]}" ;;
    esac

    log_success "Operation completed successfully!"
}

# ── Entry point ──────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
