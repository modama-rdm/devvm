#!/bin/bash
# Runs inside the VM (run by `devvm setup-dev`): git identity and Claude Code.
# Usage: setup-dev.sh GIT_USER_NAME GIT_USER_EMAIL [--claude-token-stdin]
# With --claude-token-stdin, a Claude Code token (from `claude setup-token` on the host)
# is read from stdin and exported as CLAUDE_CODE_OAUTH_TOKEN to the VM user's shells.
set -euo pipefail

[ -n "${1:-}" ] && git config --global user.name "$1"
[ -n "${2:-}" ] && git config --global user.email "$2"

if [ "${3:-}" = --claude-token-stdin ]; then
    token_file=~/.config/devvm/claude-oauth-token
    mkdir -p "$(dirname "$token_file")"
    (umask 077 && tr -d '[:space:]' > "$token_file")
    [ -s "$token_file" ] || { echo "Empty Claude Code token" >&2; exit 1; }
    # At the top of .bashrc, before its early return for non-interactive shells: also
    # commands run with `devvm ssh CMD` get the token. Login shells source .bashrc too.
    # shellcheck disable=SC2016  # expanded by .bashrc, not here
    line='[ -r ~/.config/devvm/claude-oauth-token ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat ~/.config/devvm/claude-oauth-token)"  # devvm setup-dev'
    touch ~/.bashrc
    if ! grep -qF '# devvm setup-dev' ~/.bashrc; then
        rc=$(cat ~/.bashrc)
        printf '%s\n%s\n' "$line" "$rc" > ~/.bashrc
    fi
    echo "Claude Code token installed in $token_file"
fi

if [ ! -x "$HOME/.local/bin/claude" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
fi
"$HOME/.local/bin/claude" --version
