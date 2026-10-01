#!/usr/bin/env bash
# Checks the custom themes built into the running CTFd image.
#
#   EXPECT_THEMES  space-separated themes that must be installed
#   ABSENT_THEMES  space-separated themes that must not be installed
#   ACTIVE_THEME   expected value of CTFd's ctf_theme setting
#   EXPECT_FILES   space-separated PATH or PATH=CONTENT, relative to the
#                  themes folder, that must exist (with that content)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

themes=/opt/CTFd/CTFd/themes
in_ctfd() { docker exec ctfd "$@"; }

section "Themes"

in_ctfd test -d "$themes/core/templates" || fail "CTFd's built-in core theme is missing"
pass "CTFd's core theme is intact"

for t in ${EXPECT_THEMES:-}; do
    in_ctfd test -d "$themes/$t/templates" || fail "Theme '$t' is not in the CTFd image"
    [[ "$(in_ctfd stat -c %u "$themes/$t")" == 1001 ]] \
        || fail "Theme '$t' is not owned by CTFd's user (1001) in the image"
done
[[ -z "${EXPECT_THEMES:-}" ]] || pass "Installed in the image: ${EXPECT_THEMES}"

for t in ${ABSENT_THEMES:-}; do
    ! in_ctfd test -e "$themes/$t" || fail "Theme '$t' should not be in the CTFd image"
done
[[ -z "${ABSENT_THEMES:-}" ]] || pass "Not in the image: ${ABSENT_THEMES}"

for spec in ${EXPECT_FILES:-}; do
    path="${spec%%=*}"
    in_ctfd test -f "$themes/$path" || fail "Theme file $path is missing"
    if [[ "$spec" == *=* ]]; then
        content="$(in_ctfd cat "$themes/$path")"
        [[ "$content" == "${spec#*=}" ]] || fail "Theme file $path has '$content', expected '${spec#*=}'"
    fi
done
[[ -z "${EXPECT_FILES:-}" ]] || pass "Theme files as expected: ${EXPECT_FILES}"

if [[ -n "${ACTIVE_THEME:-}" ]]; then
    active="$(in_ctfd python manage.py get_config ctf_theme 2>/dev/null | tail -n1)"
    [[ "$active" == "$ACTIVE_THEME" ]] || fail "CTFd's active theme is '$active', expected '$ACTIVE_THEME'"
    pass "CTFd's active theme is '$ACTIVE_THEME'"
fi
