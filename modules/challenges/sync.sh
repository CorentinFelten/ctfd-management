#!/usr/bin/env bash
# challenges/sync.sh — Sync (update) challenges already registered in CTFd.
# Requires: lib/common.sh, lib/discovery.sh

[[ -n "${_CHALL_SYNC_LOADED:-}" ]] && return 0
readonly _CHALL_SYNC_LOADED=1

sync_challenges() {
    log_info "Syncing existing challenges..."

    local synced=0 fail=0
    local -a failed_names=() to_sync=()

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local cname="$(basename "$challenge")"

            should_process_challenge "$category" "$challenge" || continue

            [[ -f "$category/$cname/challenge.yml" ]] \
                && to_sync+=("$category/$cname")
        done
    done

    log_info "Found ${#to_sync[@]} challenges to sync"
    [[ ${#to_sync[@]} -eq 0 ]] && { log_warning "No challenges found to sync"; return 0; }

    local current=0 path
    for path in "${to_sync[@]}"; do
        local cname="$(basename "$path")"
        ((++current))
        log_info "[$current/${#to_sync[@]}] Syncing challenge: $cname"

        if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
            log_info "Would sync challenge: $cname"
            ((++synced))
            continue
        fi

        local exit_code=0
        ctfd_sync_challenge "$path" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "Successfully synced: $cname"
            ((++synced))
        else
            log_error "Failed to sync: $cname"
            failed_names+=("$cname"); ((++fail))
        fi
    done

    # Summary
    log_info    "Challenge sync summary:"
    log_success "Successfully synced: $synced/${#to_sync[@]} challenges"

    if [[ $fail -gt 0 ]]; then
        log_warning "Failed to sync: $fail/${#to_sync[@]} challenges"
        log_warning "Failed challenges:"
        printf '  - %s\n' "${failed_names[@]}" >&2
        return 1
    fi

    log_success "All challenges have been synced successfully!"
}
