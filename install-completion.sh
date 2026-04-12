#!/usr/bin/env bash
# One-time install for challenges.sh / setup.sh bash completion.
# After running this, tab completion works automatically in every new shell
# — no sourcing required.
#
# Safe to re-run (idempotent).

set -euo pipefail

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

_say() { "$QUIET" || echo "$@"; }

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPLETION_FILE="${INFRA_DIR}/completion.bash"
LAZY_DIR="${HOME}/.local/share/bash-completion/completions"
BASH_COMPLETION_FILE="${HOME}/.bash_completion"

# ── Lazy-load dir: covers invocation by bare name (when on PATH) ──────────────

mkdir -p "$LAZY_DIR"

for name in challenges.sh setup.sh; do
    target="${LAZY_DIR}/${name}"
    if [[ -L "$target" && "$(readlink "$target")" == "$COMPLETION_FILE" ]]; then
        _say "  [ok] ${target} already points to completion.bash"
    else
        ln -sf "$COMPLETION_FILE" "$target"
        _say "  [+]  ${target} -> completion.bash"
    fi
done

# ── ~/.bash_completion: covers full/relative path invocations ─────────────────
# bash-completion sources this file unconditionally on shell start.

SOURCE_LINE="source \"${COMPLETION_FILE}\"  # ctf-infra"

if [[ -f "$BASH_COMPLETION_FILE" ]] && grep -qF "# ctf-infra" "$BASH_COMPLETION_FILE"; then
    # Update the line in case the infra dir moved
    sed -i "s|.*# ctf-infra|${SOURCE_LINE}|" "$BASH_COMPLETION_FILE"
    _say "  [ok] ~/.bash_completion entry updated"
else
    echo "" >> "$BASH_COMPLETION_FILE"
    echo "$SOURCE_LINE" >> "$BASH_COMPLETION_FILE"
    _say "  [+]  ~/.bash_completion entry added"
fi

"$QUIET" || { echo ""; echo "Done. Open a new shell (or run: source ~/.bash_completion) to activate."; }
