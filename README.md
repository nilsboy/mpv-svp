# mpv-svp

SVP (SmoothVideo Project) motion-interpolation frame rate conversion for
[mpv](https://mpv.io/), exposed through VapourSynth using SVP's GPL
[svpflow plugins](https://www.svp-team.com/wiki/Manual:SVPflow), plus an
all-in-one snap.

SVP estimates motion between frames and synthesises in-between frames, raising
the effective frame rate for smoother motion — e.g. 1080p24 → 60 fps.

## How it works

```
mpv --vf=vapoursynth=vapoursynth/svp.vpy  video.mkv
```

mpv's `vapoursynth` filter runs `vapoursynth/svp.vpy`. That script takes the
decoded frames via `video_in` and runs SVP's two VapourSynth plugins:

- `svpflow1` searches for motion vectors (`Super`, then `Analyse`).
- `svpflow2` renders the interpolated frames (`SmoothFps`).

No SVP Manager process is required on Linux; the GPL plugins run standalone.

## Requirements

- Linux x86_64. The scripts target Ubuntu but should work on any distro with
  meson/ninja and the listed dev packages.
- For real-time playback: a GPU with an OpenCL runtime (SVP renders on OpenCL).
  Intel iGPUs use `intel-opencl-icd`, AMD/NVIDIA ship their own. Without a
  usable device, SVP falls back to CPU rendering, which is much slower.

## VapourSynth version

SVP's GPL plugins are built against VapourSynth **API 3**, which R80 removed.
R79 is the last release that still accepts them, so the project pins
VapourSynth to **R79** everywhere. See [NOTES.md](NOTES.md) for details.

## Build

Everything is built from source because Ubuntu does not package VapourSynth and
its mpv is not built with VapourSynth support.

```sh
sudo scripts/install-deps.sh          # distro build dependencies
scripts/build-vapoursynth.sh          # VapourSynth R79 runtime + headers
scripts/install-svpflow.sh            # patched SVPflow plugins
scripts/build-libplacebo.sh           # libplacebo (only if your distro lacks it)
scripts/build-mpv.sh                  # mpv with -Dvapoursynth=enabled
```

Install to `/usr/local` by default; override with `PREFIX=/your/prefix`.

## Usage

Play a file with interpolation:

```sh
mpv --vf=vapoursynth=vapoursynth/svp.vpy video.mkv
```

Or use the bundled config, which adds an `[svp]` profile and a runtime toggle
bound to `Ctrl+s`:

```sh
mpv --config-dir=mpv --profile=svp video.mkv
```

In the snap, a relative `vapoursynth=` path that is not present in the current
directory is resolved against the snap's bundled `/vapoursynth/svp.vpy`, so the
command above works from anywhere.

The toggle script reads the vpy path from `script-opts/svp-toggle.conf`.

To change the target rate with the `[svp]` profile, edit the `vf-add` line in
`mpv/mpv.conf`, or pass `user-data` in the profile's filter value. When using a
source checkout (no launcher), adding a second `--vf=vapoursynth=...` alongside
`--profile=svp` runs two SVP filters; pass `--vf-remove=@svp` to drop the
profile's copy, or override it with `--vf-add=@svp:vapoursynth=...`. The snap
launcher does this removal automatically when you supply your own
`vapoursynth=` argument.

### Overriding options from the command line

mpv's `vapoursynth` filter has a `user-data` suboption that is passed to the
script verbatim, so the target frame rate (and a few other settings) can be
changed without editing the script. mpv's suboption parser requires the value
to be quoted; use `"..."` or `[...]`, and separate multiple options with `;`
or `,`:

```sh
# Retarget to 48 fps:
mpv --vf='vapoursynth=vapoursynth/svp.vpy:user-data="48"' video.mkv

# Equivalent explicit form, plus a different motion-search preset:
mpv --vf='vapoursynth=vapoursynth/svp.vpy:user-data=[fps=48;preset=balanced]' video.mkv
```

Recognised tokens:

| Token | Meaning |
| --- | --- |
| `fps=48` (or a bare `48`) | Absolute target frame rate; accepts `47.95` or `48000/1001` |
| `rate=2` (or `5/2`) | Target as a multiple of the source rate |
| `preset=quality\|balanced\|performance\|realtime` | Motion-search preset |
| `algo=13` | SVP shader |
| `gpu=0`, `gpu=off` | OpenCL device, or `off` to force CPU rendering |
| `scale=0.5` | Run search/render at this fraction, then upscale (biggest speedup) |
| `coarse=480` | Cap the width of coarse search levels (cheap CPU saving) |
| `skipfinest=1` | Skip the finest search level (requires OpenCL rendering) |

`fps`/`rate` take precedence over the defaults in the script (`FPS_NUM`/`FPS_DEN`);
if neither is given, the hardcoded target applies.

In the snap, quote the whole `--vf=` value and the `user-data` value:

```sh
mpv-svp.mpv --vf='vapoursynth=vapoursynth/svp.vpy:user-data="48"' video.mkv
```

### svp.vpy options

Configuration lives at the top of `vapoursynth/svp.vpy`:

| Option | Meaning |
| --- | --- |
| `PRESET` | Motion-search effort: `quality`, `balanced`, `performance` (default) |
| `FPS_NUM`, `FPS_DEN` | Absolute target frame rate; default `60`/`1` |
| `RATE_NUM`, `RATE_DEN` | Frame-rate multiplier, used when `FPS_NUM` is unset |
| `GPU_ID` | OpenCL device for rendering; `None` forces CPU |
| `ALGO` | SVP shader (interpolation algorithm), e.g. `13` (default), `11`, `23` |
| `SCENE_MODE` | Scene-change handling mode (`0`–`3`) |

`PRESET` is the main performance lever. SVP's motion search (`svpflow1`) is
**CPU-only** — only frame rendering (`svpflow2`) can use the GPU — so a busy CPU
with an idle GPU is expected, not a bug. `performance` uses large blocks and
1-pixel precision and is roughly 1.5–2x faster than `quality`; it is the
default so that 1080p can reach 60 fps on modest hardware. `realtime` trims the
motion search further (see below).

Per-parameter overrides (`PEL`, `BLOCK_W`, `FULL`, `SEARCH_TYPE`,
`SEARCH_DISTANCE`, `COARSE_SATD`, `COARSE_WIDTH`, `REFINE`, `REFINE_THSAD`,
`SKIP_FINEST`) are available in `_OVERRIDES` if you want to tune beyond the
presets.

### If playback is too slow

SVP's motion search is CPU-only and single-threaded per frame, so on a weak CPU
it is the bottleneck. In rough order of impact:

1. **Lower the target rate** — `user-data="48"` or `"30"`; interpolation cost
   scales with output frames per second.
2. **`scale=`** — run search *and* render at a fraction of the source and
   upscale: `user-data="48;scale=0.5"` is roughly 2x faster, at some softness.
3. **`preset=realtime`** — caps the coarse-search width and skips the finest
   search level (the latter needs OpenCL rendering).
4. **`coarse=480`** — cap the width of coarse search levels; the cheapest of
   these changes and invisible on normal content.
5. Use `--hwdec=auto-copy` (already in the bundled config) so decoding does not
   compete for CPU.

Check whether GPU rendering is actually engaged: if `intel_gpu_top` shows a
`Render/3D` load during playback, `svpflow2` is on the GPU. If it stays at 0 the
renderer fell back to CPU (the script logs "GPU rendering unavailable"), and the
whole pipeline is CPU-bound.

If playback still drops frames, lower the target rate, use `realtime`, or lower
the source resolution.

## Snap

An all-in-one snap bundles mpv, VapourSynth R79, the SVPflow plugins and the
config/profile. The snap is built against `core26`, matching this project's
Ubuntu 26.04 host:

```sh
cd snap && snapcraft pack
sudo snap install --dangerous ./mpv-svp_*.snap
```

The default managed build uses LXD; `snapcraft pack --destructive-mode` builds
directly on the host (no LXD required) and is what the project targets.

The snap requires the `pipewire` interface to talk to the host PipeWire daemon;
it is not auto-connected:

```sh
sudo snap connect mpv-svp:pipewire
```

Without it, mpv falls back to the bundled PulseAudio client against the host
pipewire-pulse socket.

Video output uses X11 (`x11`, `xv`, `x11egl`, `x11vk`) or Wayland (`wlshm`,
`dmabuf-wayland`, `wayland`, `waylandvk`) depending on `DISPLAY`/
`WAYLAND_DISPLAY`. The `x11`, `wayland` and `opengl` interfaces are
auto-connected; only `pipewire` needs the manual connect above.

SVP renders on OpenCL, so the snap bundles Mesa's and Intel's OpenCL ICDs and
regenerates the ICD vendor files at launch so they resolve to `$SNAP` paths. A
GPU with an OpenCL runtime is recommended for real-time playback.

## Tests

```sh
tests/run-tests.sh
```

Covers the vpy script syntax/load and frame-rate conversion, the mpv
`vapoursynth` filter availability, the SVPflow plugin payload and executable
stack, the snap audio payload, and that the X11/Wayland video outputs are built
and bundled. Actual GPU interpolation needs a GPU and is verified manually.

The same suite runs in CI (`.github/workflows/ci.yml`): a shellcheck job over
all shell sources, and a test job that installs the VapourSynth R79 pip wheel
plus the GPL SVPflow plugins so the vpy end-to-end interpolation test runs for
real. mpv-bound tests skip gracefully when `mpv` is not on the runner. The
workflow uses the node24-runtimed action majors (`actions/checkout@v5`,
`actions/setup-python@v6`).

## Snap releases

`.github/workflows/build-snap.yml` (modelled on mpv-practical-rife) builds the
snap on every push and pull request with snapcraft in LXD, smoke-tests it
headless (a 1 s 24 fps test clip encoded through the snap's `--profile=svp`
must come out at ~60 fps, verified with ffprobe) and uploads it as a workflow
artifact. It publishes the snap on every push:

- push to `main`: the rolling `latest` prerelease (replaced on every push),
  plus an archived per-build snapshot release `snapshot-r<N>` so old versions
  stay available
- pushed `v*` tags: an exact release with generated notes

Grab the packaged snap from the release page and install it with

```sh
sudo snap install --dangerous ./mpv-svp_<version>_amd64.snap
```

## Notes

See [NOTES.md](NOTES.md) for design and environment details.
