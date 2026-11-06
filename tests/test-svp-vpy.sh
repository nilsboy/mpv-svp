#!/usr/bin/env bash
# Run a synthetic YUV clip through svp.vpy with vspipe and check that SVP
# raises the frame rate to the configured target, including per-invocation
# overrides passed through mpv's `user-data` mechanism.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPY="$REPO_ROOT/vapoursynth/svp.vpy"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v vspipe >/dev/null; then
    echo "SKIP: vspipe not installed"
    exit 0
fi

echo "==> syntax check"
python3 -c "import ast,sys; ast.parse(open('$VPY').read())"

# mpv provides video_in and container_fps; emulate both for vspipe. The clip is
# small and short so the CPU fallback used on GPU-less hosts still finishes
# quickly, but large enough for SVP's motion-search pyramid (>= 96px). The
# user_data variable mirrors mpv's `user-data` suboption.
write_harness() {
    local out="$1" user_data="$2"
    cat > "$out" <<EOF
import vapoursynth as vs
core = vs.core
video_in = core.std.BlankClip(width=128, height=128, length=4, fpsnum=24,
                              fpsden=1, format=vs.YUV420P8)
video_in = core.std.Expr(video_in, expr=["x 4 +", "x 4 +", "x 4 +"])
video_in = core.std.SetFrameProps(video_in, _Matrix=6, _Range=1)
container_fps = 24.0
user_data = $user_data
exec(compile(open("$VPY").read(), "$VPY", "exec"))
EOF
}

info_for() {
    local harness="$1"
    if ! vspipe --info "$harness" > "$WORK/info.txt" 2> "$WORK/err.txt"; then
        if grep -qiE "no function named|LoadPlugin|svp" "$WORK/err.txt"; then
            echo "SKIP: SVPflow plugins not available"
            cat "$WORK/err.txt"
            exit 0
        fi
        echo "FAIL: vspipe failed"
        cat "$WORK/err.txt"
        exit 1
    fi
}

check() {
    local label="$1" harness="$2" want_frames="$3" want_fps="$4"
    info_for "$harness"
    local frames fps
    frames="$(sed -n 's/^Frames: //p' "$WORK/info.txt")"
    fps="$(sed -n 's/^FPS: //p' "$WORK/info.txt")"
    if [[ "$frames" != "$want_frames" ]]; then
        echo "FAIL: $label: expected $want_frames frames, got '$frames'"
        cat "$WORK/info.txt"
        exit 1
    fi
    if [[ "$fps" != "$want_fps"* ]]; then
        echo "FAIL: $label: expected fps '$want_fps', got '$fps'"
        exit 1
    fi
    echo "PASS: $label -> $frames frames @$fps"
}

# Default: 4 frames at 24 fps, absolute 60 fps target -> 8 frames.
echo "==> default target"
write_harness "$WORK/default.vpy" '""'
check "default" "$WORK/default.vpy" "8" "60/1"

# Absolute override via a bare number, as passed to mpv's user-data.
echo "==> user-data bare 48 (absolute fps)"
write_harness "$WORK/u48.vpy" '"48"'
check "user-data=48" "$WORK/u48.vpy" "7" "48/1"

# Named fps override.
echo "==> user-data fps=48"
write_harness "$WORK/fps48.vpy" '"fps=48"'
check "user-data=fps=48" "$WORK/fps48.vpy" "7" "48/1"

# Rational target rate (NTSC film).
echo "==> user-data fps=48000/1001"
write_harness "$WORK/ntsc.vpy" '"fps=48000/1001"'
check "user-data=fps=48000/1001" "$WORK/ntsc.vpy" "6" "48000/1001"

# Multiplier form: 24 fps x 3 = 72 fps.
echo "==> user-data rate=3"
write_harness "$WORK/rate3.vpy" '"rate=3"'
check "user-data=rate=3" "$WORK/rate3.vpy" "10" "72/1"

# Multiple tokens, as mpv passes them (semicolon separated).
echo "==> user-data fps=48;preset=balanced"
write_harness "$WORK/multi.vpy" '"fps=48;preset=balanced"'
check "user-data=fps=48;preset=balanced" "$WORK/multi.vpy" "7" "48/1"

# The "realtime" preset and the CPU-reduction options must still produce the
# configured rate (they change search effort, not the output rate).
echo "==> user-data preset=realtime"
write_harness "$WORK/rt.vpy" '"48;preset=realtime"'
check "user-data=48;preset=realtime" "$WORK/rt.vpy" "7" "48/1"

echo "==> user-data scale=0.5 keeps the output size and rate"
cat > "$WORK/scale.vpy" <<EOF
import vapoursynth as vs
core = vs.core
video_in = core.std.BlankClip(width=256, height=256, length=4, fpsnum=24,
                              fpsden=1, format=vs.YUV420P8)
video_in = core.std.Expr(video_in, expr=["x 4 +", "x 4 +", "x 4 +"])
video_in = core.std.SetFrameProps(video_in, _Matrix=6, _Range=1)
container_fps = 24.0
user_data = "48;scale=0.5"
exec(compile(open("$VPY").read(), "$VPY", "exec"))
EOF
info_for "$WORK/scale.vpy"
frames="$(sed -n 's/^Frames: //p' "$WORK/info.txt")"
fps="$(sed -n 's/^FPS: //p' "$WORK/info.txt")"
width="$(sed -n 's/^Width: //p' "$WORK/info.txt")"
height="$(sed -n 's/^Height: //p' "$WORK/info.txt")"
if [[ "$frames" != "7" || "$fps" != "48/1"* || "$width" != "256" || "$height" != "256" ]]; then
    echo "FAIL: user-data=48;scale=0.5: got $frames frames, $fps, ${width}x${height}"
    exit 1
fi
echo "PASS: user-data=48;scale=0.5 -> $width x $height, $frames frames @$fps"

echo "==> user-data coarse=480 and skipfinest run"
write_harness "$WORK/coarse.vpy" '"coarse=480"'
check "user-data=coarse=480" "$WORK/coarse.vpy" "8" "60/1"
write_harness "$WORK/skip.vpy" '"skipfinest=1"'
check "user-data=skipfinest=1" "$WORK/skip.vpy" "8" "60/1"

echo "PASS: user-data overrides are honoured"
