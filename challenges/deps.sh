#!/usr/bin/env bash
# challenges/deps.sh — Check system dependencies and install ctfcli.
# Requires: lib/common.sh

[[ -n "${_CHALL_DEPS_LOADED:-}" ]] && return 0
readonly _CHALL_DEPS_LOADED=1

check_dependencies() {
    log_info "Checking dependencies..."

    if [[ "${CONFIG[SKIP_DOCKER_CHECK]}" == "false" ]]; then
        log_debug "Checking Docker installation..."
        command -v docker &>/dev/null \
            || error_exit "Docker is not installed or not in PATH"

        log_debug "Checking Docker daemon..."
        if ! timeout 10 docker info &>/dev/null; then
            log_warning "Docker daemon is not running or not accessible"
            log_warning "You may need to start Docker or check permissions"
            log_warning "Use --skip-docker-check to bypass this check"
            error_exit "Docker daemon check failed"
        fi
        log_debug "Docker daemon check passed"
    else
        log_info "Skipping Docker daemon check (--skip-docker-check enabled)"
    fi

    log_debug "Checking system tools..."
    local tool
    for tool in grep sed awk; do
        command -v "$tool" &>/dev/null \
            || error_exit "$tool is not installed or not available in PATH"
        log_debug "$tool found"
    done

    log_success "All dependencies check passed"
}

check_ctfd_api_deps() {
    log_info "Checking CTFd API dependencies..."
    
    local missing_deps=()
    
    # Check for curl (required for API calls)
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi
    
    # Check for jq (required for JSON processing)
    if ! command -v jq &>/dev/null; then
        missing_deps+=("jq")
    fi
    
    # YAML parser — yaml.sh already detected the best strategy at source time
    local strategy
    strategy="$(yaml_strategy)"
    
    case "$strategy" in
        mikefarah_yq)
            log_debug "Found Mike Farah's yq (Go) for YAML parsing" ;;
        kislyuk_yq)
            log_debug "Found kislyuk's yq (Python/jq wrapper) for YAML parsing" ;;
        unknown_yq)
            log_debug "Found yq (unknown variant) for YAML parsing" ;;
        python3)
            log_debug "Found python3 with PyYAML for YAML parsing" ;;
        none)
            log_warning "No YAML parser found"
            log_warning "Install one of:"
            log_warning "  yq (Go):     https://github.com/mikefarah/yq#install"
            log_warning "  PyYAML:      python3 -m pip install PyYAML"
            log_warning "  apt:         sudo apt-get install python3-yaml"
            missing_deps+=("yq or python3-yaml")
            ;;
    esac
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies for CTFd API:"
        printf '  - %s\n' "${missing_deps[@]}" >&2
        echo >&2
        log_error "Installation instructions:"
        log_error "  Ubuntu/Debian: sudo apt-get install curl jq python3-yaml"
        log_error "  macOS: brew install curl jq yq"
        error_exit "Required dependencies are missing"
    fi
    
    log_success "All CTFd API dependencies are installed"
}

initialize_ctfd_config() {
    if ctfd_config_exists; then
        log_info "CTFd configuration already exists"
        
        # Validate configuration
        local url token
        url="$(ctfd_get_config "url")"
        token="$(ctfd_get_config "access_token")"
        
        if [[ -z "$url" || -z "$token" ]]; then
            log_warning "CTFd configuration is incomplete"
            log_info "Please run manual initialization or update config at: ${CONFIG[WORKING_DIR]}/.ctfd/config"
            error_exit "Incomplete CTFd configuration"
        fi
        
        log_debug "CTFd URL: $url"
        log_debug "Access token: ${token:0:10}..."
        return 0
    fi

    log_info "CTFd configuration not found. Initializing..."
    
    if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
        log_info "Would initialize CTFd configuration"
        return 0
    fi

    local url token
    
    # Allow Ctrl+C to cancel interactive input
    trap 'echo >&2; error_exit "Configuration aborted by user"' INT
    
    # Auto-detect CTFd URL from the .env file produced by setup.sh
    local env_file="${CONFIG[WORKING_DIR]}/infra/.env"
    local base_domain="" enable_tls=""
    
    if [[ -f "$env_file" ]]; then
        base_domain="$(read_env_value "BASE_DOMAIN" "$env_file")"
        enable_tls="$(read_env_value "ENABLE_TLS" "$env_file")"
    fi
    
    if [[ -n "$base_domain" ]]; then
        local scheme="https"
        [[ "${enable_tls,,}" == "false" ]] && scheme="http"
        local detected_url="${scheme}://${base_domain}"
        
        echo >&2
        read -rp "Connect to ${detected_url} ? [Y/n] " confirm || {
            echo >&2
            error_exit "Configuration aborted by user"
        }
        
        if [[ -z "$confirm" || "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then
            url="$detected_url"
        else
            read -rp "Enter CTFd instance URL: " url || {
                echo >&2
                error_exit "Configuration aborted by user"
            }
            if [[ ! "$url" =~ ^https?:// ]]; then
                trap - INT
                error_exit "Invalid URL format. Must start with http:// or https://"
            fi
        fi
    else
        echo >&2
        read -rp "Enter CTFd instance URL (e.g., https://ctf.example.com): " url || {
            echo >&2
            error_exit "Configuration aborted by user"
        }
        if [[ ! "$url" =~ ^https?:// ]]; then
            trap - INT
            error_exit "Invalid URL format. Must start with http:// or https://"
        fi
    fi
    
    read -rp "Enter CTFd Admin Access Token: " token || {
        echo >&2
        error_exit "Configuration aborted by user"
    }
    
    if [[ -z "$token" ]]; then
        trap - INT
        error_exit "Access token cannot be empty"
    fi
    
    # Restore default signal handling
    trap - INT
    
    ctfd_init_config "$url" "$token"
    log_success "CTFd configuration initialized successfully"
}
