#!/usr/bin/env bash
# Bash completion for challenges.sh and setup.sh
#
# Install once (no per-session sourcing needed after that):
#   ./infra/install-completion.sh
#
# For aliases/symlinks, register manually after installing:
#   complete -F _challenges_sh mychalias
#   complete -F _setup_sh mysetupalias

[[ -n "${_INFRA_COMPLETION_LOADED:-}" ]] && return 0
readonly _INFRA_COMPLETION_LOADED=1

# ── Helpers ──────────────────────────────────────────────────────────────────

# Scan COMP_WORDS for --working-folder; fall back to default.
_get_working_dir() {
    local i
    for (( i = 1; i < ${#COMP_WORDS[@]} - 1; i++ )); do
        if [[ "${COMP_WORDS[$i]}" == "--working-folder" ]]; then
            echo "${COMP_WORDS[$i+1]}"
            return
        fi
    done
    echo "/home/${SUDO_USER:-$USER}"
}

# Print bare directory names under $1, excluding names listed as subsequent args.
_list_dirs() {
    local dir="$1"; shift
    local excludes=("$@")
    [[ -d "$dir" ]] || return
    local entry name skip
    while IFS= read -r entry; do
        name="$(basename "$entry")"
        stop=false
        for excl in "${excludes[@]}"; do
            [[ "$name" == "$excl" ]] && stop=true && break
        done
        "$stop" || printf '%s\n' "$name"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
}

# Resolve a --repo value to an on-disk path (mirrors lib/repo.sh logic).
# Prints the path; prints nothing if unresolvable.
_resolve_repo() {
    local repo="$1" working_dir="$2"
    local galvanize_dir="${working_dir}/deploy/data/galvanize/challenges"
    [[ -z "$repo" ]] && return

    # Absolute path
    [[ "$repo" == /* && -d "$repo" ]] && { echo "$repo"; return; }

    # Bare name: working_dir first, then galvanize
    if [[ "$repo" != */* ]]; then
        [[ -d "${working_dir}/${repo}" ]] && { echo "${working_dir}/${repo}"; return; }
        [[ -d "${galvanize_dir}/${repo}" ]] && { echo "${galvanize_dir}/${repo}"; return; }
    fi

    # Relative path from cwd
    local rel; rel="$(pwd)/${repo}"
    [[ -d "$rel" ]] && { echo "$rel"; return; }
}

# Given a resolved repo path, return the categories root (repo/challenges/ or repo/).
_categories_root() {
    local repo_path="$1"
    [[ -z "$repo_path" ]] && return
    if [[ -d "${repo_path}/challenges" ]]; then
        echo "${repo_path}/challenges"
    else
        echo "$repo_path"
    fi
}

# Complete a comma-separated list where items are directory names.
# Usage: _complete_csv "$cur" dir [exclude...]
_complete_csv() {
    local cur="$1" dir="$2"; shift 2
    local excludes=("$@")
    [[ -z "$dir" ]] && return

    local all_names=()
    mapfile -t all_names < <(_list_dirs "$dir" "${excludes[@]}")

    # Split cur into already-chosen prefix and the fragment being typed
    local prefix="" fragment="$cur"
    if [[ "$cur" == *,* ]]; then
        prefix="${cur%,*},"
        fragment="${cur##*,}"
    fi

    # Exclude already-chosen items from suggestions
    local chosen=(); IFS=',' read -ra chosen <<< "${cur%,*}"
    local available=()
    for name in "${all_names[@]}"; do
        local skip=false
        for c in "${chosen[@]}"; do
            [[ "$name" == "$c" ]] && skip=true && break
        done
        "$skip" || available+=("$name")
    done

    # Prepend the already-committed prefix so bash replaces the whole word
    mapfile -t COMPREPLY < <(compgen -W "${available[*]}" -- "$fragment" \
        | while read -r m; do printf '%s%s\n' "$prefix" "$m"; done)
}

# ── challenges.sh completion ─────────────────────────────────────────────────

_challenges_sh() {
    local cur prev
    if declare -f _init_completion &>/dev/null; then
        _init_completion || return
    else
        cur="${COMP_WORDS[$COMP_CWORD]}"
        prev="${COMP_WORDS[$COMP_CWORD-1]}"
    fi

    local working_dir galvanize_dir
    working_dir="$(_get_working_dir)"
    galvanize_dir="${working_dir}/deploy/data/galvanize/challenges"

    case "$prev" in
        --working-folder)
            if declare -f _filedir &>/dev/null; then
                _filedir -d
            else
                COMPREPLY=( $(compgen -d -- "$cur") )
            fi
            return ;;

        --repo)
            if [[ "$cur" == /* || "$cur" == ./* ]]; then
                # Path-based: standard dir completion
                COMPREPLY=( $(compgen -d -- "$cur") )
            else
                # Bare name: working_dir (excl deploy) + galvanize challenges dir
                local names=()
                mapfile -t names < <(
                    _list_dirs "$working_dir" "deploy"
                    _list_dirs "$galvanize_dir"
                )
                COMPREPLY=( $(compgen -W "${names[*]}" -- "$cur") )
            fi
            return ;;

        --action)
            COMPREPLY=( $(compgen -W "all build ingest sync status cleanup" -- "$cur") )
            return ;;

        --categories)
            # Find --repo in already-typed words
            local repo=""
            local i
            for (( i = 1; i < ${#COMP_WORDS[@]} - 1; i++ )); do
                [[ "${COMP_WORDS[$i]}" == "--repo" ]] && repo="${COMP_WORDS[$i+1]}" && break
            done
            local repo_path cats_root
            repo_path="$(_resolve_repo "$repo" "$working_dir")"
            cats_root="$(_categories_root "$repo_path")"
            _complete_csv "$cur" "$cats_root"
            return ;;

        --challenges)
            # Collect challenge names from all category dirs under the repo
            local repo=""
            local i
            for (( i = 1; i < ${#COMP_WORDS[@]} - 1; i++ )); do
                [[ "${COMP_WORDS[$i]}" == "--repo" ]] && repo="${COMP_WORDS[$i+1]}" && break
            done
            local repo_path cats_root
            repo_path="$(_resolve_repo "$repo" "$working_dir")"
            cats_root="$(_categories_root "$repo_path")"

            if [[ -n "$cats_root" && -d "$cats_root" ]]; then
                # Gather challenge dirs one level beneath each category
                local all_challenges=()
                local cat_dir chall_name
                while IFS= read -r cat_dir; do
                    while IFS= read -r chall_dir; do
                        chall_name="$(basename "$chall_dir")"
                        all_challenges+=("$chall_name")
                    done < <(find "$cat_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
                done < <(find "$cats_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

                local prefix="" fragment="$cur"
                [[ "$cur" == *,* ]] && prefix="${cur%,*}," && fragment="${cur##*,}"
                local chosen=(); IFS=',' read -ra chosen <<< "${cur%,*}"
                local available=()
                for name in "${all_challenges[@]}"; do
                    local skip=false
                    for c in "${chosen[@]}"; do [[ "$name" == "$c" ]] && skip=true && break; done
                    "$skip" || available+=("$name")
                done
                mapfile -t COMPREPLY < <(compgen -W "${available[*]}" -- "$fragment" \
                    | while read -r m; do printf '%s%s\n' "$prefix" "$m"; done)
            fi
            return ;;

        --git-branch)
            if command -v git &>/dev/null; then
                local branches
                branches="$(git branch --all 2>/dev/null \
                    | sed 's|.*/||; s/^[* ]*//' | sort -u)"
                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
            fi
            return ;;

        --config)
            if declare -f _filedir &>/dev/null; then
                _filedir
            else
                COMPREPLY=( $(compgen -f -- "$cur") )
            fi
            return ;;

        --parallel-builds)
            COMPREPLY=( $(compgen -W "1 2 4 8 16" -- "$cur") )
            return ;;
    esac

    local opts="--working-folder --repo --action --categories --challenges
                --git-branch --config --dry-run --force --parallel-builds
                --debug --skip-docker-check --help --version"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

# ── setup.sh completion ───────────────────────────────────────────────────────

_setup_sh() {
    local cur prev
    if declare -f _init_completion &>/dev/null; then
        _init_completion || return
    else
        cur="${COMP_WORDS[$COMP_CWORD]}"
        prev="${COMP_WORDS[$COMP_CWORD-1]}"
    fi

    local working_dir
    working_dir="$(_get_working_dir)"

    case "$prev" in
        --working-folder)
            if declare -f _filedir &>/dev/null; then
                _filedir -d
            else
                COMPREPLY=( $(compgen -d -- "$cur") )
            fi
            return ;;

        --theme)
            if [[ "$cur" == /* || "$cur" == ./* ]]; then
                # Path-based: dir completion filtered to exclude any dir named 'deploy'
                local all_dirs=()
                mapfile -t all_dirs < <(compgen -d -- "$cur")
                COMPREPLY=()
                local d
                for d in "${all_dirs[@]}"; do
                    [[ "$(basename "$d")" != "deploy" ]] && COMPREPLY+=("$d")
                done
            else
                # Bare name: working_dir subdirs, excluding deploy
                local names=()
                mapfile -t names < <(_list_dirs "$working_dir" "deploy")
                COMPREPLY=( $(compgen -W "${names[*]}" -- "$cur") )
            fi
            return ;;

        --backup-schedule)
            COMPREPLY=( $(compgen -W "daily hourly 10min" -- "$cur") )
            return ;;

        --dns-provider)
            COMPREPLY=( $(compgen -W "cloudflare route53 digitalocean hetzner ovh gandiv5 gcloud godaddy namecheap ionos" -- "$cur") )
            return ;;

        --domain|--instancer-url)
            # No meaningful completion
            return ;;
    esac

    local opts="--domain --working-folder --theme --backup-schedule
                --instancer-url --no-instancer --dns-provider --no-https --help"
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
}

# ── Registration ──────────────────────────────────────────────────────────────
# Registers completions for the bare script names (when on PATH) and for the
# absolute paths resolved from this file's location (for direct invocation).

_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

complete -F _challenges_sh challenges.sh
complete -F _setup_sh    setup.sh
complete -F _challenges_sh "${_INFRA_DIR}/challenges.sh"
complete -F _setup_sh    "${_INFRA_DIR}/setup.sh"

unset _INFRA_DIR
