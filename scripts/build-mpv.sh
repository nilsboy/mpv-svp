#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$BUILD_ROOT/mpv"

clone_repo https://github.com/mpv-player/mpv.git "$SRC"

meson setup "$SRC/build" "$SRC" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dvapoursynth=enabled \
    -Dlibmpv=true \
    -Dcplayer=true \
    -Dmanpage-build=disabled
ninja -C "$SRC/build" -j "$JOBS"
install_tree "mpv installed" \
    ninja -C "$SRC/build" install

echo "verify: $PREFIX/bin/mpv"
"$PREFIX/bin/mpv" --version | head -3
"$PREFIX/bin/mpv" --vf=vapoursynth=help 2>&1 | grep -i vapoursynth || true
