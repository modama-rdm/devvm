#!/bin/bash
# A real VM through its life: create (with wait and snapshot), ssh, the hints that
# create prints, provisioning, the shared workspace and a further shared folder (also
# one that is missing or removed), setup-dev, snapshots, save and restore, use across
# a branch switch, test with reset, destroy.
#
# Needs KVM, libvirt (member of the libvirt group), virt-install and virtiofsd. The
# project is a small throw-away repository; the VM uses a fresh key, served by its own
# ssh-agent, so no passphrase is asked for. Disks go to DEVVM_E2E_POOL_DIR, default the
# DEVVM_POOL_DIR of your site settings, where the base image is downloaded once.
# shellcheck disable=SC1090,SC2031  # SC2031: the runner sets HOME, TMP in a subshell
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"
TESTS_VERBOSE=1

step() { echo "--- $*"; }

# A missing prerequisite skips the test, unless DEVVM_E2E_REQUIRED is set (in CI, where
# a skipped e2e test would go unnoticed): then it fails
unmet() {
    if [ -n "$E2E_REQUIRED" ]; then fail "$*"; else skip "$*"; fi
}

e2e_prerequisites() {
    local pool=$E2E_POOL_DIR
    command -v virt-install > /dev/null || unmet "no virt-install"
    [ -x /usr/libexec/virtiofsd ] || [ -x /usr/lib/qemu/virtiofsd ] || unmet "no virtiofsd"
    id -nG | tr ' ' '\n' | grep -qx libvirt || unmet "not in the libvirt group"
    if [ -z "$pool" ] && [ -f "$REAL_HOME/.config/devvm/site.env" ]; then
        pool=$(. "$REAL_HOME/.config/devvm/site.env" && echo "${DEVVM_POOL_DIR:-}")
    fi
    [ -n "$pool" ] || unmet "no pool: set DEVVM_E2E_POOL_DIR or run devvm setup"
    echo "$pool"
}

test_lifecycle() {
    local pool name out rc
    pool=$(e2e_prerequisites)
    name=devvm-e2e-$RANDOM-main
    # Throw-away project: few packages, small VM, provisioning and a test command
    sed -i "s|^DEVVM_POOL_DIR=.*|DEVVM_POOL_DIR=$pool|" "$HOME/.config/devvm/site.env"
    mkdir .devvm
    cat > .devvm/config.env <<EOF
DEVVM_VM_PREFIX=${name%main}
DEVVM_PACKAGES=git
DEVVM_VCPUS=2
DEVVM_RAM_MB=2048
DEVVM_DISK_GB=8
DEVVM_TEST_COMMAND=./run.sh
DEVVM_MOUNTS='source=../data,target=/data'
EOF
    cat > .devvm/provision.sh <<'EOF'
#!/bin/bash
echo provisioned > ~/provisioned
mkdir -p ~/.local/bin
EOF
    # Prints its arguments, whether the state of a test before is gone and the login
    # PATH; exits with the first argument
    cat > run.sh <<'EOF'
#!/bin/sh
[ -e "$HOME/leftover" ] && echo "leftover from before the reset"
case ":$PATH:" in *":$HOME/.local/bin:"*) echo "login PATH" ;; esac
printf '[%s]' "$@"; echo
exit "${1:-0}"
EOF
    chmod +x run.sh

    eval "$(ssh-agent -s)" > /dev/null
    ssh-add -q "$TMP/key"
    # shellcheck disable=SC2064  # expanded now
    trap "
        \"$DEVVM\" destroy -y > /dev/null 2>&1 || true
        rm -f '$pool/$name'.hostkey* '$pool/$name'.known_hosts
        ssh-agent -k > /dev/null
        rm -rf '$TMP'" EXIT

    step "a VM above the site's limit is refused, before anything is created"
    rc=0
    DEVVM_MAX_RAM_MB=512 "$DEVVM" create > "$TMP/limit.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "create ignored DEVVM_MAX_RAM_MB"
    assert_contains "$(cat "$TMP/limit.log")" "is above this site's limit DEVVM_MAX_RAM_MB=512"
    ! virsh -c qemu:///system dominfo "$name" > /dev/null 2>&1 || fail "$name was created"

    step "a missing mount source is refused, before anything is created"
    rc=0
    "$DEVVM" create > "$TMP/nodata.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "create ignored the missing mount source"
    assert_contains "$(cat "$TMP/nodata.log")" "No folder $TMP/data for the mount"
    ! virsh -c qemu:///system dominfo "$name" > /dev/null 2>&1 || fail "$name was created"
    mkdir "$TMP/data"

    step "create $name"
    # tee would hide create's exit status: take it from PIPESTATUS
    "$DEVVM" create 2>&1 | tee "$TMP/create.log"
    [ "${PIPESTATUS[0]}" -eq 0 ] || fail "devvm create failed"
    "$DEVVM" ls | grep -q "^\* $name *running" || fail "ls does not show $name running"

    step "the command create prints to watch cloud-init"
    out=$(sed -n 's/.*To watch: //p' "$TMP/create.log")
    [ -n "$out" ] || fail "no 'To watch:' hint"
    out=${out/tail -f/tail -n 1}
    read -ra words <<< "$out"
    "$DEVVM" "${words[@]:1}" || fail "the hint failed: $out"

    assert_contains "$(cat "$TMP/create.log")" "Creating $name: 2 vCPUs, 2048 MB RAM, 8 GB disk"
    assert_not_contains "$(cat "$TMP/create.log")" "reconnect to the console"
    out=$("$DEVVM" status)
    assert_contains "$out" "State:      running"
    assert_contains "$out" "Size:       2 vCPUs, 2048 MB RAM"

    step "VM user and provisioning"
    out=$("$DEVVM" ssh id -nG)
    for g in sudo docker adm; do
        tr ' ' '\n' <<< "$out" | grep -qx "$g" || fail "VM user not in $g: $out"
    done
    "$DEVVM" ssh tail -n 1 /var/log/cloud-init-output.log > /dev/null
    assert_eq "$("$DEVVM" ssh cat provisioned)" provisioned "provisioning"

    step "shared workspace"
    "$DEVVM" ssh "touch /workspaces/repo/from-vm"
    [ -O from-vm ] || fail "file from the VM missing or not owned by $(id -un)"

    step "setup-dev: screenshot tools and the kaizen plugin"
    "$DEVVM" setup-dev
    "$DEVVM" ssh dpkg -s xvfb xterm xdotool imagemagick > /dev/null || fail "tools not installed"
    # shellcheck disable=SC2088  # the VM's shell expands the tilde
    assert_contains "$("$DEVVM" ssh '~/.local/bin/claude plugin list')" "kaizen@uellue"

    step "snapshots: create, list, refuse duplicate, update, reset, delete"
    "$DEVVM" ssh "echo v1 > snapmark"
    "$DEVVM" snapshot dev
    "$DEVVM" ssh "echo v2 > snapmark"
    rc=0
    "$DEVVM" snapshot dev > "$TMP/dup.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "snapshot dev over an existing one succeeded"
    assert_contains "$(cat "$TMP/dup.log")" "snapshot -u dev"
    out=$("$DEVVM" snapshot -l)
    assert_contains "$out" "clean"
    assert_contains "$out" "dev"
    assert_contains "$("$DEVVM" ls)" "clean, dev"
    "$DEVVM" snapshot -u dev
    "$DEVVM" ssh "echo v3 > snapmark"
    "$DEVVM" reset dev
    assert_eq "$("$DEVVM" ssh cat snapmark)" v2 "state after reset to the updated snapshot"
    "$DEVVM" snapshot -u fresh   # -u creates a missing snapshot
    "$DEVVM" snapshot -d dev fresh
    out=$("$DEVVM" snapshot -l)
    assert_not_contains "$out" $'\ndev '   # one snapshot per line, after a header
    assert_not_contains "$out" "fresh"
    assert_contains "$out" "clean"
    ! "$DEVVM" snapshot -d nosuch > /dev/null 2>&1 || fail "deleting a missing snapshot succeeded"

    step "stop and start wait for the VM"
    "$DEVVM" stop
    assert_contains "$("$DEVVM" status)" "State:      shut off"
    "$DEVVM" start
    assert_eq "$("$DEVVM" ssh echo up)" up "ssh right after start"

    step "save keeps the memory, start restores it and sets the clock; reset drops it"
    # /dev/shm is in RAM: it survives only a restore, not a boot
    "$DEVVM" ssh "echo in-ram > /dev/shm/mark"
    "$DEVVM" save
    "$DEVVM" ls | grep -q "^\* $name *saved " || fail "ls does not show $name saved"
    assert_contains "$("$DEVVM" status)" "State:      saved"
    rc=0
    "$DEVVM" ssh true > "$TMP/saved-ssh.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "ssh to a saved VM succeeded"
    assert_contains "$(cat "$TMP/saved-ssh.log")" "is saved to disk, see: "
    sleep 15   # let the guest clock fall behind
    assert_contains "$("$DEVVM" start)" "Restored $name from its saved state"
    assert_eq "$("$DEVVM" ssh cat /dev/shm/mark)" in-ram "memory after the restore"
    out=$(( $("$DEVVM" ssh date +%s) - $(date +%s) ))
    [ "${out#-}" -le 3 ] || fail "guest clock off by $out s after the restore"
    "$DEVVM" save
    assert_contains "$("$DEVVM" reset)" "Discarded the saved state"
    virsh -c qemu:///system dominfo "$name" | grep -x 'Managed save: *no' > /dev/null ||
        fail "a save image survived the reset"
    "$DEVVM" ssh "test ! -e /dev/shm/mark" || fail "memory of before the reset"
    virsh -c qemu:///system suspend "$name" > /dev/null
    assert_contains "$("$DEVVM" status)" "State:      paused"
    assert_contains "$("$DEVVM" start)" "Resumed $name, which was paused"
    assert_eq "$("$DEVVM" ssh echo up)" up "ssh after a pause"

    step "use keeps the VM across a branch switch"
    git_q switch -q -c next
    rc=0
    "$DEVVM" status > "$TMP/next.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "status found a VM for branch next"
    assert_contains "$(cat "$TMP/next.log")" "or keep using an existing VM: devvm use VM"
    "$DEVVM" use "$name"
    assert_contains "$("$DEVVM" status)" "VM:         $name (set with devvm use)"
    "$DEVVM" ssh "test -d /workspaces/repo/.git" || fail "workspace after the switch"
    "$DEVVM" use --clear
    git_q switch -q main

    step "a shared folder removed from the host: start and reset refuse, the VM survives"
    "$DEVVM" ssh "touch /data/from-vm"
    [ -e "$TMP/data/from-vm" ] || fail "file in the shared folder missing on the host"
    mv "$TMP/data" "$TMP/data.away"
    assert_contains "$("$DEVVM" status)" "Missing:    $TMP/data is shared but no longer exists"
    rc=0
    "$DEVVM" reset > "$TMP/gone-reset.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "reset with a missing shared folder succeeded"
    assert_contains "$(cat "$TMP/gone-reset.log")" "Cannot reset $name: the folder $TMP/data"
    assert_contains "$("$DEVVM" status)" "State:      running"
    "$DEVVM" stop
    rc=0
    "$DEVVM" start > "$TMP/gone-start.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "start with a missing shared folder succeeded"
    assert_contains "$(cat "$TMP/gone-start.log")" "Cannot start $name: the folder $TMP/data"
    mv "$TMP/data.away" "$TMP/data"
    "$DEVVM" start
    assert_eq "$("$DEVVM" ssh ls /data)" from-vm "shared folder after the restore"

    step "test: reset, arguments, login shell"
    "$DEVVM" ssh "touch leftover"
    out=$("$DEVVM" test 0 'a b' "c'd")
    assert_not_contains "$out" "leftover"
    assert_contains "$out" "login PATH"
    assert_contains "$out" "[0][a b][c'd]"

    step "test: exit status"
    "$DEVVM" ssh "touch leftover"
    rc=0
    out=$("$DEVVM" test --no-reset 3) || rc=$?
    assert_eq "$rc" 3 "exit status of devvm test"
    assert_contains "$out" "leftover"

    step "destroy, of a saved VM"
    "$DEVVM" save
    assert_contains "$("$DEVVM" destroy -y)" "Destroyed $name"
    rc=0
    "$DEVVM" status > "$TMP/gone.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "status of a destroyed VM succeeded"
    assert_contains "$(cat "$TMP/gone.log")" "No VM $name"
    ! virsh -c qemu:///system dominfo "$name" > /dev/null 2>&1 || fail "$name still exists"
    [ ! -e "$pool/$name.qcow2" ] || fail "disk still exists"
}

run_tests
