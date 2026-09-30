#!/usr/bin/env bash
# modules/ctfd/resources.sh — Attach flags, files, hints, tags, topics, and requirements to a challenge.
# Requires: lib/common.sh, modules/ctfd/api.sh

[[ -n "${_LIB_CTFD_RESOURCES_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_RESOURCES_LOADED=1

# ── Flags ────────────────────────────────────────────────────────────────────

# _ctfd_desired_flags CHALLENGE_DATA
#   Echoes the challenge's flags as a compact JSON array of normalised
#   {type, content, data} objects. A flag may be a plain string (static flag)
#   or an object with type/content (or flag)/data.
_ctfd_desired_flags() {
    echo "$1" | jq -c '[
        (.flags // [])[]
        | select(. != null)
        | if type == "string" then {type: "static", content: ., data: ""}
          else {type: (.type // "static"), content: (.content // .flag // "" | tostring), data: (.data // "" | tostring)}
          end
    ]'
}

_ctfd_create_flag() {
    local challenge_id="$1" flag_json="$2"
    local flag_data
    flag_data="$(echo "$flag_json" | jq -c --argjson chal_id "$challenge_id" \
        '{challenge_id: $chal_id, content, type} + (if .data != "" then {data} else {} end)')"
    ctfd_api_call POST "/api/v1/flags" "$flag_data" >/dev/null
}

ctfd_add_flags() {
    local challenge_data="$1" challenge_id="$2"

    local flag_json
    while IFS= read -r flag_json; do
        [[ -z "$flag_json" ]] && continue
        _ctfd_create_flag "$challenge_id" "$flag_json" || {
            log_warning "Failed to add flag"
            return 1
        }
        log_debug "Added flag"
    done < <(_ctfd_desired_flags "$challenge_data" | jq -c '.[]')
}

# ctfd_sync_flags CHALLENGE_DATA CHALLENGE_ID
#   Makes the challenge's flags match challenge.yml without a window where the
#   challenge has no valid flag: missing flags are created first, then flags no
#   longer declared are deleted. Unchanged flags are left untouched.
ctfd_sync_flags() {
    local challenge_data="$1" challenge_id="$2"

    local existing desired plan
    existing="$(ctfd_api_call GET "/api/v1/challenges/$challenge_id/flags")" || {
        log_warning "Could not list flags for challenge $challenge_id"
        return 1
    }
    desired="$(_ctfd_desired_flags "$challenge_data")"

    plan="$(jq -cn --argjson ex "$(echo "$existing" | jq -c '.data // []')" --argjson want "$desired" '
        def key: [.type // "static", (.content // "" | tostring), (.data // "" | tostring)];
        ($ex | map(key)) as $have
        | ($want | map(key)) as $need
        | {
            add:    [ $want[] | select((key) as $k | $have | any(. == $k) | not) ],
            delete: [ $ex[]   | select((key) as $k | $need | any(. == $k) | not) | .id ]
          }')" || return 1

    local failed=0 flag_json id
    while IFS= read -r flag_json; do
        [[ -z "$flag_json" ]] && continue
        if _ctfd_create_flag "$challenge_id" "$flag_json"; then
            log_debug "Added flag"
        else
            log_warning "Failed to add flag"
            failed=1
        fi
    done < <(echo "$plan" | jq -c '.add[]')

    # Keep old flags if a new one failed, so the challenge stays solvable
    [[ $failed -eq 0 ]] || return 1

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        ctfd_api_call DELETE "/api/v1/flags/$id" >/dev/null \
            && log_debug "Deleted flag id: $id" \
            || { log_warning "Failed to delete flag id $id"; failed=1; }
    done < <(echo "$plan" | jq -r '.delete[]')

    return "$failed"
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

# _ctfd_sha1_file FILE — echo the file's SHA-1 (sha1sum, shasum or openssl)
_ctfd_sha1_file() {
    if command -v sha1sum &>/dev/null; then
        sha1sum "$1" | cut -d' ' -f1
    elif command -v shasum &>/dev/null; then
        shasum -a 1 "$1" | cut -d' ' -f1
    else
        openssl dgst -sha1 -r "$1" | cut -d' ' -f1
    fi
}

# ctfd_sync_challenge_files CHALLENGE_DATA CHALLENGE_ID CHALLENGE_PATH
#   Makes the challenge's files match challenge.yml. A remote file is kept when
#   both its SHA-1 and its name match a declared local file, so unchanged files
#   keep their download URL. New or changed files are uploaded first; remote
#   files that no longer match anything are deleted afterwards.
ctfd_sync_challenge_files() {
    local challenge_data="$1" challenge_id="$2" challenge_path="$3"

    local existing
    existing="$(ctfd_api_call GET "/api/v1/challenges/$challenge_id/files")" || {
        log_warning "Could not list files for challenge $challenge_id"
        return 1
    }

    # Build [{path, name, sha1}] for the declared files
    local desired="[]" declared_path full_path sha1 any_failed=0
    while IFS= read -r declared_path; do
        [[ -z "$declared_path" || "$declared_path" == "null" ]] && continue
        full_path="$(_resolve_challenge_file "$declared_path" "$challenge_path")" || {
            any_failed=1
            continue
        }
        sha1="$(_ctfd_sha1_file "$full_path")"
        desired="$(echo "$desired" | jq -c --arg p "$full_path" --arg n "$(basename "$full_path")" --arg s "$sha1" \
            '. + [{path: $p, name: $n, sha1: $s}]')"
    done < <(echo "$challenge_data" | jq -r '.files // [] | .[]')

    # CTFd stores uploads under werkzeug's secure_filename(); approximate it so
    # names compare equal (a mismatch only costs a redundant re-upload).
    local plan
    plan="$(jq -cn --argjson ex "$(echo "$existing" | jq -c '.data // []')" --argjson want "$desired" '
        def secure_name: gsub("\\s+"; "_") | gsub("[^A-Za-z0-9_.-]"; "") | sub("^[._]+"; "") | sub("[._]+$"; "");
        (reduce $want[] as $w ({used: [], upload: []};
            . as $st
            | ([ $ex[]
                 | select(.sha1sum == $w.sha1
                          and ((.location // "" | split("/") | last) == ($w.name | secure_name))
                          and (.id as $id | $st.used | any(. == $id) | not)) ]
               | first) as $match
            | if $match then .used += [$match.id] else .upload += [$w.path] end
        )) as $r
        | {upload: $r.upload, delete: [ $ex[] | .id | select(. as $id | $r.used | any(. == $id) | not) ]}')" || return 1

    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        if ctfd_upload_file "$path" "$challenge_id" >/dev/null; then
            log_debug "Uploaded: $(basename "$path")"
        else
            log_warning "Failed to upload: $(basename "$path")"
            any_failed=1
        fi
    done < <(echo "$plan" | jq -r '.upload[]')

    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        ctfd_api_call DELETE "/api/v1/files/$id" >/dev/null \
            && log_debug "Deleted file id: $id" \
            || { log_warning "Failed to delete file id $id"; any_failed=1; }
    done < <(echo "$plan" | jq -r '.delete[]')

    log_debug "Files: $(echo "$plan" | jq '.upload | length') uploaded, $(echo "$plan" | jq '.delete | length') removed"
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

# Must list via /challenges/<id>/files: /api/v1/files ignores unknown query
# parameters such as challenge_id and returns every file on the platform
# (all challenges' files and page uploads), which would then all be deleted.
ctfd_delete_challenge_files() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/files" "/api/v1/files/%s" "files"
}

# Deleters used by sync to clear-then-recreate tags and topics, which carry no
# player state. None of these touch the parent challenge, so its ID is
# preserved and any prerequisite references other challenges hold remain valid.
ctfd_delete_challenge_tags() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/tags" "/api/v1/tags/%s" "tags"
}

# Topics are shared entities; the per-challenge association (ChallengeTopic) is
# what we remove, hence the ?type=challenge&target_id=<assoc-id> form.
ctfd_delete_challenge_topics() {
    _ctfd_delete_subresources "$1" "/api/v1/challenges/$1/topics" "/api/v1/topics?type=challenge&target_id=%s" "topics"
}

# ── Hints ────────────────────────────────────────────────────────────────────

# Hint forms accepted in challenge.yml:
#   - "a plain string hint"
#   - { content: "...", title: "...", cost: 10 }
#   - { key: h2, content: "...", cost: 20, requirements: [h1] }   # gated hint
# A gated hint stays hidden until the player has unlocked every hint named in
# its `requirements` (referenced by the other hints' `key`).
#
# Players' unlocks reference hints by ID (CTFd keeps no foreign key, so a
# deleted hint silently orphans them). Hints are therefore updated in place:
# the Nth declared hint reuses the Nth existing hint (by creation order), and
# only surplus hints are created or deleted. Keep hint order stable in
# challenge.yml and append new hints at the end.
#
# Gated content must never be exposed before its prerequisites are enforced,
# so (mirroring ctfcli) new gated hints are created with blank content, then
# prerequisites are set on every hint, and gated content is written last.

# _ctfd_apply_hints CHALLENGE_DATA CHALLENGE_ID EXISTING_IDS
#   EXISTING_IDS: newline-separated IDs of the challenge's current hints, in
#   creation order (empty on install). Echoes the IDs left over (not reused).
_ctfd_apply_hints() {
    local challenge_data="$1" challenge_id="$2" existing_ids="$3"

    local -a existing=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && existing+=("$id")
    done <<< "$existing_ids"

    declare -A _hint_id_by_key=()   # local key → hint id
    local -a _hint_ids=() _hint_content=() _hint_title=() _hint_cost=() _hint_req_keys=() _hint_reused=()

    # ── Pass 1: assign an id to every declared hint (reuse, else create) ──
    local hint_entry i=0
    while IFS= read -r hint_entry; do
        [[ -z "$hint_entry" || "$hint_entry" == "null" ]] && continue

        local hint_content hint_title hint_cost hint_key req_keys
        if echo "$hint_entry" | jq -e 'type == "string"' >/dev/null 2>&1; then
            hint_content="$(echo "$hint_entry" | jq -r '.')"
            hint_title=""; hint_cost="0"; hint_key=""; req_keys=""
        else
            hint_content="$(echo "$hint_entry" | jq -r '.content // .hint // ""')"
            hint_title="$(echo "$hint_entry"   | jq -r '.title // ""')"
            hint_cost="$(echo "$hint_entry"    | jq -r '.cost // 0')"
            hint_key="$(echo "$hint_entry"     | jq -r '.key // empty')"
            req_keys="$(echo "$hint_entry"     | jq -r '[.requirements // [] | .[]] | join("\n")')"
        fi

        local hint_id reused=false
        if (( i < ${#existing[@]} )); then
            hint_id="${existing[$i]}"
            reused=true
        else
            # Gated hints are created with blank content (filled in pass 3)
            local post_content="$hint_content"
            [[ -n "$req_keys" ]] && post_content=""

            local response
            response="$(ctfd_api_call POST "/api/v1/hints" "$(jq -n \
                --argjson chal_id "$challenge_id" \
                --arg content "$post_content" \
                --arg title "$hint_title" \
                --argjson cost "$hint_cost" \
                '{challenge_id: $chal_id, content: $content, title: $title, cost: $cost}')")" || {
                log_warning "Failed to add hint"
                return 1
            }
            hint_id="$(echo "$response" | jq -r '.data.id')"
            [[ -n "$hint_id" && "$hint_id" != "null" ]] || {
                log_warning "Could not read created hint id from response"
                return 1
            }
            log_debug "Added hint id $hint_id (cost: $hint_cost${req_keys:+, gated})"
        fi

        _hint_ids+=("$hint_id")
        _hint_content+=("$hint_content")
        _hint_title+=("$hint_title")
        _hint_cost+=("$hint_cost")
        _hint_req_keys+=("$req_keys")
        _hint_reused+=("$reused")
        [[ -n "$hint_key" ]] && _hint_id_by_key["$hint_key"]="$hint_id"
        ((++i))
    done < <(echo "$challenge_data" | jq -c '.hints // [] | .[]')

    # ── Passes 2 & 3: prerequisites (and metadata), then content ──
    for i in "${!_hint_ids[@]}"; do
        local hid="${_hint_ids[$i]}" req_keys="${_hint_req_keys[$i]}"

        local -a prereq_ids=()
        local key
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local rid="${_hint_id_by_key[$key]:-}"
            [[ -n "$rid" ]] || {
                log_warning "Hint prerequisite key '$key' is not defined among this challenge's hints"
                return 1
            }
            prereq_ids+=("$rid")
        done <<< "$req_keys"

        local prereqs_json="[]"
        (( ${#prereq_ids[@]} > 0 )) && \
            prereqs_json="$(printf '%s\n' "${prereq_ids[@]}" | jq -R 'tonumber' | jq -sc '.')"

        # New ungated hints were created complete — nothing left to set
        [[ "${_hint_reused[$i]}" == "false" && -z "$req_keys" ]] && continue

        local meta
        meta="$(jq -n \
            --arg title "${_hint_title[$i]}" \
            --argjson cost "${_hint_cost[$i]}" \
            --argjson p "$prereqs_json" \
            '{title: $title, cost: $cost, requirements: {prerequisites: $p}}')"

        if [[ -z "$req_keys" ]]; then
            # Reused ungated hint: one update, nothing to protect
            ctfd_api_call PATCH "/api/v1/hints/$hid" \
                "$(echo "$meta" | jq --arg c "${_hint_content[$i]}" '. + {content: $c}')" >/dev/null || {
                log_warning "Failed to update hint id $hid"
                return 1
            }
            log_debug "Updated hint id $hid"
            continue
        fi

        # Gated: enforce prerequisites before revealing the content
        ctfd_api_call PATCH "/api/v1/hints/$hid" "$meta" >/dev/null || {
            log_warning "Failed to set prerequisites for hint id $hid"
            return 1
        }
        ctfd_api_call PATCH "/api/v1/hints/$hid" \
            "$(jq -n --arg c "${_hint_content[$i]}" '{content: $c}')" >/dev/null || {
            log_warning "Failed to set content for hint id $hid"
            return 1
        }
        log_debug "Wired gated hint id $hid ($prereqs_json)"
    done

    # Report existing hints that were not reused
    local j
    for (( j = ${#_hint_ids[@]}; j < ${#existing[@]}; j++ )); do
        echo "${existing[$j]}"
    done
}

ctfd_add_hints() {
    local challenge_data="$1" challenge_id="$2"
    log_debug "Adding hints..."
    _ctfd_apply_hints "$challenge_data" "$challenge_id" "" >/dev/null
}

# ctfd_sync_hints CHALLENGE_DATA CHALLENGE_ID
#   Updates the challenge's hints in place (see above), so players keep the
#   hints they unlocked. Hints removed from challenge.yml are deleted.
ctfd_sync_hints() {
    local challenge_data="$1" challenge_id="$2"

    local response existing_ids
    response="$(ctfd_api_call GET "/api/v1/challenges/$challenge_id/hints")" || {
        log_warning "Could not list hints for challenge $challenge_id"
        return 1
    }
    existing_ids="$(echo "$response" | jq -r '.data // [] | map(.id) | sort | .[]')"

    local surplus
    surplus="$(_ctfd_apply_hints "$challenge_data" "$challenge_id" "$existing_ids")" || return 1

    local id failed=0
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ctfd_api_call DELETE "/api/v1/hints/$id" >/dev/null; then
            log_warning "Deleted hint id $id (removed from challenge.yml; players who unlocked it lose access)"
        else
            log_warning "Failed to delete hint id $id"
            failed=1
        fi
    done <<< "$surplus"
    return "$failed"
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

# ── Requirements normalisation ───────────────────────────────────────────────
# The `requirements` field may be either a bare list of prerequisites or a
# {prerequisites: [...], anonymize: bool} object. These helpers present a single
# normalised view so the rest of the code never has to branch on the form.

# Echoes the prerequisites as a compact JSON array (names and/or numeric IDs).
_ctfd_requirement_prereqs() {
    echo "$1" | jq -c '(.requirements // []) | if type == "object" then (.prerequisites // []) else . end'
}

# Echoes "true"/"false" — whether locked challenges should be anonymised ("???")
# rather than hidden. Only meaningful with the object form; defaults to false.
_ctfd_requirement_anonymize() {
    echo "$1" | jq -r '(.requirements // {}) | if type == "object" then (.anonymize // false) else false end'
}

# ── Requirements pre-flight check ────────────────────────────────────────────

ctfd_preflight_requirements() {
    local challenge_data="$1" challenge_name="$2"

    local requirements_json
    requirements_json="$(_ctfd_requirement_prereqs "$challenge_data")"
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
    done < <(echo "$requirements_json" | jq -c '.[]')

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
    requirements_json="$(_ctfd_requirement_prereqs "$challenge_data")"
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
    done < <(echo "$requirements_json" | jq -c '.[]')

    # Guard: requirements were declared but all entries were blank/null
    if [[ ${#prereq_ids[@]} -eq 0 ]]; then
        log_error "Requirements were declared but none could be resolved for challenge ID $challenge_id"
        return 1
    fi

    printf '%s\n' "${prereq_ids[@]}" | jq -R 'tonumber' | jq -sc '.'
}

# ctfd_patch_requirements CHALLENGE_ID PREREQS_JSON_ARRAY [ANONYMIZE]
#   PATCHes the prerequisite list onto a challenge (empty array clears it).
#   ANONYMIZE ("true"/"false", default false) controls whether locked
#   challenges show as "???" rather than being hidden entirely.
ctfd_patch_requirements() {
    local challenge_id="$1" prereqs_array="$2" anonymize="${3:-false}"

    local req_payload
    req_payload="$(jq -n \
        --argjson prereqs "$prereqs_array" \
        --argjson anon "$anonymize" \
        '{requirements: {prerequisites: $prereqs, anonymize: $anon}}'
    )"

    log_debug "Setting requirements on challenge ID $challenge_id: $prereqs_array (anonymize: $anonymize)"

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
    requirements_json="$(_ctfd_requirement_prereqs "$challenge_data")"
    [[ "$requirements_json" == "[]" || "$requirements_json" == "null" ]] && return 0

    log_debug "Resolving requirements..."

    local prereqs_array anonymize
    prereqs_array="$(_ctfd_resolve_requirement_ids "$challenge_data" "$challenge_id")" || return 1
    anonymize="$(_ctfd_requirement_anonymize "$challenge_data")"

    ctfd_patch_requirements "$challenge_id" "$prereqs_array" "$anonymize"
}

# ctfd_sync_requirements — set prerequisites to exactly the declared set,
# clearing them when none are declared. Used by the second pass of sync, once
# every challenge is guaranteed to exist, so name→ID resolution cannot fail on a
# not-yet-synced prerequisite.
ctfd_sync_requirements() {
    local challenge_data="$1" challenge_id="$2"

    local prereqs_array anonymize
    prereqs_array="$(_ctfd_resolve_requirement_ids "$challenge_data" "$challenge_id")" || return 1
    anonymize="$(_ctfd_requirement_anonymize "$challenge_data")"

    ctfd_patch_requirements "$challenge_id" "$prereqs_array" "$anonymize"
}
