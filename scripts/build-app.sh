#!/bin/bash
# Builds NotchBuddy.app into ./build and optionally installs it.
#   scripts/build-app.sh            # build (release) → build/NotchBuddy.app
#   scripts/build-app.sh --install  # also copy to ~/Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

# iCloud Drive ("Desktop & Documents" sync) tags bundles created inside it with Finder info, which codesign
# rejects ("resource fork, Finder information, or similar detritus not allowed"), and would upload every
# build product. When the checkout is synced, both build dirs live in ~/Library/Caches and keep their
# usual paths as symlinks.
in_file_provider() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    xattr -p com.apple.file-provider-domain-id "$d" >/dev/null 2>&1 && return 0
    d="$(dirname "$d")"
  done
  return 1
}
if in_file_provider; then
  OUT="$HOME/Library/Caches/NotchBuddy/$(printf %s "$PWD" | shasum | cut -c1-12)"
  for dir in .build build; do
    [ -L "$dir" ] && [ "$(readlink "$dir")" = "$OUT/$dir" ] && continue
    rm -rf "$dir"  # build products only; both are gitignored
    mkdir -p "$OUT/$dir"
    ln -s "$OUT/$dir" "$dir"
  done
fi

CONFIG=release
swift build -c "$CONFIG" --product NotchBuddy
swift build -c "$CONFIG" --product notchbuddy-bridge
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/NotchBuddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/NotchBuddy" "$APP/Contents/MacOS/NotchBuddy"
cp "$BIN/notchbuddy-bridge" "$APP/Contents/Helpers/notchbuddy-bridge"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
[ -d Resources/Fonts ] && cp -R Resources/Fonts "$APP/Contents/Resources/"  # Manrope + OFL (NBTypography)
for l in Resources/*.lproj; do [ -d "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done  # InfoPlist.strings (permission prompts)
# Localization tables (NotchBuddyCore's resources, read by `L10n`): a plain folder of <lang>.lproj.
CORE_BUNDLE="$BIN/NotchBuddy_NotchBuddyCore.bundle"
L10N_SRC="$CORE_BUNDLE/Contents/Resources"
[ -d "$L10N_SRC" ] || L10N_SRC="$CORE_BUNDLE"
mkdir -p "$APP/Contents/Resources/Localization"
cp -R "$L10N_SRC/"*.lproj "$APP/Contents/Resources/Localization/"

# Stable designated requirement keeps TCC (Automation) grants across rebuilds when a
# real identity is available; otherwise fall back to ad-hoc.
DEFAULT_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-${DEFAULT_IDENTITY:--}}"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier me.sokolov.notchbuddy.bridge "$APP/Contents/Helpers/notchbuddy-bridge"
codesign --force --sign "$IDENTITY" --identifier me.sokolov.notchbuddy "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x NotchBuddy 2>/dev/null || true
  rm -rf "$DEST/NotchBuddy.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/NotchBuddy.app"
  echo "installed to $DEST/NotchBuddy.app"
fi
