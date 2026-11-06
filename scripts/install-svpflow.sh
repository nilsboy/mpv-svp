#!/usr/bin/env bash
# Fetch, patch and install the GPL SVPflow VapourSynth plugins.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$BUILD_ROOT/svpflow"
ZIP="$SRC/svpflow-${SVPFLOW_VERSION}.zip"

mkdir -p "$SRC"
if [[ ! -f "$ZIP" ]]; then
    curl -fSL --retry 5 -o "$ZIP" "$SVPFLOW_URL"
fi
rm -rf "$SRC/svpflow-${SVPFLOW_VERSION}"
unzip -q -o "$ZIP" -d "$SRC"

PKG="$SRC/svpflow-${SVPFLOW_VERSION}"
PLUGIN_DIR="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/vapoursynth/plugins"

install_tree "SVPflow plugin directory created" \
    mkdir -p "$PLUGIN_DIR"

for so in libsvpflow1_vs64.so libsvpflow2_vs64.so; do
    # The 2019 binaries request an executable stack, which modern glibc refuses
    # to dlopen. None of the code needs it, so clear the GNU_STACK flag.
    cp "$PKG/lib-linux/$so" "$SRC/$so"
    patchelf --clear-execstack "$SRC/$so"
    install_tree "SVPflow plugin installed: $so" \
        install -m644 "$SRC/$so" "$PLUGIN_DIR/$so"
done

install_tree "SVPflow license installed" \
    install -Dm644 "$PKG/licenses/svpflow1_gpl.txt" \
    "$PREFIX/share/licenses/svpflow/svpflow1_gpl.txt"

echo "SVPflow installed to $PLUGIN_DIR"
