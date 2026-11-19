# Notes

## Integration path

SVP is exposed to mpv through VapourSynth. mpv must be built with
`-Dvapoursynth=enabled`; the `vapoursynth` video filter then loads a `.vpy`
script that reads `video_in` and writes `video_out`.

Unlike RIFE, SVP's interpolation runs entirely inside the `svpflow1`/`svpflow2`
VapourSynth plugins, so no SVP Manager process is required on Linux.

- `svpflow1` searches for motion vectors: `Super` then `Analyse`.
- `svpflow2` renders the interpolated frames: `SmoothFps`.

## VapourSynth API 3 constraint

The GPL `svpflow` release (4.3.0.168, 2019) is built against VapourSynth API 3.
VapourSynth R79 is the last release that accepts API 3 plugins; R80 removed the
API 3 compatibility layer, so loading `libsvpflow*_vs64.so` under R80 fails with
`uses API 3, which is no longer supported`. The project therefore pins
VapourSynth to **R79** everywhere (host build and snap).

R79 still ships both `VapourSynth.h` (API 3) and `VapourSynth4.h` (API 4), and
modern mpv/vspipe initialise it through the API 4 entry points, so pinning R79
does not cost anything for the `std`/`resize` filters used here.

## Executable-stack flag

The 2019 Linux `svpflow` binaries were linked with an executable stack
(`GNU_STACK RWE`). Modern glibc refuses to `dlopen` such objects
(`cannot enable executable stack as shared object requires: Invalid argument`).
`scripts/install-svpflow.sh` and the snap's `override-build` clear the
`GNU_STACK` flag with `patchelf --clear-execstack` before installing. None of
the code needs an executable stack.

## No SVP Manager / no watermark

SVP's documentation warns that the libs "require a SVP Manager running,
otherwise you'll see a red rectangle around the video frame". That enforcement
belongs to the closed-source `svpflow2` on Windows/macOS. The Linux GPL build
used here renders clean frames with no Manager: a synthetic clip through
`Super`/`Analyse`/`SmoothFps` produced zero red-border pixels across the tested
frames.

## GPU rendering

`SmoothFps` `gpu` uses **OpenCL**, not Vulkan (`svpflow2` imports
`clReleaseMemObject`). On an Intel iGPU the OpenCL runtime is
`intel-opencl-icd` (Intel Compute Runtime / NEO), which the snap must bundle
along with its ICD file. Without a usable OpenCL device, set `GPU_ID = 0` to
render on the CPU, or SVP falls back to CPU automatically.

The target i3-1315U has an Iris Xe (UHD) iGPU (Alder Lake), which Intel's NEO
runtime supports. The test host here is a QEMU VM with a virtual VGA
(`1234:1111`) and no OpenCL device, so GPU interpolation cannot be benchmarked
on this machine; CPU rendering verifies the pipeline.

## Environment observations

- Build host: Ubuntu 26.04, x86_64, 4 cores, ~7.7 GB RAM. Disk is tight
  (~3 GB free), so build trees under `/var/tmp` must be pruned after install.
- No usable GPU and no display: QEMU virtual VGA, no `/dev/dri`, session type
  `tty`. Wayland/PipeWire runtime behaviour can only be reasoned about, not
  exercised, here.
- Ubuntu 26.04 does not package VapourSynth, so it is built from source (or, on
  the host, taken from the `vapoursynth==79` wheel) and mpv is built with
  `-Dvapoursynth=enabled`.
- `snapcraft` 9.1.3 is installed; `snapcraft pack --destructive-mode` on the
  core26 base avoids LXD and reuses host build packages.

## SVPflow plugin source

The plugins are distributed by SVP as a GPL zip
(`https://www.svp-team.com/files/gpl/svpflow-4.3.0.168.zip`). It contains
`lib-linux/libsvpflow1_vs64.so` and `libsvpflow2_vs64.so`. The snap downloads
this zip rather than cloning a source repository; the license text is installed
alongside the snap's other licenses.

## Performance: motion search is CPU-only

`svpflow1` (`Super`, `Analyse`) does the motion-vector search entirely on the
CPU; `ldd libsvpflow1_vs64.so` shows no OpenCL/Vulkan dependency, and the GPL
source (`svpflow1-src.zip`) contains zero references to OpenCL, CUDA or Vulkan.
Only `svpflow2` (`SmoothFps`) can render on the GPU, via OpenCL
(`clCreateImage2D`, `clEnqueueNDRangeKernel`, ...). A "CPU maxed, GPU idle"
report from `intel_gpu_top` is therefore expected: the GPU column only moves for
the render half, and only when OpenCL actually engages.

There is no way to move the search to the GPU with the GPL plugins. SVP's
closed-source Windows/macOS build has GPU analysis and an NVOF (NVIDIA Optical
Flow) path, and `svpflow2` even exports `SmoothFps_NVOF`, but that needs an
NVIDIA GPU and the SVP Manager/licence, so it is irrelevant here.

The `Super` `gpu` parameter is often mistaken for GPU search. From the source
(`mvsuper.cpp`, `groupofplanes.cpp`): `gpu:1` only tells `SmoothFps` to expect
an OpenCL renderer (`sharp=0`, no sub-pixel plane refinement), and `gpu:2` sets
`minLevel=1`, i.e. it *skips the finest search level*. Both are quality/speed
knobs for the CPU search, not offload. `gpu:2` also forces the OpenCL renderer,
so it cannot be combined with the CPU-render fallback.

Measured on this 4-vCPU host with a real 1920x1080 testsrc clip at 24 fps
(single-threaded `Analyse` is the serial constraint; `svpflow1` parallelises
poorly across frames — its per-frame work is internally locked):

- `Analyse` cost scales with the search settings, from ~90 ms/frame for the
  exhaustive `{}` default down to ~40 ms/frame for the `performance` preset.
- `main.search.coarse.width` is the strongest cheap CPU lever: capping it at
  480 was ~38% faster than SVP's default of 1050 with byte-identical output on
  normal content (not a pathological test pattern).
- `scale` (search *and* render at a fraction, then upscale) is the biggest
  lever overall: ~2x at 0.5, at visible softness.
- With the `performance` preset the whole 24->60 pipeline reaches ~50-60 output
  fps on 4 cores. The previous default (`Analyse` params `{}`) managed ~34 fps.
- mpv's `vapoursynth=concurrent-frames` has little effect: 3-4 is the sweet
  spot, and more than that slightly hurts because the search serialises.
- `--hwdec=auto-copy` offloads decoding and frees CPU for the search; only
  copy-back decoders are compatible with a VapourSynth filter.

The presets (`quality`/`balanced`/`performance`/`realtime`) and the per-run
`user-data` tokens (`fps`, `rate`, `scale`, `coarse`, `skipfinest`, `preset`)
are the levers; there is no GPU offload to gain beyond the render.

## GPU rendering (OpenCL) specifics

`SmoothFps` GPU rendering needs a working OpenCL platform with image support.
The snap bundles `intel-opencl-icd` (NEO), `mesa-opencl-icd` (rusticl) and
`ocl-icd-libopencl1`, plus the Intel runtime's dependencies (`libigc2`,
`libigdfcl2` including `libopencl-clang.so.16`, `libigdgmm12`). The launcher
regenerates the ICD vendor files under `$SNAP_USER_COMMON` because the staged
`intel.icd` names an absolute `/usr` path that resolves to the base snap under
confinement; it sets `OCL_ICD_VENDORS` to that directory.

When GPU rendering cannot initialise, SVP reports
`unable to init GPU-based renderer - code 65536/65791` and the script falls back
to CPU rendering with a message. On a GPU with the right driver this should not
happen; the usual causes are a missing ICD, no `/dev/dri/renderD*` access
(the `opengl` interface grants it), or an unsupported OpenCL version.


## Small sources

SVPflow's hierarchical motion search needs enough resolution to build its
pyramid; below roughly 3x the block size it fails with
`SVAnalyse: non-valid number of levels`. `svp.vpy` catches this and passes
frames through unchanged (with a message) instead of aborting playback, so a
tiny test clip or a thumbnail-sized stream still plays.

## Passing options through mpv

mpv's `vapoursynth` filter defines a `user-data` suboption that it forwards to
the `.vpy` as the global variable `user_data` (always defined, defaults to
`""`); `vf_vapoursynth.c` sets it with `mapSetData(..., dtUtf8, ...)`. The
script parses it for `fps`, `rate`, `preset`, `algo` and `gpu`, so the target
rate can be changed per-invocation without editing the file.

Two quirks worth remembering:

- mpv's suboption parser treats a second `=` as another suboption separator, so
  `user-data=fps=48` fails to parse. The value must be quoted:
  `user-data="fps=48"` or `user-data=[fps=48]`, and the whole `--vf=` value
  quoted from the shell. A bare `user-data=48` parses unquoted.
- SVP's `rate:{num,den}` is a *multiplier* of the source rate unless
  `abs:true` is set. The script therefore passes the multiplier (or, for an
  absolute target, the `abs:true` form) and not `source x rate`, which would
  multiply twice.

The snap launcher splits the filter value at the first `:` so that
`vapoursynth/svp.vpy:user-data=...` still resolves the relative script path to
`$SNAP/vapoursynth/svp.vpy`; without that split the whole string was treated as
the filename.

It also detects a user-supplied `vapoursynth=` filter and appends
`--vf-remove=@svp`, so combining `--vf=...` with `--profile=svp` (whose `vf-add`
is labelled `@svp`) does not run SVP twice. An explicitly labelled
`--vf-add=@svp:...` is left alone, since that replaces the profile's entry
itself. Without the launcher (source checkout) the same `--vf-remove=@svp` is
the user's responsibility.




## CI

`.github/workflows/ci.yml` runs shellcheck plus the test suite on
`ubuntu-24.04`. It intentionally uses the node24-runtimed first-party action
majors: `actions/checkout@v5` and `actions/setup-python@v6` (node20-based
majors surface deprecation warnings since GitHub enforces node24 for
JavaScript actions).

The test job reproduces a minimal headless SVP stack so `test-svp-vpy.sh` runs
end-to-end (CPU fallback) instead of skipping:

- `pip install vapoursynth==79` — the R79 manylinux wheel bundles `vspipe`
  (console script entry point) and autoloads plugins from
  `<site-packages>/vapoursynth/plugins`, matching the R74+ pip-based layout.
  VapourSynth's own `pip install vapoursynth` docs apply; the version is pinned
  to 79 because the GPL svpflow plugins need API 3, which R80 removed.
- `python3 -m vapoursynth config` — since R74 vspipe refuses to start until
  `vapoursynth config` has recorded the Python paths (written to
  `~/.config/vapoursynth/vapoursynth.toml`).
- `scripts/install-svpflow.sh` with `PREFIX` inside the workspace so the
  `patchelf --clear-execstack`'ed plugins land in the wheel's autoload
  directory; no sudo needed. `patchelf` comes from apt, `unzip` is already on
  the runner (installed again anyway for clarity).
- The suite runs with `<site-packages>/vapoursynth` prepended to `PATH` (puts
  the raw `vspipe` binary on it, ahead of the console-script wrapper) and as
  `LD_LIBRARY_PATH` so `libvsscript.so` resolves.

Locally this was verified by unpacking the wheel into a directory, running
`vapoursynth config` against it and running the full suite (all PASS,
mpv/snap tests skip or use static checks). Cleaned-up shellcheck
errors/warnings (SC1087/SC2034/SC2097/SC2098) with `--severity=warning` as the
CI gate; info-level findings (e.g. SC2012 `ls` hints) do not fail the build.


## Snap CI releases

`build-snap.yml` (mirrors mpv-practical-rife) packs the snap with snapcraft in
LXD on `ubuntu-24.04`. The Docker FORWARD-chain / lxdbr0 IPv6 workaround
before `snapcraft pack` comes from that workflow verbatim. Releases: rolling
`latest` prerelease on `main` pushes, exact releases on `v*` tags.

The snap smoke test differs from RIFE's (`bench` app there): this snap has
strict confinement and no bench app, and the whole mpv pipeline should be
exercised. It headlessly proves that playback through the snap interpolates:

1. `ffmpeg` (preinstalled on runners) generates a 1 s 256x256 24 fps yuv420p
   clip (`testsrc2`, `-an`).
2. `mpv-svp.mpv --profile=svp ... --o=svp-out.mkv --of=matroska --ovc=ffv1`
   encodes it through the snap's launcher + `[svp]` profile. Encode mode avoids
   any dependency on a display/audio; `--video-sync=audio` overrides the
   profile's `display-resample`, meaningless without a display clock.
   `--untimed` is dropped (encode mode already runs unthrottled).
3. `ffprobe` checks the output: ~55–65 frames and avg_frame_rate ~60 — i.e.
   SVP raised 24 fps to 60. A silent SVP failure would leave 24 frames; ffv1
   (built into libavcodec) needs no extra encoder in the snap.
   Terminal-output parsing (RIFE greps its bench log) is explicitly avoided:
   mpv's status line is unreliable without a controlling terminal.

Caveat: the snap is `base: core26`; the runner needs a snapd new enough to
install and run it, and snapcraft fetches the core26 build-base image inside
LXD. If the runner image lags, bump `runs-on` to a newer image.


## Keeping old releases

Every `main` push publishes both the rolling `latest` pointer and an archived
release `snapshot-r<N>` (N = the run number, matching the stamped snap version
`1.0.0-dev.N`). Only the `latest` pointer is deleted and recreated; snapshot
archives are never touched, so old builds accumulate as releases. Prune them
manually (`gh release list` / `gh release delete snapshot-r<N>`) if the list
grows too long.


## Workflow triggers

Pushes to `main` run only `build-snap.yml` (snap build + releases);
`ci.yml` (shellcheck + tests) runs on pull requests and manual
`workflow_dispatch` runs. This keeps pushes producing releases only.


## CI snap build troubleshooting

2026-11-19: `snapcraft pack` failed in CI at the libplacebo part: the
`glsl_preproc` source generator (`tools/glsl_preproc`) imports `jinja2`, which
the author's machine provides but the core26 build instance does not. Fixed by
adding `python3-jinja2` to the libplacebo `build-packages`. (mpv's and
VapourSynth's meson builds need Cython only, which is already listed.)

2026-11-19 follow-up: the pack succeeded with the fix; the smoke test then
died with `ffmpeg: command not found` — the GitHub ubuntu-24.04 runner image
does not ship ffmpeg in PATH. The smoke step now apt-installs ffmpeg
(provides both `ffmpeg` for input generation and `ffprobe` for verification).

2026-11-19 smoke-test reproduction: the snap installs and mpv inside it fails
with "Failed to initialize VapourSynth VSScript library: Python executable and
library path couldn't be determined despite automatic configuration." — i.e.
the launcher's VapourSynth config bootstrap is not taking effect. The build
job now uploads the packed snap regardless of the smoke result and the release
job publishes `latest` whenever packing succeeded (`needs.build.outputs.pack
== 'success'`), so failed runs are debuggable from public release assets.

Debugging the failed smoke tests took the actual snap apart (the workflow now
publishes every successfully packed build, so failed runs ship debuggable
release assets). The extracted snap run inside an `ubuntu:26.04` container
reproduces the CI failure exactly and gave the full picture:

1. `$SNAP/usr/bin/python3.14` did not start at all: the snap lacks
   `libexpat.so.1`.
2. With expat grafted in, `import vapoursynth` failed: `_ctypes` needs
   `libffi.so.8` — also not staged.
3. With both, `python3.14 -m vapoursynth config` writes the VSScript config
   (keyed by `$SNAP/usr/lib/python3/dist-packages/vapoursynth/libvsscript.so`,
   matching `VSSCRIPT_PATH`), mpv's vapoursynth filter initialises and the
   full SVP encode smoke test passes: 1 s of 24 fps in → 58 frames @ 60/1 out
   (CPU rendering, exactly as on the GPU-less runner).

So `libexpat1` and `libffi8` are now explicit stage-packages of the
vapoursynth part. Snapcraft's dependency resolution did not pull them with
the python packages, and the core26 base does not ship them.

The snapd probe report (routed onto the `latest` release as
`smoke-probe-r<N>.txt` on failure) pinpointed the CI divergence: inside
`snap run`, `XDG_CONFIG_HOME` leaks in from the host as `/home/runner/.config`
(the GitHub runner sets it), and the launcher only defaulted it via
`${XDG_CONFIG_HOME:-...}`. Under strict confinement that path is unwritable,
so `python3.14 -m vapoursynth config` died with PermissionError and VSScript
kept failing the same way even after the expat/ffi staging fix. The launcher
now pins `XDG_CONFIG_HOME` and `XDG_CACHE_HOME` to `$SNAP_USER_COMMON`
unconditionally. With that, the extracted-snap pipeline passes end to end
locally (58 frames @ 60/1 fps) inside an `ubuntu:26.04` container.
