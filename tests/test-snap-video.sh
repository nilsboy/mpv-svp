#!/usr/bin/env bash
# Check that mpv exposes the X11 and Wayland video outputs and that the snap
# bundles the libraries they need.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$REPO_ROOT/snap/snapcraft.yaml"
LAUNCHER="$REPO_ROOT/snap/bin/mpv-svp"
MPV="${MPV:-mpv}"
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

echo "==> snapcraft.yaml builds with the X11/Wayland dev packages"
# xscrnsaver is required for mpv to enable X11 at all; without libxss-dev the
# x11, xv, x11egl and x11vk outputs are silently compiled out.
for pkg in libxss-dev libxv-dev libxpresent-dev libxrandr-dev libx11-dev \
           libwayland-dev wayland-protocols; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> snapcraft.yaml stages the X11/Wayland runtime"
for pkg in libxss1 libxv1 libxpresent1 libxrandr2 libgl1 libglx0 libopengl0 \
           libegl-mesa0 libglx-mesa0 libxcb-glx0 libxxf86vm1 \
           libwayland-client0 libwayland-cursor0 libwayland-egl1; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> snapcraft.yaml stages the Vulkan driver"
for pkg in mesa-vulkan-drivers libgl1-mesa-dri libdisplay-info3 libllvm21; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> snapcraft.yaml stages the OpenCL ICDs (SVP renders on OpenCL)"
for pkg in intel-opencl-icd mesa-opencl-icd ocl-icd-libopencl1; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> snapcraft.yaml stages the VA-API drivers (--hwdec)"
for pkg in intel-media-va-driver i965-va-driver libigdgmm12 libva2; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> launcher points the GPU stacks at the bundled drivers"
for var in VK_ADD_DRIVER_FILES LIBGL_DRIVERS_PATH LIBVA_DRIVERS_PATH \
           __EGL_VENDOR_LIBRARY_FILENAMES OCL_ICD_VENDORS; do
    require "$LAUNCHER" "export $var="
done

echo "==> launcher regenerates the OpenCL ICD vendor files"
require "$LAUNCHER" 'intel.icd'
require "$LAUNCHER" 'rusticl.icd'

echo "==> launcher regenerates a stale VSScript config"
require "$LAUNCHER" 'VSS_CONFIG='
require "$LAUNCHER" 'grep -qF'

echo "==> launcher makes WAYLAND_DISPLAY absolute"
require "$LAUNCHER" 'WAYLAND_DISPLAY'

echo "==> launcher resolves the bundled vpy for a relative vapoursynth= path"
require "$LAUNCHER" 'vapoursynth='
require "$LAUNCHER" '\$SNAP/\$_path'
require "$LAUNCHER" '_rest='

echo "==> installed mpv offers x11 and wayland video outputs"
if command -v "$MPV" >/dev/null; then
    vos="$("$MPV" --vo=help 2>&1 || true)"
    for vo in x11 xv wlshm; do
        if ! grep -qE "^[[:space:]]*$vo[[:space:]]" <<<"$vos"; then
            echo "FAIL: $MPV has no '$vo' video output"
            fail=1
        fi
    done
    contexts="$("$MPV" --gpu-context=help 2>&1 || true)"
    for ctx in x11egl wayland; do
        if ! grep -qE "^[[:space:]]*$ctx[[:space:]]" <<<"$contexts"; then
            echo "FAIL: $MPV has no '$ctx' GPU context"
            fail=1
        fi
    done
else
    echo "SKIP: $MPV not installed"
fi

if [[ -n "$SNAP" && -f "$SNAP" ]]; then
    if ! command -v unsquashfs >/dev/null; then
        echo "SKIP: unsquashfs not installed, cannot inspect $SNAP"
    else
        echo "==> $SNAP contains the X11/Wayland runtime"
        listing="$(unsquashfs -l "$SNAP" 2>/dev/null)"
        for path in \
            'usr/lib/x86_64-linux-gnu/libXss.so.1' \
            'usr/lib/x86_64-linux-gnu/libXv.so.1' \
            'usr/lib/x86_64-linux-gnu/libXpresent.so.1' \
            'usr/lib/x86_64-linux-gnu/libGL.so.1' \
            'usr/lib/x86_64-linux-gnu/libGLX.so.0' \
            'usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0' \
            'usr/lib/x86_64-linux-gnu/libxcb-glx.so.0' \
            'usr/lib/x86_64-linux-gnu/libwayland-client.so.0' \
            'usr/lib/x86_64-linux-gnu/libwayland-egl.so.1' \
            'usr/lib/x86_64-linux-gnu/libvulkan_lvp.so' \
            'usr/share/vulkan/icd.d/lvp_icd.json' \
            'usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so' \
            'usr/lib/x86_64-linux-gnu/dri/i965_drv_video.so' \
            'vapoursynth/svp.vpy'; do
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

echo "PASS: mpv exposes X11 and Wayland video outputs"
