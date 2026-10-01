#!/bin/bash
# Packs an app into a drag-to-install disk image: the app beside a link to /Applications.
#   scripts/make-dmg.sh [--release] build/NotchBuddy.app build/release/Notchbuddy-1.1.dmg
# Uses create-dmg (Homebrew) for a laid-out window when it is installed, plain hdiutil otherwise
# (MAKE_DMG_PLAIN=1 forces hdiutil).
#
# The image is signed with NOTCHBUDDY_SIGN_IDENTITY, else the first "Apple Development" certificate (an unsigned
# image only gets a warning). --release requires a "Developer ID Application" identity (NOTCHBUDDY_SIGN_IDENTITY or
# the first one in the keychain), adds a secure timestamp and fails instead of leaving the image unsigned.
# Notarizing and stapling the image is scripts/release.sh's job.
set -euo pipefail

RELEASE=0
if [ "${1:-}" = "--release" ]; then
  RELEASE=1
  shift
fi
if [ $# -ne 2 ]; then
  echo "usage: $0 [--release] <app> <out.dmg>" >&2
  exit 2
fi
APP="${1%/}"
OUT="$2"
VOLNAME="Notchbuddy"
fail() { echo "make-dmg.sh: $*" >&2; exit 1; }
[ -d "$APP" ] || fail "no app at $APP"

identities() { security find-identity -v -p codesigning 2>/dev/null || true; }
first_identity() { identities | awk -v kind="\"$1: " 'index($0, kind) {print $2; exit}'; }
if [ "$RELEASE" = 1 ]; then
  IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-$(first_identity "Developer ID Application")}"
  [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] \
    || fail "--release needs a \"Developer ID Application\" certificate in the keychain"
  identities | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application: ' \
    || fail "$IDENTITY is not a valid \"Developer ID Application\" identity"
else
  IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-$(first_identity "Apple Development")}"
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"  # the volume's root; mktemp makes it private
APP_NAME="$(basename "$APP")"
ditto "$APP" "$STAGE/$APP_NAME"

if [ "${MAKE_DMG_PLAIN:-0}" != 1 ] && command -v create-dmg >/dev/null 2>&1 \
   && create-dmg --help 2>&1 | grep -q -- '--app-drop-link'; then
  create-dmg \
    --volname "$VOLNAME" \
    --window-size 540 340 \
    --icon-size 96 \
    --icon "$APP_NAME" 140 160 \
    --hide-extension "$APP_NAME" \
    --app-drop-link 400 160 \
    "$OUT" "$STAGE"
else
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
fi

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  if [ "$RELEASE" = 1 ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$OUT"
  else
    codesign --force --sign "$IDENTITY" --timestamp=none "$OUT"
  fi
  codesign --verify --strict "$OUT"
else
  echo "make-dmg.sh: no signing identity, $OUT is not signed" >&2
fi
hdiutil verify -quiet "$OUT"
echo "built $OUT"
