#!/usr/bin/env bash
# modules/challenges/ingest.sh — Install challenges into CTFd via ctfcli.
# Requires: lib/common.sh, lib/discovery.sh

[[ -n "${_CHALL_INGEST_LOADED:-}" ]] && return 0
readonly _CHALL_INGEST_LOADED=1

# ── Dependency-ordered ingest helpers ─────────────────────────────────────────
#
# Globals used by the topological sort (all prefixed _TOPO_ to avoid clashes):
#   _TOPO_NAME_TO_PATH  assoc: challenge_name → path
#   _TOPO_DEPS          assoc: challenge_name → newline-separated dep names (batch-local)
#   _TOPO_STATE         assoc: challenge_name → 0 (unvisited) | 1 (in-progress) | 2 (done)
#   _TOPO_STACK         indexed: current DFS path, used for cycle reporting
#   _TOPO_SORTED        indexed: names in topological order (output)
#
# Declared here (global scope) to avoid declare -g + local -n interaction bugs.
declare -Ag _TOPO_NAME_TO_PATH=()
declare -Ag _TOPO_DEPS=()
declare -Ag _TOPO_STATE=()
declare -ag _TOPO_STACK=()
declare -ag _TOPO_SORTED=()

_ingest_topo_visit() {
    local node="$1"

    case "${_TOPO_STATE[$node]:-0}" in
        2) return 0 ;;  # already fully processed
        1)              # back-edge → cycle
            local cycle; cycle="$(IFS=' → '; echo "${_TOPO_STACK[*]} → $node")"
            log_error "Circular dependency detected: $cycle"
            return 1
            ;;
    esac

    _TOPO_STATE["$node"]="1"
    _TOPO_STACK+=("$node")

    local dep
    while IFS= read -r dep; do
        # Only recurse into deps that are part of this ingest batch
        [[ -z "$dep" ]] && continue
        [[ -n "${_TOPO_NAME_TO_PATH[$dep]+x}" ]] || continue
        _ingest_topo_visit "$dep" || return 1
    done <<< "${_TOPO_DEPS[$node]:-}"

    # Pop from DFS stack
    _TOPO_STACK=("${_TOPO_STACK[@]:0:${#_TOPO_STACK[@]}-1}")
    _TOPO_STATE["$node"]="2"
    _TOPO_SORTED+=("$node")
}

# _ingest_sort_by_deps ARRAY_NAME
#   Re-orders the named indexed array (of challenge paths) so that every
#   challenge appears after all of its intra-batch dependencies.
#   Errors out with a descriptive message on circular dependencies.
_ingest_sort_by_deps() {
    local -n _sort_paths="$1"

    # (Re-)initialise globals fresh for this run
    _TOPO_NAME_TO_PATH=()
    _TOPO_DEPS=()
    _TOPO_STATE=()
    _TOPO_STACK=()
    _TOPO_SORTED=()

    log_info "Building challenge dependency index..."

    local path yml data name reqs
    for path in "${_sort_paths[@]}"; do
        yml="$path/challenge.yml"
        [[ -f "$yml" ]] || continue
        data="$(parse_challenge_yaml "$yml" 2>/dev/null)" || continue
        name="$(echo "$data" | jq -r '.name // empty')"
        [[ -z "$name" ]] && continue

        _TOPO_NAME_TO_PATH["$name"]="$path"
        # Collect only string-name requirements (numeric IDs are already in CTFd)
        reqs="$(echo "$data" | jq -r \
            '[.requirements // [] | .[] | select(type == "string")] | join("\n")' \
            2>/dev/null)" || reqs=""
        _TOPO_DEPS["$name"]="${reqs}"

        if [[ -n "$reqs" ]]; then
            log_debug "  Indexed '$name' — requires: $reqs"
        else
            log_debug "  Indexed '$name' — no requirements"
        fi
    done

    # Detect any intra-batch dependencies so we can report reordering
    local has_intra_deps=false n dep
    for n in "${!_TOPO_NAME_TO_PATH[@]}"; do
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            if [[ -n "${_TOPO_NAME_TO_PATH[$dep]+x}" ]]; then
                has_intra_deps=true
                break
            fi
        done <<< "${_TOPO_DEPS[$n]:-}"
        [[ "$has_intra_deps" == "true" ]] && break
    done

    if [[ "$has_intra_deps" == "true" ]]; then
        log_info "Intra-batch dependencies found — resolving install order..."
    else
        log_debug "No intra-batch dependencies found — order unchanged"
    fi

    # Run DFS over every node
    for n in "${!_TOPO_NAME_TO_PATH[@]}"; do
        _ingest_topo_visit "$n" || return 1
    done

    # Rebuild the caller's array in topological order
    local -a sorted_paths=()
    for n in "${_TOPO_SORTED[@]}"; do
        sorted_paths+=("${_TOPO_NAME_TO_PATH[$n]}")
    done
    _sort_paths=("${sorted_paths[@]}")

    [[ "$has_intra_deps" == "true" ]] && \
        log_info "Install order resolved: ${#sorted_paths[@]} challenges"
}

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

    # Sort to_ingest by dependency order; errors out on circular dependencies
    _ingest_sort_by_deps to_ingest || return 1

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
