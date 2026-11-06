#!/usr/bin/env bash
# Check that the snap bundles the SVPflow plugins and the VapourSynth R79
# runtime they need (API 3).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$REPO_ROOT/snap/snapcraft.yaml"
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

echo "==> snapcraft.yaml pins VapourSynth to R79 (last API 3 release)"
require "$YAML" 'source-tag:[[:space:]]*R79'

echo "==> snapcraft.yaml patches the SVPflow executable stack"
require "$YAML" 'clear-execstack'

echo "==> snapcraft.yaml fetches the SVPflow GPL release"
require "$YAML" 'svpflow'

if [[ -n "$SNAP" && -f "$SNAP" ]]; then
    if ! command -v unsquashfs >/dev/null; then
        echo "SKIP: unsquashfs not installed, cannot inspect $SNAP"
    else
        echo "==> $SNAP contains the SVPflow plugins and VapourSynth runtime"
        listing="$(unsquashfs -l "$SNAP" 2>/dev/null)"
        for path in \
            'usr/lib/vapoursynth/libsvpflow1_vs64.so' \
            'usr/lib/vapoursynth/libsvpflow2_vs64.so' \
            'usr/lib/python3/dist-packages/vapoursynth/libvsscript.so' \
            'usr/lib/python3/dist-packages/vapoursynth/libvapoursynth.so.4'; do
            if ! grep -q "$path" <<<"$listing"; then
                echo "FAIL: $SNAP is missing $path"
                fail=1
            fi
        done

        echo "==> SVPflow plugins do not request an executable stack"
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' EXIT
        unsquashfs -q -f -d "$work" "$SNAP" \
            'usr/lib/vapoursynth/libsvpflow1_vs64.so' \
            'usr/lib/vapoursynth/libsvpflow2_vs64.so' >/dev/null 2>&1 || true
        for so in "$work"/usr/lib/vapoursynth/libsvpflow*_vs64.so; do
            [[ -e "$so" ]] || continue
            if readelf -l "$so" 2>/dev/null | grep -q 'GNU_STACK.*RWE'; then
                echo "FAIL: $(basename "$so") still has an executable stack"
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

echo "PASS: snap ships SVPflow plugins"
