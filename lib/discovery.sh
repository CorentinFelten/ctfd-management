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
    local repo_path="${CONFIG[REPO_PATH]}"
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

# ── Extract a field from challenge.yml ──────────────────────────────────────
#
# Each challenge.yml is parsed to JSON exactly once and memoised, so the several
# get_challenge_info calls per challenge (name/type/image/playbook_name) spawn a
# single parser instead of one yq per field. Callers invoke get_challenge_info
# via $(...), i.e. in a subshell, so an in-memory cache would not survive across
# calls — the cache is on disk instead. $$ is stable across those subshells (and
# across parallel build workers), so they all share one per-run cache directory.
# Challenge files do not change mid-run, so cached entries stay valid; the
# directory is removed on exit by lib/common.sh's cleanup trap.

_CHALL_YAML_CACHE_DIR="${TMPDIR:-/tmp}/ctf_yamlcache_$$"

_challenge_yaml_json() {
    local yml="$1"
    [[ -f "$yml" ]] || return 1

    local cache_file="${_CHALL_YAML_CACHE_DIR}/${yml//[^A-Za-z0-9._-]/_}"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local json
    json="$(parse_challenge_yaml "$yml" 2>/dev/null || true)"

    # Publish atomically (rename) so a parallel worker never reads a partial file
    mkdir -p "$_CHALL_YAML_CACHE_DIR" 2>/dev/null || true
    local tmp="${cache_file}.${BASHPID}.tmp"
    if printf '%s' "$json" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi

    printf '%s' "$json"
}

get_challenge_info() {
    local challenge_yml="$1" info_type="$2"
    [[ -f "$challenge_yml" ]] || return 1

    # Map legacy short names to jq paths
    local jq_path
    case "$info_type" in
        name)  jq_path=".name" ;;
        type)  jq_path=".type" ;;
        image) jq_path=".deploy_parameters.image" ;;
        .*)    jq_path="$info_type" ;;            # already a path
        *)     jq_path=".$info_type" ;;            # bare key -> .key
    esac

    local json
    json="$(_challenge_yaml_json "$challenge_yml")"
    [[ -n "$json" ]] || return 1

    local result
    result="$(printf '%s' "$json" | jq -r "$jq_path // empty" 2>/dev/null)" || return 1
    [[ -n "$result" && "$result" != "null" ]] && printf '%s' "$result"
}
