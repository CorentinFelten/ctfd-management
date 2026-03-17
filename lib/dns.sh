#!/usr/bin/env bash
# lib/dns.sh — DNS-01 challenge provider registry, interactive wizard, and validation.
# Supports the most common DNS providers for wildcard TLS certificates via Traefik/lego.
# Requires: lib/common.sh, lib/env.sh

[[ -n "${_LIB_DNS_LOADED:-}" ]] && return 0
readonly _LIB_DNS_LOADED=1

# ── Provider registry ────────────────────────────────────────────────────────
# Each provider entry: "lego_name|Display Name|REQUIRED_ENV_1,REQUIRED_ENV_2|docs_url"
# Env vars listed are the minimum required credentials.

readonly -a DNS_PROVIDERS=(
    "cloudflare|Cloudflare|CF_DNS_API_TOKEN|https://go-acme.github.io/lego/dns/cloudflare/"
    "route53|AWS Route 53|AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_REGION|https://go-acme.github.io/lego/dns/route53/"
    "digitalocean|DigitalOcean|DO_AUTH_TOKEN|https://go-acme.github.io/lego/dns/digitalocean/"
    "hetzner|Hetzner|HETZNER_API_KEY|https://go-acme.github.io/lego/dns/hetzner/"
    "ovh|OVH|OVH_ENDPOINT,OVH_APPLICATION_KEY,OVH_APPLICATION_SECRET,OVH_CONSUMER_KEY|https://go-acme.github.io/lego/dns/ovh/"
    "gandiv5|Gandi Live DNS|GANDIV5_PERSONAL_ACCESS_TOKEN|https://go-acme.github.io/lego/dns/gandiv5/"
    "gcloud|Google Cloud DNS|GCE_PROJECT,GCE_SERVICE_ACCOUNT_FILE|https://go-acme.github.io/lego/dns/gcloud/"
    "godaddy|GoDaddy|GODADDY_API_KEY,GODADDY_API_SECRET|https://go-acme.github.io/lego/dns/godaddy/"
    "namecheap|Namecheap|NAMECHEAP_API_USER,NAMECHEAP_API_KEY|https://go-acme.github.io/lego/dns/namecheap/"
    "ionos|IONOS|IONOS_API_KEY|https://go-acme.github.io/lego/dns/ionos/"
)

# ── Lookup helpers ────────────────────────────────────────────────────────────

# Get a field from a provider entry by lego name.
# Usage: _dns_provider_field <lego_name> <field_index>
#   field 0=lego_name, 1=display_name, 2=env_vars, 3=docs_url
_dns_provider_field() {
    local name="$1" field_idx="$2"
    local entry
    for entry in "${DNS_PROVIDERS[@]}"; do
        if [[ "${entry%%|*}" == "$name" ]]; then
            local IFS='|'
            local -a parts=($entry)
            printf '%s' "${parts[$field_idx]}"
            return 0
        fi
    done
    return 1
}

dns_provider_display_name() { _dns_provider_field "$1" 1; }
dns_provider_env_vars()     { _dns_provider_field "$1" 2; }
dns_provider_docs_url()     { _dns_provider_field "$1" 3; }

# Check if a provider name is valid (exists in the registry).
dns_provider_exists() {
    local name="$1"
    local entry
    for entry in "${DNS_PROVIDERS[@]}"; do
        [[ "${entry%%|*}" == "$name" ]] && return 0
    done
    return 1
}

# ── List providers ────────────────────────────────────────────────────────────

dns_list_providers() {
    local entry lego_name display_name
    local idx=1
    for entry in "${DNS_PROVIDERS[@]}"; do
        IFS='|' read -r lego_name display_name _ _ <<< "$entry"
        printf '  %2d) %-16s %s\n' "$idx" "$lego_name" "$display_name"
        ((idx++))
    done
}

# ── Interactive wizard ────────────────────────────────────────────────────────

# Presents a menu of supported providers, prompts for credentials, validates
# them, and writes them to .env via setup_env_key.
# Sets CONFIG[DNS_PROVIDER] as a side effect.
dns_setup_wizard() {
    local provider="${CONFIG[DNS_PROVIDER]:-}"

    echo "" >&2
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║      DNS-01 Challenge Provider Setup (Wildcard TLS)          ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    echo "" >&2
    log_info "Wildcard certificates (*.${CONFIG[DOMAIN]}) require a DNS provider"
    log_info "that Traefik can use to create verification TXT records."
    echo "" >&2

    # If --dns-provider was passed and is valid, skip the selection menu
    if [[ -n "$provider" ]] && dns_provider_exists "$provider"; then
        local display
        display="$(dns_provider_display_name "$provider")"
        log_info "DNS provider pre-selected: $display ($provider)"
    else
        log_info "Supported DNS providers:"
        echo "" >&2
        dns_list_providers >&2
        echo "" >&2

        local choice
        while true; do
            read -rp "Select provider [1-${#DNS_PROVIDERS[@]}] (default: 1 = cloudflare): " choice
            choice="${choice:-1}"

            if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#DNS_PROVIDERS[@]})); then
                local selected="${DNS_PROVIDERS[$((choice - 1))]}"
                provider="${selected%%|*}"
                break
            fi
            log_warning "Invalid selection. Enter a number between 1 and ${#DNS_PROVIDERS[@]}."
        done
    fi

    CONFIG[DNS_PROVIDER]="$provider"
    setup_env_key DNS_PROVIDER "$provider"

    local display_name docs_url env_vars_csv
    display_name="$(dns_provider_display_name "$provider")"
    docs_url="$(dns_provider_docs_url "$provider")"
    env_vars_csv="$(dns_provider_env_vars "$provider")"

    echo "" >&2
    log_info "Provider: $display_name ($provider)"
    log_info "Docs:     $docs_url"
    echo "" >&2

    # Prompt for each required credential
    local IFS=',' var_name var_value
    local -a required_vars
    read -ra required_vars <<< "$env_vars_csv"

    for var_name in "${required_vars[@]}"; do
        # Check if already set in environment or .env
        var_value="${!var_name:-}"
        if [[ -z "$var_value" ]]; then
            var_value="$(grep "^${var_name}=" "${SCRIPT_DIR}/.env" 2>/dev/null \
                | head -n1 | cut -d= -f2- | tr -d "'\"\r" || true)"
        fi

        if [[ -n "$var_value" ]]; then
            local masked
            masked="$(printf '%s' "$var_value" | sed 's/./*/g; s/\(.\{4\}\)$//' | head -c 20)$(printf '%s' "$var_value" | tail -c 4)"
            log_info "$var_name is already set (${masked})"
            read -rp "Keep current value? [Y/n]: " -n 1 keep
            echo >&2
            if [[ "$keep" =~ ^[Nn]$ ]]; then
                var_value=""
            fi
        fi

        if [[ -z "$var_value" ]]; then
            while true; do
                read -rp "  $var_name: " var_value
                if [[ -n "$var_value" ]]; then
                    break
                fi
                log_warning "$var_name is required. Please enter a value."
            done
        fi

        setup_env_key "$var_name" "$var_value"
    done

    echo "" >&2
    log_success "DNS provider credentials configured for $display_name"
    log_info "Credentials saved to .env — they will be passed to Traefik at runtime."
    echo "" >&2
}

# ── Validation ────────────────────────────────────────────────────────────────

# Checks that all required env vars for the configured provider are set in .env.
# Returns 0 if valid, 1 if credentials are missing.
dns_validate_credentials() {
    local provider="${1:-${CONFIG[DNS_PROVIDER]:-cloudflare}}"
    local env_file="${SCRIPT_DIR}/.env"

    if ! dns_provider_exists "$provider"; then
        log_error "Unknown DNS provider: $provider"
        log_info "Supported providers:"
        dns_list_providers >&2
        return 1
    fi

    local env_vars_csv
    env_vars_csv="$(dns_provider_env_vars "$provider")"

    local IFS=',' var_name var_value
    local -a required_vars missing_vars=()
    read -ra required_vars <<< "$env_vars_csv"

    for var_name in "${required_vars[@]}"; do
        var_value="$(grep "^${var_name}=" "$env_file" 2>/dev/null \
            | head -n1 | cut -d= -f2- | tr -d "'\"\r" || true)"
        if [[ -z "$var_value" ]]; then
            missing_vars+=("$var_name")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        local display_name docs_url
        display_name="$(dns_provider_display_name "$provider")"
        docs_url="$(dns_provider_docs_url "$provider")"
        log_error "Missing credentials for $display_name ($provider):"
        local v
        for v in "${missing_vars[@]}"; do
            log_error "  - $v"
        done
        log_info "See: $docs_url"
        return 1
    fi

    return 0
}