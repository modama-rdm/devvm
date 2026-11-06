#!/bin/bash
# Runs inside the VM (run by `devvm setup-dev`): git identity, Claude Code, and the tools
# of the kaizen:hallway-test skill for judging a terminal by eye (Xvfb, xterm, xdotool,
# ImageMagick), the kaizen plugin of the author's skills (github.com/uellue/skills) and
# the two companions it recommends: Matt Pocock's skills (github.com/mattpocock/skills)
# and OpenSpec (github.com/Fission-AI/OpenSpec) with Node.js, telemetry off.
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
    if ! grep -qF 'export CLAUDE_CODE_OAUTH_TOKEN=' ~/.bashrc; then
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

# The companions kaizen recommends; Matt Pocock's skills at user scope like kaizen
if ! "$claude" plugin list 2> /dev/null | grep -q 'mattpocock-skills@mattpocock'; then
    "$claude" plugin marketplace add mattpocock/skills < /dev/null
    "$claude" plugin install mattpocock-skills@mattpocock --scope user < /dev/null
fi

# OpenSpec needs Node.js >= 22.12; Debian 13's is older. The latest 22 LTS from
# nodejs.org, checksum verified, into ~/.local (no root, no apt source); the guest is amd64.
if [ ! -x "$HOME/.local/bin/node" ]; then
    version=$(curl -fsS https://nodejs.org/dist/index.json |
        python3 -c 'import json, sys; print(next(r["version"] for r in json.load(sys.stdin) if r["version"].startswith("v22.") and r["lts"]))')
    tarball=node-$version-linux-x64.tar.xz
    download=$(mktemp -d)
    curl -fsSo "$download/$tarball" "https://nodejs.org/dist/$version/$tarball"
    curl -fsSo "$download/SHASUMS256.txt" "https://nodejs.org/dist/$version/SHASUMS256.txt"
    (cd "$download" && grep " $tarball\$" SHASUMS256.txt | sha256sum -c --quiet -)
    mkdir -p ~/.local/lib/nodejs ~/.local/bin
    tar -xJf "$download/$tarball" -C ~/.local/lib/nodejs
    rm -r -- "${download:?}"
    for b in node npm npx; do
        ln -sfn "$HOME/.local/lib/nodejs/node-$version-linux-x64/bin/$b" ~/.local/bin/$b
    done
fi
# npm and openspec start with `env node`
export PATH=$HOME/.local/bin:$PATH
node --version

# Telemetry is on unless this is set; at the top of .bashrc like the token above, so that
# non-interactive shells and Claude Code started from them get it too
export OPENSPEC_TELEMETRY=0
touch ~/.bashrc
if ! grep -qF 'export OPENSPEC_TELEMETRY=0' ~/.bashrc; then
    rc=$(cat ~/.bashrc)
    printf '%s\n%s\n' 'export OPENSPEC_TELEMETRY=0  # devvm setup-dev' "$rc" > ~/.bashrc
fi
if [ ! -x "$HOME/.local/bin/openspec" ]; then
    npm config set prefix "$HOME/.local"
    npm install -g --no-fund @fission-ai/openspec < /dev/null
fi
openspec --version
