#!/usr/bin/env bash
# modules/ctfd/yaml.sh — Challenge YAML parsing.
#
# Strategy order (first success wins):
#   1. Mike Farah's yq  (Go)     — yq eval -o=json FILE
#   2. kislyuk's yq     (Python) — yq '.' FILE  (outputs JSON by default)
#   3. python3 + PyYAML           — yaml.safe_load → json.dumps
#
# Requires: lib/common.sh

[[ -n "${_LIB_CTFD_YAML_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_YAML_LOADED=1

# ── Detect the best available YAML→JSON strategy ────────────────────────────
# Sets _YAML_STRATEGY to one of: mikefarah_yq | kislyuk_yq | python3 | none
# Called once at source time; result is cached.

_detect_yaml_strategy() {
    if command -v yq &>/dev/null; then
        local yq_ver
        yq_ver="$(yq --version 2>&1 || true)"

        # Mike Farah's Go binary: "yq (https://github.com/mikefarah/yq/) version v4.x.x"
        if [[ "$yq_ver" == *mikefarah* ]]; then
            _YAML_STRATEGY="mikefarah_yq"
            return
        fi

        # kislyuk's Python wrapper: "yq X.Y.Z" (wraps jq, outputs JSON natively)
        if [[ "$yq_ver" =~ ^yq\ [0-9] ]]; then
            _YAML_STRATEGY="kislyuk_yq"
            return
        fi

        # Unrecognised yq — we'll try both syntaxes at parse time
        _YAML_STRATEGY="unknown_yq"
        return
    fi

    if command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null; then
        _YAML_STRATEGY="python3"
        return
    fi

    _YAML_STRATEGY="none"
}

_YAML_STRATEGY=""
_detect_yaml_strategy

# Expose the detected strategy so deps.sh can report it accurately.
yaml_strategy() { echo "$_YAML_STRATEGY"; }

# ── Individual parse backends ────────────────────────────────────────────────

_parse_with_mikefarah_yq() {
    yq eval -o=json "$1" 2>/dev/null
}

_parse_with_kislyuk_yq() {
    # kislyuk's yq feeds YAML through jq; '.' passes the whole document.
    yq '.' "$1" 2>/dev/null
}

_parse_with_python3() {
    python3 -c "
import yaml, json, sys
with open(sys.argv[1], 'r') as f:
    data = yaml.safe_load(f)
print(json.dumps(data, ensure_ascii=False))
" "$1" 2>/dev/null
}

# ── Public entry point ───────────────────────────────────────────────────────

parse_challenge_yaml() {
    local yml_file="$1"

    [[ -f "$yml_file" ]] || {
        log_error "Challenge YAML not found: $yml_file"
        return 1
    }

    local output=""

    # Fast path — use the detected strategy directly
    case "$_YAML_STRATEGY" in
        mikefarah_yq)
            output="$(_parse_with_mikefarah_yq "$yml_file")" \
                && { echo "$output"; return 0; }
            log_debug "Mike Farah's yq failed on: $yml_file — trying fallbacks"
            ;;
        kislyuk_yq)
            output="$(_parse_with_kislyuk_yq "$yml_file")" \
                && { echo "$output"; return 0; }
            log_debug "kislyuk's yq failed on: $yml_file — trying fallbacks"
            ;;
        python3)
            output="$(_parse_with_python3 "$yml_file")" \
                && { echo "$output"; return 0; }
            log_error "python3+PyYAML failed to parse: $yml_file"
            return 1
            ;;
        unknown_yq)
            # Try both yq syntaxes
            output="$(_parse_with_mikefarah_yq "$yml_file")" \
                && { echo "$output"; return 0; }
            output="$(_parse_with_kislyuk_yq "$yml_file")" \
                && { echo "$output"; return 0; }
            log_debug "Unknown yq variant failed — trying python3 fallback"
            ;;
        none)
            ;; # fall straight through to python3 attempt below
    esac

    # Fallback: always try python3+PyYAML when the primary strategy failed
    if command -v python3 &>/dev/null && python3 -c "import yaml" &>/dev/null; then
        output="$(_parse_with_python3 "$yml_file")" \
            && { echo "$output"; return 0; }
    fi

    log_error "All YAML parsers failed for: $yml_file. Check file manually"
    return 1
}
