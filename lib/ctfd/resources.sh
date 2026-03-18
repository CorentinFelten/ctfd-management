#!/usr/bin/env bash
# lib/ctfd/resources.sh — Attach flags, files, hints, tags, topics, and requirements to a challenge.
# Requires: lib/common.sh, lib/ctfd/api.sh

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

ctfd_delete_challenge_files() {
    local challenge_id="$1"

    local response
    response="$(ctfd_api_call GET "/api/v1/files?challenge_id=${challenge_id}")" || {
        log_warning "Could not list files for challenge $challenge_id"
        return 1
    }

    local file_ids
    file_ids="$(echo "$response" | jq -r '.data // [] | .[].id' 2>/dev/null)"
    [[ -z "$file_ids" ]] && { log_debug "No existing files to delete for challenge $challenge_id"; return 0; }

    local file_id
    while IFS= read -r file_id; do
        [[ -z "$file_id" || "$file_id" == "null" ]] && continue
        ctfd_api_call DELETE "/api/v1/files/$file_id" >/dev/null || \
            log_warning "Failed to delete file ID $file_id from challenge $challenge_id"
        log_debug "Deleted file ID: $file_id"
    done <<< "$file_ids"
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

ctfd_add_requirements() {
    local challenge_data="$1" challenge_id="$2"

    local requirements_json
    requirements_json="$(echo "$challenge_data" | jq -c '.requirements // []')"
    [[ "$requirements_json" == "[]" || "$requirements_json" == "null" ]] && return 0

    log_debug "Resolving requirements..."

    local -a prereq_ids=()

    while IFS= read -r req_entry; do
        [[ -z "$req_entry" || "$req_entry" == "null" ]] && continue

        if echo "$req_entry" | jq -e 'type == "number"' >/dev/null 2>&1; then
            # Already a numeric ID
            prereq_ids+=("$(echo "$req_entry" | jq -r '.')")
        else
            # String name → resolve to ID; do NOT suppress errors or swallow failures
            local req_name resolved_id
            req_name="$(echo "$req_entry" | jq -r '.')"
            resolved_id="$(ctfd_get_challenge_id_by_name "$req_name")" || {
                log_error "API error while resolving requirement '$req_name' for challenge ID $challenge_id"
                return 1
            }

            if [[ -n "$resolved_id" && "$resolved_id" != "null" ]]; then
                prereq_ids+=("$resolved_id")
                log_debug "Resolved requirement '$req_name' → ID $resolved_id"
            else
                log_error "Requirement '$req_name' not found in CTFd — it must be ingested before challenge ID $challenge_id"
                return 1
            fi
        fi
    done < <(echo "$challenge_data" | jq -c '.requirements // [] | .[]')

    # Guard: requirements were declared but all entries were blank/null
    if [[ ${#prereq_ids[@]} -eq 0 ]]; then
        log_error "Requirements were declared but none could be resolved for challenge ID $challenge_id"
        return 1
    fi

    local prereqs_array
    prereqs_array="$(printf '%s\n' "${prereq_ids[@]}" | jq -R 'tonumber' | jq -sc '.')"

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
