#!/bin/bash
# Waiting for SSH in start and wait: a key that needs a passphrase, a VM whose sshd is
# not up yet, a host key mismatch. libvirt and SSH are replaced by stubs.
# shellcheck disable=SC1090,SC2034,SC2317  # SC2317: stubs, called indirectly
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# SSH_ERRORS: one line per probe, the error that probe gets; past the end it succeeds.
# virsh reports the VM as STATE; the probes are counted in $TMP/probes.
stub_vm() {
    STATE=${1:-running}
    require_vm() { :; }
    require_ip() { echo 192.0.2.1; }
    vm_ip() { echo 192.0.2.1; }
    check_shares() { :; }
    eject_cdroms() { :; }
    sleep() { :; }
    virsh() {
        case $1 in
            domstate) echo "$STATE" ;;
            start) STATE=running ;;
        esac
    }
    vm_ssh() {
        local n line
        n=$(( $(cat "$TMP/probes" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$TMP/probes"
        line=$(sed -n "${n}p" <<< "$SSH_ERRORS")
        if [ -n "$line" ]; then echo "$line" >&2; return 255; fi
    }
}

PERMISSION_DENIED='devvm@192.0.2.1: Permission denied (publickey).'
REFUSED='ssh: connect to host 192.0.2.1 port 22: Connection refused'
repeat() { local i; for ((i = 0; i < $1; i++)); do echo "$2"; done; }   # N LINE

test_start_with_a_key_that_needs_a_passphrase() {
    . "$DEVVM"
    stub_vm "shut off"
    SSH_ERRORS=$(echo "$REFUSED"; repeat 200 "$PERMISSION_DENIED")
    out=$(cmd_start 2>&1) || fail "start failed: $out"
    assert_contains "$out" "is up, at 192.0.2.1"
    assert_contains "$out" "ssh-add"
    assert_eq "$(cat "$TMP/probes")" 2 "probes"
}

test_start_retries_until_ssh_answers() {
    . "$DEVVM"
    stub_vm "shut off"
    SSH_ERRORS=$(printf '%s\n' "$REFUSED" "$REFUSED" "$REFUSED")
    out=$(cmd_start 2>&1) || fail "start failed: $out"
    assert_contains "$out" "is up, at 192.0.2.1"
    assert_not_contains "$out" "ssh-add"
    assert_eq "$(cat "$TMP/probes")" 4 "probes"
}

test_start_gives_up_with_the_last_error() {
    . "$DEVVM"
    stub_vm "shut off"
    SSH_ERRORS=$(repeat 200 "$REFUSED")
    assert_fails cmd_start
    assert_contains "$(cat "$TMP/out")" "SSH does not answer yet"
    assert_contains "$(cat "$TMP/out")" "Connection refused"
}

test_start_fails_at_once_on_a_host_key_mismatch() {
    . "$DEVVM"
    stub_vm "shut off"
    SSH_ERRORS="Host key verification failed."
    assert_fails cmd_start
    assert_contains "$(cat "$TMP/out")" "Host key verification failed"
    assert_not_contains "$(cat "$TMP/out")" "does not answer"
    assert_eq "$(cat "$TMP/probes")" 1 "probes"
}

test_start_stops_waiting_when_the_vm_shuts_off() {
    . "$DEVVM"
    stub_vm "shut off"
    SSH_ERRORS=$(repeat 200 "$REFUSED")
    virsh() { [ "$1" != domstate ] || echo "shut off"; }
    assert_fails cmd_start
    assert_contains "$(cat "$TMP/out")" "repo-main is shut off"
    assert_not_contains "$(cat "$TMP/out")" "does not answer"
    assert_eq "$(cat "$TMP/probes")" 1 "probes"
}

test_start_of_a_running_vm_does_nothing() {
    . "$DEVVM"
    stub_vm running
    out=$(cmd_start 2>&1)
    assert_contains "$out" "is already running"
    [ ! -f "$TMP/probes" ] || fail "probed SSH"
}

test_wait_with_a_key_that_needs_a_passphrase() {
    . "$DEVVM"
    stub_vm running
    SSH_ERRORS=$(printf '%s\n' "$REFUSED" "$PERMISSION_DENIED")
    out=$(cmd_wait 2>&1) || fail "wait failed: $out"
    assert_contains "$out" "ssh-add"
    assert_contains "$out" "cloud-init done"
    # two probes, then the one session for cloud-init
    assert_eq "$(cat "$TMP/probes")" 3 "probes"
}

run_tests
