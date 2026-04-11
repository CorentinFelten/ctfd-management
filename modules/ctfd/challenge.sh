#!/usr/bin/env bash
# modules/ctfd/challenge.sh — High-level challenge install / sync operations.
# Requires: lib/common.sh, modules/ctfd/api.sh, modules/ctfd/yaml.sh, modules/ctfd/resources.sh

[[ -n "${_LIB_CTFD_CHALLENGE_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_CHALLENGE_LOADED=1

# ── Look up a challenge by name ─────────────────────────────────────────────

ctfd_get_challenge_id_by_name() {
    local name="$1"

    # Use view=admin so hidden/unlisted challenges are included, and per_page=500
    # to avoid pagination truncating recently-created challenges from results.
    local response
    response="$(ctfd_api_call GET "/api/v1/challenges?view=admin&per_page=500")" || return 1

    echo "$response" | jq -r --arg name "$name" '.data[] | select(.name == $name) | .id' 2>/dev/null | head -n1
}

# ── Build the common JSON payload for a challenge ────────────────────────────

_ctfd_build_challenge_payload() {
    local challenge_data="$1"

    local name category description value type
    name="$(echo "$challenge_data"        | jq -r '.name // empty')"
    category="$(echo "$challenge_data"    | jq -r '.category // empty')"
    description="$(echo "$challenge_data" | jq -r '.description // empty')"
    value="$(echo "$challenge_data"       | jq -r '.value // 100')"
    type="$(echo "$challenge_data"        | jq -r '.type // "standard"')"

    [[ -n "$name" ]]     || { log_error "Challenge name is required";     return 1; }
    [[ -n "$category" ]] || { log_error "Challenge category is required"; return 1; }

    local api_data
    api_data="$(jq -n \
        --arg name "$name" \
        --arg category "$category" \
        --arg description "$description" \
        --arg value "$value" \
        --arg type "$type" \
        '{
            name: $name,
            category: $category,
            description: $description,
            value: ($value | tonumber),
            type: $type
        }'
    )"

    # Optional scalar fields
    local field val
    for field in connection_info attempts attribution; do
        val="$(echo "$challenge_data" | jq -r ".${field} // empty")"
        [[ -z "$val" ]] && continue
        if [[ "$field" == "attempts" ]]; then
            api_data="$(echo "$api_data" | jq --argjson v "$val" ". + {max_attempts: \$v}")"
        else
            api_data="$(echo "$api_data" | jq --arg v "$val" ". + {$field: \$v}")"
        fi
    done

    # Dynamic scoring extras
    if [[ "$type" == "dynamic" ]]; then
        local initial minimum decay
        initial="$(echo "$challenge_data" | jq -r '.value // 500')"
        minimum="$(echo "$challenge_data" | jq -r '.minimum // 100')"
        decay="$(echo "$challenge_data"   | jq -r '.decay // 450')"

        api_data="$(echo "$api_data" | jq \
            --argjson initial "$initial" \
            --argjson minimum "$minimum" \
            --argjson decay   "$decay" \
            '. + {initial: $initial, minimum: $minimum, decay: $decay}'
        )"
    fi

    # Extra properties — merge any key/value pairs under `extra` directly into
    # the payload, allowing challenge authors to pass through arbitrary CTFd
    # plugin fields without modifying this script.
    local extra_json
    extra_json="$(echo "$challenge_data" | jq -c '.extra // empty')"
    if [[ -n "$extra_json" && "$extra_json" != "null" ]]; then
        api_data="$(echo "$api_data" | jq --argjson extra "$extra_json" '. + $extra')"
    fi

    echo "$api_data"
}

# ── Delete a challenge and all its owned resources ───────────────────────────

ctfd_delete_challenge() {
    local challenge_id="$1" challenge_name="${2:-ID $1}"

    # Best-effort file cleanup first (CTFd may not cascade storage deletion)
    ctfd_delete_challenge_files "$challenge_id" 2>/dev/null || \
        log_debug "Could not pre-delete files for '$challenge_name' during rollback (continuing)"

    ctfd_api_call DELETE "/api/v1/challenges/$challenge_id" >/dev/null || {
        log_error "Rollback: failed to delete challenge '$challenge_name' (ID $challenge_id) from CTFd — manual cleanup required"
        return 1
    }

    log_debug "Rollback: deleted challenge '$challenge_name' (ID $challenge_id)"
}

# ── Install (create) a new challenge ─────────────────────────────────────────

ctfd_install_challenge() {
    local challenge_path="$1"
    local yml_file="$challenge_path/challenge.yml"

    [[ -f "$yml_file" ]] || {
        log_error "challenge.yml not found in: $challenge_path"
        return 1
    }

    log_debug "Parsing challenge YAML: $yml_file"
    local challenge_data
    challenge_data="$(parse_challenge_yaml "$yml_file")" || return 1

    local name
    name="$(echo "$challenge_data" | jq -r '.name // empty')"
    [[ -n "$name" ]] || { log_error "Challenge name is required"; return 1; }

    # Check for duplicate
    local existing_id
    existing_id="$(ctfd_get_challenge_id_by_name "$name" 2>/dev/null || true)"

    if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
        log_debug "Challenge '$name' already exists with ID $existing_id"
        return 2   # special code: already exists
    fi

    # Pre-flight: verify all local files exist before writing anything to CTFd
    ctfd_preflight_files "$challenge_data" "$challenge_path" "$name" || return 1

    # Pre-flight: verify all requirements exist in CTFd before writing anything
    ctfd_preflight_requirements "$challenge_data" "$name" || return 1

    # Build payload
    local api_data
    api_data="$(_ctfd_build_challenge_payload "$challenge_data")" || return 1

    # Set initial state (visible by default)
    local state
    state="$(echo "$challenge_data" | jq -r '.state // "visible"')"
    api_data="$(echo "$api_data" | jq --arg state "$state" '. + {state: $state}')"

    log_debug "Final challenge payload for '$name': $api_data"

    # Create
    log_debug "Creating challenge in CTFd: $name"
    local response
    response="$(ctfd_api_call POST "/api/v1/challenges" "$api_data")" || {
        log_error "Failed to create challenge: $name"
        return 1
    }

    local challenge_id
    challenge_id="$(echo "$response" | jq -r '.data.id')"
    [[ -n "$challenge_id" && "$challenge_id" != "null" ]] || {
        log_error "Failed to get challenge ID from response"
        return 1
    }

    log_debug "Challenge created with ID: $challenge_id"

    # Attach resources
    _rollback_install() {
        local step="$1"
        log_error "Failed to attach $step for '$name' — rolling back"
        if ctfd_delete_challenge "$challenge_id" "$name"; then
            log_warning "Rolled back: challenge '$name' has been removed from CTFd"
        fi
        return 1
    }

    ctfd_add_flags              "$challenge_data" "$challenge_id" "$challenge_path" || { _rollback_install "flags";        return 1; }
    ctfd_upload_challenge_files "$challenge_data" "$challenge_id" "$challenge_path" || { _rollback_install "files";        return 1; }
    ctfd_add_hints              "$challenge_data" "$challenge_id"                   || { _rollback_install "hints";        return 1; }
    ctfd_add_tags               "$challenge_data" "$challenge_id"                   || { _rollback_install "tags";         return 1; }
    ctfd_add_topics             "$challenge_data" "$challenge_id"                   || { _rollback_install "topics";       return 1; }
    ctfd_add_requirements       "$challenge_data" "$challenge_id"                   || { _rollback_install "requirements"; return 1; }

    return 0
}

# ── Sync (update) an existing challenge ──────────────────────────────────────

ctfd_sync_challenge() {
    local challenge_path="$1"
    local yml_file="$challenge_path/challenge.yml"

    [[ -f "$yml_file" ]] || {
        log_error "challenge.yml not found in: $challenge_path"
        return 1
    }

    log_debug "Parsing challenge YAML: $yml_file"
    local challenge_data
    challenge_data="$(parse_challenge_yaml "$yml_file")" || return 1

    local name
    name="$(echo "$challenge_data" | jq -r '.name // empty')"
    [[ -n "$name" ]] || { log_error "Challenge name is required"; return 1; }

    local challenge_id
    challenge_id="$(ctfd_get_challenge_id_by_name "$name")" || {
        log_error "Challenge '$name' not found in CTFd — use ingest to create it first"
        return 1
    }
    [[ -n "$challenge_id" && "$challenge_id" != "null" ]] || {
        log_error "Challenge '$name' not found in CTFd — use ingest to create it first"
        return 1
    }

    log_debug "Found challenge '$name' with ID: $challenge_id"

    # Build update payload (state intentionally excluded to prevent accidental leaking)
    local api_data
    api_data="$(_ctfd_build_challenge_payload "$challenge_data")" || return 1

    log_debug "Updating challenge in CTFd: $name"
    ctfd_api_call PATCH "/api/v1/challenges/$challenge_id" "$api_data" >/dev/null || {
        log_error "Failed to update challenge: $name"
        return 1
    }

    log_debug "Refreshing files for: $name"
    ctfd_delete_challenge_files "$challenge_id" || \
        log_warning "Could not cleanly delete existing files for: $name (proceeding anyway)"
    ctfd_upload_challenge_files "$challenge_data" "$challenge_id" "$challenge_path" || \
        log_warning "Some files failed to re-upload for: $name"
    return 0
}
