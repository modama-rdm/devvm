#!/bin/bash
# Manage a libvirt/KVM development VM for working on deploy/ with Docker.
# Settings: defaults.env < site.env < environment. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Under sudo only libvirt needs root; files, downloads and SSH belong to the invoking user
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    as_user() { sudo -u "$SUDO_USER" -- "$@"; }
else
    USER_HOME=$HOME
    as_user() { "$@"; }
fi

# Exported variables are overrides from the environment; re-apply them after sourcing
saved_env=$(export -p)
# shellcheck source=defaults.env
source "$HERE/defaults.env"
if [ -f "$HERE/site.env" ]; then
    source "$HERE/site.env"
else
    echo "Missing $HERE/site.env, copy site.env.example and adapt it" >&2
    exit 1
fi
eval "$saved_env"

# virt-install needs the system python (python3-gi); e.g. conda envs on PATH break it
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LIBVIRT_DEFAULT_URI=$LIBVIRT_URI

DISK=$POOL_DIR/$VM_NAME.qcow2
BASE_DIR=$POOL_DIR/base
KNOWN_HOSTS=$POOL_DIR/known_hosts

usage() {
    cat <<EOF
Usage: $(basename "$0") COMMAND [ARGS]

  create            download base image, create and start the VM
  wait              wait until cloud-init has finished and Docker works
  ssh [CMD...]      log in to the VM or run a command there
  ip                print the VM's IP address
  status            show VM state and snapshots
  start | stop      boot or shut down the VM
  snapshot [NAME]   create a snapshot (default: clean)
  reset [NAME]      revert to a snapshot (default: clean)
  destroy [-y]      remove the VM, its disk and snapshots (keeps the base image)
EOF
}

vm_ip() {
    virsh domifaddr "$VM_NAME" --source lease 2>/dev/null |
        awk '/ipv4/ {sub("/.*", "", $4); print $4; exit}'
}

require_ip() {
    local ip
    for _ in $(seq 60); do
        ip=$(vm_ip)
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
        if [ "$(virsh domstate "$VM_NAME" 2>/dev/null)" = "shut off" ]; then
            echo "$VM_NAME is shut off, see /var/log/libvirt/qemu/$VM_NAME.log" >&2
            exit 1
        fi
        sleep 3
    done
    echo "No IP address for $VM_NAME" >&2
    exit 1
}

vm_ssh() {
    local ip
    ip=$(require_ip)
    as_user ssh -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        "$VM_USER@$ip" "$@"
}

render() {
    local pubkey
    pubkey=$(cat "$SSH_PUBKEY_FILE")
    sed -e "s|@VM_NAME@|$VM_NAME|g" -e "s|@VM_USER@|$VM_USER|g" \
        -e "s|@SSH_PUBKEY@|$pubkey|g" "$1"
}

cmd_create() {
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "VM $VM_NAME already exists" >&2
        exit 1
    fi
    [ -r "$SSH_PUBKEY_FILE" ] || { echo "Cannot read $SSH_PUBKEY_FILE" >&2; exit 1; }
    as_user mkdir -p "$BASE_DIR"

    if [ ! -f "$BASE_DIR/$IMAGE_FILE" ]; then
        as_user curl -fL -o "$BASE_DIR/$IMAGE_FILE.part" "$IMAGE_URL/$IMAGE_FILE"
        as_user curl -fL -o "$BASE_DIR/SHA512SUMS" "$IMAGE_URL/SHA512SUMS"
        (cd "$BASE_DIR" &&
            grep " $IMAGE_FILE\$" SHA512SUMS | sed "s|$IMAGE_FILE\$|$IMAGE_FILE.part|" |
            sha512sum -c -)
        as_user mv "$BASE_DIR/$IMAGE_FILE.part" "$BASE_DIR/$IMAGE_FILE"
    fi

    # Copy-on-write overlay, the base image stays untouched
    rm -f "$DISK"
    as_user qemu-img create -f qcow2 -F qcow2 -b "$BASE_DIR/$IMAGE_FILE" "$DISK" "${DISK_GB}G"

    local ci_dir
    ci_dir=$(mktemp -d)
    trap 'rm -rf "$ci_dir"' RETURN
    render "$HERE/cloud-init/user-data.tmpl" > "$ci_dir/user-data"
    render "$HERE/cloud-init/meta-data.tmpl" > "$ci_dir/meta-data"

    virsh net-start "$NETWORK" &>/dev/null || true
    virt-install --name "$VM_NAME" --vcpus "$VCPUS" --memory "$RAM_MB" \
        --cpu host-passthrough --osinfo "$OS_VARIANT" \
        --disk path="$DISK",bus=virtio \
        --network network="$NETWORK",model=virtio \
        --cloud-init user-data="$ci_dir/user-data",meta-data="$ci_dir/meta-data",disable=on \
        --graphics none --noautoconsole --import \
        --video virtio  # without any display device the Debian kernel resets right after GRUB

    rm -f "$KNOWN_HOSTS"
    local ip
    ip=$(require_ip)
    echo "$VM_NAME is at $ip. Next: $0 wait && $0 snapshot"
}

cmd_wait() {
    for _ in $(seq 100); do
        vm_ssh -o ConnectTimeout=5 -o BatchMode=yes true 2>/dev/null && break
        sleep 3
    done
    vm_ssh 'cloud-init status --wait && docker version --format "Docker {{.Server.Version}}" && docker compose version'
}

cmd_destroy() {
    if [ "${1:-}" != "-y" ]; then
        read -rp "Remove VM $VM_NAME with disk $DISK and all snapshots? [y/N] " answer
        [ "$answer" = y ] || exit 1
    fi
    virsh destroy "$VM_NAME" &>/dev/null || true
    virsh undefine "$VM_NAME" --snapshots-metadata --remove-all-storage
    rm -f "$KNOWN_HOSTS"
}

case "${1:-}" in
    create) cmd_create ;;
    wait) cmd_wait ;;
    ssh) shift; vm_ssh "$@" ;;
    ip) require_ip ;;
    status) virsh dominfo "$VM_NAME"; virsh snapshot-list "$VM_NAME" ;;
    start) virsh start "$VM_NAME" ;;
    stop) virsh shutdown "$VM_NAME" ;;
    snapshot) virsh snapshot-create-as "$VM_NAME" "${2:-clean}" --atomic ;;
    reset) virsh snapshot-revert "$VM_NAME" "${2:-clean}" --running ;;
    destroy) shift; cmd_destroy "$@" ;;
    *) usage; exit 1 ;;
esac
