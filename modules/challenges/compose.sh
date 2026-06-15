#!/usr/bin/env bash
# modules/challenges/compose.sh — Docker Compose validation and deployment for challenges.
# Requires: lib/common.sh, modules/ctfd/yaml.sh

[[ -n "${_CHALL_COMPOSE_LOADED:-}" ]] && return 0
readonly _CHALL_COMPOSE_LOADED=1

# ── Docker Compose image tag validation ─────────────────────────────────────
#
# validate_compose_image_tags CHALLENGE_PATH
#
# For every service in the compose file (compose.y[a]ml or docker-compose.y[a]ml):
#   • Services with a `build:` key are considered *locally built*.
#     – The `image:` field MUST be present and MUST carry a tag (name:tag).
#   • Services with only an `image:` key (no `build:`) are *pulled* and are
#     exempt from all tag checks.
#
# Returns 0 when all checks pass, 1 on any violation (caller should skip
# ingestion for this challenge).

validate_compose_image_tags() {
    local challenge_path="$1"
    local compose_file challenge_yml="$challenge_path/challenge.yml"

    # No compose file → nothing to validate
    compose_file="$(get_compose_file "$challenge_path")" || return 0

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
            log_error "[$cname] Service '$svc' is built locally but has no 'image:' field in compose file — a tagged image name is required"
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
            log_error "[$cname] Service '$svc' is built locally but its image '$image_field' has no tag — add a tag (e.g. '$image_field:latest')"
            ok=false
            continue
        fi

        log_debug "[$cname] Service '$svc': locally built image '$image_field' has tag '$image_tag' ✓"
    done

    [[ "$ok" == "true" ]]
}

# ── Deploy a single challenge's docker-compose stack ────────────────────────

deploy_single_compose() {
    local challenge_path="$1"
    local challenge_name compose_file

    challenge_name="$(basename "$challenge_path")"
    compose_file="$(get_compose_file "$challenge_path")" || {
        log_debug "No compose file found for: $challenge_name"
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
