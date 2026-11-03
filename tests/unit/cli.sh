#!/bin/bash
# devvm as a command: usage and dispatch
# shellcheck disable=SC1090
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

need_libvirt_group() {
    id -nG | tr ' ' '\n' | grep -qx libvirt || skip "not in the libvirt group"
}

test_usage_lists_every_command() {
    local out rc=0 cmd
    out=$("$DEVVM" 2>&1) || rc=$?
    assert_eq "$rc" 1 "exit status without a command"
    while read -r cmd; do
        grep -q "^  ${cmd//_/-}\b" <<< "$out" || fail "usage does not list ${cmd//_/-}"
    done < <(sed -n 's/^cmd_\([a-z_]*\)() {.*/\1/p' "$DEVVM")
}

test_usage_lists_project_commands() {
    mkdir .devvm
    cat > .devvm/commands.sh <<'EOF'
PROJECT_USAGE+="  hello             greet"
project_cmd_hello() { echo "hello $*"; }
EOF
    assert_contains "$("$DEVVM" 2>&1 || true)" "  hello             greet"
}

test_project_command_with_arguments() {
    need_libvirt_group
    mkdir .devvm
    echo 'project_cmd_say_hello() { printf "[%s]" "$@"; }' > .devvm/commands.sh
    assert_eq "$("$DEVVM" say-hello 'a b' c)" "[a b][c]"
}

test_test_command_without_configuration() {
    need_libvirt_group
    assert_fails "$DEVVM" test
    assert_contains "$(cat "$TMP/out")" "set DEVVM_TEST_COMMAND"
}

test_unknown_command() {
    need_libvirt_group
    assert_fails "$DEVVM" no-such-command
    assert_contains "$(cat "$TMP/out")" "Unknown command: no-such-command"
}

test_missing_site_settings() {
    need_libvirt_group
    rm "$HOME/.config/devvm/site.env"
    assert_fails "$DEVVM" ls
    assert_contains "$(cat "$TMP/out")" "devvm setup"
}


test_snapshot_rejects_option_like_names() {
    need_libvirt_group
    assert_fails "$DEVVM" snapshot --bogus
    assert_contains "$(cat "$TMP/out")" "Invalid snapshot name"
    assert_fails "$DEVVM" reset --bogus
    assert_contains "$(cat "$TMP/out")" "Invalid snapshot name"
}

test_snapshot_help() {
    need_libvirt_group
    assert_contains "$("$DEVVM" snapshot --help 2>&1)" "snapshot -u"
}

test_commands_on_a_missing_vm_say_so_once() {
    need_libvirt_group
    local c
    for c in status ssh ip start stop snapshot "snapshot -l" "snapshot -d x" "snapshot -u x" \
             reset destroy wait push fetch setup-dev "test"; do
        mkdir -p .devvm
        echo "DEVVM_TEST_COMMAND=true" > .devvm/config.env
        # shellcheck disable=SC2086
        assert_fails "$DEVVM" -n nosuch-vm-$RANDOM $c
        assert_eq "$(wc -l < "$TMP/out")" 1 "lines printed by: devvm $c"
        assert_contains "$(cat "$TMP/out")" "No VM nosuch-vm-"
    done
    assert_fails "$DEVVM" status   # without -n: the VM of this checkout
    assert_contains "$(cat "$TMP/out")" "No VM repo-main for this checkout. Create it with: devvm create"
}

test_option_n_needs_a_value() {
    assert_fails "$DEVVM" -n
    assert_eq "$(cat "$TMP/out")" "-n needs a VM name (see: devvm ls -a)"
}

test_help_goes_to_stdout_with_status_0() {
    local a
    for a in --help -h help; do
        assert_contains "$("$DEVVM" $a 2>/dev/null)" "Usage: devvm"
    done
}

test_unknown_command_error_comes_last() {
    need_libvirt_group
    assert_fails "$DEVVM" frobnicate
    assert_contains "$(tail -n 1 "$TMP/out")" "Unknown command: frobnicate"
}

test_commands_reject_arguments_they_do_not_take() {
    need_libvirt_group
    local c
    for c in "ls extra" "ls --bogus" "ls -a extra" "version x" "wait x" "ip x" "start x" \
             "stop x" "status x" "status -v x" "reset a b" "destroy x" "destroy -y x" "prune x" \
             "fetch x" "push a b" "setup-dev x"; do
        # shellcheck disable=SC2086
        assert_fails "$DEVVM" $c
        assert_eq "$(wc -l < "$TMP/out")" 1 "lines printed by: devvm $c"
    done
}

run_tests
