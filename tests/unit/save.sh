#!/bin/bash
# save (to disk) with start (restores it, and continues a paused VM), and how the other
# commands treat a saved or paused VM. libvirt and SSH are replaced by stubs.
# shellcheck disable=SC1090,SC2034,SC2317  # SC2317: stubs, called indirectly
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# A VM in libvirt state $TMP/state ("running", "paused", "shut off"), with a managed
# save image if $TMP/saved exists. virsh changes them as libvirt would and logs its
# calls to $TMP/calls; SSH always works.
stub_vm() {
    echo "$1" > "$TMP/state"
    rm -f "$TMP/saved"; [ "${2:-}" != saved ] || touch "$TMP/saved"
    : > "$TMP/calls"
    require_vm() { :; }
    check_shares() { :; }
    eject_cdroms() { :; }
    sleep() { :; }
    vm_ip() { echo 192.0.2.1; }
    vm_ssh() { echo "ssh $*" >> "$TMP/calls"; }
    virsh() {
        echo "$*" >> "$TMP/calls"
        case $1 in
            domstate) cat "$TMP/state" ;;
            dominfo) echo "State:          $(cat "$TMP/state")"
                     echo "Managed save:   $([ -e "$TMP/saved" ] && echo yes || echo no)" ;;
            managedsave) touch "$TMP/saved"; echo "shut off" > "$TMP/state" ;;
            managedsave-remove) rm -f "$TMP/saved" ;;
            start) rm -f "$TMP/saved"; echo running > "$TMP/state" ;;
            resume) echo running > "$TMP/state" ;;
            shutdown) echo "shut off" > "$TMP/state" ;;
            snapshot-list) echo clean ;;
            snapshot-revert) echo running > "$TMP/state" ;;   # leaves a save image, as libvirt does
        esac
    }
}

test_vm_state() {
    . "$DEVVM"
    stub_vm running;          assert_eq "$(vm_state)" running
    stub_vm "shut off";       assert_eq "$(vm_state)" "shut off"
    stub_vm "shut off" saved; assert_eq "$(vm_state)" saved
    stub_vm paused;           assert_eq "$(vm_state)" paused
}

test_save_and_start() {
    . "$DEVVM"
    stub_vm running
    out=$(cmd_save)
    assert_contains "$out" "is saved and stopped"
    assert_contains "$(cat "$TMP/calls")" "managedsave $DEVVM_VM_NAME --running"
    assert_eq "$(vm_state)" saved
    assert_contains "$(cmd_save)" "already saved"
    out=$(cmd_start)
    assert_contains "$out" "Restored $DEVVM_VM_NAME from its saved state"
    assert_contains "$out" "is up, at 192.0.2.1"
    assert_eq "$(vm_state)" running
    assert_contains "$(cat "$TMP/calls")" "ssh -o ConnectTimeout=10 sudo date -u -s @"
}

test_start_of_a_vm_that_was_shut_off_leaves_the_clock() {
    . "$DEVVM"
    stub_vm "shut off"
    assert_contains "$(cmd_start)" "Started $DEVVM_VM_NAME"
    assert_not_contains "$(cat "$TMP/calls")" "sudo date"
}

test_save_a_vm_that_is_shut_off() {
    . "$DEVVM"
    stub_vm "shut off"
    assert_contains "$(cmd_save)" "nothing to save"
    assert_not_contains "$(cat "$TMP/calls")" managedsave
}

test_start_continues_a_paused_vm() {
    . "$DEVVM"
    stub_vm paused
    out=$(cmd_start)
    assert_contains "$out" "Resumed $DEVVM_VM_NAME, which was paused"
    assert_contains "$(cat "$TMP/calls")" "resume $DEVVM_VM_NAME"
    assert_not_contains "$(cat "$TMP/calls")" "start $DEVVM_VM_NAME"
    assert_contains "$(cat "$TMP/calls")" "sudo date"
    assert_eq "$(vm_state)" running
}

test_ssh_to_a_saved_or_paused_vm_says_so() {
    . "$DEVVM"
    stub_vm "shut off" saved
    assert_fails require_ip
    assert_contains "$(cat "$TMP/out")" "is saved to disk, see: "
    stub_vm paused
    assert_fails require_ip
    assert_contains "$(cat "$TMP/out")" "is paused, see: $PROG start"
}

test_reset_discards_a_saved_state_before_the_revert() {
    . "$DEVVM"
    stub_vm "shut off" saved
    out=$(cmd_reset)
    assert_contains "$out" "Discarded the saved state"
    [ ! -e "$TMP/saved" ] || fail "the save image survived the reset"
    [ "$(grep -n managedsave-remove "$TMP/calls" | cut -d: -f1)" -lt \
      "$(grep -n snapshot-revert "$TMP/calls" | cut -d: -f1)" ] || fail "removed after the revert"
}

test_reset_without_a_saved_state() {
    . "$DEVVM"
    stub_vm running
    assert_not_contains "$(cmd_reset)" "Discarded"
    assert_not_contains "$(cat "$TMP/calls")" managedsave-remove
}

test_snapshot_of_a_saved_vm_is_refused() {
    . "$DEVVM"
    stub_vm "shut off" saved
    assert_fails cmd_snapshot dev
    assert_contains "$(cat "$TMP/out")" "is saved to disk"
    assert_not_contains "$(cat "$TMP/calls")" snapshot-create
}

test_stop_of_a_saved_vm_keeps_it() {
    . "$DEVVM"
    stub_vm "shut off" saved
    assert_contains "$(cmd_stop)" "is saved to disk, not running"
    assert_not_contains "$(cat "$TMP/calls")" shutdown
    [ -e "$TMP/saved" ] || fail "stop discarded the saved state"
}

test_stop_of_a_paused_vm_resumes_it_first() {
    . "$DEVVM"
    stub_vm paused
    assert_contains "$(cmd_stop)" "is shut off"
    assert_eq "$(grep -E '^(resume|shutdown)' "$TMP/calls")" "resume $DEVVM_VM_NAME
shutdown $DEVVM_VM_NAME"
}

test_destroy_removes_a_saved_state() {
    . "$DEVVM"
    stub_vm "shut off" saved
    cmd_destroy -y > /dev/null
    assert_contains "$(cat "$TMP/calls")" "undefine $DEVVM_VM_NAME --managed-save"
}

test_status_and_ls_show_saved() {
    . "$DEVVM"
    stub_vm "shut off" saved
    vm_workspace() { :; }
    missing_shares() { :; }
    assert_contains "$(cmd_status)" "State:      saved (to disk; "
    eval "$(declare -f virsh | sed 's/^virsh ()/stub_virsh ()/')"
    virsh() {
        if [ "$1 ${2:-}" = "list --all" ]; then echo "$DEVVM_VM_NAME"; else stub_virsh "$@"; fi
    }
    cmd_ls -a | grep -q "$DEVVM_VM_NAME *saved " || fail "ls: $(cmd_ls -a)"
}

run_tests
