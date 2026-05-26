#!/usr/bin/env bash
# modules/ctfd/api.sh — Low-level CTFd REST API communication.
# Requires: lib/common.sh, modules/ctfd/config.sh

[[ -n "${_LIB_CTFD_API_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_API_LOADED=1

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

    local body_file
    body_file="$(mktemp)"
    _cleanup_files+=("$body_file")

    local -a curl_args=(
        -X "$method"
        -H "Authorization: Token $token"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -s -S
        --connect-timeout 10
        --max-time 60
        -o "$body_file"
        -w '%{http_code}'
    )

    [[ -n "$data" ]] && curl_args+=(-d "$data")

    local status
    status="$(curl "${curl_args[@]}" "${url}${endpoint}" 2>/dev/null)" || {
        rm -f "$body_file"
        log_error "curl failed for: $method $endpoint"
        return 1
    }

    local body
    body="$(cat "$body_file")"
    rm -f "$body_file"

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        log_debug "API request failed: $method $endpoint"
        log_debug "Status code: $status"
        log_debug "Response: $body"
        echo "$body"
        return 1
    fi
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

    local body_file
    body_file="$(mktemp)"
    _cleanup_files+=("$body_file")

    local status
    status="$(curl -s -S \
        --connect-timeout 10 \
        --max-time 120 \
        -X POST \
        -H "Authorization: Token $token" \
        -F "file=@$file_path" \
        -F "type=challenge" \
        -F "challenge_id=$challenge_id" \
        -o "$body_file" \
        -w '%{http_code}' \
        "${url}/api/v1/files" 2>/dev/null)" || {
        rm -f "$body_file"
        log_error "curl failed uploading: $(basename "$file_path")"
        return 1
    }

    local body
    body="$(cat "$body_file")"
    rm -f "$body_file"

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        log_error "File upload failed: $(basename "$file_path")"
        log_debug "Status: $status, Response: $body"
        return 1
    fi
}
