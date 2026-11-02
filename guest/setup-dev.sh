#!/bin/bash
# Runs inside the VM (run by `devvm setup-dev`): git identity and Claude Code.
# Usage: setup-dev.sh GIT_USER_NAME GIT_USER_EMAIL
set -euo pipefail

[ -n "${1:-}" ] && git config --global user.name "$1"
[ -n "${2:-}" ] && git config --global user.email "$2"

if [ ! -x "$HOME/.local/bin/claude" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
fi
"$HOME/.local/bin/claude" --version
