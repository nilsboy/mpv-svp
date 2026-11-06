# SVP (SmoothVideo Project) frame interpolation for mpv's vapoursynth filter.
#
# SVP is split across two plugins:
#   svpflow1 (Super, Analyse)  motion-vector search -- CPU ONLY
#   svpflow2 (SmoothFps)       frame rendering      -- CPU or OpenCL
#
# There is no GPU motion search in the GPL plugins, so the CPU is the usual
# bottleneck (and why intel_gpu_top shows a busy CPU with an idle GPU). The
# PRESET below is the main lever; "performance" roughly halves the CPU cost of
# "quality". Run with `--hwdec=auto-copy` so decoding shares less CPU.
#
# mpv's VapourSynth bridge exchanges YUV clips. SVP's motion search only
# consumes 8-bit YUV 4:2:0; rendering can keep the source depth (SVPflow 4.2+
# supports 10-bit).
#
# Run with:
#   mpv --vf=vapoursynth=/path/to/svp.vpy video.mkv

import vapoursynth as vs

from fractions import Fraction
import os
import re

core = vs.core


def _ensure_svpflow():
    # Prefer the plugins autoloaded from VapourSynth's plugin directory (the
    # snap sets VAPOURSYNTH_EXTRA_PLUGIN_PATH). Fall back to an explicit load so
    # a source checkout works without installing them system-wide.
    namespaces = {plugin.namespace for plugin in core.plugins()}
    script_path = globals().get("__file__")
    here = os.path.dirname(os.path.abspath(script_path)) if script_path else ""
    for namespace, soname in (
        ("svp1", "libsvpflow1_vs64.so"),
        ("svp2", "libsvpflow2_vs64.so"),
    ):
        if namespace in namespaces:
            continue
        for directory in (here, "/usr/local/lib/vapoursynth"):
            path = os.path.join(directory, soname)
            if os.path.exists(path):
                core.std.LoadPlugin(path)
                break


_ensure_svpflow()


# --- configuration -----------------------------------------------------------

# Motion-search effort, which is CPU-bound and normally the bottleneck:
#   "quality"     exhaustive search, small blocks -- slowest, best vectors
#   "balanced"    hexagon search, small blocks
#   "performance" hexagon search, large blocks, 1-pixel accuracy -- fastest
PRESET = "performance"

# Target frame rate expressed as a multiple of the source rate. 2/1 doubles the
# rate, turning a 30 fps clip into 60 fps.
RATE_NUM = 2
RATE_DEN = 1

# Absolute target frame rate; overrides the multiplier when both are set. This
# is how the "to 60 FPS" goal is expressed for arbitrary source rates, e.g.
# FPS_NUM, FPS_DEN = 60, 1.
FPS_NUM = 60
FPS_DEN = 1

# OpenCL device used for frame rendering (0 = default/first device). Set to
# None to force CPU rendering, which is slower but needs no GPU/OpenCL runtime.
GPU_ID = 0

# Interpolation quality. "algo" is SVP's "shader" (see the SVPflow manual):
#   1  fastest, backward vectors only
#   2  like 1 but nearest-frame, good for 2D animation
#   11 time-weighted blend of forward/backward motion compensation
#   13 like 11 with a dynamic median (minimum artifacts, some halos)
#   21 like 11 plus cover/uncover masking
#   23 like 21 with extra vectors from adjacent frames
ALGO = 13

# Scene-change handling: repeat frames at cuts instead of blending across them.
# "mode" 3 is SVP's adaptive mode.
SCENE_MODE = 3

# Advanced overrides. Leave the derived preset values alone unless tuning; each
# must be consistent (FULL requires PEL 1).
_OVERRIDES = {
    # "PEL": 2,       # sub-pixel accuracy: 1, 2 or 4
    # "BLOCK_W": 16,  # motion block width: 8, 16 or 32
    # "FULL": True,   # full-resolution super clip (only valid with PEL 1)
    # "SEARCH_TYPE": 2,  # 2 hexagon, 3 uneven multi-hexagon, 4 exhaustive
    # "SEARCH_DISTANCE": -2,  # -2*PEL adaptive range; 0 skips the finest level
    # "COARSE_SATD": True,
    # "COARSE_WIDTH": 480,  # cap the width of coarse search levels
    # "REFINE": True,
    # "REFINE_THSAD": 250,
    # "SKIP_FINEST": False,  # run the finest search level (SVP Super gpu:2)
}

# -----------------------------------------------------------------------------

_PRESETS = {
    "quality": dict(
        PEL=2, BLOCK_W=16, FULL=True, SEARCH_TYPE=4, SEARCH_DISTANCE=-2,
        COARSE_SATD=True, COARSE_WIDTH=None, REFINE=True, REFINE_THSAD=200,
        SKIP_FINEST=False,
    ),
    "balanced": dict(
        PEL=2, BLOCK_W=16, FULL=True, SEARCH_TYPE=2, SEARCH_DISTANCE=-2,
        COARSE_SATD=True, COARSE_WIDTH=None, REFINE=True, REFINE_THSAD=200,
        SKIP_FINEST=False,
    ),
    "performance": dict(
        PEL=1, BLOCK_W=32, FULL=False, SEARCH_TYPE=2, SEARCH_DISTANCE=-2,
        COARSE_SATD=True, COARSE_WIDTH=None, REFINE=True, REFINE_THSAD=250,
        SKIP_FINEST=False,
    ),
    # performance plus a coarse-search width cap and no finest level: fastest,
    # at some cost to small-motion precision.
    "realtime": dict(
        PEL=1, BLOCK_W=32, FULL=False, SEARCH_TYPE=2, SEARCH_DISTANCE=-2,
        COARSE_SATD=True, COARSE_WIDTH=480, REFINE=True, REFINE_THSAD=280,
        SKIP_FINEST=True,
    ),
}


def _search_settings(preset):
    if preset not in _PRESETS:
        raise ValueError("unknown preset %r" % preset)
    settings = dict(_PRESETS[preset])
    settings.update(_OVERRIDES)
    if not settings["FULL"] and settings["PEL"] != 1:
        raise ValueError("FULL=false requires PEL=1")
    return settings


def _parse_rate(value):
    # "48", "47.95" or "48000/1001" -> (num, den).
    if "/" in value:
        num, den = value.split("/", 1)
        return int(num), int(den)
    frac = Fraction(value).limit_denominator(100000)
    return frac.numerator, frac.denominator


def _parse_user_data(raw):
    # mpv's vapoursynth filter passes its `user-data` suboption here verbatim.
    # Accept ";", "," and whitespace separated tokens:
    #   fps=48        absolute target frame rate (48, 47.95, 48000/1001)
    #   rate=2        target as a multiple of the source rate (2 or 5/2)
    #   preset=...    quality | balanced | performance | realtime
    #   algo=13       SVP shader
    #   gpu=0|off     OpenCL device, or "off"/"cpu" to force CPU rendering
    #   scale=0.75    run search+render at this fraction, then upscale
    #   coarse=480    cap the width of coarse search levels (CPU lever)
    #   skipfinest=1  skip the finest search level (needs GPU rendering)
    # A bare token (e.g. "48") is treated as an absolute target frame rate.
    options = {}
    raw = (raw or "").replace(",", ";")
    # Normalise "fps = 48" to "fps=48" so whitespace around "=" is tolerated.
    raw = re.sub(r"\s*=\s*", "=", raw)
    for chunk in raw.split(";"):
        for token in chunk.split():
            if "=" in token:
                key, value = token.split("=", 1)
                key = key.strip().lower()
                if key:
                    options[key] = value.strip()
            else:
                options.setdefault("fps", token)
    return options


def _source_fps(clip):
    # mpv's video_in clip reports 0/0 fps; the real rate is in container_fps.
    if clip.fps_num and clip.fps_den:
        return clip.fps_num, clip.fps_den
    if container_fps:
        frac = Fraction(container_fps).limit_denominator(100000)
        return frac.numerator, frac.denominator
    raise RuntimeError("could not determine source frame rate")


def main():
    clip = video_in
    if clip is None:
        return

    options = _parse_user_data(globals().get("user_data", ""))

    preset = options.get("preset", PRESET)
    settings = _search_settings(preset)
    algo = int(options["algo"]) if "algo" in options else ALGO
    source_num, source_den = _source_fps(clip)

    if "coarse" in options:
        settings["COARSE_WIDTH"] = int(options["coarse"])
    if "skipfinest" in options:
        settings["SKIP_FINEST"] = options["skipfinest"].lower() not in (
            "0", "false", "no", "off",
        )
    if settings["SKIP_FINEST"] and settings["PEL"] != 1:
        raise ValueError("skipfinest requires PEL=1")
    scale = float(options.get("scale", 1.0))
    if not 0.0 < scale <= 1.0:
        raise ValueError("scale must be in (0, 1]")

    if "rate" in options:
        # Without abs:true, SVP treats num/den as a multiplier of the source
        # rate, so pass the multiplier itself.
        rate_num, rate_den = _parse_rate(options["rate"])
        rate = "{num:%d,den:%d}" % (rate_num, rate_den)
    elif "fps" in options:
        fps_num, fps_den = _parse_rate(options["fps"])
        rate = "{num:%d,den:%d,abs:true}" % (fps_num, fps_den)
    elif FPS_NUM is not None and FPS_DEN is not None:
        rate = "{num:%d,den:%d,abs:true}" % (FPS_NUM, FPS_DEN)
    else:
        # Without abs:true, SVP treats num/den as a multiplier of the source.
        rate = "{num:%d,den:%d}" % (RATE_NUM, RATE_DEN)

    gpu_id = GPU_ID
    if "gpu" in options:
        gpu_id = None if options["gpu"].lower() in ("off", "cpu", "none") \
            else int(options["gpu"])

    # SVP's motion search only consumes 8-bit YUV 4:2:0; the rendering step can
    # keep the source depth.
    search = clip
    render = clip
    if clip.format.bits_per_sample != 8 or clip.format.subsampling_w != 1:
        search = core.resize.Bicubic(clip, format=vs.YUV420P8)
    if clip.format.bits_per_sample not in (8, 10):
        render = core.resize.Bicubic(clip, format=vs.YUV420P10)

    # Scale the whole pipeline down and upscale the result. RIFE-style "SCALE":
    # the search and render cost scale with pixel count, so this is the biggest
    # lever, at the cost of some softness.
    output_width, output_height = clip.width, clip.height
    if scale != 1.0:
        scaled_w = max(2, int(clip.width * scale) & ~1)
        scaled_h = max(2, int(clip.height * scale) & ~1)
        search = core.resize.Bicubic(search, scaled_w, scaled_h)
        render = core.resize.Bicubic(render, scaled_w, scaled_h)

    search = core.std.AssumeFPS(search, fpsnum=source_num, fpsden=source_den)
    render = core.std.AssumeFPS(render, fpsnum=source_num, fpsden=source_den)

    def analyse_params(settings):
        coarse = "{type:2,satd:%s" % (
            "true" if settings["COARSE_SATD"] else "false",
        )
        if settings["COARSE_WIDTH"] is not None:
            coarse += ",width:%d" % settings["COARSE_WIDTH"]
        coarse += "}"
        search_params = "{type:%d,distance:%d,coarse:%s}" % (
            settings["SEARCH_TYPE"],
            settings["SEARCH_DISTANCE"],
            coarse,
        )
        params = "{block:{w:%d},main:{search:%s}" % (
            settings["BLOCK_W"],
            search_params,
        )
        if settings["REFINE"]:
            params += ",refine:[{thsad:%d,search:{type:2,distance:-2}}]" % (
                settings["REFINE_THSAD"],
            )
        return params + "}"

    def interpolate(use_gpu):
        # SVSuper's "gpu" selects the renderer and how much search runs:
        #   0  CPU render
        #   1  OpenCL render
        #   2  OpenCL render, skipping the finest search level (faster)
        # SVP ties the "skip finest level" optimisation to the OpenCL renderer,
        # so it is only applied when GPU rendering is in use; the CPU fallback
        # always runs the full search.
        gpu_mode = 1 if use_gpu else 0
        if use_gpu and settings["SKIP_FINEST"]:
            gpu_mode = 2
        super_params = "{pel:%d,gpu:%d,full:%s}" % (
            settings["PEL"],
            gpu_mode,
            "true" if settings["FULL"] else "false",
        )
        smoothfps_params = "{rate:%s,algo:%d,scene:{mode:%d}}" % (
            rate,
            algo,
            SCENE_MODE,
        )
        if use_gpu:
            smoothfps_params = smoothfps_params[:-1] + ",gpuid:%d}" % int(gpu_id)
        super_clip = core.svp1.Super(search, super_params)
        vectors = core.svp1.Analyse(
            super_clip["clip"],
            super_clip["data"],
            search,
            analyse_params(settings),
        )
        return core.svp2.SmoothFps(
            render,
            super_clip["clip"],
            super_clip["data"],
            vectors["clip"],
            vectors["data"],
            smoothfps_params,
        )

    def attempt(use_gpu):
        node = interpolate(use_gpu=use_gpu)
        if scale != 1.0:
            node = core.resize.Bicubic(
                node, output_width, output_height,
                format=clip.format.id,
            )
        # SVSuper's pseudo-audio carries the real output fps; adopt it.
        return core.std.AssumeFPS(
            node, fpsnum=node.fps_num, fpsden=node.fps_den
        )

    smooth = None
    passthrough_error = None
    if gpu_id is not None:
        # GPU (OpenCL) rendering is unavailable on machines without a usable
        # device; fall back to CPU rather than failing playback.
        try:
            smooth = attempt(use_gpu=True)
        except vs.Error as error:
            print("svp.vpy: GPU rendering unavailable (%s); using CPU" % error)
    if smooth is None:
        try:
            smooth = attempt(use_gpu=False)
        except vs.Error as error:
            passthrough_error = error
    if smooth is None:
        # SVP's motion search needs enough resolution to build its
        # hierarchical pyramid; clips smaller than roughly 3x the block size
        # cannot be analysed. Pass frames through so playback still works.
        print(
            "svp.vpy: interpolation unavailable for this source (%s); "
            "passing frames through" % passthrough_error
        )
        smooth = core.std.AssumeFPS(
            clip, fpsnum=source_num, fpsden=source_den
        )

    smooth.set_output()


main()
