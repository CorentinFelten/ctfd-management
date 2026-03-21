#!/usr/bin/env bash
# challenges/ingest.sh — Install challenges into CTFd via ctfcli.
# Requires: lib/common.sh, lib/challenges.sh

[[ -n "${_CHALL_INGEST_LOADED:-}" ]] && return 0
readonly _CHALL_INGEST_LOADED=1

ingest_challenges() {
    local ok=0 fail=0 skip=0 total=0
    local -a failed_names=() skipped_names=() to_ingest=()

    log_info "Discovering challenges to ingest..."
    log_debug "Scanning directory: ${CONFIG[CHALLENGE_PATH]}"

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        log_debug "Processing category: $(basename "$category")"

        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local cname="$(basename "$challenge")"

            should_process_challenge "$category" "$challenge" || {
                log_debug "Skipping $cname due to filters"; continue
            }

            if [[ -f "$category/$cname/challenge.yml" ]]; then
                if validate_compose_image_tags "$category/$cname"; then
                    to_ingest+=("$category/$cname")
                    ((++total))
                else
                    log_error "Skipping '$cname': docker-compose image tag validation failed (see errors above)"
                    failed_names+=("$cname"); ((++fail))
                fi
            fi
        done
    done

    log_info "Found $total challenges to ingest${fail:+ ($fail rejected by tag validation)}"
    if [[ $total -eq 0 ]]; then
        if [[ $fail -gt 0 ]]; then
            log_error "No challenges to ingest \u2014 all candidates failed tag validation"
            log_error "Failed challenges:"
            printf '  - %s\n' "${failed_names[@]}" >&2
            return 1
        fi
        log_warning "No challenges found to ingest"
        return 0
    fi

    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        echo >&2
        log_info "Ready to ingest $total challenges."
        read -rp "Press Enter to continue with ingesting challenges, or Ctrl+C to abort..."
    fi

    local current=0 path
    for path in "${to_ingest[@]}"; do
        local cname="$(basename "$path")"
        ((++current))
        log_info "[$current/$total] Installing $cname..."

        if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
            log_info "Would install: ctf challenge install '${path}'"
            ((++ok))
            continue
        fi

        local exit_code=0
        ctfd_install_challenge "$path" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "Successfully installed: $cname"
            ((++ok))
        elif [[ $exit_code -eq 2 ]]; then
            # Return code 2 means challenge already exists
            log_warning "Challenge already exists: $cname (use --action sync to update)"
            skipped_names+=("$cname"); ((++skip))
        else
            log_error "Failed to install: $cname"
            failed_names+=("$cname"); ((++fail))
        fi
    done

    # ── Summary ──
    log_info "Challenge installation summary:"
    log_success "Successfully installed: $ok/$total challenges"

    if [[ $skip -gt 0 ]]; then
        log_warning "Skipped (already exist): $skip/$total challenges"
        [[ ${#skipped_names[@]} -gt 0 ]] && {
            log_info "Skipped challenges (use --action sync to update):"
            printf '  - %s\n' "${skipped_names[@]}" >&2
        }
    fi

    if [[ $fail -gt 0 ]]; then
        log_error "Failed to install: $fail/$total challenges"
        [[ ${#failed_names[@]} -gt 0 ]] && {
            log_error "Failed challenges:"
            printf '  - %s\n' "${failed_names[@]}" >&2
        }
    fi

    if [[ $fail -eq 0 && $skip -eq 0 ]]; then
        log_success "All challenges have been ingested successfully!"
    elif [[ $fail -eq 0 ]]; then
        log_success "All new challenges have been ingested successfully!"
    fi

    [[ $fail -eq 0 ]]
}
