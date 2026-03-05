#!/usr/bin/env bash
# lib/ctfd/challenge.sh — High-level challenge install / sync operations.
# Requires: lib/common.sh, lib/ctfd/api.sh, lib/ctfd/yaml.sh, lib/ctfd/resources.sh

[[ -n "${_LIB_CTFD_CHALLENGE_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_CHALLENGE_LOADED=1

# ── Look up a challenge by name ─────────────────────────────────────────────

ctfd_get_challenge_id_by_name() {
    local name="$1"

    local response
    response="$(ctfd_api_call GET "/api/v1/challenges")" || return 1

    echo "$response" | jq -r ".data[] | select(.name == \"$name\") | .id" 2>/dev/null | head -n1
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

    echo "$api_data"
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
    ctfd_add_flags              "$challenge_data" "$challenge_id" "$challenge_path" || return 1
    ctfd_upload_challenge_files "$challenge_data" "$challenge_id" "$challenge_path" || return 1
    ctfd_add_hints              "$challenge_data" "$challenge_id"                   || return 1
    ctfd_add_tags               "$challenge_data" "$challenge_id"                   || return 1

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
