#!/usr/bin/env bash
# modules/challenges/compose.sh — Docker Compose validation and deployment for challenges.
# Requires: lib/common.sh, modules/ctfd/yaml.sh

[[ -n "${_CHALL_COMPOSE_LOADED:-}" ]] && return 0
readonly _CHALL_COMPOSE_LOADED=1

# ── Docker Compose image tag validation ─────────────────────────────────────
#
# validate_compose_image_tags CHALLENGE_PATH
#
# For every service in CHALLENGE_PATH/docker-compose.yml:
#   • Services with a `build:` key are considered *locally built*.
#     – The `image:` field MUST be present and MUST carry a tag (name:tag).
#     – If challenge.yml contains a `compose_definition` block, every image
#       reference inside it must match the tag declared in docker-compose.yml.
#   • Services with only an `image:` key (no `build:`) are *pulled* and are
#     exempt from all tag checks.
#
# Returns 0 when all checks pass, 1 on any violation (caller should skip
# ingestion for this challenge).

validate_compose_image_tags() {
    local challenge_path="$1"
    local compose_file="$challenge_path/docker-compose.yml"
    local challenge_yml="$challenge_path/challenge.yml"

    # No compose file → nothing to validate
    [[ -f "$compose_file" ]] || return 0

    local cname
    cname="$(basename "$challenge_path")"

    # ── Parse docker-compose.yml into JSON ───────────────────────────────────
    local compose_json
    if ! compose_json="$(parse_challenge_yaml "$compose_file")"; then
        log_error "[$cname] Could not parse docker-compose.yml — skipping tag validation"
        return 1
    fi

    # ── Collect service names ────────────────────────────────────────────────
    local -a services
    mapfile -t services < <(echo "$compose_json" | jq -r '.services // {} | keys[]' 2>/dev/null)

    if [[ ${#services[@]} -eq 0 ]]; then
        log_debug "[$cname] docker-compose.yml has no services — skipping tag validation"
        return 0
    fi

    # ── Parse compose_definition from challenge.yml (optional) ───────────────
    local compose_def_json=""
    if [[ -f "$challenge_yml" ]]; then
        local chall_json
        chall_json="$(parse_challenge_yaml "$challenge_yml" 2>/dev/null)" || true
        if [[ -n "$chall_json" ]]; then
            compose_def_json="$(echo "$chall_json" | jq -c '.compose_definition // empty' 2>/dev/null)" || true
        fi
    fi

    # ── Per-service checks ───────────────────────────────────────────────────
    local ok=true svc

    for svc in "${services[@]}"; do
        local is_built image_field

        # Determine whether this service is locally built (has a `build:` key)
        is_built="$(echo "$compose_json" | jq -r --arg svc "$svc" \
            '.services[$svc] | if has("build") then "true" else "false" end' 2>/dev/null)"

        if [[ "$is_built" != "true" ]]; then
            log_debug "[$cname] Service '$svc' uses a pulled image — skipping tag checks"
            continue
        fi

        # ── Locally built: `image:` field must exist and carry a tag ─────────
        image_field="$(echo "$compose_json" | jq -r --arg svc "$svc" \
            '.services[$svc].image // ""' 2>/dev/null)"

        if [[ -z "$image_field" ]]; then
            log_error "[$cname] Service '$svc' is built locally but has no 'image:' field in docker-compose.yml — a tagged image name is required"
            ok=false
            continue
        fi

        # Tag is everything after the last colon in the last path segment,
        # excluding digest (@sha256:...) and bare port numbers (pure digits).
        local image_tag
        image_tag="$(printf '%s' "$image_field" | jq -Rr '
            split("@")[0]                           # strip digest
            | split("/")[-1]                        # last path segment
            | if contains(":") then
                split(":")[-1]                      # part after last colon
                | if test("^[0-9]+$") then "" else . end  # reject port numbers
              else ""
              end
        ' 2>/dev/null)"

        if [[ -z "$image_tag" ]]; then
            log_error "[$cname] Service '$svc' is built locally but its image '$image_field' has no tag — add a tag (e.g. '$image_field:latest') to docker-compose.yml"
            ok=false
            continue
        fi

        log_debug "[$cname] Service '$svc': locally built image '$image_field' has tag '$image_tag' ✓"

        # ── compose_definition consistency check ──────────────────────────────
        if [[ -z "$compose_def_json" ]]; then
            log_debug "[$cname] No compose_definition in challenge.yml — skipping consistency check for service '$svc'"
            continue
        fi

        # Find every image reference inside compose_definition for this service
        local -a mismatches
        mapfile -t mismatches < <(echo "$compose_def_json" | jq -r --arg svc "$svc" --arg expected "$image_field" '
            if type == "object" then
                (.services // .)?[$svc]?.image // ""
            elif type == "string" then
                # Raw YAML string — best-effort line scan for image: field
                [split("\n")[] | capture("^\\s*image:\\s*(?<img>.+)") | .img
                 | gsub("^[\"'"'"']+|[\"'"'"']+$"; "")] | first // ""
            else ""
            end
            | if . != "" and . != $expected then . else empty end
        ' 2>/dev/null)

        if [[ ${#mismatches[@]} -gt 0 ]]; then
            local mismatch
            for mismatch in "${mismatches[@]}"; do
                log_error "[$cname] compose_definition in challenge.yml references image '$mismatch' for service '$svc', but docker-compose.yml declares '$image_field' — they must match"
            done
            ok=false
        else
            log_debug "[$cname] Service '$svc': compose_definition image reference is consistent ✓"
        fi
    done

    [[ "$ok" == "true" ]]
}

# ── Deploy a single challenge's docker-compose stack ────────────────────────

deploy_single_compose() {
    local challenge_path="$1"
    local challenge_name compose_file

    challenge_name="$(basename "$challenge_path")"
    compose_file="$challenge_path/docker-compose.yml"

    [[ -f "$compose_file" ]] || {
        log_debug "No docker-compose.yml found for: $challenge_name"
        return 0
    }

    log_info "Deploying docker-compose for challenge: $challenge_name"

    if [[ "${CONFIG[DRY_RUN]}" == "false" ]]; then
        local compose_output exit_code=0

        compose_output="$(cd "$challenge_path" && docker compose up -d 2>&1)" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "Successfully deployed compose stack: $challenge_name"
            log_debug "Compose output: $compose_output"
        else
            log_error "Failed to deploy compose stack: $challenge_name"
            log_error "Error output: $compose_output"
            return 1
        fi
    else
        log_info "Would deploy: docker compose -f '${compose_file}' up -d"
    fi
}
