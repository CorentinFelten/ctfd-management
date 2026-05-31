#!/usr/bin/env bash
# challenges/cleanup.sh — Remove Docker images built for challenges.
# Requires: lib/common.sh, lib/discovery.sh

[[ -n "${_CHALL_CLEANUP_LOADED:-}" ]] && return 0
readonly _CHALL_CLEANUP_LOADED=1

cleanup_docker() {
    log_info "Cleaning up Docker resources..."

    local -a images=()

    local -a compose_challenges=()

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            should_process_challenge "$category" "$challenge" || continue

            local yml="$category/$(basename "$challenge")/challenge.yml"
            [[ -f "$yml" ]] || continue

            local ctype
            ctype="$(get_challenge_info "$yml" "type")"
            if [[ "$ctype" == "zync" ]]; then
                local img
                img="$(get_challenge_info "$yml" "image")"
                [[ -n "$img" ]] && images+=("$img")
            fi

            [[ -f "$category/$(basename "$challenge")/docker-compose.yml" ]] \
                && compose_challenges+=("$category/$(basename "$challenge")")
        done
    done

    # ── Stop running compose stacks ──
    if [[ ${#compose_challenges[@]} -gt 0 ]]; then
        local -a running_stacks=()

        # Ask Compose itself whether each stack has running containers, so the
        # project name is resolved correctly rather than matched by folder-name
        # prefix (Docker lowercases/sanitises project names).
        local cpath
        for cpath in "${compose_challenges[@]}"; do
            if [[ -n "$( (cd "$cpath" 2>/dev/null && docker compose ps -q 2>/dev/null || true) )" ]]; then
                running_stacks+=("$cpath")
            fi
        done

        if [[ ${#running_stacks[@]} -gt 0 ]]; then
            log_info "Found ${#running_stacks[@]} running compose stack(s)"
            printf '  - %s\n' "${running_stacks[@]##*/}" >&2
            read -rp "Stop these compose stacks? [Y/n] " -n 1 REPLY
            echo >&2
            if [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]]; then
                for cpath in "${running_stacks[@]}"; do
                    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
                        (cd "$cpath" && docker compose down 2>/dev/null) \
                            && log_success "Stopped: $(basename "$cpath")" \
                            || log_warning "Failed to stop: $(basename "$cpath")"
                    else
                        log_info "Would stop: docker compose down (in $(basename "$cpath"))"
                    fi
                done
            fi
        fi
    fi

    # ── Remove images ──
    if [[ ${#images[@]} -eq 0 ]]; then
        log_info "No challenge Docker images found"
        return 0
    fi

    log_info "Found ${#images[@]} challenge images"
    echo "Images to remove:" >&2
    printf '  - %s\n' "${images[@]}" >&2
    read -rp "Remove these images? [Y/n] " -n 1 REPLY
    echo >&2
    [[ -z "$REPLY" || $REPLY =~ ^[Yy]$ ]] || { log_info "Cleanup cancelled"; return 0; }

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
