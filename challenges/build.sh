#!/usr/bin/env bash
# challenges/build.sh — Build Docker images for challenges (sequential & parallel).
# Requires: lib/common.sh, lib/challenges.sh

[[ -n "${_CHALL_BUILD_LOADED:-}" ]] && return 0
readonly _CHALL_BUILD_LOADED=1

# ── Build one challenge (sequential / verbose) ──────────────────────────────

_build_single() {
    local category="$1" challenge="$2"
    local challenge_name challenge_folder challenge_yml docker_image dockerfile_name=""

    challenge_folder="$(basename "$challenge")"
    challenge_yml="$category/$challenge_folder/challenge.yml"
    challenge_name="$(get_challenge_info "$challenge_yml" "name")"

    [[ -f "$challenge_yml" ]] || { log_warning "No challenge.yml for: $challenge_folder"; return 1; }

    local challenge_type
    challenge_type="$(get_challenge_info "$challenge_yml" "type")"
    [[ "$challenge_type" == "zync" ]] || {
        log_debug "Skipping non-docker challenge: $challenge_name (type: ${challenge_type:-unknown})"
        return 0
    }

    docker_image="$(get_challenge_info "$challenge_yml" "image")"
    [[ -n "$docker_image" ]] || { log_error "No image in challenge.yml for: $challenge_name"; return 1; }

    local dockerfile
    for dockerfile in "$category/$challenge_folder"/[Dd]ockerfile*; do
        [[ -f "$dockerfile" ]] && { dockerfile_name="$(basename "$dockerfile")"; break; }
    done
    [[ -n "$dockerfile_name" ]] || { log_error "No Dockerfile for challenge: $challenge_name"; return 1; }

    log_info "Building Challenge: $challenge_name -> $docker_image"

    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        local -a build_args=()
        [[ "${CONFIG[FORCE]}" == "true" ]] && build_args+=(--no-cache)

        (cd "$category/$challenge_folder" && docker build "${build_args[@]}" . -t "$docker_image" -f "$dockerfile_name") || {
            log_error "Failed to build $challenge_name"
            return 1
        }
        log_success "Built: $docker_image"
    else
        log_info "Would build: docker build . -t '${docker_image}' -f '${dockerfile_name}'"
    fi
}

# ── Build one challenge (parallel / quiet, writes status file) ──────────────

_build_single_quiet() {
    local category="$1" challenge="$2" status_file="$3"
    local challenge_name challenge_folder challenge_yml docker_image dockerfile_name=""

    challenge_folder="$(basename "$challenge")"
    challenge_yml="$category/$challenge_folder/challenge.yml"
    challenge_name="$(get_challenge_info "$challenge_yml" "name")"

    if [[ ! -f "$challenge_yml" ]]; then
        echo "FAIL:${challenge_name}" > "$status_file"; return 1
    fi

    local challenge_type
    challenge_type="$(get_challenge_info "$challenge_yml" "type")"
    if [[ "$challenge_type" != "zync" ]]; then
        echo "SKIP:${challenge_name}" > "$status_file"; return 0
    fi

    docker_image="$(get_challenge_info "$challenge_yml" "image")"
    if [[ -z "$docker_image" ]]; then
        echo "FAIL:${challenge_name}" > "$status_file"; return 1
    fi

    local dockerfile
    for dockerfile in "$category/$challenge_folder"/[Dd]ockerfile*; do
        [[ -f "$dockerfile" ]] && { dockerfile_name="$(basename "$dockerfile")"; break; }
    done
    if [[ -z "$dockerfile_name" ]]; then
        echo "FAIL:${challenge_name}" > "$status_file"; return 1
    fi

    local -a build_args=()
    [[ "${CONFIG[FORCE]}" == "true" ]] && build_args+=(--no-cache)

    local build_log
    build_log="$(mktemp "/tmp/ctf_build_${challenge_name}_XXXXXX.log")"

    if (cd "$category/$challenge_folder" && docker build "${build_args[@]}" . -t "$docker_image" -f "$dockerfile_name" >> "$build_log" 2>&1); then
        rm -f "$build_log"
        echo "SUCCESS:${challenge_name}" > "$status_file"
    else
        echo "FAIL:${challenge_name}" > "$status_file"
        log_error "Docker build failed for $challenge_name. See: $build_log"
        return 1
    fi
}

# ── Collect results from a batch of parallel status files ────────────────────

_drain_parallel_batch() {
    local -n _pids=$1
    local -n _files=$2
    local -n _ok=$3
    local -n _fail=$4
    local -n _failed_list=$5

    local i
    for i in "${!_pids[@]}"; do
        wait "${_pids[$i]}" || true

        if [[ -f "${_files[$i]}" ]]; then
            local result rname
            result="$(cut -d: -f1  < "${_files[$i]}")"
            rname="$(cut -d: -f2- < "${_files[$i]}")"

            case "$result" in
                SUCCESS) log_success "Image $rname successfully built"; ((++_ok)) ;;
                FAIL)    log_error   "Docker build failed for image $rname"
                         _failed_list+=("$rname"); ((++_fail)) ;;
            esac
            rm -f "${_files[$i]}"
        fi
    done
    _pids=()
    _files=()
}

# ── Build all challenges ────────────────────────────────────────────────────

build_challenges() {
    local total=0 ok=0 fail=0
    local -a failed_names=() to_build=()

    log_info "Discovering Docker challenges..."

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            should_process_challenge "$category" "$challenge" || continue

            local cname="$(basename "$challenge")"
            local yml="$category/$cname/challenge.yml"

            if [[ -f "$yml" ]]; then
                local ctype
                ctype="$(get_challenge_info "$yml" "type")"
                if [[ "$ctype" == "zync" ]]; then
                    to_build+=("$category:$challenge")
                    ((++total))
                fi
            fi
        done
    done

    log_info "Found $total Docker challenges to build"
    [[ $total -eq 0 ]] && { log_info "No Docker challenges to build"; return 0; }

    local current=0
    local max_par="${CONFIG[PARALLEL_BUILDS]}"

    if [[ "${CONFIG[DRY_RUN]}" == "false" && $max_par -gt 1 ]]; then
        # ── Parallel ──
        local -a pids=() status_files=()

        local info
        for info in "${to_build[@]}"; do
            IFS=':' read -r category challenge <<< "$info"
            ((++current))
            log_info "[$current/$total] Starting build for $(basename "$challenge")"

            local sf
            sf="$(mktemp "/tmp/ctf_status_$(basename "$challenge")_XXXXXX.txt")"
            _build_single_quiet "$category" "$challenge" "$sf" &
            pids+=($!)
            status_files+=("$sf")

            if [[ ${#pids[@]} -ge $max_par ]]; then
                _drain_parallel_batch pids status_files ok fail failed_names
            fi
        done
        _drain_parallel_batch pids status_files ok fail failed_names
    else
        # ── Sequential ──
        local info
        for info in "${to_build[@]}"; do
            IFS=':' read -r category challenge <<< "$info"
            ((++current))
            log_info "[$current/$total] Starting build for $(basename "$challenge")"

            if _build_single "$category" "$challenge"; then
                ((++ok))
            else
                failed_names+=("$(basename "$challenge")")
                ((++fail))
            fi
        done
    fi

    # Summary
    log_info  "Build summary:"
    log_success "Successfully built: $ok/$total challenges"
    if [[ $fail -gt 0 ]]; then
        log_warning "Failed to build: $fail/$total challenges"
        [[ ${#failed_names[@]} -gt 0 ]] && {
            log_warning "Failed challenges:"
            printf '  - %s\n' "${failed_names[@]}" >&2
        }
    fi

    [[ $fail -eq 0 ]]
}
