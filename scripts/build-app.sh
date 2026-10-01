#!/bin/bash
# Builds NotchBuddy.app into ./build and optionally installs it.
#   scripts/build-app.sh            # build (release configuration) → build/NotchBuddy.app
#   scripts/build-app.sh --install  # also copy to ~/Applications and relaunch
#   scripts/build-app.sh --release  # the public build: universal (arm64 + x86_64), Developer ID, secure timestamps
#                                   # (NOTCHBUDDY_RELEASE=1 does the same)
#
# Signing identity: NOTCHBUDDY_SIGN_IDENTITY (a SHA-1 hash or a certificate name), else the first "Apple Development"
# certificate, else ad hoc. With --release it must be a "Developer ID Application" certificate (the first one in the
# keychain unless NOTCHBUDDY_SIGN_IDENTITY names another), and the build fails without one. A Developer ID signature
# always carries a secure timestamp, whatever the mode.
#
# A real identity signs every piece with the hardened runtime; the app gets Resources/NotchBuddy.entitlements (Apple
# Events for the terminal jump and the music widget, calendars for the calendar widget). An ad hoc build has no
# runtime: library validation would refuse a Sparkle.framework without a Team ID.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=dev
[ "${NOTCHBUDDY_RELEASE:-0}" = 1 ] && MODE=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) MODE=release ;;
    *) echo "usage: $0 [--release] [--install]" >&2; exit 2 ;;
  esac
done
fail() { echo "build-app.sh: $*" >&2; exit 1; }

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

# The signing identity, chosen before the (long) build so a release without a certificate fails at once.
identities() { security find-identity -v -p codesigning 2>/dev/null || true; }
first_identity() { identities | awk -v kind="\"$1: " 'index($0, kind) {print $2; exit}'; }
if [ "$MODE" = release ]; then
  IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-$(first_identity "Developer ID Application")}"
  [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] \
    || fail "--release needs a \"Developer ID Application\" certificate in the keychain"
  identities | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application: ' \
    || fail "$IDENTITY is not a valid \"Developer ID Application\" identity"
else
  DEFAULT_IDENTITY="$(first_identity "Apple Development")"
  IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-${DEFAULT_IDENTITY:--}}"
fi

CONFIG=release
ARCHS=()
[ "$MODE" = release ] && ARCHS=(--arch arm64 --arch x86_64)
build() { swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} "$@"; }
build --product NotchBuddy
build --product notchbuddy-bridge
BIN="$(build --show-bin-path)"

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

# Sparkle (self-updates): the framework from SwiftPM's binary artifact, symlinks and all (ditto), in Contents/Frameworks.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || SPARKLE_SRC="$BIN/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || fail "Sparkle.framework not found (swift package resolve)"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$SPARKLE"
# The app finds it through @executable_path/../Frameworks (a linker flag in Package.swift). SwiftPM also leaves
# absolute rpaths into the build folder and the toolchain; a shipped binary has no business looking there (only the
# system's Swift runtime, /usr/lib/swift, stays).
EXE="$APP/Contents/MacOS/NotchBuddy"
BRIDGE="$APP/Contents/Helpers/notchbuddy-bridge"
rpaths() { otool -l "$1" | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u; }
outside_rpaths() { rpaths "$1" | grep '^/' | grep -vx '/usr/lib/swift' || true; }
grep -qx '@executable_path/../Frameworks' <<<"$(rpaths "$EXE")" \
  || install_name_tool -add_rpath '@executable_path/../Frameworks' "$EXE"
for binary in "$EXE" "$BRIDGE"; do
  while IFS= read -r path; do
    [ -n "$path" ] && { install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null || true; }
  done < <(outside_rpaths "$binary")
  [ -z "$(outside_rpaths "$binary")" ] || fail "$binary still has rpaths outside the app: $(outside_rpaths "$binary" | tr '\n' ' ')"
done

# Inside out, no --deep (Sparkle's guide for apps outside the sandbox): its XPC services, Autoupdate and Updater.app,
# then the framework, then the bridge and the app. Downloader.xpc keeps its own entitlements; Autoupdate must not
# (its com.apple.application-identifier is restricted and would stop it from launching).
SIGN=(codesign --force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN+=(--options runtime); fi
DEVELOPER_ID=0
[ "$IDENTITY" != "-" ] && identities | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application: ' && DEVELOPER_ID=1
if [ "$MODE" = release ] || [ "$DEVELOPER_ID" = 1 ]; then SIGN+=(--timestamp); else SIGN+=(--timestamp=none); fi
ENTITLEMENTS=Resources/NotchBuddy.entitlements
xattr -cr "$APP"
NESTED=()
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
  [ -e "$xpc" ] || continue
  case "$xpc" in
    *Downloader.xpc) "${SIGN[@]}" --preserve-metadata=entitlements "$xpc" ;;
    *) "${SIGN[@]}" "$xpc" ;;
  esac
  NESTED+=("$xpc")
done
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" --identifier me.sokolov.notchbuddy.bridge "$BRIDGE"
"${SIGN[@]}" --identifier me.sokolov.notchbuddy --entitlements "$ENTITLEMENTS" "$APP"
NESTED+=("$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$BRIDGE" "$APP")

codesign --verify --strict "$SPARKLE"
codesign --verify --deep --strict "$APP"
# The app's entitlements are exactly the file's.
codesign -d --entitlements - --xml "$APP" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
signed = plistlib.loads(sys.stdin.buffer.read() or plistlib.dumps({}))
wanted = plistlib.load(open(sys.argv[1], "rb"))
sys.exit(0 if signed == wanted else f"the app is signed with {signed}, not {wanted}")' "$ENTITLEMENTS"

if [ "$MODE" = release ]; then
  # Notarization wants every piece of code with the hardened runtime, a secure timestamp and the same team.
  TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ -n "$TEAM" ] && [ "$TEAM" != "not set" ] || fail "$APP has no Team ID"
  for code in "${NESTED[@]}"; do
    info="$(codesign -dvv "$code" 2>&1)"
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(([a-z-]+,)*runtime' <<<"$info" || fail "$code: no hardened runtime"
    grep -q '^Timestamp=' <<<"$info" || fail "$code: no secure timestamp"
    grep -qx "TeamIdentifier=$TEAM" <<<"$info" || fail "$code: not signed by team $TEAM"
    grep -q '^Authority=Developer ID Application: ' <<<"$info" || fail "$code: not signed with Developer ID"
  done
  for exe in "$EXE" "$BRIDGE"; do
    archs="$(lipo -archs "$exe")"
    for arch in arm64 x86_64; do
      grep -qw "$arch" <<<"$archs" || fail "$exe has no $arch slice ($archs)"
    done
  done
fi
echo "built $APP ($MODE, signed: $([ "$IDENTITY" = - ] && echo "ad hoc" || echo "$IDENTITY"))"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x NotchBuddy 2>/dev/null || true
  rm -rf "$DEST/NotchBuddy.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/NotchBuddy.app"
  echo "installed to $DEST/NotchBuddy.app"
fi
