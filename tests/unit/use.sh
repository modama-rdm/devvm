#!/bin/bash
# devvm use: the VM of a checkout, instead of the one named after its branch, and the
# precedence of the ways to name a VM. libvirt is replaced by a stub.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2317  # SC2317: stubs, called indirectly
# SC2030/SC2031: the precedence test sets variables in subshells on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# devvm again, as a new run would: without the name the previous run chose
reload() { unset DEVVM_VM_NAME; . "$DEVVM"; }

# VMs that exist, one per line
stub_virsh() {
    VMS=${1:-}
    virsh() { [ "$1 $2" != "list --all" ] || echo "$VMS"; }
}

test_use_keeps_a_vm_across_branches() {
    . "$DEVVM"
    stub_virsh repo-main
    assert_contains "$(cmd_use repo-main)" "This checkout uses VM repo-main"
    git_q checkout -q -b next
    reload
    assert_eq "$DEVVM_VM_NAME" repo-main
    assert_eq "$VM_NAME_FROM" checkout
    assert_contains "$(cmd_use)" "This checkout uses VM repo-main (set with "
    assert_contains "$(cmd_use)" "returns to the branch's VM repo-next"
}

test_use_is_kept_in_the_git_directory() {
    . "$DEVVM"
    stub_virsh
    cmd_use kept > /dev/null
    assert_eq "$(cat .git/devvm-vm)" kept
    assert_eq "$(git status --porcelain)" "" "git status"
}

test_use_is_per_worktree() {
    git_q worktree add -q -b other ../wt
    . "$DEVVM"
    stub_virsh
    cmd_use main-vm > /dev/null
    cd ../wt
    reload
    assert_eq "$DEVVM_VM_NAME" repo-other "the other worktree keeps its default"
    stub_virsh
    cmd_use wt-vm > /dev/null
    reload
    assert_eq "$DEVVM_VM_NAME" wt-vm
    cd ../repo
    reload
    assert_eq "$DEVVM_VM_NAME" main-vm
}

test_use_clear_returns_to_the_branch() {
    . "$DEVVM"
    stub_virsh
    cmd_use other > /dev/null
    assert_contains "$(cmd_use --clear)" "named after its branch again, repo-main"
    reload
    assert_eq "$DEVVM_VM_NAME" repo-main
    assert_eq "$VM_NAME_FROM" branch
    assert_contains "$(cmd_use)" "uses the VM named after its branch, repo-main"
}

test_use_of_a_vm_that_does_not_exist_yet() {
    . "$DEVVM"
    stub_virsh other-vm
    assert_contains "$(cmd_use new-vm)" "new-vm does not exist yet; "
    assert_not_contains "$(cmd_use other-vm)" "does not exist"
}

test_use_refuses_bad_input() {
    . "$DEVVM"
    stub_virsh
    assert_fails cmd_use 'bad name'
    assert_contains "$(cat "$TMP/out")" "Invalid VM name"
    assert_fails cmd_use --nope
    assert_fails cmd_use a b
    [ ! -e .git/devvm-vm ] || fail "a refused name was stored"
}

test_use_outside_a_repository() {
    cd "$TMP"
    . "$DEVVM"
    assert_fails cmd_use x
    assert_contains "$(cat "$TMP/out")" "Not in a git repository"
}

test_use_gives_a_detached_head_a_vm() {
    echo pinned > .git/devvm-vm
    git_q checkout -q --detach
    . "$DEVVM"
    assert_eq "$DEVVM_VM_NAME" pinned
}

test_precedence_option_environment_use_settings_branch() {
    echo used > .git/devvm-vm
    mkdir .devvm
    echo DEVVM_VM_NAME=configured > .devvm/config.env
    (set -- -n opt; . "$DEVVM"; assert_eq "$DEVVM_VM_NAME/$VM_NAME_FROM" opt/option)
    (export DEVVM_VM_NAME=env; . "$DEVVM"; assert_eq "$DEVVM_VM_NAME/$VM_NAME_FROM" env/environment)
    (. "$DEVVM"; assert_eq "$DEVVM_VM_NAME/$VM_NAME_FROM" used/checkout)
    rm .git/devvm-vm
    (. "$DEVVM"; assert_eq "$DEVVM_VM_NAME/$VM_NAME_FROM" configured/settings)
    rm .devvm/config.env
    (. "$DEVVM"; assert_eq "$DEVVM_VM_NAME/$VM_NAME_FROM" repo-main/branch)
}

test_use_says_when_the_environment_wins() {
    export DEVVM_VM_NAME=env-vm
    . "$DEVVM"
    stub_virsh
    assert_contains "$(cmd_use x)" "DEVVM_VM_NAME=env-vm in the environment takes precedence"
}

test_missing_vm_message_depends_on_the_source_of_the_name() {
    . "$DEVVM"
    stub_virsh
    assert_fails require_vm
    assert_contains "$(cat "$TMP/out")" "No VM repo-main for this checkout. Create it with: "
    assert_contains "$(cat "$TMP/out")" "or keep using an existing VM: "
    echo gone > .git/devvm-vm
    reload
    stub_virsh
    assert_fails require_vm
    assert_contains "$(cat "$TMP/out")" "No VM gone, which this checkout uses (set with "
    assert_eq "$(wc -l < "$TMP/out")" 1 "lines"
}

run_tests
