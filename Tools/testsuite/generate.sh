#!/bin/zsh
# Generates synthetic test footage for Tools/testsuite/run.py into TestFootage/ (git-ignored).
# Needs ffmpeg (test-only; the app itself doesn't depend on it). Existing clips are kept, so reruns are fast.
#   Tools/testsuite/generate.sh          generate missing clips
#   Tools/testsuite/generate.sh --clean  delete TestFootage/ and regenerate everything
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=TestFootage
HELPERS=.build/testsuite
[[ "${1:-}" == "--clean" ]] && rm -rf "$OUT"
mkdir -p "$OUT" "$HELPERS"
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed for the test footage: brew install ffmpeg" >&2; exit 1; }

# Swift helpers (HDR gray patches, procedural landscape), compiled once.
for tool in hdrgen scene; do
    if [[ ! -x $HELPERS/$tool || Tools/testsuite/$tool.swift -nt $HELPERS/$tool ]]; then
        echo "compiling $tool"
        swiftc -O -swift-version 5 -o $HELPERS/$tool Tools/testsuite/$tool.swift 2>&1 | grep -E ' error:' || true
    fi
done

# testsrc2 (moving pattern + timer), BT.709-tagged HEVC.  usage: clip <name> <WxH> <fps> <seconds> [codec]
clip() {
    [[ -f $OUT/$1.mov ]] && return
    echo "generating $1"
    local codec=(-c:v hevc_videotoolbox -b:v 30M -tag:v hvc1)
    [[ "${5:-}" == "h264" ]] && codec=(-c:v h264_videotoolbox -b:v 20M)
    ffmpeg -hide_banner -v error -y -f lavfi -i "testsrc2=size=${2}:rate=${3}:duration=${4}" "${codec[@]}" -pix_fmt yuv420p \
        -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$OUT/$1.mov"
}

# Resolution x frame rate matrix (3 s each)
clip src_720p24   1280x720  24  3 h264
clip src_720p30   1280x720  30  3 h264
clip src_720p60   1280x720  60  3 h264
clip src_1080p24  1920x1080 24  3
clip src_1080p30  1920x1080 30  3
clip src_1080p60  1920x1080 60  3
clip src_1080p120 1920x1080 120 3
clip src_1080p240 1920x1080 240 3
clip src_2160p24  3840x2160 24  3
clip src_2160p30  3840x2160 30  3
clip src_2160p60  3840x2160 60  3
clip src_2160p120 3840x2160 120 3

# Shapes and edge cases
clip src_wide24   3840x1608 24  3          # 21:9 cinema widescreen
clip src_low30    736x414   30  3 h264     # low resolution (popup case)
clip src_short30  1920x1080 30  2          # too short for Smooth loop
if [[ ! -f $OUT/src_portrait30.mov ]]; then   # upright phone video: stored 1920x1080, displayed 1080x1920
    echo "generating src_portrait30"
    clip tmp_land30 1920x1080 30 3
    ffmpeg -hide_banner -v error -y -display_rotation 90 -i $OUT/tmp_land30.mov -c copy $OUT/src_portrait30.mov && rm $OUT/tmp_land30.mov
fi

# HDR gray patches with known levels
[[ -f $OUT/hdr_pq2160.mov ]]  || { echo "generating hdr_pq2160";  $HELPERS/hdrgen $OUT/hdr_pq2160.mov pq 3840 2160 >/dev/null; }
[[ -f $OUT/hdr_hlg2160.mov ]] || { echo "generating hdr_hlg2160"; $HELPERS/hdrgen $OUT/hdr_hlg2160.mov hlg 3840 2160 >/dev/null; }
[[ -f $OUT/hdr_hlg1080.mov ]] || { echo "generating hdr_hlg1080"; $HELPERS/hdrgen $OUT/hdr_hlg1080.mov hlg 1920 1080 >/dev/null; }
if [[ ! -f $OUT/hdr_hlg2160_rot.mov ]]; then
    echo "generating hdr_hlg2160_rot"
    ffmpeg -hide_banner -v error -y -display_rotation 90 -i $OUT/hdr_hlg2160.mov -c copy $OUT/hdr_hlg2160_rot.mov
fi

# Natural-texture landscape (procedural, original): 4K reference plus 1080p / 720p versions for Enhance detail
if [[ ! -f $OUT/scene_1080p30.mov ]]; then
    echo "generating scene footage"
    $HELPERS/scene $OUT/scene_2160p30.mov 30 >/dev/null
    for size in 1920:1080:1080p 1280:720:720p; do
        IFS=: read -r w h name <<< "$size"
        ffmpeg -hide_banner -v error -y -i $OUT/scene_2160p30.mov -vf "scale=${w}:${h}:flags=lanczos" \
            -c:v hevc_videotoolbox -b:v 30M -tag:v hvc1 -pix_fmt yuv420p $OUT/scene_${name}30.mov
    done
fi

echo "test footage ready in $OUT/ ($(ls $OUT/*.mov | wc -l | tr -d ' ') clips, $(du -sh $OUT | cut -f1))"
