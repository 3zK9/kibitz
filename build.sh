#!/bin/sh
# Build revdiff and install it to ~/.local/bin
set -e
cd "$(dirname "$0")"
zig build-exe src/main.zig -lc -O ReleaseFast --name revdiff
install -m 755 revdiff "$HOME/.local/bin/revdiff"
echo "installed $HOME/.local/bin/revdiff"
