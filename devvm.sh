#!/bin/bash
# Manage a libvirt/KVM development VM for working on deploy/ with Docker.
# Settings: defaults.env < ~/.config/modama-devvm/site.env < environment;
# VM_NAME defaults to the branch of this checkout. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Under sudo only libvirt needs root; files, downloads and SSH belong to the invoking user
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    USER_NAME=$SUDO_USER
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    as_user() { sudo -u "$SUDO_USER" -- "$@"; }
else
    USER_NAME=$(id -un)
    USER_HOME=$HOME
    as_user() { "$@"; }
fi

# Members of the libvirt group may manage qemu:///system without root
# Without sudo: the groups of this process (a fresh usermod needs a new login);
# under sudo: the invoking user's groups
in_libvirt_group() {
    if [ -n "${SUDO_USER:-}" ]; then id -nG "$USER_NAME"; else id -nG; fi | tr ' ' '\n' | grep -qx libvirt
}
libvirt_group_hint() {
    # Already added, but this login predates it
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx libvirt; then
        echo "$USER_NAME is in the libvirt group, but this session is not yet. Log in again" >&2
        echo "(or start a shell with: newgrp libvirt) to run $(basename "$0") without sudo." >&2
        return
    fi
    echo "Add $USER_NAME to the libvirt group to run $(basename "$0") without sudo:" >&2
    echo "    sudo usermod -aG libvirt $USER_NAME" >&2
    echo "then log in again (or start a shell with: newgrp libvirt)." >&2
}

# Site-specific settings of the invoking user, created by `setup`
SITE_ENV=$USER_HOME/.config/modama-devvm/site.env

cmd_setup() {
    local pool pubkey default_key answer f
    if [ -f "$SITE_ENV" ]; then
        read -rp "$SITE_ENV exists, overwrite? [y/N] " answer
        [ "$answer" = y ] || exit 1
    fi
    echo "Directory for base images, VM disks and SSH host keys. Needs ~100 GB per VM"
    echo "and must be traversable (x) by the libvirt-qemu user."
    read -rp "POOL_DIR [/var/lib/libvirt/images/modama-devvm]: " pool
    pool=${pool:-/var/lib/libvirt/images/modama-devvm}
    default_key=
    for f in "$USER_HOME"/.ssh/id_*.pub; do
        [ -e "$f" ] && { default_key=$f; break; }
    done
    read -rp "Public key that may log in to the VMs [${default_key:-none found}]: " pubkey
    pubkey=${pubkey:-$default_key}
    as_user test -r "$pubkey" || { echo "Cannot read $pubkey" >&2; exit 1; }
    case "$pool$pubkey" in *[[:space:]]*) echo "Paths must not contain whitespace" >&2; exit 1 ;; esac
    if ! as_user mkdir -p "$pool" 2>/dev/null; then
        echo "Cannot create $pool as $USER_NAME. Create it writable for that user, e.g." >&2
        echo "    sudo install -d -o $USER_NAME $pool" >&2
        exit 1
    fi
    chmod o+x "$pool" 2>/dev/null || true   # libvirt-qemu must be able to traverse it
    as_user mkdir -p "$(dirname "$SITE_ENV")"
    as_user tee "$SITE_ENV" > /dev/null <<EOF
# Site-specific settings for devvm.sh, written by \`devvm.sh setup\` on $(date -I).
# Generic defaults are in devvm/defaults.env; any variable can be overridden per
# command in the environment, e.g. RAM_MB=32768 ./devvm.sh create

# Directory for base images, VM disks and SSH host keys (~100 GB per VM, must be
# traversable by the libvirt-qemu user)
POOL_DIR=$pool

# Public key that is authorized to log in to the VMs
SSH_PUBKEY_FILE=$pubkey
EOF
    echo "Wrote $SITE_ENV"
    if in_libvirt_group; then
        echo "$USER_NAME is in the libvirt group, no sudo needed"
    else
        libvirt_group_hint
    fi
}

# Global option: -n VM addresses a VM other than this checkout's own
OPT_VM_NAME=
while [ $# -gt 0 ]; do
    case $1 in
        -n|--vm) OPT_VM_NAME=${2:?-n needs a VM}; shift 2 ;;
        -n*) OPT_VM_NAME=${1#-n}; shift ;;
        *) break ;;
    esac
done

if [ "${1:-}" = setup ]; then
    cmd_setup
    exit 0
fi

NO_COMMAND=
if [ $# -eq 0 ]; then
    NO_COMMAND=1   # only the usage text follows, which needs no libvirt or site config
elif [ "$(id -u)" != 0 ] && ! in_libvirt_group; then
    libvirt_group_hint
    exit 1
fi

# Exported variables are overrides from the environment; re-apply them after sourcing
saved_env=$(export -p)
# shellcheck source=defaults.env
source "$HERE/defaults.env"
if [ -f "$SITE_ENV" ]; then
    # shellcheck source=/dev/null
    source "$SITE_ENV"
elif [ -n "$NO_COMMAND" ]; then
    POOL_DIR=/unconfigured SSH_PUBKEY_FILE=/unconfigured
else
    echo "Missing $SITE_ENV, run: $0 setup" >&2
    exit 1
fi
eval "$saved_env"
[ -n "$OPT_VM_NAME" ] && VM_NAME=$OPT_VM_NAME

# One VM per checkout: the name defaults to the branch this script runs from, so
# every worktree gets its own VM with its own disk, snapshots and host refs
if [ -z "${VM_NAME:-}" ]; then
    branch=$(as_user git -C "$HERE" rev-parse --abbrev-ref HEAD)
    if [ "$branch" = HEAD ]; then
        # Detached: no name of its own, and "modama-HEAD" would be shared by every
        # detached checkout. Only the usage text and ls work without a VM.
        case "${1:-}" in
            ""|ls) VM_NAME= ;;
            *) echo "Detached HEAD, no default VM: pass -n VM (see: $(basename "$0") ls)" >&2; exit 1 ;;
        esac
    else
        VM_NAME=$VM_PREFIX$(tr -c 'A-Za-z0-9\n' '-' <<< "$branch")
    fi
fi
# The name is a libvirt domain, a file name stem, a hostname and an ssh alias
[ -z "$VM_NAME" ] || [[ $VM_NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "Invalid VM name: $VM_NAME" >&2; exit 1; }
case "$POOL_DIR" in *[[:space:]]*|"") echo "POOL_DIR must be an absolute path without whitespace" >&2; exit 1 ;; esac

# virt-install needs the system python (python3-gi); e.g. conda envs on PATH break it
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LIBVIRT_DEFAULT_URI=$LIBVIRT_URI

IMAGE_URL=$IMAGE_BASE_URL/$IMAGE_RELEASE
IMAGE_FILE=debian-13-$IMAGE_VARIANT-amd64-$IMAGE_RELEASE.qcow2
DISK=$POOL_DIR/$VM_NAME.qcow2
BASE_DIR=$POOL_DIR/base
# The VM's SSH host key is generated here once and installed by cloud-init, so the
# VM's identity is known before the first connection and survives re-creation
HOSTKEY=$POOL_DIR/$VM_NAME.hostkey
KNOWN_HOSTS=$POOL_DIR/$VM_NAME.known_hosts
SSH_OPTS="-o UserKnownHostsFile=$KNOWN_HOSTS -o HostKeyAlias=$VM_NAME -o StrictHostKeyChecking=yes"
REPO_ROOT=$(as_user git -C "$HERE" rev-parse --show-toplevel)

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n VM] COMMAND [ARGS]

All commands act on the VM of this checkout, ${VM_NAME:-none on a detached HEAD}, unless -n VM (long form
--vm VM, or VM_NAME=VM in the environment) selects another one.

  setup             write the site settings to ~/.config/modama-devvm/site.env
  ls [-a]           list the VMs of this project, with -a all VMs on this host;
                    * marks the one of this checkout
  create            download base image, create and start the VM
  wait              wait until cloud-init has finished and Docker works
  ssh [CMD...]      log in to the VM or run a command there
  ip                print the VM's IP address
  status            show VM state and snapshots
  start | stop      boot or shut down the VM
  snapshot [SNAP]   create snapshot SNAP of the VM (default: clean)
  reset [SNAP]      revert the VM to snapshot SNAP (default: clean)
  destroy [-y]      remove the VM, its disk and snapshots (keeps base image and host key)
  prune             delete base images that no VM disk and no current setting uses

  push [REF]        push REF (default: the branch checked out here) from the host
                    repository to the VM's checkout ~/$VM_REPO; origin/BRANCH
                    becomes branch BRANCH in the VM
  fetch             fetch the VM's branches into the host as $VM_NAME/*
  setup-dev         copy the host's git identity and install Claude Code in the VM
  test-deploy [REF] [--clean]
                    push REF (default: the branch checked out here), build and
                    start the test deployment in the VM and wait until it is up;
                    --clean starts from scratch
EOF
}

# Empty if the VM has no lease (yet) or is not running; never fails, so that
# callers under set -e get to report why
vm_ip() {
    virsh domifaddr "${1:-$VM_NAME}" --source lease 2>/dev/null |
        awk '/ipv4/ {sub("/.*", "", $4); print $4; exit}' || true
}

require_ip() {
    local ip state
    for _ in $(seq 60); do
        ip=$(vm_ip)
        if [ -n "$ip" ]; then
            echo "$ip"
            return
        fi
        if ! state=$(virsh domstate "$VM_NAME" 2>/dev/null); then
            echo "No VM $VM_NAME, see: $(basename "$0") ls" >&2
            exit 1
        fi
        if [ "$state" = "shut off" ]; then
            echo "$VM_NAME is shut off, see /var/log/libvirt/qemu/$VM_NAME.log" >&2
            exit 1
        fi
        sleep 3
    done
    echo "No IP address for $VM_NAME" >&2
    exit 1
}

# known_hosts is derived from the host key; HostKeyAlias keeps it independent of the IP
write_known_hosts() {
    [ -f "$HOSTKEY.pub" ] || { echo "No host key $HOSTKEY.pub, was the VM created by this script?" >&2; exit 1; }
    as_user mkdir -p "$POOL_DIR"
    echo "$VM_NAME $(cut -d' ' -f1,2 "$HOSTKEY.pub")" | as_user tee "$KNOWN_HOSTS" > /dev/null
}

vm_ssh() {
    local ip
    ip=$(require_ip)
    [ -f "$KNOWN_HOSTS" ] || write_known_hosts
    # shellcheck disable=SC2086
    as_user ssh $SSH_OPTS "$VM_USER@$ip" "$@"
}

# git in the host repository, talking to the VM over SSH. Commits travel through the
# host, so the VM never holds credentials for the upstream repository.
vm_git() {
    [ -f "$KNOWN_HOSTS" ] || write_known_hosts
    as_user env GIT_SSH_COMMAND="ssh $SSH_OPTS" \
        git -C "$REPO_ROOT" "$@"
}

# Placeholder substitution. The key is a single-quoted YAML scalar in the template
# (a " #" in its comment would otherwise start a YAML comment), so ' is doubled;
# then the sed replacement specials are escaped.
render() {
    local pubkey
    pubkey=$(head -1 "$SSH_PUBKEY_FILE" | sed "s/'/''/g; s/[|&\\\\]/\\\\&/g")
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
    if [ -e "$DISK" ]; then
        echo "$DISK exists; run '$0 -n $VM_NAME destroy' first" >&2
        exit 1
    fi
    as_user qemu-img create -f qcow2 -F qcow2 -b "$BASE_DIR/$IMAGE_FILE" "$DISK" "${DISK_GB}G"

    local ci_dir
    ci_dir=$(mktemp -d)
    # Expanded now: ci_dir is local and gone when the EXIT trap runs. The directory
    # holds the VM's private host key, so it must not be left behind.
    # shellcheck disable=SC2064
    trap "rm -rf -- '$ci_dir'" EXIT
    render "$HERE/cloud-init/user-data.tmpl" > "$ci_dir/user-data"
    render "$HERE/cloud-init/meta-data.tmpl" > "$ci_dir/meta-data"
    # Host key: kept across re-creates, so a VM of this name keeps its identity
    if [ ! -f "$HOSTKEY" ]; then
        as_user ssh-keygen -q -t ed25519 -N '' -C "$VM_NAME host key" -f "$HOSTKEY"
    fi
    {
        echo "ssh_genkeytypes: [ed25519]"
        echo "ssh_keys:"
        echo "  ed25519_private: |"
        sed 's/^/    /' "$HOSTKEY"
        echo "  ed25519_public: $(cat "$HOSTKEY.pub")"
    } >> "$ci_dir/user-data"
    write_known_hosts

    virsh net-start "$NETWORK" &>/dev/null || true
    virt-install --name "$VM_NAME" --vcpus "$VCPUS" --memory "$RAM_MB" \
        --cpu host-passthrough --osinfo "$OS_VARIANT" \
        --disk path="$DISK",bus=virtio \
        --network network="$NETWORK",model=virtio \
        --cloud-init "user-data=$ci_dir/user-data,meta-data=$ci_dir/meta-data,disable=on" \
        --graphics none --noautoconsole --import \
        --video virtio  # without any display device the Debian kernel resets right after GRUB

    local ip
    ip=$(require_ip)
    echo "$VM_NAME is at $ip. Next: $0 wait && $0 snapshot"
}

cmd_wait() {
    local err
    for _ in $(seq 100); do
        err=$(vm_ssh -o ConnectTimeout=5 -o BatchMode=yes true 2>&1) && break
        case "$err" in *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION"*)
            echo "$err" >&2; exit 1 ;;   # not a timing problem, retrying will not help
        esac
        if [ "$(virsh domstate "$VM_NAME")" = "shut off" ]; then
            echo "$VM_NAME is shut off" >&2; exit 1
        fi
        sleep 3
    done
    [ -n "${err:-}" ] && echo "last error: $err" >&2
    vm_ssh 'cloud-init status --wait && docker version --format "Docker {{.Server.Version}}" && docker compose version'
    eject_cdroms
}

# virt-install deletes its cloud-init ISO right after creating the VM, but the running
# VM keeps it in its CD drive until the next reboot. A snapshot taken before that would
# reference the missing file and could not be reverted, so eject it from the running VM.
eject_cdroms() {
    local _type device target source
    while read -r _type device target source; do
        if [ "$device" != cdrom ] || [ -z "$source" ] || [ "$source" = - ]; then continue; fi
        virsh change-media "$VM_NAME" "$target" --eject --live --force > /dev/null
    done < <(virsh domblklist "$VM_NAME" --details | tail -n +3)
}

cmd_snapshot() {
    [ "$(virsh domstate "$VM_NAME")" = running ] && eject_cdroms
    virsh snapshot-create-as "$VM_NAME" --name "${1:-clean}" --atomic
}

cmd_reset() {
    virsh snapshot-revert "$VM_NAME" --snapshotname "${1:-clean}" --running
    # The guest clock resumes at the time the snapshot was taken; NTP may take a while
    # (or be unreachable), so set it from the host
    vm_ssh -o ConnectTimeout=10 "sudo date -u -s @$(date -u +%s) > /dev/null" ||
        echo "Could not set the VM's clock, it may lag behind" >&2
}

cmd_destroy() {
    if [ "${1:-}" != "-y" ]; then
        read -rp "Remove VM $VM_NAME with disk $DISK and all snapshots? [y/N] " answer
        [ "$answer" = y ] || exit 1
    fi
    virsh destroy "$VM_NAME" &>/dev/null || true
    virsh undefine "$VM_NAME" --snapshots-metadata --remove-all-storage
    # The host key stays: a VM re-created under this name keeps its identity
    rm -f "$KNOWN_HOSTS"
}

cmd_ls() {
    local filter="^$VM_PREFIX" name state ip size snaps mark
    [ "${1:-}" = -a ] && filter=.
    printf '  %-28s %-10s %-16s %6s  %s\n' VM STATE IP USED SNAPSHOTS
    while read -r name; do
        [ -n "$name" ] || continue
        state=$(virsh domstate "$name")
        ip=$(vm_ip "$name")
        size=$(du -h "$POOL_DIR/$name.qcow2" 2>/dev/null | cut -f1 || true)
        snaps=$(virsh snapshot-list "$name" --name | grep -c . || true)
        mark=' '; [ "$name" = "$VM_NAME" ] && mark='*'
        printf '%s %-28s %-10s %-16s %6s  %s\n' "$mark" "$name" "$state" "${ip:--}" "${size:--}" "$snaps"
    done < <(virsh list --all --name | grep "$filter" | sort)
}

cmd_prune() {
    local keep=() disk img backing
    keep+=("$(realpath -m "$BASE_DIR/$IMAGE_FILE")")
    # Every VM disk in the pool is an overlay; keep what it is backed by. Paths are
    # canonicalised, a plain string compare could miss the image in use.
    for disk in "$POOL_DIR"/*.qcow2; do
        [ -e "$disk" ] || continue
        # -U: the disk may be in use by a running VM
        backing=$(qemu-img info -U --output=json "$disk" | python3 -c \
            'import json, sys; print(json.load(sys.stdin).get("full-backing-filename", ""))') ||
            { echo "Cannot inspect $disk, not pruning" >&2; exit 1; }
        [ -n "$backing" ] || { echo "$disk has no backing file, not pruning" >&2; exit 1; }
        keep+=("$(realpath -m "$backing")")
    done
    for img in "$BASE_DIR"/*.qcow2; do
        [ -e "$img" ] || continue
        if printf '%s\n' "${keep[@]}" | grep -qxF "$(realpath -m "$img")"; then
            echo "keep   $img"
        else
            echo "delete $img"
            as_user rm -f "$img"
        fi
    done
}

# The branch checked out in the host repository; the default for push and test-deploy
current_branch() {
    local b
    b=$(as_user git -C "$REPO_ROOT" symbolic-ref --short -q HEAD) ||
        { echo "Detached HEAD on the host, give the ref to push explicitly" >&2; exit 1; }
    echo "$b"
}

cmd_push() {
    local ref=${1:-} branch ip new b r
    [ -n "$ref" ] || ref=$(current_branch)
    branch=${ref#origin/}
    as_user git -C "$REPO_ROOT" check-ref-format --branch "$branch" > /dev/null
    # check-ref-format allows shell metacharacters; the branch ends up in a remote command
    [[ $branch =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || { echo "Unsupported characters in branch name: $branch" >&2; exit 1; }
    # Check on the host first, so that a typo does not leave an empty repository in the VM
    as_user git -C "$REPO_ROOT" rev-parse -q --verify "$ref^{commit}" > /dev/null ||
        { echo "No commit $ref in $REPO_ROOT (for origin/*: git fetch origin first)" >&2; exit 1; }
    ip=$(require_ip)
    b=$(printf %q "$branch"); r=$(printf %q "$VM_REPO")
    # Pushing to the checked-out branch updates the VM's working tree if it is clean.
    # "new" as long as the VM repository has no commit, so that an interrupted first
    # push still gets its submodules on the next one.
    new=$(vm_ssh "{ test -d $r/.git || { git init -q -b $b $r &&
        git -C $r config receive.denyCurrentBranch updateInstead; }; } &&
        { git -C $r rev-parse -q --verify HEAD > /dev/null || echo new; }")
    vm_git push "$VM_USER@$ip:$VM_REPO" "$ref:refs/heads/$branch"
    if [ "$new" = new ]; then
        vm_ssh "cd $r && git reset -q --hard &&
            { git submodule update --init || echo 'Warning: not all submodules could be fetched' >&2; }"
    fi
}

cmd_fetch() {
    local ip
    ip=$(require_ip)
    vm_git fetch "$VM_USER@$ip:$VM_REPO" "+refs/heads/*:refs/remotes/$VM_NAME/*"
}

cmd_setup_dev() {
    local name email
    name=$(as_user git -C "$REPO_ROOT" config user.name || true)
    email=$(as_user git -C "$REPO_ROOT" config user.email || true)
    vm_ssh "bash -s -- $(printf '%q ' "$name" "$email")" < "$HERE/guest/setup-dev.sh"
}

cmd_test_deploy() {
    local ref= clean='' commit
    for arg in "$@"; do
        case $arg in
            --clean) clean=--clean ;;
            *) ref=$arg ;;
        esac
    done
    [ -n "$ref" ] || ref=$(current_branch)
    commit=$(as_user git -C "$REPO_ROOT" rev-parse --verify "$ref^{commit}")
    cmd_push "$ref"
    vm_ssh "bash -s -- $(printf '%q ' "$VM_REPO" "$commit" $clean)" < "$HERE/guest/test-deployment.sh"
}

case "${1:-}" in
    ls) shift; cmd_ls "$@" ;;
    create) cmd_create ;;
    wait) cmd_wait ;;
    ssh) shift; vm_ssh "$@" ;;
    ip) require_ip ;;
    status) virsh dominfo "$VM_NAME"; virsh snapshot-list "$VM_NAME" ;;
    start) virsh start "$VM_NAME" ;;
    stop) virsh shutdown "$VM_NAME" ;;
    snapshot) cmd_snapshot "${2:-}" ;;
    reset) cmd_reset "${2:-}" ;;
    destroy) shift; cmd_destroy "$@" ;;
    prune) cmd_prune ;;
    push) shift; cmd_push "$@" ;;
    fetch) cmd_fetch ;;
    setup-dev) cmd_setup_dev ;;
    test-deploy) shift; cmd_test_deploy "$@" ;;
    *) usage; exit 1 ;;
esac
