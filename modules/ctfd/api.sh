#!/usr/bin/env bash
# modules/ctfd/api.sh — Low-level CTFd REST API communication.
# Requires: lib/common.sh, modules/ctfd/config.sh

[[ -n "${_LIB_CTFD_API_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_API_LOADED=1

# ── Auth header file ─────────────────────────────────────────────────────────
#
# The access token is handed to curl via a private (0600) header file rather
# than on its command line, where any local user could read it from `ps`.
# Callers run inside $(...) subshells, whose EXIT trap does not fire, so each
# caller removes the file itself.

_ctfd_auth_header_file() {
    local token="$1" header_file
    header_file="$(mktemp)" || return 1
    printf 'Authorization: Token %s\n' "$token" > "$header_file"
    echo "$header_file"
}

# ── Generic authenticated API call ──────────────────────────────────────────

ctfd_api_call() {
    local method="$1" endpoint="$2" data="${3:-}"

    local url token
    url="$(ctfd_get_config "url")"
    token="$(ctfd_get_config "access_token")"

    if [[ -z "$url" || -z "$token" ]]; then
        log_error "CTFd URL and access token must be configured"
        return 1
    fi

    url="${url%/}"

    local body_file header_file data_file=""
    body_file="$(mktemp)"
    header_file="$(_ctfd_auth_header_file "$token")" || { rm -f "$body_file"; return 1; }
    _cleanup_files+=("$body_file" "$header_file")

    local -a curl_args=(
        -X "$method"
        -H "@$header_file"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -s -S
        --connect-timeout 10
        --max-time 60
        -o "$body_file"
        -w '%{http_code}'
    )

    # Payloads (flag contents, hint text…) go through a private file too
    if [[ -n "$data" ]]; then
        data_file="$(mktemp)"
        _cleanup_files+=("$data_file")
        printf '%s' "$data" > "$data_file"
        curl_args+=(--data-binary "@$data_file")
    fi

    # Transient-failure retry with linear backoff. 429 (rate limited) is always
    # safe to retry since the request was not processed; a network error or 5xx
    # is only retried for idempotent methods, because a POST may have been
    # applied server-side before the failure was reported.
    local max_attempts=3 attempt=1 status body
    while :; do
        status="$(curl "${curl_args[@]}" "${url}${endpoint}" 2>/dev/null)" || status=""
        body="$(cat "$body_file")"

        if [[ -n "$status" && "$status" -ge 200 && "$status" -lt 300 ]]; then
            rm -f "$body_file" "$header_file" "$data_file"
            echo "$body"
            return 0
        fi

        local retry=false
        if [[ "$status" == "429" ]]; then
            retry=true
        elif [[ "$method" != "POST" ]] && { [[ -z "$status" ]] || [[ "$status" -ge 500 ]]; }; then
            retry=true
        fi

        if [[ "$retry" == "true" && $attempt -lt $max_attempts ]]; then
            local delay=$((attempt * 2))
            log_debug "API $method $endpoint failed (status: ${status:-network-error}); retry $attempt/$((max_attempts - 1)) in ${delay}s"
            sleep "$delay"
            ((++attempt))
            continue
        fi
        break
    done

    rm -f "$body_file" "$header_file" "$data_file"
    if [[ -z "$status" ]]; then
        log_error "curl failed for: $method $endpoint"
        return 1
    fi
    log_debug "API request failed: $method $endpoint"
    log_debug "Status code: $status"
    log_debug "Response: $body"
    echo "$body"
    return 1
}

# ── Multipart file upload ───────────────────────────────────────────────────

ctfd_upload_file() {
    local file_path="$1" challenge_id="$2"

    local url token
    url="$(ctfd_get_config "url")"
    token="$(ctfd_get_config "access_token")"
    url="${url%/}"

    [[ -f "$file_path" ]] || {
        log_error "File not found: $file_path"
        return 1
    }

    log_debug "Uploading file: $(basename "$file_path")"

    local body_file header_file
    body_file="$(mktemp)"
    header_file="$(_ctfd_auth_header_file "$token")" || { rm -f "$body_file"; return 1; }
    _cleanup_files+=("$body_file" "$header_file")

    local status
    status="$(curl -s -S \
        --connect-timeout 10 \
        --max-time 120 \
        -X POST \
        -H "@$header_file" \
        -F "file=@$file_path" \
        -F "type=challenge" \
        -F "challenge_id=$challenge_id" \
        -o "$body_file" \
        -w '%{http_code}' \
        "${url}/api/v1/files" 2>/dev/null)" || {
        rm -f "$body_file" "$header_file"
        log_error "curl failed uploading: $(basename "$file_path")"
        return 1
    }

    local body
    body="$(cat "$body_file")"
    rm -f "$body_file" "$header_file"

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        log_error "File upload failed: $(basename "$file_path")"
        log_debug "Status: $status, Response: $body"
        return 1
    fi
}
