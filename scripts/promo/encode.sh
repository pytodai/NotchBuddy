#!/bin/bash
# Encodes a rendered PNG frame sequence into the GitHub promo assets.
#   scripts/promo/encode.sh <frames-dir> [out-dir] [fps] [name]
# Frames must be named frame_00000.png, frame_00001.png, … (any resolution, even width/height preferred).
# Produces: <name>.mp4 (H.264, full res, for releases/attachments), <name>-readme.mp4 (1280 px, small),
#           <name>.gif (800 px, 24 fps, ordered dither: small enough for inline README autoplay;
#           GIF_WIDTH / GIF_FPS override; NO_GIF=1 skips it). <name> defaults to "notchbuddy".
set -euo pipefail
FRAMES="${1:?frames dir}"
OUT="${2:-docs/media}"
FPS="${3:-60}"
NAME="${4:-notchbuddy}"
mkdir -p "$OUT"
IN=(-framerate "$FPS" -i "$FRAMES/frame_%05d.png")

# Master: high quality, streamable.
ffmpeg -y -loglevel error "${IN[@]}" -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart "$OUT/$NAME.mp4"

# Small MP4 for the README (GitHub renders uploaded MP4 attachments inline).
ffmpeg -y -loglevel error "${IN[@]}" -vf "scale=1280:-2:flags=lanczos" \
  -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -movflags +faststart "$OUT/$NAME-readme.mp4"

# GIF: two-pass palette; ordered (Bayer) dither compresses far better than error diffusion on the soft wallpaper,
# which keeps a 30 s film under GitHub's 10 MB inline limit.
if [ "${NO_GIF:-0}" != 1 ]; then
  GIF_FPS="${GIF_FPS:-24}"
  GIF_WIDTH="${GIF_WIDTH:-800}"
  PAL="$(mktemp -t nbpal).png"
  ffmpeg -y -loglevel error "${IN[@]}" -vf "fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=192" "$PAL"
  ffmpeg -y -loglevel error "${IN[@]}" -i "$PAL" \
    -lavfi "fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$OUT/$NAME.gif"
  rm -f "$PAL"
fi

ls -lh "$OUT"/"$NAME"*
