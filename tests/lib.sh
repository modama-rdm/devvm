# shellcheck shell=bash disable=SC2034  # DEVVM, ROOT: used by the test files
# Test helpers, sourced by the test files. A test file defines functions test_*,
# sources this file and ends with: run_tests
# Each test runs in a subshell with errexit, in a fresh environment (setup_env), and
# passes unless it fails or exits non-zero. Output is shown for failing tests only.
# Exit code 77 skips a test (as automake does), e.g. when a prerequisite is missing.

# setup_env replaces HOME; the e2e tests read the real site settings from here
REAL_HOME=$HOME
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$TESTS_DIR")
DEVVM=$ROOT/devvm

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*" >&2; exit 77; }

assert_eq() {   # ACTUAL EXPECTED [WHAT]
    [ "$1" = "$2" ] || fail "${3:-value}: expected [$2], got [$1]"
}
assert_contains() {   # HAYSTACK NEEDLE
    case "$1" in *"$2"*) ;; *) fail "expected [$2] in: $1" ;; esac
}
assert_not_contains() {
    case "$1" in *"$2"*) fail "unexpected [$2] in: $1" ;; esac
}
# Runs CMD... in a subshell, which must fail; its output goes to $TMP/out
assert_fails() {
    if ( "$@" ) > "$TMP/out" 2>&1; then
        fail "expected to fail: $* (output: $(cat "$TMP/out"))"
    fi
}

git_q() { git -c user.name=Test -c user.email=test@example.invalid "$@"; }

# A fresh HOME with site settings and a key, and a project repository on branch main
# as the current directory; nothing of the caller's DEVVM_* settings
setup_env() {
    local v
    for v in $(compgen -v DEVVM_ || true); do unset "$v"; done
    TMP=$(mktemp -d)
    export HOME=$TMP/home
    mkdir -p "$HOME/.config/devvm" "$TMP/pool" "$TMP/repo"
    ssh-keygen -q -t ed25519 -N '' -C test -f "$TMP/key"
    cat > "$HOME/.config/devvm/site.env" <<EOF
DEVVM_POOL_DIR=$TMP/pool
DEVVM_SSH_PUBKEY_FILE=$TMP/key.pub
EOF
    cd "$TMP/repo"
    git_q init -q -b main
    git_q commit -q --allow-empty -m init
}

run_tests() {
    local t out rc failed=0 passed=0 skipped=0
    for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
        # Not in a condition: there, errexit would be off in the subshell
        set +e
        if [ -n "${TESTS_VERBOSE:-}" ]; then
            # Long tests: their output as it comes
            echo "  ...   $t"
            (set -e; setup_env; trap 'rm -rf "$TMP"' EXIT; "$t") 2>&1 | sed -u 's/^/        /'
            rc=${PIPESTATUS[0]}
            out=
        else
            out=$(set -e; setup_env; trap 'rm -rf "$TMP"' EXIT; "$t" 2>&1)
            rc=$?
        fi
        set -e
        case $rc in
            0) passed=$((passed + 1)); echo "  ok    $t" ;;
            77) skipped=$((skipped + 1)); echo "  skip  $t: ${out##*SKIP: }" ;;
            *) failed=$((failed + 1)); echo "  FAIL  $t (exit $rc)"; printf '        %s\n' "${out//$'\n'/$'\n'        }" ;;
        esac
    done
    echo "  $(basename "$0"): $passed passed, $failed failed, $skipped skipped"
    [ "$failed" -eq 0 ]
}
