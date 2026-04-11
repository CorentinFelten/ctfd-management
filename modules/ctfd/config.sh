#!/usr/bin/env bash
# modules/ctfd/config.sh — CTFd INI-style configuration management.
# Requires: lib/common.sh

[[ -n "${_LIB_CTFD_CONFIG_LOADED:-}" ]] && return 0
readonly _LIB_CTFD_CONFIG_LOADED=1

readonly CTFD_CONFIG_DIR=".ctfd"
readonly CTFD_CONFIG_FILE="${CTFD_CONFIG_DIR}/config"

# ── Query helpers ────────────────────────────────────────────────────────────

ctfd_config_exists() {
    [[ -f "${CONFIG[WORKING_DIR]}/${CTFD_CONFIG_FILE}" ]]
}

ctfd_get_config() {
    local key="$1"
    local config_file="${CONFIG[WORKING_DIR]}/${CTFD_CONFIG_FILE}"

    [[ -f "$config_file" ]] || return 1

    # Split on the first '=' manually so that:
    #   1. key is trimmed (no trailing space from "key = value")
    #   2. values containing '=' are preserved intact
    awk -v key="$key" '
        /^\[config\]/ { in_section=1; next }
        /^\[/         { in_section=0 }
        in_section {
            eq = index($0, "=")
            if (eq == 0) next
            k = substr($0, 1, eq - 1)
            v = substr($0, eq + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$config_file"
}

# ── Write helpers ────────────────────────────────────────────────────────────

ctfd_set_config() {
    local section="$1" key="$2" value="$3"
    local config_file="${CONFIG[WORKING_DIR]}/${CTFD_CONFIG_FILE}"

    local temp_file
    temp_file="$(mktemp)"
    _cleanup_files+=("$temp_file")

    if grep -q "^\[$section\]" "$config_file" 2>/dev/null; then
        awk -v section="[$section]" -v key="$key" -v value="$value" '
            BEGIN { updated=0 }
            $0 == section { in_section=1; print; next }
            /^\[/ {
                if (in_section && !updated) {
                    print key " = " value
                    updated=1
                }
                in_section=0
            }
            in_section {
                eq = index($0, "=")
                if (eq > 0) {
                    k = substr($0, 1, eq - 1)
                    gsub(/^[ \t]+|[ \t]+$/, "", k)
                    if (k == key) {
                        print key " = " value
                        updated=1
                        next
                    }
                }
            }
            { print }
            END {
                if (in_section && !updated) {
                    print key " = " value
                }
            }
        ' "$config_file" > "$temp_file"
    else
        {
            cat "$config_file" 2>/dev/null || true
            echo ""
            echo "[$section]"
            echo "$key = $value"
        } > "$temp_file"
    fi

    mv "$temp_file" "$config_file"
}

ctfd_init_config() {
    local url="$1" token="$2"
    local config_dir="${CONFIG[WORKING_DIR]}/${CTFD_CONFIG_DIR}"
    local config_file="${CONFIG[WORKING_DIR]}/${CTFD_CONFIG_FILE}"

    mkdir -p "$config_dir"

    cat > "$config_file" << EOF
[config]
url = $url
access_token = $token

[challenges]
EOF

    log_success "CTFd configuration saved to $config_file"
}
