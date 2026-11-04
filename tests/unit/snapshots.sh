#!/bin/bash
# Snapshot listing in status and snapshot -l. libvirt is replaced by a stub.
# shellcheck disable=SC1090,SC2034,SC2317  # SC2317: stubs, called indirectly
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# virsh snapshot-list prints SNAPSHOTS as its table; the State column is the state of
# the VM when the snapshot was taken, "running" for devvm's live snapshots
stub_virsh() {
    SNAPSHOTS=$1
    require_vm() { :; }
    virsh() {
        case $1 in
            snapshot-list)
                echo " Name    Creation Time               State"
                echo "----------------------------------------------"
                [ -z "$SNAPSHOTS" ] || echo "$SNAPSHOTS"
                echo ;;
        esac
    }
}

test_list_without_the_misleading_state_column() {
    . "$DEVVM"
    stub_virsh " clean   2026-11-03 16:39:10 +0100   running
 dev     2026-11-03 16:40:25 +0100   running"
    out=$(cmd_snapshot -l)
    assert_not_contains "$out" running
    assert_not_contains "$out" State
    assert_contains "$out" "clean     2026-11-03 16:39:10 +0100"
    assert_contains "$out" "dev       2026-11-03 16:40:25 +0100"
}

test_list_a_name_with_spaces() {
    . "$DEVVM"
    stub_virsh " before upgrade   2026-11-03 16:39:10 +0100   running"
    assert_contains "$(cmd_snapshot -l)" "before upgrade  2026-11-03 16:39:10 +0100"
}

test_list_without_snapshots() {
    . "$DEVVM"
    stub_virsh ""
    assert_eq "$(cmd_snapshot -l)" "No snapshots"
}

run_tests
