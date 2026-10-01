#!/usr/bin/env bash
# Boots a fresh Debian virtual machine on the runner with Incus (KVM), set
# up like a freshly installed server: a sudo user "ci", sshd, and a copy of
# the repository in /home/ci/repo. The e2e variables (VM_NAME, SERVER_IP,
# DOMAIN, DEPLOY_DIR, SETUP_ARGS) are exported to later steps through
# GITHUB_ENV; run commands in the VM with vm-run.sh.
#
# Usage: vm-start.sh IMAGE   (e.g. debian/13)

set -euo pipefail

image="${1:?Usage: $0 IMAGE}"
vm="${VM_NAME:-server}"
repo="${GITHUB_WORKSPACE:-$(pwd)}"

log() { echo "== $*"; }
fail() { echo "::error::$*" >&2; exit 1; }

# wait_for DESCRIPTION TIMEOUT_SECONDS COMMAND... — retry COMMAND every 3s
wait_for() {
    local what="$1" timeout="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || fail "Timed out after ${timeout}s waiting for: $what"
        sleep 3
    done
}

[[ -e /dev/kvm ]] || fail "/dev/kvm is missing: this runner cannot run virtual machines"

log "Installing Incus"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq incus >/dev/null
sudo incus admin init --minimal
# Docker on the runner sets the FORWARD policy to DROP, which also drops the
# VM's traffic through the Incus bridge (no internet in the VM otherwise)
sudo iptables -P FORWARD ACCEPT

log "Booting images:${image} as a VM"
sudo incus launch "images:${image}" "$vm" --vm \
    -c limits.cpu=4 -c limits.memory=12GiB -d root,size=30GiB

vm_exec() { sudo incus exec "$vm" -- "$@"; }
wait_for "the VM agent" 180 vm_exec true
wait_for "the VM network" 120 vm_exec getent hosts deb.debian.org

vm_ip="$(sudo incus list "$vm" -c 4 -f csv | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
[[ -n "$vm_ip" ]] || fail "Could not determine the VM's IPv4 address"
log "VM ${vm} is up at ${vm_ip}: $(vm_exec sh -c '. /etc/os-release && echo "$PRETTY_NAME"')"

# What a fresh server has before setup.sh: a sudo user and sshd (Galvanize
# deploys challenges with Ansible over SSH to the --domain address)
log "Preparing the VM as a server"
vm_exec bash -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq sudo openssh-server ca-certificates curl >/dev/null
    useradd -m -s /bin/bash ci
    echo "ci ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ci
    chmod 440 /etc/sudoers.d/ci
    systemctl enable --now ssh
'

log "Copying the repository to /home/ci/repo"
tar -C "$repo" -czf - . | vm_exec bash -euc '
    mkdir -p /home/ci/repo
    tar -C /home/ci/repo -xzf -
    chown -R ci:ci /home/ci/repo
'

{
    echo "VM_NAME=$vm"
    echo "SERVER_IP=$vm_ip"
    echo "DOMAIN=$vm_ip"
    echo "DEPLOY_DIR=/home/ci/deploy"
    echo "SETUP_ARGS=--domain $vm_ip --working-folder /home/ci --yes"
} >> "${GITHUB_ENV:-/dev/null}"
