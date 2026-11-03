#!/bin/bash
# Settings and VM names: devvm sourced without a command, no libvirt needed
# shellcheck disable=SC1090,SC2034
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# devvm sourced with ARGS as its command line, from a function: for failures only, as
# the environment overrides become local to this function
load() { . "$DEVVM"; }

test_precedence_defaults_project_site_env() {
    mkdir .devvm
    printf 'DEVVM_VCPUS=2\nDEVVM_RAM_MB=2\nDEVVM_DISK_GB=2\n' > .devvm/config.env
    printf 'DEVVM_RAM_MB=3\nDEVVM_DISK_GB=3\n' >> "$HOME/.config/devvm/site.env"
    export DEVVM_DISK_GB=4
    . "$DEVVM"
    assert_eq "$DEVVM_NETWORK" default "defaults.env"
    assert_eq "$DEVVM_VCPUS" 2 "project over defaults"
    assert_eq "$DEVVM_RAM_MB" 3 "site over project"
    assert_eq "$DEVVM_DISK_GB" 4 "environment over site"
}

test_vm_name_from_branch() {
    git_q checkout -q -b feature/x.y
    . "$DEVVM"
    assert_eq "$DEVVM_VM_PREFIX" repo- "default prefix"
    assert_eq "$DEVVM_VM_NAME" repo-feature-x-y
    assert_eq "$DEVVM_VM_REPO" repo
}

test_vm_name_with_project_prefix() {
    mkdir .devvm
    echo DEVVM_VM_PREFIX=proj- > .devvm/config.env
    . "$DEVVM"
    assert_eq "$DEVVM_VM_NAME" proj-main
}

test_linked_worktree_uses_main_repository_name() {
    git_q worktree add -q -b other ../wt
    cd ../wt
    . "$DEVVM"
    assert_eq "$DEVVM_VM_NAME" repo-other
    assert_eq "$DEVVM_VM_REPO" repo
}

test_option_n_selects_vm() {
    set -- -n some-vm
    . "$DEVVM"
    assert_eq "$DEVVM_VM_NAME" some-vm
}

test_invalid_vm_name() {
    assert_fails load -n 'bad name'
    assert_contains "$(cat "$TMP/out")" "Invalid VM name"
}

test_detached_head_has_no_default_vm() {
    git_q checkout -q --detach
    . "$DEVVM"
    assert_eq "$DEVVM_VM_NAME" ""
}

run_tests
