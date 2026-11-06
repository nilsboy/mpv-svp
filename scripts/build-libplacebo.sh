#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$BUILD_ROOT/libplacebo"

clone_repo https://github.com/haasn/libplacebo.git "$SRC"

meson setup "$SRC/build" "$SRC" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Ddemos=false \
    -Dtests=false
ninja -C "$SRC/build" -j "$JOBS"
install_tree "libplacebo installed" \
    ninja -C "$SRC/build" install

echo "verify: $(pkg-config --modversion libplacebo)"
