#!/usr/bin/env bash
# modules/setup/theme.sh — Install, remove and activate custom CTFd themes.
# Requires: lib/common.sh
#
# Themes are baked into the CTFd image: they live in <deploy>/ctfd/themes/
# <name>/, inside the image's build context, and Dockerfile.ctfd copies that
# folder over /opt/CTFd/CTFd/themes/, next to CTFd's own themes. Installed
# themes therefore persist across setup runs (every run rebuilds the image)
# until they are removed with --remove-theme.

[[ -n "${_SETUP_THEME_LOADED:-}" ]] && return 0
readonly _SETUP_THEME_LOADED=1

# Themes shipped in the CTFd image, which a custom theme must not replace
readonly CTFD_BUILTIN_THEMES=(admin core core-deprecated)

# Filled by setup.sh's argument parsing (--theme / --remove-theme)
THEME_SOURCES=()
THEMES_TO_REMOVE=()

themes_dir() { printf '%s' "${CONFIG[DEPLOY_DIR]}/ctfd/themes"; }

# theme_source_parts SOURCE — prints "<location>\t<ref>\t<name>".
#   SOURCE is a local folder or a Git URL, optionally followed by #REF (a
#   branch or tag to clone). The theme name is the last path component,
#   without a trailing slash or .git.
theme_source_parts() {
    local source="$1" location ref="" name
    location="${source%%#*}"
    [[ "$source" == *#* ]] && ref="${source#*#}"
    location="${location%/}"
    name="${location##*/}"
    name="${name%.git}"
    printf '%s\t%s\t%s' "$location" "$ref" "$name"
}

# validate_theme_name NAME — exits on a name CTFd cannot use as a theme
# folder, or one that would replace a built-in theme.
validate_theme_name() {
    local name="$1" builtin
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || error_exit "Invalid theme name '$name': use letters, digits, '.', '_' and '-'"
    for builtin in "${CTFD_BUILTIN_THEMES[@]}"; do
        [[ "$name" != "$builtin" ]] \
            || error_exit "A theme cannot be named '$name': that would replace CTFd's built-in theme"
    done
}

# install_theme SOURCE — copies or clones SOURCE into the themes folder,
# replacing any previous version of the same theme. The new version is
# prepared next to it and swapped in only once complete and valid.
install_theme() {
    local source="$1" location ref name
    IFS=$'\t' read -r location ref name < <(theme_source_parts "$source")
    validate_theme_name "$name"

    local dir staging
    dir="$(themes_dir)"
    mkdir -p "$dir"
    staging="$(mktemp -d "$dir/.${name}.XXXXXX")"
    _cleanup_files+=("$staging")

    if is_git_url "$location"; then
        log_info "Cloning theme '$name' from $location${ref:+ ($ref)}..."
        local -a clone=(git clone --quiet --depth 1)
        [[ -n "$ref" ]] && clone+=(--branch "$ref")
        "${clone[@]}" "$location" "$staging/theme" \
            || error_exit "Failed to clone theme '$name' from $location${ref:+ at $ref}"
        rm -rf "$staging/theme/.git"
    else
        [[ -z "$ref" ]] || error_exit "Theme '$source': #REF is only supported for Git URLs"
        local path="$location"
        if [[ ! -d "$path" && "$path" != /* && -d "${CONFIG[WORKING_DIR]}/$path" ]]; then
            path="${CONFIG[WORKING_DIR]}/$path"
        fi
        [[ -d "$path" ]] || error_exit "Theme folder not found: $location"
        log_info "Copying theme '$name' from $path..."
        mkdir "$staging/theme"
        # "/." copies hidden files too
        cp -a "$path/." "$staging/theme/" || error_exit "Failed to copy theme '$name' from $path"
    fi

    [[ -d "$staging/theme/templates" ]] \
        || error_exit "'$source' is not a CTFd theme: it has no templates/ folder"

    rm -rf "${dir:?}/$name"
    mv "$staging/theme" "$dir/$name"
    rm -rf "$staging"
    log_success "Theme '$name' installed"
}

# remove_theme NAME
remove_theme() {
    local name="$1" dir
    validate_theme_name "$name"
    dir="$(themes_dir)"
    if [[ -d "$dir/$name" ]]; then
        rm -rf "${dir:?}/$name"
        log_success "Theme '$name' removed"
    else
        log_warning "Theme '$name' is not installed, nothing to remove"
    fi
}

# installed_themes — names of the custom themes, one per line
installed_themes() {
    local dir d
    dir="$(themes_dir)"
    [[ -d "$dir" ]] || return 0
    for d in "$dir"/*/; do
        [[ -d "$d" ]] && basename "$d"
    done
    return 0
}

# Deployments made before themes were baked into the image mounted a single
# theme from data/CTFd/themes/<THEME_NAME>. Carry it over once.
_migrate_mounted_theme() {
    local name old
    name="$(grep '^THEME_NAME=' "${CONFIG[DEPLOY_DIR]}/.env" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    [[ -n "$name" ]] || return 0
    old="${CONFIG[DEPLOY_DIR]}/data/CTFd/themes/$name"
    if [[ -d "$old" && ! -e "$(themes_dir)/$name" ]]; then
        mkdir -p "$(themes_dir)"
        cp -a "$old" "$(themes_dir)/$name"
        log_info "Moved theme '$name' from the old bind mount ($old) into the CTFd image"
    fi
}

# setup_themes — applies --theme and --remove-theme to the themes folder.
# Must run before the CTFd image is built.
setup_themes() {
    _migrate_mounted_theme

    local source name
    for name in "${THEMES_TO_REMOVE[@]}"; do
        remove_theme "$name"
    done
    for source in "${THEME_SOURCES[@]}"; do
        install_theme "$source"
    done

    # Like the rest of the deploy dir (the image gets its own ownership)
    if [[ -d "$(themes_dir)" ]]; then
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$(themes_dir)"
    fi

    local -a themes
    mapfile -t themes < <(installed_themes)
    if (( ${#themes[@]} > 0 )); then
        log_info "Custom themes in the CTFd image: ${themes[*]}"
    fi
}

# _ctfd_cli COMPOSE_ARRAY_NAME ARGS... — runs CTFd's CLI (manage.py) in the
# running ctfd container and prints the last output line (CTFd logs plugin
# loading on stdout before the command's own output).
_ctfd_cli() {
    local -n _compose="$1"; shift
    "${_compose[@]}" exec -T ctfd python manage.py "$@" 2>/dev/null | tail -n1
}

# apply_active_theme COMPOSE_ARRAY_NAME — after the containers are up, sets
# CTFd's active theme (--active-theme), and warns when the active theme is
# no longer installed.
apply_active_theme() {
    local compose_array="$1"
    local wanted="${CONFIG[ACTIVE_THEME]:-}"

    if [[ -n "$wanted" ]]; then
        # admin is CTFd's admin panel theme, not a site theme
        local known=false t
        for t in core core-deprecated $(installed_themes); do
            [[ "$t" == "$wanted" ]] && known=true
        done
        [[ "$known" == true ]] \
            || error_exit "--active-theme $wanted: no such theme (available: core core-deprecated $(installed_themes | xargs))"
    fi

    # CTFd's CLI needs the app (and its database migrations) up
    log_info "Waiting for CTFd to be healthy..."
    local deadline=$((SECONDS + 300)) status=""
    while ((SECONDS < deadline)); do
        status="$(docker inspect -f '{{.State.Health.Status}}' ctfd 2>/dev/null || true)"
        [[ "$status" == healthy ]] && break
        sleep 5
    done
    if [[ "$status" != healthy ]]; then
        log_warning "CTFd is not healthy (status: ${status:-unknown}); not checking the active theme"
        [[ -z "$wanted" ]] || log_warning "Set the theme manually: Admin Panel → Config → Themes → $wanted"
        return 0
    fi

    local current setup_done
    current="$(_ctfd_cli "$compose_array" get_config ctf_theme || true)"
    setup_done="$(_ctfd_cli "$compose_array" get_config setup || true)"

    if [[ -n "$wanted" && "$current" != "$wanted" ]]; then
        _ctfd_cli "$compose_array" set_config ctf_theme "$wanted" >/dev/null \
            || error_exit "Failed to set CTFd's active theme to '$wanted'"
        current="$wanted"
        log_success "CTFd's active theme set to '$wanted'"
    elif [[ -n "$wanted" ]]; then
        log_info "CTFd's active theme is already '$wanted'"
    fi

    # The first-run setup wizard saves its own Theme choice (default: core)
    if [[ -n "$wanted" && ! "${setup_done,,}" =~ ^(true|1)$ ]]; then
        log_warning "CTFd's setup wizard has not been completed yet: it will ask for a theme and"
        log_warning "save that choice, so pick '$wanted' in its Theme field."
    fi

    # Theme removed while active: CTFd falls back to core for missing pages
    if [[ -n "$current" && "$current" != "None" ]]; then
        local t found=false
        for t in "${CTFD_BUILTIN_THEMES[@]}" $(installed_themes); do
            [[ "$t" == "$current" ]] && found=true
        done
        [[ "$found" == true ]] \
            || log_warning "CTFd's active theme '$current' is not installed; CTFd falls back to 'core'. Use --active-theme to pick another."
    fi
}
