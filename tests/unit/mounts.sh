#!/bin/bash
# Shared folders and volumes: plan_mounts, check_path, expand_vars
# shellcheck disable=SC1090,SC2034
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
