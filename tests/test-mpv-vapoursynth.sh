#!/usr/bin/env bash
# Check that mpv was built with the VapourSynth filter.
set -euo pipefail

MPV="${MPV:-mpv}"

if ! command -v "$MPV" >/dev/null; then
    echo "SKIP: $MPV not installed"
    exit 0
fi

echo "==> $MPV --version"
# Capture first: piping into head can SIGPIPE mpv, which `pipefail` reports as
# a failure even though the command itself worked.
version="$("$MPV" --version)"
printf '%s\n' "$version" | sed -n '1,3p'

echo "==> vapoursynth filter options"
if ! "$MPV" --vf=vapoursynth=help >/dev/null 2>&1; then
    echo "FAIL: mpv has no vapoursynth filter"
    exit 1
fi

"$MPV" --vf=vapoursynth=help

echo "PASS: vapoursynth filter available"
