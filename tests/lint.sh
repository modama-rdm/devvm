#!/bin/bash
# Lint: shellcheck on all shell scripts of devvm
set -euo pipefail
cd "$(dirname "$0")/.."
command -v shellcheck > /dev/null || { echo "  shellcheck is not installed" >&2; exit 1; }
# -x: follow the files that the scripts source, relative to the repository root
files=(devvm install.sh guest/*.sh .devvm/*.sh tests/*.sh tests/unit/*.sh tests/e2e/*.sh)
if shellcheck -x "${files[@]}"; then
    echo "  ok    shellcheck (${#files[@]} files)"
else
    echo "  FAIL  shellcheck"
    exit 1
fi
