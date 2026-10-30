#!/bin/sh
# Build kibitz and install it to ~/.local/bin
set -e
cd "$(dirname "$0")"
zig build-exe src/main.zig -lc -O ReleaseFast --name kibitz
install -m 755 kibitz "$HOME/.local/bin/kibitz"
echo "installed $HOME/.local/bin/kibitz"
