#!/usr/bin/env bash
# modules/ctfd/resources.sh — Attach flags, files, hints, tags, topics, and requirements to a challenge.
# Requires: lib/common.sh, modules/ctfd/api.sh

[[ -n "${_LIB_CTFD_RESOURCES_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_RESOURCES_LOADED=1

# ── Flags ────────────────────────────────────────────────────────────────────

ctfd_add_flags() {
    local challenge_data="$1" challenge_id="$2" challenge_path="$3"

    local flags_json
    flags_json="$(echo "$challenge_data" | jq -c '.flags // []')"
    [[ "$flags_json" == "[]" || "$flags_json" == "null" ]] && return 0

    log_debug "Adding flags..."

    while IFS= read -r flag_entry; do
        [[ -z "$flag_entry" || "$flag_entry" == "null" ]] && continue

        local flag_data

        if echo "$flag_entry" | jq -e 'type == "string"' >/dev/null 2>&1; then
            # Simple string flag
            flag_data="$(jq -n \
                --argjson chal_id "$challenge_id" \
                --argjson content "$flag_entry" \
                '{challenge_id: $chal_id, content: $content, type: "static"}'
            )"
        else
            # Complex flag object
            local flag_type flag_content flag_data_attr
            flag_type="$(echo "$flag_entry" | jq -r '.type // "static"')"
            flag_content="$(echo "$flag_entry" | jq -r '.content // .flag')"
            flag_data_attr="$(echo "$flag_entry" | jq -r '.data // empty')"

            flag_data="$(jq -n \
                --argjson chal_id "$challenge_id" \
                --arg content "$flag_content" \
                --arg ftype "$flag_type" \
                '{challenge_id: $chal_id, content: $content, type: $ftype}'
            )"

            [[ -n "$flag_data_attr" && "$flag_data_attr" != "null" ]] && \
                flag_data="$(echo "$flag_data" | jq --arg data "$flag_data_attr" '. + {data: $data}')"
        fi

        ctfd_api_call POST "/api/v1/flags" "$flag_data" >/dev/null || {
            log_warning "Failed to add flag"
            return 1
        }
        log_debug "Added flag"
    done < <(echo "$challenge_data" | jq -c '.flags // [] | .[]')
}

# ── File uploads ─────────────────────────────────────────────────────────────
_resolve_challenge_file() {
    local declared="$1" challenge_path="$2"

    # Absolute path — use directly
    if [[ "$declared" == /* ]]; then
        if [[ -f "$declared" ]]; then
            echo "$declared"
            return 0
        fi
        log_warning "File not found (absolute path): $declared"
        return 1
    fi

    # Relative path — try challenge root first, then files/ subdir
    local candidate
    for candidate in \
        "${challenge_path}/${declared}" \
        "${challenge_path}/files/${declared}"
    do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_warning "File not found (tried challenge root and files/ subdir): $declared"
    return 1
}

ctfd_preflight_files() {
    local challenge_data="$1" challenge_path="$2" challenge_name="$3"

    local files_json
    files_json="$(echo "$challenge_data" | jq -c '.files // []')"
    [[ "$files_json" == "[]" || "$files_json" == "null" ]] && return 0

    log_debug "Pre-flight: checking local files for '$challenge_name'..."

    local any_missing=0
    while IFS= read -r declared_path; do
        [[ -z "$declared_path" || "$declared_path" == "null" ]] && continue
        if ! _resolve_challenge_file "$declared_path" "$challenge_path" >/dev/null; then
            log_error "Pre-flight failed: file '$declared_path' not found for '$challenge_name'"
            any_missing=1
        fi
    done < <(echo "$challenge_data" | jq -r '.files // [] | .[]')

    return "$any_missing"
}

ctfd_upload_challenge_files() {
    local challenge_data="$1" challenge_id="$2" challenge_path="$3"

    local files_json
    files_json="$(echo "$challenge_data" | jq -c '.files // []')"
    [[ "$files_json" == "[]" || "$files_json" == "null" ]] && return 0

    log_debug "Uploading files..."

    local any_failed=0
    while IFS= read -r declared_path; do
        [[ -z "$declared_path" || "$declared_path" == "null" ]] && continue

        local full_path
        full_path="$(_resolve_challenge_file "$declared_path" "$challenge_path")" || {
            any_failed=1
            continue
        }

        ctfd_upload_file "$full_path" "$challenge_id" >/dev/null || {
            log_warning "Failed to upload: $(basename "$full_path")"
            any_failed=1
            continue
        }
        log_debug "Uploaded: $(basename "$full_path")"
    done < <(echo "$challenge_data" | jq -r '.files // [] | .[]')

    return "$any_failed"
}

# _ctfd_delete_subresources CHALLENGE_ID LIST_ENDPOINT DELETE_PATH_FMT LABEL
#   Generic best-effort cleanup: list a challenge's owned sub-resources via
#   LIST_ENDPOINT and DELETE each one. DELETE_PATH_FMT is a printf format string
#   with a single %s placeholder for the resource id. Failures are logged but do
#   not abort, mirroring CTFd's lack of cascade deletion guarantees.
_ctfd_delete_subresources() {
    local challenge_id="$1" list_endpoint="$2" delete_fmt="$3" label="$4"

    local response
    response="$(ctfd_api_call GET "$list_endpoint")" || {
        log_warning "Could not list $label for challenge $challenge_id"
        return 1
    }

    local ids
    ids="$(echo "$response" | jq -r '.data // [] | .[].id' 2>/dev/null)"
    [[ -z "$ids" ]] && { log_debug "No existing $label to delete for challenge $challenge_id"; return 0; }

    local id del_endpoint
    while IFS= read -r id; do
        [[ -z "$id" || "$id" == "null" ]] && continue
        printf -v del_endpoint "$delete_fmt" "$id"
        ctfd_api_call DELETE "$del_endpoint" >/dev/null || \
            log_warning "Failed to delete $label id $id from challenge $challenge_id"
        log_debug "Deleted $label id: $id"
    done <<< "$ids"
}

ctfd_delete_challenge_files() {
    _ctfd_delete_subresources "$1" "/api/v1/files?challenge_id=$1" "/api/v1/files/%s" "files"
}

# Owned sub-resource deleters used by sync to clear-then-recreate. None of these
# touch the parent challenge, so its ID is preserved and any prerequisite
# references other challenges hold remain valid.
ctfd_delete_challenge_flags() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/flags" "/api/v1/flags/%s" "flags"
}

ctfd_delete_challenge_tags() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/tags" "/api/v1/tags/%s" "tags"
}

ctfd_delete_challenge_hints() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/hints" "/api/v1/hints/%s" "hints"
}

# Topics are shared entities; the per-challenge association (ChallengeTopic) is
# what we remove, hence the ?type=challenge&target_id=<assoc-id> form.
ctfd_delete_challenge_topics() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/topics" "/api/v1/topics?type=challenge&target_id=%s" "topics"
}

# ── Hints ────────────────────────────────────────────────────────────────────

ctfd_add_hints() {
    local challenge_data="$1" challenge_id="$2"

    local hints_json
    hints_json="$(echo "$challenge_data" | jq -c '.hints // []')"
    [[ "$hints_json" == "[]" || "$hints_json" == "null" ]] && return 0

    log_debug "Adding hints..."

    while IFS= read -r hint_entry; do
        [[ -z "$hint_entry" || "$hint_entry" == "null" ]] && continue

        local hint_content hint_cost

        if echo "$hint_entry" | jq -e 'type == "string"' >/dev/null 2>&1; then
            hint_content="$(echo "$hint_entry" | jq -r '.')"
            hint_cost="0"
        else
            hint_content="$(echo "$hint_entry" | jq -r '.content // .hint')"
            hint_cost="$(echo "$hint_entry" | jq -r '.cost // 0')"
        fi

        local hint_data
        hint_data="$(jq -n \
            --argjson chal_id "$challenge_id" \
            --arg content "$hint_content" \
            --argjson cost "$hint_cost" \
            '{challenge_id: $chal_id, content: $content, cost: $cost}'
        )"

        ctfd_api_call POST "/api/v1/hints" "$hint_data" >/dev/null || {
            log_warning "Failed to add hint"
            return 1
        }
        log_debug "Added hint (cost: $hint_cost)"
    done < <(echo "$challenge_data" | jq -c '.hints // [] | .[]')
}

# ── Tags ─────────────────────────────────────────────────────────────────────

ctfd_add_tags() {
    local challenge_data="$1" challenge_id="$2"

    local tags_json
    tags_json="$(echo "$challenge_data" | jq -c '.tags // []')"
    [[ "$tags_json" == "[]" || "$tags_json" == "null" ]] && return 0

    log_debug "Adding tags..."

    while IFS= read -r tag; do
        [[ -z "$tag" || "$tag" == "null" ]] && continue

        local tag_data
        tag_data="$(jq -n \
            --argjson chal_id "$challenge_id" \
            --arg value "$tag" \
            '{challenge_id: $chal_id, value: $value}'
        )"

        ctfd_api_call POST "/api/v1/tags" "$tag_data" >/dev/null || {
            log_warning "Failed to add tag: $tag"
            return 1
        }
        log_debug "Added tag: $tag"
    done < <(echo "$challenge_data" | jq -r '.tags // [] | .[]')
}

# ── Topics ───────────────────────────────────────────────────────────────────

ctfd_add_topics() {
    local challenge_data="$1" challenge_id="$2"

    local topics_json
    topics_json="$(echo "$challenge_data" | jq -c '.topics // []')"
    [[ "$topics_json" == "[]" || "$topics_json" == "null" ]] && return 0

    log_debug "Adding topics..."

    while IFS= read -r topic; do
        [[ -z "$topic" || "$topic" == "null" ]] && continue

        local topic_data
        topic_data="$(jq -n \
            --argjson chal_id "$challenge_id" \
            --arg value "$topic" \
            '{challenge_id: $chal_id, value: $value, type: "challenge"}'
        )"

        ctfd_api_call POST "/api/v1/topics" "$topic_data" >/dev/null || {
            log_warning "Failed to add topic: $topic"
            return 1
        }
        log_debug "Added topic: $topic"
    done < <(echo "$challenge_data" | jq -r '.topics // [] | .[]')
}

# ── Requirements pre-flight check ────────────────────────────────────────────

ctfd_preflight_requirements() {
    local challenge_data="$1" challenge_name="$2"

    local requirements_json
    requirements_json="$(echo "$challenge_data" | jq -c '.requirements // []')"
    [[ "$requirements_json" == "[]" || "$requirements_json" == "null" ]] && return 0

    log_debug "Pre-flight: resolving requirements for '$challenge_name'..."

    while IFS= read -r req_entry; do
        [[ -z "$req_entry" || "$req_entry" == "null" ]] && continue

        # Numeric IDs are taken as-is — nothing to resolve
        echo "$req_entry" | jq -e 'type == "number"' >/dev/null 2>&1 && continue

        local req_name resolved_id
        req_name="$(echo "$req_entry" | jq -r '.')"
        resolved_id="$(ctfd_get_challenge_id_by_name "$req_name")" || {
            log_error "Pre-flight failed: API error while resolving requirement '$req_name' for '$challenge_name'"
            return 1
        }

        if [[ -z "$resolved_id" || "$resolved_id" == "null" ]]; then
            log_error "Pre-flight failed: requirement '$req_name' not found in CTFd — ingest it before '$challenge_name'"
            return 1
        fi

        log_debug "Pre-flight: requirement '$req_name' → ID $resolved_id OK"
    done < <(echo "$challenge_data" | jq -c '.requirements // [] | .[]')

    return 0
}

# ── Requirements ─────────────────────────────────────────────────────────────

# _ctfd_resolve_requirement_ids CHALLENGE_DATA CHALLENGE_ID
#   Resolves the challenge's declared requirements (numeric IDs taken as-is,
#   string names resolved by lookup) and echoes a compact JSON array of numeric
#   IDs. Echoes "[]" when no requirements are declared. Returns 1 on an API
#   error, or when a named requirement cannot be found, or when a self-reference
#   is detected.
_ctfd_resolve_requirement_ids() {
    local challenge_data="$1" challenge_id="$2"

    local requirements_json
    requirements_json="$(echo "$challenge_data" | jq -c '.requirements // []')"
    if [[ "$requirements_json" == "[]" || "$requirements_json" == "null" ]]; then
        echo "[]"
        return 0
    fi

    local -a prereq_ids=()

    while IFS= read -r req_entry; do
        [[ -z "$req_entry" || "$req_entry" == "null" ]] && continue

        local resolved_id
        if echo "$req_entry" | jq -e 'type == "number"' >/dev/null 2>&1; then
            # Already a numeric ID
            resolved_id="$(echo "$req_entry" | jq -r '.')"
        else
            # String name → resolve to ID; do NOT suppress errors or swallow failures
            local req_name
            req_name="$(echo "$req_entry" | jq -r '.')"
            resolved_id="$(ctfd_get_challenge_id_by_name "$req_name")" || {
                log_error "API error while resolving requirement '$req_name' for challenge ID $challenge_id"
                return 1
            }

            if [[ -z "$resolved_id" || "$resolved_id" == "null" ]]; then
                log_error "Requirement '$req_name' not found in CTFd — it must be ingested before challenge ID $challenge_id"
                return 1
            fi
            log_debug "Resolved requirement '$req_name' → ID $resolved_id"
        fi

        # Reject self-requirements: a challenge cannot require itself.
        if [[ "$resolved_id" == "$challenge_id" ]]; then
            log_error "Challenge ID $challenge_id lists itself as a requirement — rejected"
            return 1
        fi

        prereq_ids+=("$resolved_id")
    done < <(echo "$challenge_data" | jq -c '.requirements // [] | .[]')

    # Guard: requirements were declared but all entries were blank/null
    if [[ ${#prereq_ids[@]} -eq 0 ]]; then
        log_error "Requirements were declared but none could be resolved for challenge ID $challenge_id"
        return 1
    fi

    printf '%s\n' "${prereq_ids[@]}" | jq -R 'tonumber' | jq -sc '.'
}

# ctfd_patch_requirements CHALLENGE_ID PREREQS_JSON_ARRAY
#   PATCHes the prerequisite list onto a challenge (empty array clears it).
ctfd_patch_requirements() {
    local challenge_id="$1" prereqs_array="$2"

    local req_payload
    req_payload="$(jq -n \
        --argjson prereqs "$prereqs_array" \
        '{requirements: {prerequisites: $prereqs}}'
    )"

    log_debug "Setting requirements on challenge ID $challenge_id: $prereqs_array"

    ctfd_api_call PATCH "/api/v1/challenges/$challenge_id" "$req_payload" >/dev/null || {
        log_error "Failed to set requirements for challenge ID $challenge_id"
        return 1
    }
    log_debug "Requirements set"
}

# ctfd_add_requirements — set prerequisites during install. No-op when the
# challenge declares no requirements.
ctfd_add_requirements() {
    local challenge_data="$1" challenge_id="$2"

    local requirements_json
    requirements_json="$(echo "$challenge_data" | jq -c '.requirements // []')"
    [[ "$requirements_json" == "[]" || "$requirements_json" == "null" ]] && return 0

    log_debug "Resolving requirements..."

    local prereqs_array
    prereqs_array="$(_ctfd_resolve_requirement_ids "$challenge_data" "$challenge_id")" || return 1

    ctfd_patch_requirements "$challenge_id" "$prereqs_array"
}

# ctfd_sync_requirements — set prerequisites to exactly the declared set,
# clearing them when none are declared. Used by the second pass of sync, once
# every challenge is guaranteed to exist, so name→ID resolution cannot fail on a
# not-yet-synced prerequisite.
ctfd_sync_requirements() {
    local challenge_data="$1" challenge_id="$2"

    local prereqs_array
    prereqs_array="$(_ctfd_resolve_requirement_ids "$challenge_data" "$challenge_id")" || return 1

    ctfd_patch_requirements "$challenge_id" "$prereqs_array"
}
