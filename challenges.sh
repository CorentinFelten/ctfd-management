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
    [WORKING_DIR]="$(invoking_user_home)"
    [REPO]=""
    [REPO_PATH]=""
    [ACTION]="all"
    [CATEGORIES]=""
    [CHALLENGES]=""
    [FORCE]="false"
    [PARALLEL_BUILDS]="4"
    [BUILD_IMAGES]="auto"
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
    -a, --action ACTION         Action to perform: all, build, ingest, sync, status, cleanup (default: all)

MAIN OPTIONS:
    -w, --working-folder DIR    Set working directory (default: your home directory)
    -r, --repo REPO         Challenge repository — resolved in this priority order:
                                  1. Folder name inside --working-folder (e.g. "MyCTF-Challenges")
                                  2. Folder name inside <working-folder>/deploy/data/galvanize/challenges/
                                  3. Git URL — cloned to --working-folder, or to
                                     <working-folder>/deploy/data/galvanize/challenges/ when galvanize
                                     is configured there (detected automatically)
                                  4. Absolute or relative path to any existing folder
    -b, --git-branch BRANCH     Git branch/tag to checkout after cloning (optional)
    -f, --config FILE           Load configuration from file

FILTERING OPTIONS:
    -c, --categories LIST       Comma-separated list of categories to process
    -C, --challenges LIST       Comma-separated list of specific challenges to process

BEHAVIOR OPTIONS:
    -n, --dry-run               Show what would be done without executing
    -F, --force                 Force operations (rebuild images, overwrite challenges)
    -P, --parallel-builds N     Number of parallel Docker builds (default: 4)
        --build-images MODE     Build challenge images: auto, yes, no (default: auto)
                                  auto builds only when the Galvanize instancer runs on
                                  this host; a remote instancer cannot use local images

DEBUGGING:
    -D, --debug                 Enable debug output
        --skip-docker-check     Skip Docker daemon availability check
    -h, --help                  Show this help message
    -v, --version               Show version information

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
            -w|--working-folder)
                [[ -n ${2:-} ]] || error_exit "Missing value for --working-folder"
                CONFIG[WORKING_DIR]="$2"; shift 2 ;;
            -r|--repo)
                [[ -n ${2:-} ]] || error_exit "Missing value for --repo"
                CONFIG[REPO]="$2"; shift 2 ;;
            -b|--git-branch)
                [[ -n ${2:-} ]] || error_exit "Missing value for --git-branch"
                CONFIG[GIT_BRANCH]="$2"; shift 2 ;;
            -a|--action)
                [[ -n ${2:-} ]] || error_exit "Missing value for --action"
                case "$2" in
                    all|build|ingest|sync|status|cleanup) CONFIG[ACTION]="$2" ;;
                    *) error_exit "Invalid action: $2. Valid: all, build, ingest, sync, status, cleanup" ;;
                esac
                shift 2 ;;
            -c|--categories)
                [[ -n ${2:-} ]] || error_exit "Missing value for --categories"
                CONFIG[CATEGORIES]="$2"; shift 2 ;;
            -C|--challenges)
                [[ -n ${2:-} ]] || error_exit "Missing value for --challenges"
                CONFIG[CHALLENGES]="$2"; shift 2 ;;
            -P|--parallel-builds)
                [[ -n ${2:-} ]] || error_exit "Missing value for --parallel-builds"
                [[ "$2" =~ ^[0-9]+$ ]] || error_exit "Invalid number for --parallel-builds: $2"
                CONFIG[PARALLEL_BUILDS]="$2"; shift 2 ;;
            --build-images)
                [[ -n ${2:-} ]] || error_exit "Missing value for --build-images"
                case "${2,,}" in
                    auto|yes|no) CONFIG[BUILD_IMAGES]="${2,,}" ;;
                    *) error_exit "Invalid value for --build-images: $2. Valid: auto, yes, no" ;;
                esac
                shift 2 ;;
            -f|--config)
                [[ -n ${2:-} ]] || error_exit "Missing value for --config"
                CONFIG[CONFIG_FILE]="$2"; shift 2 ;;
            -n|--dry-run)        CONFIG[DRY_RUN]="true";         shift ;;
            -F|--force)          CONFIG[FORCE]="true";           shift ;;
            -D|--debug)          CONFIG[DEBUG]="true"; _DEBUG="true"; shift ;;
            --skip-docker-check) CONFIG[SKIP_DOCKER_CHECK]="true"; shift ;;
            -h|--help)    show_usage;   exit 0 ;;
            -v|--version) show_version        ;;
            *)         error_exit "Unknown parameter: $1" ;;
        esac
    done

    [[ -n "${CONFIG[CONFIG_FILE]}" ]] && load_config_file "${CONFIG[CONFIG_FILE]}"
    [[ -n "${CONFIG[REPO]}" ]]   || error_exit "Error: --repo is mandatory and must be specified."

    resolve_ctf_repo_path
}

# ── Decide whether challenge images need building on this host ──────────────
#
# Galvanize deploys images from the Docker host it targets, so building here
# only helps when that is this machine. Sets CONFIG[DO_BUILD] to true/false.

resolve_build_images() {
    case "${CONFIG[BUILD_IMAGES]}" in
        yes) CONFIG[DO_BUILD]="true";  log_info "Image build forced (--build-images yes)" ;;
        no)  CONFIG[DO_BUILD]="false"; log_info "Image build disabled (--build-images no)" ;;
        auto)
            if is_local_instancer; then
                CONFIG[DO_BUILD]="true"
                log_debug "Galvanize instancer is local ($_INSTANCER_DETECTION) — images will be built"
            else
                CONFIG[DO_BUILD]="false"
                log_info "Galvanize instancer is not hosted locally ($_INSTANCER_DETECTION) — skipping image build"
                log_info "Use --build-images yes to build anyway"
            fi
            ;;
        *) error_exit "Invalid BUILD_IMAGES value: ${CONFIG[BUILD_IMAGES]}. Valid: auto, yes, no" ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_info "Enhanced CTF Challenge Management Tool v${VERSION}"
    log_info "Action: ${CONFIG[ACTION]}"

    [[ "${CONFIG[ACTION]}" == "all" || "${CONFIG[ACTION]}" == "build" ]] && resolve_build_images

    check_dependencies
    check_ctfd_api_deps
    get_challenges_path

    local has_failures=false

    case "${CONFIG[ACTION]}" in
        all)
            if [[ "${CONFIG[DO_BUILD]}" == "true" ]]; then
                build_challenges   || has_failures=true
                [[ "$has_failures" == "true" ]] \
                    && log_warning "Some builds failed — continuing with ingestion for successfully built challenges"
            fi
            initialize_ctfd_config
            ingest_challenges  || has_failures=true
            ;;
        build)
            if [[ "${CONFIG[DO_BUILD]}" == "true" ]]; then
                build_challenges || has_failures=true
            else
                log_warning "Build action skipped: images are not built on this host (--build-images ${CONFIG[BUILD_IMAGES]})"
            fi
            ;;
        ingest)  initialize_ctfd_config; ingest_challenges || has_failures=true ;;
        sync)    initialize_ctfd_config; sync_challenges   || has_failures=true ;;
        status)  show_status        ;;
        cleanup) cleanup_docker     ;;
        *)       error_exit "Unknown action: ${CONFIG[ACTION]}" ;;
    esac

    if [[ "$has_failures" == "true" ]]; then
        log_warning "Operation completed with errors (see above)"
    else
        log_success "Operation completed successfully!"
    fi
    mark_completed
}

# ── Entry point ──────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_arguments "$@"
    main
fi
