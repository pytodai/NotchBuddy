#!/bin/bash
# Frame-pacing benchmark of the island's transitions (debug tool; see "Measuring" in docs/island-architecture.md).
#
#   scripts/perf-bench.sh [--load] [--tabs] [--drag] [--style notch|island] [--runs N] [--bin PATH/TO/NotchBuddy] [--label TEXT]
#
# Starts a separate dev instance (NOTCHBUDDY_PERF=1, its own NOTCHBUDDY_HOME and socket, so its single-instance
# lock lives in that home too; no menu bar item, no keychain, no network, no sounds, never takes the pointer)
# beside the installed app, drives it through hover / open / close / flash / card / cardAdvance N times with fake
# sessions (the list opens as a resting pointer opens it: hover, then ~0.12 s later), quits it and prints a summary of
# its perf.log. With --load, one `yes > /dev/null` per core runs meanwhile (killed afterwards). With --tabs the list
# gets a tab strip (Агенты, Таймер, Система) and each run also switches tabs forward and back ("tab"; once cold, as a
# swipe does it, twice as a click after the pointer rested on the tab). --style picks «Чёлка» (notch, the default) or
# «Островок» (island) for the dev instance only. --drag (implies --style island) also moves the capsule aside each run,
# opens and closes the list from there ("open-offset", "close-offset": it slides inward as it grows), drags the capsule
# sideways and back ("drag": 0.45 s of pointer events at 120 Hz, then the settle), and with the capsule at the left
# edge opens the list as a resting pointer does and grabs it where the capsule sits ("grab": it folds back into the
# capsule, which is pulled 360 pt and let go). The dev island is invisible (1 % opacity, click-through) while it runs.
# The installed app is not touched.
set -euo pipefail

RUNS=10
LOAD=0
TABS=0
DRAG=0
STYLE=notch
LABEL=""
BIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --load) LOAD=1 ;;
        --tabs) TABS=1 ;;
        --drag) DRAG=1; STYLE=island ;;
        --style) STYLE="$2"; shift ;;
        --runs) RUNS="$2"; shift ;;
        --bin) BIN="$2"; shift ;;
        --label) LABEL="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
if [ -z "$BIN" ]; then
    BIN="$(swift build -c release --show-bin-path)/NotchBuddy"
fi
[ -x "$BIN" ] || { echo "no binary at $BIN (build it first)" >&2; exit 1; }

export NOTCHBUDDY_HOME="${NOTCHBUDDY_HOME:-/tmp/notchbuddy-perf}"
export NOTCHBUDDY_SOCKET="${NOTCHBUDDY_SOCKET:-/tmp/notchbuddy-perf.sock}"
export NOTCHBUDDY_PERF=1
mkdir -p "$NOTCHBUDDY_HOME"
LOG="$NOTCHBUDDY_HOME/Library/Logs/NotchBuddy/perf.log"

LOAD_PIDS=()
APP_PID=""
cleanup() {
    for pid in "${LOAD_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        "$BIN" --perf-send quit || true
        sleep 0.5
        kill "$APP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

send() { "$BIN" --perf-send "$@"; }

"$BIN" >/dev/null 2>&1 &
APP_PID=$!
sleep 2.5
kill -0 "$APP_PID" 2>/dev/null || { echo "dev instance did not start (another one on $NOTCHBUDDY_SOCKET?)" >&2; exit 1; }
send style "$STYLE"
sleep 0.5
send seed
sleep 1.5
if [ "$TABS" = 1 ]; then
    send tabs
    sleep 0.5
fi

if [ "$LOAD" = 1 ]; then
    for _ in $(seq "$(sysctl -n hw.ncpu)"); do
        yes > /dev/null &
        LOAD_PIDS+=($!)
    done
    sleep 3
fi

TAG="bench ${LABEL:+$LABEL }style=$STYLE drag=$DRAG load=$LOAD runs=$RUNS $(date +%s)"
send mark "begin $TAG"
for _ in $(seq "$RUNS"); do
    send hover;       sleep 0.45
    send hover;       sleep 0.45
    send hoverOpen;   sleep 0.8
    if [ "$TABS" = 1 ]; then
        send tab timer;        sleep 0.7
        send tabClick system;  sleep 0.85
        send tabClick agents;  sleep 0.85
    fi
    send close;       sleep 0.7
    if [ "$DRAG" = 1 ]; then
        send offset -480; sleep 0.6
        send hoverOpen;   sleep 0.8
        send close;       sleep 0.7
        send offset 0;    sleep 0.6
        send drag -360;   sleep 1.1
        send drag 360;    sleep 1.1
        send offset -2000; sleep 0.6
        send hoverOpen;   sleep 0.8
        send grab 360;    sleep 1.2
        send offset 0;    sleep 0.6
    fi
    send flash;       sleep 0.8
    send dismiss;     sleep 0.7
    send card;        sleep 0.8
    send cardAdvance; sleep 0.8
    send clearCards;  sleep 0.8
done
# The window server's own pictures of the island while the list opens with the main thread blocked for 300 ms.
for _ in 1 2 3; do
    send verify 0.3; sleep 1.4
done
send mark "end $TAG"
sleep 0.3

for pid in "${LOAD_PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
LOAD_PIDS=()

python3 "$(dirname "$0")/perf-summary.py" "$LOG" "$TAG"
awk -v tag="# begin $TAG" 'index($0, tag) == 1 { on = 1 } on && /^# verify/ { sub(/ load [0-9.]+$/, ""); print }' "$LOG"
