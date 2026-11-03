#!/bin/bash
# devvm's tests. Usage: tests/run.sh [SUITE|FILE...]
#   lint   shellcheck, seconds
#   unit   devvm's functions and commands without VMs, seconds
#   e2e    real VMs: create, wait, ssh, test, reset, destroy; minutes, needs KVM and
#          libvirt, and downloads the base image once into the pool
#   all    all of them
# Default: lint unit. A FILE runs one test file, e.g. tests/unit/mounts.sh.
# From the host, in the project's VM reset to "clean": devvm test [SUITE|FILE...]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)

[ $# -gt 0 ] || set -- lint unit
args=()
for a; do
    if [ "$a" = all ]; then args+=(lint unit e2e); else args+=("$a"); fi
done

rc=0
for a in "${args[@]}"; do
    case $a in
        lint) echo "== lint"; bash "$here/lint.sh" || rc=1 ;;
        unit|e2e)
            for f in "$here/$a"/*.sh; do
                echo "== $a/$(basename "$f")"
                bash "$f" || rc=1
            done ;;
        *)
            if [ -f "$a" ]; then
                echo "== $a"
                bash "$a" || rc=1
            else
                sed -n '2,/^set /{/^set /d;s/^# \{0,1\}//p}' "$0" >&2
                exit 2
            fi ;;
    esac
done
[ $rc -eq 0 ] && echo "All passed" || echo "Some tests FAILED"
exit $rc
