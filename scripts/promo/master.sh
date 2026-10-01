#!/bin/bash
# The promo master (default 4K 120 fps HEVC) straight from the renderer into the Mac's hardware encoder: no PNGs, nothing
# big on disk. The film is cut into chunks rendered by several NotchBuddy processes at once (each through a FIFO into its
# own ffmpeg), then joined without re-encoding.
#   scripts/promo/master.sh [--size 3840x2160] [--fps 120] [--lang en] [--jobs 3] [--chunks 6] [--bitrate 80M]
#                           [--out docs/media/notchbuddy-4k120.mp4] [--no-build]
set -euo pipefail
cd "$(dirname "$0")/../.."
SIZE=3840x2160 FPS=120 LANG_=en JOBS=3 CHUNKS=6 BITRATE=80M OUT=docs/media/notchbuddy-4k120.mp4 BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --lang) LANG_="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --chunks) CHUNKS="$2"; shift 2 ;;
    --bitrate) BITRATE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
W=${SIZE%x*} H=${SIZE#*x}
BIN=.build/release/NotchBuddy
[ "$BUILD" = 1 ] && swift build -c release --product NotchBuddy
DUR=$("$BIN" --render-promo --info | tail -1)
TOTAL=$(python3 -c "print(round($DUR * $FPS))")
WORK=$(mktemp -d -t nbmaster)
trap 'pkill -f "render-promo --raw $WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
echo "master: ${W}x${H} @ $FPS fps, $DUR s = $TOTAL frames, $CHUNKS chunks, $JOBS at once"

chunk() {  # chunk <k>: frames [a, b) → $WORK/chunk-k.mp4
  local k=$1 a=$(( TOTAL * $1 / CHUNKS )) b=$(( TOTAL * ($1 + 1) / CHUNKS ))
  local fifo="$WORK/chunk-$k.fifo"
  mkfifo "$fifo"
  ffmpeg -y -loglevel error -f rawvideo -pix_fmt bgra -s "${W}x${H}" -r "$FPS" -i "$fifo" \
    -c:v hevc_videotoolbox -b:v "$BITRATE" -maxrate "$BITRATE" -tag:v hvc1 -profile:v main \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 "$WORK/chunk-$k.mp4" &
  local enc=$!
  "$BIN" --render-promo --raw "$fifo" --frames "$a:$b" --size "${W}x${H}" --fps "$FPS" --lang "$LANG_" \
    > "$WORK/chunk-$k.log" 2>&1
  wait $enc
  echo "master: chunk $k (frames $a..<$b) done"
}
export -f chunk
export WORK TOTAL CHUNKS W H FPS BITRATE BIN LANG_
seq 0 $((CHUNKS - 1)) | xargs -P "$JOBS" -I{} bash -c 'chunk {}'

: > "$WORK/list.txt"
for k in $(seq 0 $((CHUNKS - 1))); do echo "file '$WORK/chunk-$k.mp4'" >> "$WORK/list.txt"; done
mkdir -p "$(dirname "$OUT")"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$WORK/list.txt" -c copy -tag:v hvc1 -movflags +faststart "$OUT"
FRAMES=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$OUT")
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,codec_name -show_entries format=duration,size \
  -of compact=p=0 "$OUT"
[ "$FRAMES" = "$TOTAL" ] && echo "master: $OUT — $FRAMES frames ✓" || { echo "master: frame count $FRAMES ≠ $TOTAL" >&2; exit 1; }
