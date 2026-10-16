#!/usr/bin/env python3
"""AerialSwap test suite.

Transcodes the clips from Tools/testsuite/generate.sh with the AerialSwap CLI and checks the results:
format (HEVC Main 10, hvc1, 3840x2160, 10-bit, no audio, Apple's color tags, temporal-layer sample groups),
automatic frame rate, exact frame count (with and without Smooth loop), Smooth motion (few repeated frames),
HDR tone mapping (patch levels), rotation, and Enhance detail (brightness matches the normal path).

    Tools/testsuite/run.py            all cases (several minutes: 4K and Enhance detail are slow)
    Tools/testsuite/run.py --quick    skip 4K sources and Enhance detail
    Tools/testsuite/run.py -k hdr     only cases whose name contains "hdr"
    Tools/testsuite/run.py --app PATH use another AerialSwap binary (default: ./AerialSwap.app, then /Applications)

Never touches the aerials folder: the CLI only writes to TestFootage/out/.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FOOTAGE = os.path.join(ROOT, "TestFootage")
OUT = os.path.join(FOOTAGE, "out")

# Measured references: PQ via AVFoundation, HLG via our Core Image tone curve (both on 0...1023 full-range luma).
PQ_PATCHES = [0, 62, 254, 547, 746, 919, 1021, 1022]
HLG_PATCHES = [0, 67, 248, 547, 696, 921, 989, 1005]


def run(cmd, timeout=3600):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def probe(path):
    r = run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path])
    return json.loads(r.stdout)


def video_stream(info):
    return next(s for s in info["streams"] if s["codec_type"] == "video")


def fps_of(stream):
    num, den = stream["r_frame_rate"].split("/")
    return float(num) / float(den)


def auto_fps(source_fps):
    """Same rule as Transcoder.autoFPS."""
    return 240 if source_fps >= 130 else 120 if source_fps >= 65 else 60


def sample_groups(path):
    """Grouping types of all 'sgpd' boxes in the movie (e.g. tscl, tsas for HEVC temporal layers)."""
    containers = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}
    found = set()
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()

        def walk(start, end):
            pos = start
            while pos < end - 8:
                f.seek(pos)
                box_size, box_type = struct.unpack(">I4s", f.read(8))
                header = 8
                if box_size == 1:
                    box_size = struct.unpack(">Q", f.read(8))[0]
                    header = 16
                if box_size == 0:
                    box_size = end - pos
                if box_type == b"sgpd":
                    f.seek(pos + header + 4)                      # skip version + flags
                    found.add(f.read(4).decode("latin1"))
                if box_type in containers:
                    walk(pos + header, pos + box_size)
                pos += box_size

        walk(0, size)
    return found


def consecutive_psnr(path):
    """PSNR between each pair of consecutive frames (downscaled); repeated frames score > 45 dB."""
    graph = ("[0:v]scale=480:270,format=yuv420p,split[x][y];[x]trim=start_frame=1,setpts=PTS-STARTPTS[a];"
             "[y]setpts=PTS-STARTPTS[b];[a][b]psnr=stats_file=-")
    r = run(["ffmpeg", "-hide_banner", "-v", "error", "-i", path, "-filter_complex", graph, "-f", "null", "-"])
    values = []
    for line in r.stdout.splitlines():
        for part in line.split():
            if part.startswith("psnr_avg:"):
                v = part.split(":")[1]
                values.append(99.0 if v == "inf" else float(v))
    return values


def patches(path):
    """Average luma (0...1023, full range) of the 8 vertical patches in frame 10."""
    graph = "select='eq(n\\,10)',format=yuv420p10le,extractplanes=y,scale=8:1:flags=area"
    r = subprocess.run(["ffmpeg", "-hide_banner", "-v", "error", "-i", path, "-vf", graph, "-frames:v", "1",
                        "-f", "rawvideo", "-pix_fmt", "gray10le", "-"], capture_output=True)
    return list(struct.unpack("<8H", r.stdout[:16]))


def rows(path, count=6):
    """Average luma of `count` horizontal bands, top to bottom (frame 10)."""
    graph = f"select='eq(n\\,10)',format=yuv420p10le,extractplanes=y,scale=1:{count}:flags=area"
    r = subprocess.run(["ffmpeg", "-hide_banner", "-v", "error", "-i", path, "-vf", graph, "-frames:v", "1",
                        "-f", "rawvideo", "-pix_fmt", "gray10le", "-"], capture_output=True)
    return list(struct.unpack(f"<{count}H", r.stdout[:2 * count]))


def mean_luma(path):
    graph = "format=yuv420p10le,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-"
    r = run(["ffmpeg", "-hide_banner", "-v", "error", "-i", path, "-vf", graph, "-f", "null", "-"])
    values = [float(l.split("=")[1]) for l in r.stdout.splitlines() if "YAVG=" in l]
    return sum(values) / len(values) if values else 0.0


class Case:
    def __init__(self, name, source, args=(), *, fps=None, loop=0.0, interpolate=False, slow=False,
                 hdr=None, rotated=False, compare_brightness_with=None):
        self.name, self.source, self.args = name, source, list(args)
        self.fps, self.loop, self.interpolate, self.slow = fps, loop, interpolate, slow
        self.hdr, self.rotated, self.compare_brightness_with = hdr, rotated, compare_brightness_with

    @property
    def output(self):
        return os.path.join(OUT, self.name.replace(" ", "_") + ".mov")


# App defaults are Smooth loop (1 s) + Smooth motion; the CLI needs them spelled out.
APP = ["--loop", "1", "--interpolate"]
CASES = [
    # Resolution x frame rate with app defaults
    Case("720p24", "src_720p24", APP, loop=1, interpolate=True),
    Case("720p30", "src_720p30", APP, loop=1, interpolate=True),
    Case("720p60", "src_720p60", APP, loop=1, interpolate=True),
    Case("1080p24", "src_1080p24", APP, loop=1, interpolate=True),
    Case("1080p30", "src_1080p30", APP, loop=1, interpolate=True),
    Case("1080p60", "src_1080p60", APP, loop=1, interpolate=True),
    Case("1080p120 auto fps", "src_1080p120", APP, loop=1, interpolate=True),
    Case("1080p240 auto fps", "src_1080p240", APP, loop=1, interpolate=True),
    Case("2160p24", "src_2160p24", APP, loop=1, interpolate=True, slow=True),
    Case("2160p30", "src_2160p30", APP, loop=1, interpolate=True, slow=True),
    Case("2160p60", "src_2160p60", APP, loop=1, interpolate=True, slow=True),
    Case("2160p120 auto fps", "src_2160p120", APP, loop=1, interpolate=True, slow=True),
    # Motion options
    Case("1080p24 original motion", "src_1080p24", ["--loop", "1"], loop=1),
    Case("1080p24 maximum 120", "src_1080p24", APP + ["--fps", "120"], fps=120, loop=1, interpolate=True),
    Case("1080p60 maximum 120", "src_1080p60", APP + ["--fps", "120"], fps=120, loop=1, interpolate=True),
    Case("1080p30 no loop", "src_1080p30", ["--interpolate"], interpolate=True),
    # Shapes and edge cases
    Case("widescreen 21:9", "src_wide24", APP, loop=1, interpolate=True, slow=True),
    Case("low resolution 736x414", "src_low30", APP, loop=1, interpolate=True),
    Case("short clip skips loop", "src_short30", APP, loop=1, interpolate=True),   # 2 s < 3 s: no crossfade
    Case("portrait phone video", "src_portrait30", APP, loop=1, interpolate=True, rotated=True),
    # HDR
    Case("hdr pq 2160p", "hdr_pq2160", [], hdr="pq", slow=True),
    Case("hdr hlg 2160p", "hdr_hlg2160", [], hdr="hlg", slow=True),
    Case("hdr hlg 1080p", "hdr_hlg1080", [], hdr="hlg"),
    Case("hdr hlg 1080p smooth motion", "hdr_hlg1080", ["--interpolate"], hdr="hlg", interpolate=True),
    Case("hdr hlg rotated", "hdr_hlg2160_rot", [], hdr="hlg-rotated", rotated=True, slow=True),
    # Enhance detail (slow: ~1.25 s per source frame)
    Case("scene 1080p plain", "scene_1080p30", ["--fps", "30"], fps=30),
    Case("scene 1080p enhanced", "scene_1080p30", ["--fps", "30", "--enhance"], fps=30, slow=True,
         compare_brightness_with="scene 1080p plain"),
    Case("scene 720p plain", "scene_720p30", ["--fps", "30"], fps=30),
    Case("scene 720p enhanced", "scene_720p30", ["--fps", "30", "--enhance"], fps=30, slow=True,
         compare_brightness_with="scene 720p plain"),
    Case("hdr hlg 1080p enhanced", "hdr_hlg1080", ["--enhance"], hdr="hlg-enhanced", slow=True),
]


def check(case, app, results_by_name):
    source = os.path.join(FOOTAGE, case.source + ".mov")
    if not os.path.exists(source):
        return False, [f"missing {case.source}.mov (run Tools/testsuite/generate.sh)"], 0.0
    started = time.time()
    r = run([app, "--transcode", source, case.output] + case.args)
    elapsed = time.time() - started
    if r.returncode != 0 or not os.path.exists(case.output):
        return False, [f"transcode failed: {(r.stdout + r.stderr).strip().splitlines()[-1:]}"], elapsed

    problems = []
    info = probe(case.output)
    v = video_stream(info)
    src = video_stream(probe(source))
    src_fps, src_duration = fps_of(src), float(probe(source)["format"]["duration"])

    # Format Apple expects
    expect = {"codec_name": "hevc", "profile": "Main 10", "codec_tag_string": "hvc1", "width": 3840, "height": 2160,
              "pix_fmt": "yuv420p10le", "color_primaries": "bt709", "color_transfer": "iec61966-2-1"}
    for key, value in expect.items():
        if v.get(key) != value:
            problems.append(f"{key}={v.get(key)} (want {value})")
    if len(info["streams"]) != 1:
        problems.append(f"{len(info['streams'])} streams (want video only)")
    groups = sample_groups(case.output)
    if not {"tscl", "tsas"} <= groups:
        problems.append(f"temporal-layer sample groups missing: {sorted(groups)}")

    # Frame rate and exact frame count
    want_fps = case.fps or auto_fps(src_fps)
    out_fps = fps_of(v)
    if abs(out_fps - want_fps) > 0.01:
        problems.append(f"{out_fps:g} fps (want {want_fps})")
    loop = case.loop if case.loop and src_duration >= 3 * case.loop else 0
    want_frames = round((src_duration - loop) * want_fps)
    frames = int(v.get("nb_frames", 0))
    if abs(frames - want_frames) > 1:
        problems.append(f"{frames} frames (want {want_frames})")

    # Smooth motion: generated frames instead of repeats
    if case.interpolate and src_fps < want_fps * 0.85 and not case.hdr:
        steps = consecutive_psnr(case.output)
        repeats = sum(1 for s in steps if s > 45) / max(1, len(steps))
        if repeats > 0.05:
            problems.append(f"{repeats:.0%} repeated frames (want < 5% with Smooth motion)")

    # HDR tone mapping
    if case.hdr in ("pq", "hlg", "hlg-enhanced"):
        want = PQ_PATCHES if case.hdr == "pq" else HLG_PATCHES
        tolerance = 14 if case.hdr == "hlg-enhanced" else 8      # the ML model shifts single patches slightly
        got = patches(case.output)
        worst = max(abs(a - b) for a, b in zip(got, want))
        if worst > tolerance:
            problems.append(f"patch levels {got} vs {want} (off by {worst})")
    if case.hdr == "hlg-rotated":
        bands = rows(case.output)
        if not all(bands[i] >= bands[i + 1] for i in range(len(bands) - 1)) or bands[0] <= bands[-1]:
            problems.append(f"rotation: bands top->bottom {bands} (want bright to dark)")

    # Rotation of the upright phone video: 16:9 output, compare with ffmpeg's own auto-rotated reference
    if case.rotated and not case.hdr:
        ref = case.output.replace(".mov", "_ref.mov")
        run(["ffmpeg", "-hide_banner", "-v", "error", "-y", "-i", source, "-vf",
             "scale=3840:-2:flags=lanczos,crop=3840:2160", "-frames:v", "10", "-c:v", "ffv1", ref])
        def psnr(extra):
            g = f"[0:v]trim=end_frame=10,scale=960:540[a];[1:v]{extra}scale=960:540[b];[a][b]psnr"
            out = run(["ffmpeg", "-hide_banner", "-i", case.output, "-i", ref, "-filter_complex", g, "-f", "null", "-"])
            for part in out.stderr.split():
                if part.startswith("average:"):
                    return float(part.split(":")[1])
            return 0.0
        right, flipped = psnr(""), psnr("vflip,hflip,")
        if right < flipped + 3:
            problems.append(f"orientation unclear: {right:.1f} dB vs rotated-180 {flipped:.1f} dB")

    # Enhance detail keeps the brightness of the normal path
    if case.compare_brightness_with:
        other = results_by_name.get(case.compare_brightness_with)
        if other and os.path.exists(other.output):
            a, b = mean_luma(case.output), mean_luma(other.output)
            if abs(a - b) / max(b, 1) > 0.01:
                problems.append(f"brightness {a:.1f} vs {b:.1f} without Enhance detail (> 1% apart)")

    return not problems, problems, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quick", action="store_true", help="skip 4K sources and Enhance detail")
    parser.add_argument("-k", metavar="TEXT", help="only cases whose name contains TEXT")
    parser.add_argument("--app", help="AerialSwap binary to test")
    args = parser.parse_args()

    app = args.app
    for candidate in (os.path.join(ROOT, "AerialSwap.app/Contents/MacOS/AerialSwap"),
                      "/Applications/AerialSwap.app/Contents/MacOS/AerialSwap"):
        if not app and os.path.exists(candidate):
            app = candidate
    if not app:
        sys.exit("AerialSwap not found: run ./build.sh first, or pass --app")
    os.makedirs(OUT, exist_ok=True)
    print(f"testing {app}\n")

    cases = [c for c in CASES if not (args.quick and c.slow) and (not args.k or args.k.lower() in c.name.lower())]
    by_name, failures = {}, 0
    for case in cases:
        print(f"  {case.name:<30}", end="", flush=True)
        ok, problems, elapsed = check(case, app, by_name)
        by_name[case.name] = case
        print(f"{'PASS' if ok else 'FAIL'}  {elapsed:6.1f}s" + ("" if ok else "  " + "; ".join(problems)))
        failures += 0 if ok else 1
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
