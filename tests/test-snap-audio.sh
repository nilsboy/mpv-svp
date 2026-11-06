#!/usr/bin/env bash
# Check that the snap ships the pipewire runtime bits and points mpv at them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$REPO_ROOT/snap/snapcraft.yaml"
LAUNCHER="$REPO_ROOT/snap/bin/mpv-svp"
SNAP="${SNAP_FILE:-$(ls -1 "$REPO_ROOT"/dist/mpv-svp_*.snap 2>/dev/null | head -1 || true)}"

fail=0
require() {
    local file="$1"
    local pattern="$2"
    if ! grep -qE "$pattern" "$file"; then
        echo "FAIL: $file is missing /$pattern/"
        fail=1
    fi
}

echo "==> snapcraft.yaml declares the pipewire plug"
require "$YAML" '^[[:space:]]*-[[:space:]]*pipewire[[:space:]]*$'

echo "==> snapcraft.yaml stages the pipewire runtime"
for pkg in libpipewire-0.3-modules libspa-0.2-modules pipewire-bin; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> launcher points pipewire at the bundled paths"
for var in SPA_PLUGIN_DIR PIPEWIRE_MODULE_DIR PIPEWIRE_CONFIG_DIR PIPEWIRE_RUNTIME_DIR PULSE_SERVER; do
    require "$LAUNCHER" "export $var="
done

if [[ -n "$SNAP" && -f "$SNAP" ]]; then
    if ! command -v unsquashfs >/dev/null; then
        echo "SKIP: unsquashfs not installed, cannot inspect $SNAP"
    else
        echo "==> $SNAP contains pipewire modules and client.conf"
        listing="$(unsquashfs -l "$SNAP" 2>/dev/null)"
        for path in \
            'usr/lib/x86_64-linux-gnu/pipewire-0.3/' \
            'usr/lib/x86_64-linux-gnu/spa-0.2/support/libspa-support.so' \
            'usr/share/pipewire/client.conf'; do
            if ! grep -q "$path" <<<"$listing"; then
                echo "FAIL: $SNAP is missing $path"
                fail=1
            fi
        done
    fi
else
    echo "SKIP: no snap in dist/, rebuild to inspect the payload"
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "PASS: snap ships pipewire audio support"
