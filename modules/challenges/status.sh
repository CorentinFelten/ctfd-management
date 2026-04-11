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
                docker) ((++docker_ct)) ;;
                *)      ((++static_ct)) ;;
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

    if command -v ctf &>/dev/null; then
        printf '%b%s%b\n' "$CYAN" "CTFcli Status:" "$NC" >&2
        echo "  Version: $(ctf --version 2>/dev/null | head -n1 || echo unknown)" >&2
        if [[ -f ".ctf/config" ]]; then
            echo "  Configuration: Found" >&2
        else
            echo "  Configuration: Not found (run 'ctf init' first)" >&2
        fi
    else
        printf '%b%s%b\n' "$YELLOW" "CTFcli: Not installed" "$NC" >&2
    fi

    # Running compose services
    if [[ $compose_ct -gt 0 && "${CONFIG[DRY_RUN]}" == "false" ]]; then
        echo >&2
        printf '%b%s%b\n' "$CYAN" "Running Compose Services:" "$NC" >&2
        local running=0
        local all_running
        all_running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"

        for category in "${CONFIG[CHALLENGE_PATH]}"/*; do
            [[ -d "$category" ]] || continue
            for challenge in "$category"/*; do
                [[ -d "$challenge" ]] || continue
                local cname="$(basename "$challenge")"
                [[ -f "$category/$cname/docker-compose.yml" ]] || continue

                local count
                count="$(echo "$all_running" | grep -c "^${cname}" 2>/dev/null || echo 0)"
                if [[ $count -gt 0 ]]; then
                    echo "  $cname: $count container(s) running" >&2
                    ((++running))
                fi
            done
        done

        [[ $running -eq 0 ]] && echo "  No compose services currently running" >&2
    fi

    echo >&2
}
