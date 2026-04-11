#!/bin/sh
# Custom entrypoint wrapper for CTFd
# Installs plugin requirements before delegating to the upstream entrypoint.
# Uses a marker file so pip install only runs once per container lifecycle,
# not on every restart.

set -e

# Verify the upload directory is writable before attempting to start CTFd.
# If it is root-owned (Docker created it without the setup script having run),
# file uploads will 500 at runtime — better to fail loud here.
if [ ! -w "/var/uploads" ]; then
    echo "[custom-entrypoint] ERROR: /var/uploads is not writable by UID $(id -u)." >&2
    echo "[custom-entrypoint] Run the setup script to create it with correct ownership (chown -R 1001:1001)." >&2
    exit 1
fi

MARKER="/tmp/.plugins_installed"

if [ ! -f "$MARKER" ]; then
    echo "[custom-entrypoint] Installing plugin requirements..."
    for d in CTFd/plugins/*/; do
        if [ -f "${d}requirements.txt" ]; then
            echo "[custom-entrypoint]   -> ${d}requirements.txt"
            pip install --no-cache-dir -r "${d}requirements.txt" || {
                echo "[custom-entrypoint] WARNING: Failed to install requirements for ${d}" >&2
            }
        fi
    done
    touch "$MARKER"
    echo "[custom-entrypoint] Plugin requirements installed."
else
    echo "[custom-entrypoint] Plugin requirements already installed, skipping."
fi

exec /opt/CTFd/docker-entrypoint.sh "$@"