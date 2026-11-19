- [x] build mpv with SVP to run on a i3-1315U with 1080p → 60 FPS
- [x] make sure pipewire and wayland are supported
- [x] test if everything works
- [x] build a snap
- [x] allow retargeting the frame rate from the command line via mpv's
      vapoursynth `user-data` suboption (bare value = absolute fps)
- [x] stop `--vf=...` plus `--profile=svp` from running SVP twice: the snap
      launcher appends `--vf-remove=@svp` when the user supplies their own filter
- [x] add CPU-search reduction options (`preset=realtime`, `scale`, `coarse`,
      `skipfinest`) since the motion search cannot be GPU-offloaded
- [x] add GitHub Actions CI (shellcheck + test suite with the VapourSynth R79
      pip wheel and svpflow plugins, node24-runtimed actions)
- [x] build the snap in CI and attach it to releases (`.github/workflows/build-snap.yml`,
      modelled on mpv-practical-rife's build-snap.yml: snapcraft+LXD pack, ~60 fps
      ffprobe smoke test, rolling `latest` prerelease, exact releases on `v*` tags)

## Follow-ups

- [ ] confirm the GPU render path on the target i3-1315U with intel_gpu_top:
      SVP's motion search is CPU-only, so ~half the load stays on the CPU even
      when OpenCL rendering works, and the script logs "GPU rendering
      unavailable" when `SmoothFps` falls back to CPU
- [ ] benchmark real 1080p→60 on the target; try `preset=realtime` and/or
      `scale=0.75` if `performance` does not sustain 60 fps
- [ ] verify Wayland/PipeWire playback on a graphical session

## Not worth pursuing

- GPU motion search: the GPL `svpflow1` plugin has no OpenCL/Vulkan path (its
  source has zero GPU references), so the CPU search cannot be offloaded.
  SVP's closed-source build has GPU analysis and NVOF, but needs an NVIDIA GPU
  and the SVP Manager/licence, so it is not distributable here.
- `Super` `gpu:2` is not a GPU-search mode: it only skips the finest search
  level (a CPU saving), and it forces the OpenCL renderer.
