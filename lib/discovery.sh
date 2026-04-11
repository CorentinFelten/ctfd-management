#!/usr/bin/env bash
# lib/discovery.sh — Challenge discovery, filtering, and metadata parsing.
# Requires: lib/common.sh
#
# Docker Compose validation and deployment live in modules/challenges/compose.sh
# to keep this library free of module-level dependencies.

[[ -n "${_LIB_DISCOVERY_LOADED:-}" ]] && return 0
readonly _LIB_DISCOVERY_LOADED=1

# ── Resolve the path to the challenges directory ────────────────────────────

get_challenges_path() {
    local repo_path="${CONFIG[CTF_REPO_PATH]}"
    local complete_path="$repo_path"

    [[ -d "$repo_path/challenges" ]] && complete_path="$repo_path/challenges"

    CONFIG[CHALLENGE_PATH]="$complete_path"
    log_info "Challenge path: '$complete_path'"
}

# ── Filter: should a given challenge be processed? ──────────────────────────

should_process_challenge() {
    local category="$1" challenge="$2"
    local category_name challenge_name

    category_name="$(basename "$category")"
    challenge_name="$(basename "$challenge")"

    # Category filter
    if [[ -n "${CONFIG[CATEGORIES]}" ]]; then
        local -a arr; IFS=',' read -ra arr <<< "${CONFIG[CATEGORIES]}"
        local found=false cat
        for cat in "${arr[@]}"; do
            [[ "$category_name" == "$cat" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && return 1
    fi

    # Challenge filter
    if [[ -n "${CONFIG[CHALLENGES]}" ]]; then
        local -a arr; IFS=',' read -ra arr <<< "${CONFIG[CHALLENGES]}"
        local found=false chall
        for chall in "${arr[@]}"; do
            [[ "$challenge_name" == "$chall" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && return 1
    fi

    return 0
}

# ── Extract a field from challenge.yml using yq ─────────────────────────────

get_challenge_info() {
    local challenge_yml="$1" info_type="$2"
    [[ -f "$challenge_yml" ]] || return 1

    # Map legacy short names to yq paths
    local yq_path
    case "$info_type" in
        name)  yq_path=".name" ;;
        type)  yq_path=".type" ;;
        image) yq_path=".deploy_parameters.image" ;;
        .*)    yq_path="$info_type" ;;           # already a yq path
        *)     yq_path=".$info_type" ;;           # bare key -> .key
    esac

    local result
    result="$(yq "$yq_path" "$challenge_yml" 2>/dev/null)" || return 1
    [[ -n "$result" && "$result" != "null" ]] && printf '%s' "$result"
}
