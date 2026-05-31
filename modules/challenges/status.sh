#!/usr/bin/env bash
# challenges/status.sh — Display a report of challenges, categories, and running services.
# Requires: lib/common.sh, lib/discovery.sh

[[ -n "${_CHALL_STATUS_LOADED:-}" ]] && return 0
readonly _CHALL_STATUS_LOADED=1

show_status() {
    log_info "CTF Challenge Status Report"
    echo "==========================" >&2

    printf '%b%s%b\n' "$CYAN" "Environment:" "$NC" >&2
    echo "  Working Directory: ${CONFIG[WORKING_DIR]}"   >&2
    echo "  CTF Repository: ${CONFIG[REPO]}"         >&2
    echo "  Challenge Path: ${CONFIG[CHALLENGE_PATH]}"   >&2
    echo >&2

    local total=0 docker_ct=0 static_ct=0 compose_ct=0
    local -a categories=()

    local category challenge
    for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
        [[ -d "$category" ]] || continue
        local cat_name cat_count=0
        cat_name="$(basename "$category")"
        categories+=("$cat_name")

        for challenge in "$category"/*; do
            [[ -d "$challenge" ]] || continue
            local cname="$(basename "$challenge")"
            local yml="$category/$cname/challenge.yml"
            local compose="$category/$cname/docker-compose.yml"

            [[ -f "$yml" ]] || continue
            ((++total)); ((++cat_count))

            local ctype
            ctype="$(get_challenge_info "$yml" "type")"
            case "$ctype" in
                zync) ((++docker_ct)) ;;
                *)    ((++static_ct)) ;;
            esac
            [[ -f "$compose" ]] && ((++compose_ct))
        done
        echo "  $cat_name: $cat_count challenges" >&2
    done

    echo >&2
    printf '%b%s%b\n' "$CYAN" "Challenge Statistics:" "$NC" >&2
    echo "  Total Challenges: $total"        >&2
    echo "  Docker Challenges: $docker_ct"   >&2
    echo "  Static Challenges: $static_ct"   >&2
    echo "  Compose Challenges: $compose_ct" >&2
    echo "  Categories: ${#categories[@]} (${categories[*]})" >&2
    echo >&2

    printf '%b%s%b\n' "$CYAN" "CTFd Integration:" "$NC" >&2
    echo "  YAML parser: $(yaml_strategy)" >&2
    if ctfd_config_exists; then
        echo "  Configuration: Found (${CONFIG[WORKING_DIR]}/.ctfd/config)" >&2
    else
        echo "  Configuration: Not found (you will be prompted on first ingest/sync)" >&2
    fi

    # Running compose services — ask Compose itself per challenge directory so the
    # project name is resolved correctly (Docker lowercases/sanitises it), instead
    # of guessing container names by prefix.
    if [[ $compose_ct -gt 0 && "${CONFIG[DRY_RUN]}" == "false" ]]; then
        echo >&2
        printf '%b%s%b\n' "$CYAN" "Running Compose Services:" "$NC" >&2
        local running=0

        for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
            [[ -d "$category" ]] || continue
            for challenge in "$category"/*; do
                [[ -d "$challenge" ]] || continue
                local cname="$(basename "$challenge")"
                [[ -f "$category/$cname/docker-compose.yml" ]] || continue

                local count
                count="$( (cd "$category/$cname" 2>/dev/null && docker compose ps -q 2>/dev/null || true) | grep -c . || true)"
                if [[ "$count" -gt 0 ]]; then
                    echo "  $cname: $count container(s) running" >&2
                    ((++running))
                fi
            done
        done

        [[ $running -eq 0 ]] && echo "  No compose services currently running" >&2
    fi

    echo >&2
}
