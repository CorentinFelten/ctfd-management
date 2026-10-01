#!/usr/bin/env bash
# modules/setup/ctfd_admin.sh — First-run CTFd setup from the command line:
# the first admin account and the event settings are created by setup.sh,
# never through CTFd's web setup wizard (Traefik does not route /setup).
# Requires: lib/common.sh, modules/setup/theme.sh
#
# On a new deployment, --admin-name, --admin-email and --user-mode are
# mandatory, and the admin password is asked for once, without echo, at the
# start of the run (or read from CTFD_ADMIN_PASSWORD for unattended runs).
# It only lives in this process's memory: it reaches CTFd on the standard
# input of a curl run inside the ctfd container, never on a command line or
# on disk. CTFd stores only its bcrypt hash.
#
# Required by CTFd (CTFd/views.py setup(), CTFd/forms/setup.py):
#   name, email, password   the handler fails without them
#   user_mode               required by the wizard form; omitted, the handler
#                           silently defaults to "users" while the wizard
#                           defaults to "teams". It cannot be changed later
#                           without wiping every account, so it is explicit.
# Optional (CTFd defaults otherwise): ctf_name (shown as "CTFd"),
# ctf_description, team_size, ctf_theme (core; set from --active-theme).

[[ -n "${_SETUP_CTFD_ADMIN_LOADED:-}" ]] && return 0
readonly _SETUP_CTFD_ADMIN_LOADED=1

# The admin password, once collected (never exported, never written to disk)
_CTFD_ADMIN_PASSWORD=""

# ctfd_cli COMPOSE_ARRAY_NAME ARGS... — runs CTFd's CLI (manage.py) in the
# running ctfd container and prints the last output line (CTFd logs plugin
# loading on stdout before the command's own output)
ctfd_cli() {
    local -n _compose="$1"; shift
    "${_compose[@]}" exec -T ctfd python manage.py "$@" 2>/dev/null | tail -n1
}

# _ctfd_is_true VALUE — CTFd prints boolean settings as True/1
_ctfd_is_true() { [[ "${1,,}" =~ ^(true|1)$ ]]; }

# wait_for_ctfd_healthy [TIMEOUT] — CTFd's CLI and setup need the app (and
# its database migrations) up
wait_for_ctfd_healthy() {
    local timeout="${1:-300}" status=""
    local deadline=$((SECONDS + timeout))
    log_info "Waiting for CTFd to be healthy..."
    while ((SECONDS < deadline)); do
        status="$(docker inspect -f '{{.State.Health.Status}}' ctfd 2>/dev/null || true)"
        [[ "$status" == healthy ]] && return 0
        sleep 5
    done
    log_error "CTFd did not become healthy within ${timeout}s (status: ${status:-unknown})"
    return 1
}

# _ctfd_setup_state — before anything is installed or started:
#   fresh    no MariaDB data yet: CTFd will need its first-run setup
#   done     the running CTFd is already set up
#   pending  the running CTFd is not set up yet
#   unknown  data exists but CTFd is not running (decided after startup)
_ctfd_setup_state() {
    local mysql_dir="${CONFIG[DEPLOY_DIR]}/data/mysql"
    if [[ ! -d "$mysql_dir" || -z "$(ls -A "$mysql_dir" 2>/dev/null)" ]]; then
        echo fresh
        return
    fi
    if command -v docker >/dev/null 2>&1 \
        && [[ "$(docker inspect -f '{{.State.Running}}' ctfd 2>/dev/null || true)" == true ]]; then
        local value
        value="$(docker exec ctfd python manage.py get_config setup 2>/dev/null | tail -n1 || true)"
        if _ctfd_is_true "$value"; then
            echo done
        else
            echo pending
        fi
        return
    fi
    echo unknown
}

# _validate_ctfd_admin_options — the same checks CTFd's setup applies, so a
# mistake fails before anything is installed
_validate_ctfd_admin_options() {
    local name="${CONFIG[ADMIN_NAME]}" email="${CONFIG[ADMIN_EMAIL]}" mode="${CONFIG[USER_MODE]}"
    local email_re='^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    local -a missing=()
    [[ -n "$name" ]]  || missing+=(--admin-name)
    [[ -n "$email" ]] || missing+=(--admin-email)
    [[ -n "$mode" ]]  || missing+=(--user-mode)
    if (( ${#missing[@]} > 0 )); then
        error_exit "CTFd's first admin account and mode are created by setup.sh, not in the browser:
  missing ${missing[*]}.
  Example: $SCRIPT_NAME --domain ${CONFIG[DOMAIN]} --admin-name admin --admin-email admin@example.com --user-mode teams ...
  The admin password is asked for during the run (or read from CTFD_ADMIN_PASSWORD with --yes)."
    fi
    (( ${#name} <= 128 ))           || error_exit "--admin-name is too long (128 characters at most)"
    [[ ! "$name" =~ $email_re ]]    || error_exit "--admin-name cannot be an email address (CTFd refuses it)"
    [[ "$email" =~ $email_re ]]     || error_exit "--admin-email is not a valid email address: $email"
    (( ${#email} <= 128 ))          || error_exit "--admin-email is too long (128 characters at most)"
    if [[ -n "${CONFIG[TEAM_SIZE]}" && "$mode" != teams ]]; then
        error_exit "--team-size only applies to --user-mode teams"
    fi
}

# _read_ctfd_admin_password — from CTFD_ADMIN_PASSWORD, else a hidden
# prompt typed twice. The variable is removed from the environment so that
# no command started by setup inherits it.
_read_ctfd_admin_password() {
    local password="" confirm=""
    if [[ -n "${CTFD_ADMIN_PASSWORD:-}" ]]; then
        password="$CTFD_ADMIN_PASSWORD"
        log_info "Using the CTFd admin password from CTFD_ADMIN_PASSWORD"
    elif [[ "$_ASSUME_YES" == "true" ]]; then
        error_exit "--yes cannot ask for the CTFd admin password: set CTFD_ADMIN_PASSWORD and keep it
  through sudo, e.g.: export CTFD_ADMIN_PASSWORD; sudo --preserve-env=CTFD_ADMIN_PASSWORD $SCRIPT_NAME ..."
    else
        require_terminal "the CTFd admin password"
        while true; do
            read -rsp "CTFd admin password for '${CONFIG[ADMIN_NAME]}': " password; echo >&2
            read -rsp "Confirm the password: " confirm; echo >&2
            if [[ -z "$password" ]]; then
                log_warning "The password cannot be empty."
            elif [[ "$password" != "$confirm" ]]; then
                log_warning "The passwords do not match."
            else
                break
            fi
        done
    fi
    unset CTFD_ADMIN_PASSWORD confirm
    (( ${#password} <= 128 )) || error_exit "The CTFd admin password is too long (128 characters at most)"
    [[ -n "$password" ]] || error_exit "The CTFd admin password cannot be empty"
    _CTFD_ADMIN_PASSWORD="$password"
}

# prepare_ctfd_admin — called right after argument parsing, before any
# change to the system, so a new deployment cannot start without its admin
# and the rest of the run needs no input
prepare_ctfd_admin() {
    local state
    state="$(_ctfd_setup_state)"
    CONFIG[CTFD_SETUP_STATE]="$state"

    case "$state" in
        done)
            if [[ -n "${CONFIG[ADMIN_NAME]}${CONFIG[ADMIN_EMAIL]}${CONFIG[USER_MODE]}${CONFIG[CTF_NAME]}" ]]; then
                log_info "CTFd is already set up: the first-run options (--admin-name, --user-mode, ...) are ignored"
            fi
            unset CTFD_ADMIN_PASSWORD
            ;;
        fresh|pending)
            _validate_ctfd_admin_options
            _read_ctfd_admin_password
            ;;
        unknown)
            # Existing data, CTFd stopped: collect what was given, and decide
            # once CTFd is up whether it is still needed
            if [[ -n "${CONFIG[ADMIN_NAME]}" ]]; then
                _validate_ctfd_admin_options
                _read_ctfd_admin_password
            fi
            ;;
    esac
}

# The request CTFd's setup wizard would send, run inside the ctfd container
# against CTFd itself (no Traefik, DNS or certificate involved). Arguments
# are form fields as field=value; the password arrives on standard input.
# Exit status: 0 accepted, 3 no session/CSRF token, 4 CSRF rejected,
# 5 CTFd refused the values (messages on stderr), 6 other HTTP status.
read -r -d '' _CTFD_SETUP_REQUEST <<'SH' || true
set -eu
url=http://localhost:8000/setup
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# GET: a session cookie and the CSRF nonce bound to it. The cookie is sent
# back by hand: CTFd may flag it Secure, which curl's cookie jar would not
# send over plain HTTP.
curl -sS -D "$tmp/headers" -o "$tmp/page" "$url"
cookie=$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Ss]et-[Cc]ookie: *\(session=[^;]*\).*/\1/p' | head -n 1)
nonce=$(sed -n "s/.*'csrfNonce': \"\([^\"]*\)\".*/\1/p" "$tmp/page" | head -n 1)
if [ -z "$cookie" ] || [ -z "$nonce" ]; then
    echo "The setup page returned no session or CSRF token" >&2
    exit 3
fi

# POST: the fields, then the password from standard input
n=$#
for field; do set -- "$@" --data-urlencode "$field"; done
shift "$n"
code=$(curl -sS -o "$tmp/response" -w '%{http_code}' -H "Cookie: $cookie" \
    --data-urlencode "nonce=$nonce" "$@" --data-urlencode "password@-" "$url")

case "$code" in
    302|303) exit 0 ;;
    403) echo "CTFd rejected the CSRF token (HTTP 403)" >&2; exit 4 ;;
    200)
        echo "CTFd refused the setup:" >&2
        grep -E "valid email|already|cannot be an email|Pick a" "$tmp/response" \
            | sed 's/^[[:space:]]*//' >&2 || true
        exit 5 ;;
    *) echo "Unexpected HTTP $code from $url" >&2; exit 6 ;;
esac
SH

# run_ctfd_first_setup COMPOSE_ARRAY_NAME — after the containers are up:
# creates the first admin and the event settings if CTFd is not set up
run_ctfd_first_setup() {
    local compose_array="$1"

    wait_for_ctfd_healthy || error_exit "CTFd is not healthy, so its first-run setup cannot be done. See: docker compose logs ctfd"

    local setup_done
    setup_done="$(ctfd_cli "$compose_array" get_config setup || true)"
    if _ctfd_is_true "$setup_done"; then
        log_info "CTFd is already set up"
        _CTFD_ADMIN_PASSWORD=""
        return 0
    fi

    if [[ -z "$_CTFD_ADMIN_PASSWORD" ]]; then
        error_exit "CTFd is not set up yet, and its web setup is disabled. Re-run setup with
  --admin-name, --admin-email and --user-mode (the password is asked for) to create the first admin."
    fi

    local theme="${CONFIG[ACTIVE_THEME]:-core}"
    theme_is_available "$theme" \
        || error_exit "--active-theme $theme: no such theme (available: $(available_themes | xargs))"

    local -a fields=(
        "name=${CONFIG[ADMIN_NAME]}"
        "email=${CONFIG[ADMIN_EMAIL]}"
        "user_mode=${CONFIG[USER_MODE]}"
        "ctf_theme=$theme"
    )
    [[ -n "${CONFIG[CTF_NAME]}" ]]        && fields+=("ctf_name=${CONFIG[CTF_NAME]}")
    [[ -n "${CONFIG[CTF_DESCRIPTION]}" ]] && fields+=("ctf_description=${CONFIG[CTF_DESCRIPTION]}")
    [[ -n "${CONFIG[TEAM_SIZE]}" ]]       && fields+=("team_size=${CONFIG[TEAM_SIZE]}")

    log_info "Setting up CTFd: admin '${CONFIG[ADMIN_NAME]}', ${CONFIG[USER_MODE]} mode, theme '$theme'..."
    local -n _compose="$compose_array"
    if ! printf '%s' "$_CTFD_ADMIN_PASSWORD" \
        | "${_compose[@]}" exec -T ctfd sh -c "$_CTFD_SETUP_REQUEST" sh "${fields[@]}"; then
        _CTFD_ADMIN_PASSWORD=""
        error_exit "CTFd's first-run setup failed (see above)"
    fi
    _CTFD_ADMIN_PASSWORD=""

    setup_done="$(ctfd_cli "$compose_array" get_config setup || true)"
    _ctfd_is_true "$setup_done" || error_exit "CTFd accepted the setup request but is still not set up"
    log_success "CTFd is set up: log in as '${CONFIG[ADMIN_NAME]}' with the password you entered"
}
