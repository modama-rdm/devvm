#!/bin/bash
# devvm test: options, quoting of the arguments, exit status. The VM is replaced by
# stubs; the command devvm would run over SSH runs locally instead.
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

# A test command that prints its arguments and exits with the first one
write_run_sh() {
    mkdir -p "$1"
    cat > "$1/run.sh" <<'EOF'
#!/bin/sh
echo "pwd=$PWD n=$#"
for a; do echo "[$a]"; done
exit "${1:-0}"
EOF
    chmod +x "$1/run.sh"
}

# Stubs, after sourcing devvm; WS is what vm_workspace reports
stub_vm() {
    WS=$TMP/ws
    write_run_sh "$WS"
    cmd_reset() { echo "reset $*" >> "$TMP/calls"; }
    cmd_push() { echo "push $*" >> "$TMP/calls"; }
    vm_workspace() { echo "$WS"; }
    vm_ssh() { [ $# -eq 1 ] || fail "vm_ssh with $# arguments"; bash -c "$1"; }
    : > "$TMP/calls"
}

test_resets_and_passes_arguments() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    out=$(cmd_test 0 'a b' "c'd" '$HOME' '*' ';' '' $'new\nline')
    assert_eq "$(cat "$TMP/calls")" "reset clean"
    assert_eq "$out" "pwd=$WS n=8
[0]
[a b]
[c'd]
[\$HOME]
[*]
[;]
[]
[new
line]"
}

test_no_arguments() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    assert_eq "$(cmd_test)" "pwd=$WS n=0"
}

test_command_with_shell_syntax() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND='X=1 ./run.sh first'
    stub_vm
    assert_eq "$(cmd_test second)" "pwd=$WS n=2
[first]
[second]"
}

test_exit_status() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    local rc=0
    (cmd_test 3 > /dev/null) || rc=$?
    assert_eq "$rc" 3 "exit status"
}

test_options() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    cmd_test --no-reset > /dev/null
    assert_eq "$(cat "$TMP/calls")" ""
    cmd_test --snapshot dev > /dev/null
    assert_eq "$(cat "$TMP/calls")" "reset dev"
    : > "$TMP/calls"
    # After --, devvm's options go to the tests
    assert_contains "$(cmd_test --no-reset -- 0 --no-reset || true)" "[--no-reset]"
    assert_eq "$(cat "$TMP/calls")" ""
    assert_fails cmd_test --snapshot
}

test_unshared_vm_gets_a_push() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    WS=''
    write_run_sh "$HOME/repo"
    assert_eq "$(cmd_test)" "pwd=$HOME/repo n=0"
    assert_eq "$(cat "$TMP/calls")" "reset clean
push "
}

test_login_shell() {
    . "$DEVVM"
    DEVVM_TEST_COMMAND='echo "$PATH"'
    stub_vm
    mkdir -p "$HOME/.local/bin"
    printf 'PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.profile"
    assert_contains "$(cmd_test)" "$HOME/.local/bin"
}

test_without_test_command() {
    . "$DEVVM"
    stub_vm
    assert_fails cmd_test
    assert_contains "$(cat "$TMP/out")" "set DEVVM_TEST_COMMAND"
    assert_eq "$(cat "$TMP/calls")" "" "no reset"
}

test_project_command_takes_precedence() {
    mkdir .devvm
    echo 'project_cmd_test() { echo "project: $*"; }' > .devvm/commands.sh
    . "$DEVVM"
    DEVVM_TEST_COMMAND=./run.sh
    stub_vm
    assert_eq "$(cmd_test --no-reset 'a b')" "project: --no-reset a b"
    assert_eq "$(cat "$TMP/calls")" ""
}

run_tests
