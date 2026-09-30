#!/bin/sh
# Custom entrypoint wrapper for CTFd
# Installs plugin requirements before delegating to the upstream entrypoint,
# only when they changed since the last successful install.

set -eu

# Verify the upload directory is writable before attempting to start CTFd.
# If it is root-owned (Docker created it without the setup script having run),
# file uploads will 500 at runtime — better to fail loud here.
if [ ! -w "/var/uploads" ]; then
    echo "[custom-entrypoint] ERROR: /var/uploads is not writable by UID $(id -u)." >&2
    echo "[custom-entrypoint] Run the setup script to create it with correct ownership (chown -R 1001:1001)." >&2
    exit 1
fi

# The marker stores a hash of every plugin's requirements.txt, so requirements
# are reinstalled whenever they change (e.g. after setup.sh updates a plugin
# and restarts the container), and skipped on plain restarts otherwise.
MARKER="/tmp/.plugin_requirements.sha256"
CURRENT="$(cat CTFd/plugins/*/requirements.txt 2>/dev/null | sha256sum | cut -d' ' -f1)"

if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER")" != "$CURRENT" ]; then
    echo "[custom-entrypoint] Installing plugin requirements..."
    FAILED=0
    for d in CTFd/plugins/*/; do
        if [ -f "${d}requirements.txt" ]; then
            echo "[custom-entrypoint]   -> ${d}requirements.txt"
            pip install --no-cache-dir -r "${d}requirements.txt" || {
                echo "[custom-entrypoint] WARNING: Failed to install requirements for ${d}" >&2
                FAILED=1
            }
        fi
    done
    # Only remember success, so a failed install is retried on the next start
    if [ "$FAILED" -eq 0 ]; then
        echo "$CURRENT" > "$MARKER"
        echo "[custom-entrypoint] Plugin requirements installed."
    fi
else
    echo "[custom-entrypoint] Plugin requirements unchanged, skipping."
fi

exec /opt/CTFd/docker-entrypoint.sh "$@"