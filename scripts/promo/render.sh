#!/bin/bash
# The promo video in one command: release build, frames (NotchBuddy --render-promo), then encode.sh.
#   scripts/promo/render.sh [--size 3840x2160|2560x1440|1920x1080] [--fps 120|60] [--lang en|ru] [--out docs/media] [--keep-frames]
# Frames go to build/promo-frames-<lang> (~8 MB each at 3840×2160: removed after encoding unless --keep-frames).
# Draft first: --size 1280x720 --fps 30 (every motion samples the video clock, so a draft shows the final's timing).
# English: docs/media/notchbuddy{.mp4,-readme.mp4,.gif}; Russian: notchbuddy-ru{.mp4,-readme.mp4} (no GIF).
# Everything runs under nice; the island's panel is invisible (1 % opacity, click-through) while it renders.
# Storyboard: Sources/NotchBuddy/Promo/PromoStoryboard.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
SIZE=3840x2160 FPS=120 LANG_=en OUT=docs/media KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --lang) LANG_="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --keep-frames) KEEP=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
FRAMES="build/promo-frames-$LANG_"
nice -n 15 swift build -c release --product NotchBuddy
rm -rf "$FRAMES"
nice -n 15 .build/release/NotchBuddy --render-promo "$FRAMES" --size "$SIZE" --fps "$FPS" --lang "$LANG_"
if [ "$LANG_" = en ]; then
  nice -n 15 scripts/promo/encode.sh "$FRAMES" "$OUT" "$FPS" notchbuddy
else
  NO_GIF=1 nice -n 15 scripts/promo/encode.sh "$FRAMES" "$OUT" "$FPS" "notchbuddy-$LANG_"
fi
[ "$KEEP" = 1 ] || rm -rf "$FRAMES"
