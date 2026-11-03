#!/bin/bash
# Settings and VM names: devvm sourced without a command, no libvirt needed
# shellcheck disable=SC1090,SC2034
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# devvm sourced with ARGS as its command line, from a function: for failures only, as
# the environment overrides become local to this function
load() { . "$DEVVM"; }

test_precedence_defaults_site_project_env() {
    mkdir .devvm
    printf 'DEVVM_VCPUS=2\nDEVVM_RAM_MB=2\nDEVVM_DISK_GB=2\n' >> "$HOME/.config/devvm/site.env"
    printf 'DEVVM_RAM_MB=3\nDEVVM_DISK_GB=3\n' > .devvm/config.env
    export DEVVM_DISK_GB=4
    . "$DEVVM"
    assert_eq "$DEVVM_NETWORK" default "defaults.env"
    assert_eq "$DEVVM_VCPUS" 2 "site over defaults"
    assert_eq "$DEVVM_RAM_MB" 3 "project over site"
    assert_eq "$DEVVM_DISK_GB" 4 "environment over project"
}

test_site_limits_refuse_a_larger_vm() {
    mkdir .devvm
    printf 'DEVVM_MAX_VCPUS=4\nDEVVM_MAX_RAM_MB=8192\nDEVVM_MAX_DISK_GB=40\n' >> "$HOME/.config/devvm/site.env"
    printf 'DEVVM_VCPUS=2\nDEVVM_RAM_MB=4096\nDEVVM_DISK_GB=40\n' > .devvm/config.env
    . "$DEVVM"
    check_limits   # at the limit is fine
    DEVVM_RAM_MB=16384
    assert_fails check_limits
    assert_contains "$(cat "$TMP/out")" "DEVVM_RAM_MB=16384 is above this site's limit DEVVM_MAX_RAM_MB=8192"
    DEVVM_RAM_MB=4096 DEVVM_VCPUS=8
    assert_fails check_limits
    assert_contains "$(cat "$TMP/out")" "DEVVM_VCPUS=8"
}

test_a_project_cannot_raise_the_site_limits() {
    mkdir .devvm
    echo DEVVM_MAX_RAM_MB=8192 >> "$HOME/.config/devvm/site.env"
    printf 'DEVVM_MAX_RAM_MB=999999\nDEVVM_RAM_MB=16384\n' > .devvm/config.env
    . "$DEVVM"
    assert_eq "$DEVVM_MAX_RAM_MB" 8192 "the site's limit"
    assert_fails check_limits
}

test_environment_can_override_the_site_limits() {
    echo DEVVM_MAX_RAM_MB=8192 >> "$HOME/.config/devvm/site.env"
    export DEVVM_MAX_RAM_MB=65536 DEVVM_RAM_MB=16384
    . "$DEVVM"
    check_limits
}

test_no_limits_by_default() {
    . "$DEVVM"
    check_limits
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
