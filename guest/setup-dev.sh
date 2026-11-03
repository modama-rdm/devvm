#!/bin/bash
# Runs inside the VM (run by `devvm setup-dev`): git identity, Claude Code, and the tools
# of the kaizen:hallway-test skill for judging a terminal by eye (Xvfb, xterm, xdotool,
# ImageMagick), and the kaizen plugin of the author's skills (github.com/uellue/skills).
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

# Debian packages; stdin from /dev/null, as stdin may carry the token above
tools=(xvfb xterm xdotool imagemagick)
missing=()
for p in "${tools[@]}"; do
    dpkg -s "$p" > /dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    sudo apt-get update -qq < /dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" < /dev/null
fi

if [ ! -x "$HOME/.local/bin/claude" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
fi
claude=$HOME/.local/bin/claude
"$claude" --version

# Dieter Weber's personal skills, at user scope; skipped when already installed
if ! "$claude" plugin list 2> /dev/null | grep -q 'kaizen@uellue'; then
    "$claude" plugin marketplace add uellue/skills < /dev/null
    "$claude" plugin install kaizen@uellue --scope user < /dev/null
fi
