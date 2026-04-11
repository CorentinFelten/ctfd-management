#!/usr/bin/env bash
# lib/repo.sh — CTF repository resolution and cloning.
#
# Requires: lib/common.sh

[[ -n "${_LIB_REPO_LOADED:-}" ]] && return 0
readonly _LIB_REPO_LOADED=1

# ── Public entry point ────────────────────────────────────────────────────────

resolve_ctf_repo_path() {
    local repo="${CONFIG[CTF_REPO]}"
    local working_dir="${CONFIG[WORKING_DIR]}"
    local deploy_dir="${working_dir}/deploy"
    local galvanize_dir="${deploy_dir}/data/galvanize/challenges"

    # ── Case 3: Git URL ──────────────────────────────────────────────────────
    if is_git_url "$repo"; then
        _clone_ctf_repo "$repo" "$working_dir" "$galvanize_dir"
        return
    fi

    # ── Case 1: bare name present in working dir ─────────────────────────────
    if [[ "$repo" != */* && -d "${working_dir}/${repo}" ]]; then
        log_info "Using existing repository in working directory: ${working_dir}/${repo}"
        CONFIG[CTF_REPO_PATH]="${working_dir}/${repo}"
        return
    fi

    # ── Case 2: bare name present in galvanize challenges dir ────────────────
    if [[ "$repo" != */* && -d "${galvanize_dir}/${repo}" ]]; then
        log_info "Using existing repository in galvanize dir: ${galvanize_dir}/${repo}"
        CONFIG[CTF_REPO_PATH]="${galvanize_dir}/${repo}"
        return
    fi

    # ── Case 4: generic path (absolute or relative) ───────────────────────────
    local resolved_path
    if [[ "$repo" == /* ]]; then
        resolved_path="$repo"
    else
        resolved_path="$(pwd)/${repo}"
    fi

    if [[ -d "$resolved_path" ]]; then
        log_info "Using path directly: $resolved_path"
        CONFIG[CTF_REPO_PATH]="$resolved_path"
        return
    fi

    error_exit "Error: Could not resolve --ctf-repo '${repo}'.
  Tried:
    • ${working_dir}/${repo}
    • ${galvanize_dir}/${repo}
    • ${resolved_path}
  Pass a Git URL to clone automatically, or ensure the directory exists."
}

# ── Private helpers ───────────────────────────────────────────────────────────

_clone_ctf_repo() {
    local url="$1" working_dir="$2" galvanize_dir="$3"

    command -v git &>/dev/null \
        || error_exit "git is required to clone a repository but was not found in PATH."

    # Derive destination folder name from URL (strip trailing .git)
    local repo_name
    repo_name="$(basename "$url" .git)"

    # Prefer galvanize layout when the directory is already set up
    local clone_parent
    if [[ -d "$galvanize_dir" ]]; then
        clone_parent="$galvanize_dir"
        log_info "Galvanize challenges directory detected — cloning into: ${galvanize_dir}/${repo_name}"
    else
        clone_parent="$working_dir"
        log_info "Cloning repository into working directory: ${working_dir}/${repo_name}"
    fi

    local dest="${clone_parent}/${repo_name}"

    # Handle an existing clone
    if [[ -d "$dest/.git" ]]; then
        if [[ "${CONFIG[FORCE]}" == "true" ]]; then
            log_info "Force flag set — removing existing clone and re-cloning."
            rm -rf "$dest"
        else
            log_warning "Repository already cloned at '${dest}' — skipping clone (pass --force to re-clone)."
            CONFIG[CTF_REPO_PATH]="$dest"
            return
        fi
    fi

    if [[ "${CONFIG[DRY_RUN]}" == "true" ]]; then
        log_info "DRY-RUN: would clone '${url}' → '${dest}'"
        CONFIG[CTF_REPO_PATH]="$dest"
        return
    fi

    local -a git_args=(git clone)
    [[ -n "${CONFIG[GIT_BRANCH]}" ]] && git_args+=(--branch "${CONFIG[GIT_BRANCH]}")
    git_args+=("$url" "$dest")

    local use_sudo=false
    if [[ "$clone_parent" == "$galvanize_dir" ]] && ! _dir_is_writable "$clone_parent"; then
        if command -v sudo &>/dev/null; then
            use_sudo=true
            log_info "Directory '${clone_parent}' is not writable — running git clone via sudo"
        else
            log_warning "Directory '${clone_parent}' is not writable and sudo is unavailable; attempting clone anyway"
        fi
    fi

    log_info "Running: ${git_args[*]}"
    if [[ "$use_sudo" == "true" ]]; then
        sudo "${git_args[@]}" || error_exit "Failed to clone repository: ${url}"
        # Hand ownership back to the invoking user so subsequent operations
        # (reads, builds, etc.) work without elevation.
        local real_user="${SUDO_USER:-$USER}"
        sudo chown -R "${real_user}:" "$dest" \
            || log_warning "chown of '${dest}' failed — you may need to fix permissions manually"
    else
        "${git_args[@]}" || error_exit "Failed to clone repository: ${url}"
    fi

    log_success "Repository cloned to: ${dest}"
    CONFIG[CTF_REPO_PATH]="$dest"
}

_dir_is_writable() {
    local dir="$1"
    local probe
    probe="$(mktemp -d "${dir}/.write_probe_XXXXXX" 2>/dev/null)" || return 1
    rmdir "$probe" 2>/dev/null
    return 0
}