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

    local -a curl_args=(
        -X "$method"
        -H "Authorization: Token $token"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -s -S
        -w "\n%{http_code}"
    )

    [[ -n "$data" ]] && curl_args+=(-d "$data")

    local response
    response="$(curl "${curl_args[@]}" "${url}${endpoint}" 2>&1)"

    local body status
    body="$(echo "$response" | sed '$d')"
    status="$(echo "$response" | tail -n1)"

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

    local response
    response="$(curl -s -S -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Token $token" \
        -F "file=@$file_path" \
        -F "type=challenge" \
        -F "challenge_id=$challenge_id" \
        "${url}/api/v1/files" 2>&1)"

    local body status
    body="$(echo "$response" | sed '$d')"
    status="$(echo "$response" | tail -n1)"

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "$body"
        return 0
    else
        log_error "File upload failed: $(basename "$file_path")"
        log_debug "Status: $status, Response: $body"
        return 1
    fi
}
