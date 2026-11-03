#!/bin/sh
# Install devvm for the current user: link the devvm command into DEVVM_BIN_DIR. Run from a
# clone, it links that clone; otherwise it clones the repository into DEVVM_INSTALL_DIR
# first. Running it again updates (git pull --ff-only); so does `devvm update`.
#
#   git clone https://github.com/modama-rdm/devvm ~/.local/share/devvm
#   ~/.local/share/devvm/install.sh
#
# Settings (environment): DEVVM_GIT_URL, DEVVM_INSTALL_DIR (default ~/.local/share/devvm),
# DEVVM_BIN_DIR (default ~/.local/bin).
set -eu

REPO=${DEVVM_GIT_URL:-https://github.com/modama-rdm/devvm}
DEVVM_BIN_DIR=${DEVVM_BIN_DIR:-$HOME/.local/bin}

here=$(cd "$(dirname "$0")" && pwd)
if [ -x "$here/devvm" ] && git -C "$here" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    DIR=$here
else
    DIR=${DEVVM_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/devvm}
    if [ ! -d "$DIR/.git" ]; then
        git clone "$REPO" "$DIR"
    fi
fi
git -C "$DIR" pull --ff-only
[ -x "$DIR/devvm" ] || { echo "No devvm command in $DIR" >&2; exit 1; }

mkdir -p "$DEVVM_BIN_DIR"
if [ -e "$DEVVM_BIN_DIR/devvm" ] && [ ! -L "$DEVVM_BIN_DIR/devvm" ]; then
    echo "$DEVVM_BIN_DIR/devvm exists and is not a symlink, not replacing it" >&2
    exit 1
fi
ln -sfn "$DIR/devvm" "$DEVVM_BIN_DIR/devvm"
echo "Linked $DEVVM_BIN_DIR/devvm -> $DIR/devvm ($(git -C "$DIR" describe --tags --always --dirty))"

case ":$PATH:" in
    *":$DEVVM_BIN_DIR:"*) ;;
    *) echo "$DEVVM_BIN_DIR is not on PATH; add it, e.g. in ~/.profile:"
       echo "    PATH=\"$DEVVM_BIN_DIR:\$PATH\"" ;;
esac
command -v virt-install > /dev/null 2>&1 ||
    echo "virt-install not found; see the prerequisites in $DIR/README.md"
[ -f "$HOME/.config/devvm/site.env" ] || echo "Next: devvm setup"
