#!/bin/bash
# What a first user who follows only devvm's output needs, from the hallway test of
# 2026-11-07: ssh CMD runs where a login starts, and messages name the next step.
# libvirt and SSH are replaced by stubs.
# shellcheck disable=SC1090,SC2034,SC2317  # SC2317: stubs, called indirectly
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# ssh runs its command string in a local shell, as sshd would; the profile script that
# create writes into the VM moves to $TMP/ws
stub_ssh() {
    require_vm() { :; }
    vm_ssh() { printf '%s\n' "$*" > "$TMP/ssh-args"; (cd "$HOME" && bash -c "$*"); }
    mkdir -p "$TMP/ws"
    WS_PROFILE=$TMP/profile.sh
    echo "if [ \"\$PWD\" = \"\$HOME\" ] && [ -d $TMP/ws ]; then cd $TMP/ws; fi" > "$WS_PROFILE"
}

test_ssh_command_runs_in_the_workspace() {
    . "$DEVVM"
    stub_ssh
    assert_eq "$(cmd_ssh pwd)" "$TMP/ws"
    assert_eq "$(cmd_ssh 'echo "a  b"; exit 3' || echo "rc=$?")" "a  b
rc=3" "quoting and exit status"
}

test_ssh_command_without_the_profile_script_stays_home() {
    . "$DEVVM"
    stub_ssh
    rm "$WS_PROFILE"
    assert_eq "$(cmd_ssh pwd)" "$HOME"
}

test_ssh_options_go_to_ssh_unchanged() {
    . "$DEVVM"
    stub_ssh
    vm_ssh() { echo "$#"; printf "[%s]" "$@"; }
    assert_eq "$(cmd_ssh -L 8080:localhost:8080)" "2
[-L][8080:localhost:8080]"
    assert_eq "$(cmd_ssh)" "0
[]"
}

test_test_without_config_points_to_init() {
    . "$DEVVM"
    require_vm() { :; }
    assert_fails cmd_test
    assert_contains "$(cat "$TMP/out")" "run $PROG init, then set DEVVM_TEST_COMMAND in "
    mkdir -p "$PROJECT_DIR"
    touch "$PROJECT_DIR/config.env"
    assert_fails cmd_test
    assert_contains "$(cat "$TMP/out")" "set DEVVM_TEST_COMMAND in $PROJECT_DIR/config.env, see README"
}

test_ls_says_when_this_checkout_has_no_vm() {
    . "$DEVVM"
    VMS=other-vm
    virsh() {
        case "$1 ${2:-}" in
            "list --all") echo "$VMS" ;;
            "dominfo $VMS") ;;
            dominfo*) return 1 ;;
        esac
    }
    vm_state() { echo "shut off"; }
    vm_ip() { :; }
    assert_contains "$(cmd_ls -a 2>&1)" "No VM $DEVVM_VM_NAME for this checkout yet: $PROG create"
    VMS=$DEVVM_VM_NAME
    assert_not_contains "$(cmd_ls 2>&1)" "No VM"
}

test_confirm_without_a_terminal() {
    . "$DEVVM"
    assert_fails confirm "Destroy x?" "use destroy -y" < /dev/null
    assert_eq "$(cat "$TMP/out")" "Destroy x? (no terminal to confirm; use destroy -y)"
}

run_tests
