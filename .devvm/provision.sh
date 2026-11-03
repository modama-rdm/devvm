#!/bin/bash
# Runs once in a new VM of the devvm project, as the VM user: makes the VM a devvm host,
# so that devvm can be developed and tested inside it with nested VMs.
set -euo pipefail

# libvirt without sudo; effective for the next login (cloud-init runs before any)
sudo usermod -aG libvirt "$USER"

# libvirt's default network uses 192.168.122.0/24, which is usually the network this VM
# is on already; nested VMs get the first 192.168.N.0/24 not routed here (this VM may
# itself be nested, on another subnet)
n=122
while ip -4 route | grep -q "^192\.168\.$n\."; do n=$((n + 1)); done
sudo virsh -c qemu:///system net-destroy default > /dev/null 2>&1 || true
sudo virsh -c qemu:///system net-dumpxml --inactive default |
    sed "s/192\.168\.122\./192.168.$n./g" > /tmp/devvm-default-net.xml
sudo virsh -c qemu:///system net-define /tmp/devvm-default-net.xml > /dev/null
rm -f /tmp/devvm-default-net.xml
sudo virsh -c qemu:///system net-autostart default > /dev/null
sudo virsh -c qemu:///system net-start default > /dev/null

# A key for logging in to nested VMs; it never leaves this VM, so no passphrase
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519

# Pool for nested VMs, and the site settings `devvm setup` would ask for. Nested VMs are
# smaller than the defaults, which are as large as this whole VM.
sudo install -d -o "$USER" -g "$(id -gn)" -m 0751 /var/lib/libvirt/images/devvm
mkdir -p ~/.config/devvm
cat > ~/.config/devvm/site.env <<EOF
# Site settings of devvm in the devvm development VM, written by .devvm/provision.sh
DEVVM_POOL_DIR=/var/lib/libvirt/images/devvm
DEVVM_SSH_PUBKEY_FILE=$HOME/.ssh/id_ed25519.pub
DEVVM_VCPUS=2
DEVVM_RAM_MB=4096
DEVVM_DISK_GB=20
EOF

# devvm on PATH, from the shared checkout (absent with DEVVM_SHARE_WORKSPACE=0, where
# the checkout arrives later by devvm push)
ws=$(awk '$1 == "devvm-ws" { print $2 }' /etc/fstab)
if [ -n "$ws" ] && [ -x "$ws/devvm" ]; then
    mkdir -p ~/.local/bin
    ln -sfn "$ws/devvm" ~/.local/bin/devvm
fi
