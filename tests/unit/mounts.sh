#!/bin/bash
# Shared folders and volumes: plan_mounts, check_path, expand_vars
# shellcheck disable=SC1090,SC2034,SC2317  # SC2317: stubs, called indirectly
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

test_workspace_and_mounts() {
    mkdir data
    . "$DEVVM"
    DEVVM_MOUNTS='
        source=data,target=/data,readonly
        source=build,target=build,type=volume
    '
    plan_mounts
    assert_eq "${FS_TAG[*]}" "devvm-ws devvm-m1"
    assert_eq "${FS_SRC[0]}" "$PWD"
    assert_eq "${FS_TGT[0]}" /workspaces/repo
    assert_eq "${FS_SRC[1]}" "$(realpath data)"
    assert_eq "${FS_TGT[1]}" /data
    assert_eq "${FS_RO[0]}/${FS_RO[1]}" "/1" "read-only flags"
    assert_eq "${VOL_NAME[*]}" build
    assert_eq "${VOL_TGT[*]}" /workspaces/repo/build
}

test_no_share() {
    . "$DEVVM"
    DEVVM_SHARE_WORKSPACE=0
    plan_mounts
    assert_eq "${#FS_TAG[@]}" 0
    assert_eq "$GUEST_WS" /home/dev/repo
}

test_linked_worktree_shares_git_dir() {
    git_q worktree add -q -b other ../wt
    cd ../wt
    . "$DEVVM"
    plan_mounts
    assert_eq "${FS_TAG[*]}" "devvm-ws devvm-git"
    assert_eq "${FS_SRC[1]}" "$TMP/repo/.git"
    assert_eq "${FS_TGT[1]}" "$TMP/repo/.git"
}

# Issue #8. The VM's view of a linked worktree with a submodule, without a VM: the
# checkout at GUEST_WS (moved there instead of shared), the git directory at its host
# path, and the symlinks that guest_git_links makes, as setup.sh would
test_linked_worktree_with_submodules_in_vm() {
    git_q init -q -b main ../sub
    git_q -C ../sub commit -q --allow-empty -m sub
    git_q -c protocol.file.allow=always submodule add -q ../sub deploy/sub
    git_q commit -q -m submodule
    git_q worktree add -q -b other ../wt
    cd ../wt
    git_q -c protocol.file.allow=always submodule update -q --init
    . "$DEVVM"
    DEVVM_WORKSPACE_ROOT=$TMP/workspaces
    plan_mounts
    assert_eq "$GUEST_WS" "$TMP/workspaces/wt"
    cd "$TMP"
    mkdir workspaces
    mv wt workspaces/
    mkpoint() { mkdir -p "$1"; }
    eval "$(guest_git_links)"
    cd "$GUEST_WS"
    git status --short > "$TMP/out" 2>&1 || fail "git status: $(cat "$TMP/out")"
    assert_eq "$(cat "$TMP/out")" ""
    assert_contains "$(git submodule status)" " deploy/sub "
    # The submodule's working tree is the checkout in the VM
    assert_eq "$(git -C deploy/sub rev-parse --show-toplevel)" "$GUEST_WS/deploy/sub"
    echo change > deploy/sub/file
    assert_contains "$(git status --short)" "? deploy/sub"
    assert_eq "$GIT_MIRROR" "$TMP/workspaces/repo/.git"
    # A second run of setup.sh leaves the links alone
    eval "$(guest_git_links)"
}

test_missing_mount_source_says_where_it_is_set() {
    mkdir .devvm
    echo "DEVVM_MOUNTS='source=../pyxdg,target=/workspaces/pyxdg'" > .devvm/config.env
    . "$DEVVM"
    assert_fails plan_mounts
    assert_contains "$(cat "$TMP/out")" "No folder $TMP/pyxdg for the mount source=../pyxdg,"
    assert_contains "$(cat "$TMP/out")" "set in $PWD/.devvm/config.env."
    assert_contains "$(cat "$TMP/out")" "Create the folder, or fix or remove the mount there."
    # From the environment, which overrides the project's setting
    export DEVVM_MOUNTS=source=/no/such/dir,target=/x
    . "$DEVVM"
    assert_fails plan_mounts
    assert_contains "$(cat "$TMP/out")" "No folder /no/such/dir for the mount"
    assert_contains "$(cat "$TMP/out")" "set in the environment."
}

# A VM whose definition shares the checkout and $TMP/data; virsh logs what it is asked
stub_vm_with_shares() {
    require_vm() { :; }
    vm_ssh() { :; }
    vm_ip() { echo 192.0.2.1; }
    virsh() {
        echo "$*" >> "$TMP/calls"
        case $1 in
            dumpxml) cat <<EOF ;;
<domain type='kvm'>
  <devices>
    <disk type='file' device='disk'>
      <source file='$TMP/pool/repo-main.qcow2'/>
    </disk>
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='$TMP/repo'/>
      <target dir='devvm-ws'/>
    </filesystem>
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='$TMP/data'/>
      <target dir='devvm-m1'/>
      <readonly/>
    </filesystem>
  </devices>
</domain>
EOF
            domstate) echo "shut off" ;;
            snapshot-list) echo clean ;;
        esac
    }
    : > "$TMP/calls"
}

test_start_and_reset_refuse_when_a_shared_folder_is_gone() {
    . "$DEVVM"
    stub_vm_with_shares
    assert_eq "$(vm_shares)" "devvm-ws $TMP/repo
devvm-m1 $TMP/data"
    assert_eq "$(missing_shares)" "devvm-m1 $TMP/data"
    for c in cmd_start cmd_reset; do
        assert_fails "$c"
        assert_contains "$(cat "$TMP/out")" "the folder $TMP/data of its DEVVM_MOUNTS no longer exists"
        assert_contains "$(cat "$TMP/out")" "re-create the VM without it"
    done
    assert_not_contains "$(cat "$TMP/calls")" "start repo-main"
    assert_not_contains "$(cat "$TMP/calls")" "snapshot-revert"
    # The checkout itself, e.g. a removed worktree
    mkdir "$TMP/data"
    mv "$TMP/repo" "$TMP/moved"
    assert_fails cmd_start
    assert_contains "$(cat "$TMP/out")" "its shared checkout $TMP/repo no longer exists"
    # All there: libvirt is asked
    mv "$TMP/moved" "$TMP/repo"
    assert_eq "$(missing_shares)" ""
    cmd_reset > /dev/null
    assert_contains "$(cat "$TMP/calls")" "snapshot-revert"
}

test_variables_in_mounts() {
    . "$DEVVM"
    GUEST_WS=/workspaces/repo
    export FOO=/foo
    # shellcheck disable=SC2016
    assert_eq "$(expand_vars '${localEnv:FOO}/${localWorkspaceFolderBasename}:${containerWorkspaceFolder}')" \
        /foo/repo:/workspaces/repo
    # shellcheck disable=SC2016
    assert_eq "$(expand_vars '${localEnv:HOME}')" "$HOME"
}

test_invalid_mounts() {
    mkdir data
    . "$DEVVM"
    local spec
    for spec in source=missing,target=/x source=data,target=/x,bogus source=data \
        source=v,target=/x,type=volume,readonly 'source=bad/name,target=/x,type=volume' \
        source=data,target=/x,type=tmpfs source=data,target=/a,b; do
        DEVVM_MOUNTS=$spec
        assert_fails plan_mounts
    done
    DEVVM_SHARE_WORKSPACE=0 DEVVM_MOUNTS=source=data,target=rel
    assert_fails plan_mounts
    assert_contains "$(cat "$TMP/out")" "Relative target needs DEVVM_SHARE_WORKSPACE=1"
}

test_check_path() {
    . "$DEVVM"
    check_path /ok/path-1_2.x
    local p
    for p in relative '/with space' /a,b "/quo'te" '/a&b' '/a<b'; do
        assert_fails check_path "$p"
    done
}

run_tests
