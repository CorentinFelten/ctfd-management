#!/usr/bin/env bash
# challenges/cleanup.sh — Remove Docker images built for challenges.
# Requires: lib/common.sh, lib/challenges.sh

[[ -n "${_CHALL_CLEANUP_LOADED:-}" ]] && return 0
readonly _CHALL_CLEANUP_LOADED=1

cleanup_docker() {
    log_info "Cleaning up Docker resources..."

    local -a images=()

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local yml="$category/$(basename "$challenge")/challenge.yml"
            [[ -f "$yml" ]] || continue

            local ctype
            ctype="$(get_challenge_info "$yml" "type")"
            if [[ "$ctype" == "docker" ]]; then
                local img
                img="$(get_challenge_info "$yml" "image")"
                [[ -n "$img" ]] && images+=("$img")
            fi
        done
    done

    if [[ ${#images[@]} -eq 0 ]]; then
        log_info "No challenge Docker images found"
        return 0
    fi

    log_info "Found ${#images[@]} challenge images"
    echo "Images to remove:" >&2
    printf '  - %s\n' "${images[@]}" >&2
    read -rp "Remove these images? (y/N): "
    [[ $REPLY =~ ^[Yy]$ ]] || { log_info "Cleanup cancelled"; return 0; }

    local removed=0 img
    for img in "${images[@]}"; do
        if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
            if docker rmi "$img" 2>/dev/null; then
                log_success "Removed: $img"
                ((++removed))
            else
                log_warning "Failed to remove or not found: $img"
            fi
        else
            log_info "Would remove: docker rmi '${img}'"
            ((++removed))
        fi
    done

    log_info "Cleanup completed: $removed images processed"
}
