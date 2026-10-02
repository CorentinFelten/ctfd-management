#!/usr/bin/env bash
# Galvanize API client for the checks, calling it the way Zync does from a
# player's browser: JWTs signed with ZYNC_JWT_SECRET. Source after common.sh.
#
#   galvanize_jwt ROLE TEAM CATEGORY CHALLENGE   prints a signed token
#   galvanize_api METHOD PATH TOKEN [JSON]       prints the HTTP status; the
#                                                body is in $GALVANIZE_BODY
#   galvanize_errors                             prints the error deployments

GALVANIZE_DOMAIN="$(env_value INSTANCER_DOMAIN)"
GALVANIZE_JWT_SECRET="$(env_value ZYNC_JWT_SECRET)"
[[ -n "$GALVANIZE_DOMAIN" && -n "$GALVANIZE_JWT_SECRET" ]] || fail ".env has no INSTANCER_DOMAIN or ZYNC_JWT_SECRET"

GALVANIZE_BODY="$(mktemp)"
trap 'rm -f "$GALVANIZE_BODY"' EXIT

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

galvanize_jwt() {
    local header payload signature
    header="$(printf '{"alg":"HS256","typ":"JWT"}' | _b64url)"
    payload="$(jq -cjn \
        --arg role "$1" --arg team "$2" --arg cat "$3" --arg chall "$4" \
        --argjson exp "$(($(date +%s) + 3600))" \
        '{team_id: $team, challenge_name: $chall, category: $cat, role: $role, exp: $exp}' | _b64url)"
    signature="$(printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -hmac "$GALVANIZE_JWT_SECRET" -binary | _b64url)"
    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

galvanize_api() {
    local -a args=(-o "$GALVANIZE_BODY" -w '%{http_code}' -X "$1" -H "Authorization: Bearer $3")
    [[ -n "${4:-}" ]] && args+=(-H "Content-Type: application/json" -d "$4")
    fetch "${SCHEME}://${GALVANIZE_DOMAIN}$2" "${args[@]}"
}

galvanize_errors() {
    galvanize_api GET /admin/error-deployments "$(galvanize_jwt admin "" "" "")" >/dev/null || true
    echo "Galvanize error deployments:" >&2
    jq . "$GALVANIZE_BODY" >&2 || cat "$GALVANIZE_BODY" >&2
}
