#!/usr/bin/env bash
# Checks CTFd's first-run setup done by setup.sh: CTFd is set up with the
# expected settings, its web setup is not reachable, and the first admin can
# log in through the public URL with the password given to setup.sh.
#
#   CTFD_ADMIN_NAME, CTFD_ADMIN_PASSWORD   the first admin's credentials
#   EXPECT_USER_MODE, EXPECT_CTF_NAME      expected settings
#   EXPECT_TEAM_SIZE                       optional

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
: "${CTFD_ADMIN_NAME:?}" "${CTFD_ADMIN_PASSWORD:?}" "${EXPECT_USER_MODE:?}" "${EXPECT_CTF_NAME:?}"

ctfd_config() { docker exec ctfd python manage.py get_config "$1" 2>/dev/null | tail -n1; }

section "CTFd first-run setup"

setup_done="$(ctfd_config setup)"
[[ "${setup_done,,}" =~ ^(true|1)$ ]] || fail "CTFd is not set up (setup = '$setup_done')"
pass "CTFd is set up"

for spec in "user_mode=$EXPECT_USER_MODE" "ctf_name=$EXPECT_CTF_NAME" ${EXPECT_TEAM_SIZE:+"team_size=$EXPECT_TEAM_SIZE"}; do
    key="${spec%%=*}" want="${spec#*=}"
    got="$(ctfd_config "$key")"
    [[ "$got" == "$want" ]] || fail "CTFd's $key is '$got', expected '$want'"
done
pass "CTFd settings: ${EXPECT_USER_MODE} mode, name '${EXPECT_CTF_NAME}'${EXPECT_TEAM_SIZE:+, teams of $EXPECT_TEAM_SIZE}"

code="$(fetch "${SCHEME}://${DOMAIN}/setup" -o /dev/null -w '%{http_code}')"
[[ "$code" == 404 ]] || fail "CTFd's web setup is reachable at ${SCHEME}://${DOMAIN}/setup (HTTP $code)"
pass "The web setup wizard is not routed (HTTP 404)"

# login PASSWORD_FILE — logs in as the first admin, prints the session cookie
# of the logged-in session (empty when the login is refused). The password
# is read from a file descriptor, never put on a command line.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
login() {
    fetch "${SCHEME}://${DOMAIN}/login" -D "$tmp/h1" -o "$tmp/page" >/dev/null
    local cookie nonce code
    cookie="$(tr -d '\r' < "$tmp/h1" | sed -n 's/^[Ss]et-[Cc]ookie: *\(session=[^;]*\).*/\1/p' | head -n1)"
    nonce="$(sed -n "s/.*'csrfNonce': \"\([^\"]*\)\".*/\1/p" "$tmp/page" | head -n1)"
    [[ -n "$cookie" && -n "$nonce" ]] || fail "The login page returned no session or CSRF token"
    code="$(fetch "${SCHEME}://${DOMAIN}/login" -D "$tmp/h2" -o /dev/null -w '%{http_code}' \
        -H "Cookie: $cookie" --data-urlencode "nonce=$nonce" \
        --data-urlencode "name=$CTFD_ADMIN_NAME" --data-urlencode "password@-" < "$1")"
    [[ "$code" == 302 ]] || return 0
    tr -d '\r' < "$tmp/h2" | sed -n 's/^[Ss]et-[Cc]ookie: *\(session=[^;]*\).*/\1/p' | head -n1
}

printf '%s' "$CTFD_ADMIN_PASSWORD" > "$tmp/password"
session="$(login "$tmp/password")"
[[ -n "$session" ]] || fail "The first admin cannot log in at ${SCHEME}://${DOMAIN}/login with the password given to setup.sh"
code="$(fetch "${SCHEME}://${DOMAIN}/admin/statistics" -o /dev/null -w '%{http_code}' -H "Cookie: $session")"
[[ "$code" == 200 ]] || fail "The first admin's session cannot open the admin panel (HTTP $code)"
pass "The first admin logs in through ${SCHEME}://${DOMAIN} and reaches the admin panel"

printf '%s' "not-the-password" > "$tmp/password"
[[ -z "$(login "$tmp/password")" ]] || fail "CTFd accepted a wrong admin password"
pass "A wrong password is refused"
