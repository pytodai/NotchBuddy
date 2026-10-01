#!/bin/bash
# Builds a public release: signed with Developer ID, notarized and stapled. Publishing stays a manual step; the steps
# are printed at the end and nothing is committed, tagged or pushed.
#   scripts/release.sh <version> <build-number> <notes-file>       e.g. scripts/release.sh 1.1 2 notes.txt
#
# <notes-file>: the release's changes, one per line (scripts/release-notes.sh turns them into the release notes).
# RELEASE_TAG=<tag> publishes under another tag than v<version> (e.g. 1.0.0 under v1.0). When that tag already has a
# release on GitHub, the files are added to it next to what is there; nothing on it is replaced.
# PREV_TAG=<tag> (or "-") names the previous release for the "Full Changelog" link; by default it is the newest v* tag
# below the new one on the remote (NOTCHBUDDY_REMOTE, default origin). Local tags do not count: only what is published.
#
# Needs:
# - a "Developer ID Application" certificate in the login keychain (NOTCHBUDDY_SIGN_IDENTITY picks one of several);
# - a notarytool keychain profile, "notchbuddy" unless NOTARY_PROFILE says otherwise
#   (xcrun notarytool store-credentials notchbuddy);
# - SUPublicEDKey in Resources/Info.plist, and Sparkle's private key in the login keychain (generate_keys) or in a file
#   named by SPARKLE_KEY_FILE. Keep that file outside the repository.
#
# 1. Checks: the tag is not on the remote yet (unless RELEASE_TAG names it), the build number is above every build in appcast.xml, and the Sparkle
#    key signs what SUPublicEDKey verifies.
# 2. Sets CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist.
# 3. Builds build/NotchBuddy.app: universal, Developer ID, hardened runtime, secure timestamps (build-app.sh --release).
# 4. Has Apple notarize the app and staples the ticket to it.
# 5. Packs build/release/Notchbuddy-<version>.zip (the update Sparkle downloads) and Notchbuddy-<version>.dmg from the
#    stapled app; the DMG is signed, notarized and stapled too. Gatekeeper then checks the app, the DMG and the app
#    inside the zip.
# 6. Writes build/release/notes-<tag>.md, signs the zip with Sparkle's EdDSA key and adds it, with the notes, to
#    appcast.xml (scripts/appcast.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 3 ]; then
  echo "usage: $0 <version> <build-number> <notes-file>" >&2
  exit 2
fi
VERSION="$1"
BUILD="$2"
NOTES_SRC="$3"
fail() { echo "release.sh: $*" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "version '$VERSION' is not like 1.2 or 1.2.3"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "build '$BUILD' is not a whole number"
[ -f "$NOTES_SRC" ] || fail "no notes file at $NOTES_SRC"
NOTES_SRC="$(cd "$(dirname "$NOTES_SRC")" && pwd)/$(basename "$NOTES_SRC")"

PLIST=Resources/Info.plist
PLISTBUDDY=/usr/libexec/PlistBuddy
REPO="${NOTCHBUDDY_REPO:-pytodai/NotchBuddy}"
REMOTE="${NOTCHBUDDY_REMOTE:-origin}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notchbuddy}"
TAG="${RELEASE_TAG:-v$VERSION}"
[[ "$TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]] || fail "tag '$TAG' is not like v1.2 or v1.2.3"
APP=build/NotchBuddy.app
OUT=build/release
ZIP="$OUT/Notchbuddy-$VERSION.zip"
DMG="$OUT/Notchbuddy-$VERSION.dmg"
NOTES="$OUT/notes-$TAG.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------------------------------
# 1. Checks, before anything is built.

# The tag must be new: a published release is never rebuilt. The one exception is a tag named on purpose with
# RELEASE_TAG; its release then only gains files (gh release upload without --clobber refuses to replace any).
REMOTE_TAGS="$(git ls-remote --tags --refs "$REMOTE")" || fail "could not list the tags on $REMOTE"
REMOTE_TAGS="$(sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/##p' <<<"$REMOTE_TAGS")"
EXISTING_TAG=0
if grep -qxF "$TAG" <<<"$REMOTE_TAGS"; then
  [ -n "${RELEASE_TAG:-}" ] \
    || fail "$TAG already exists on $REMOTE; an existing release is never rebuilt, pick a new version"
  EXISTING_TAG=1
  echo "$TAG is already on $REMOTE: the files go into its release, next to what is there"
elif git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "the tag $TAG already exists in this repository"
fi
if [ -n "${PREV_TAG+set}" ]; then
  PREV="$PREV_TAG"
else
  # The newest published tag that sorts below the new one.
  PREV="$( { grep -E '^v[0-9]+(\.[0-9]+){1,2}$' <<<"$REMOTE_TAGS" | grep -vxF "$TAG"; echo "$TAG"; } | sort -V \
    | grep -B1 -xF "$TAG" | grep -vxF "$TAG" || true)"
fi

# Builds only go up: Sparkle compares sparkle:version, so a build at or below a published one reaches nobody.
LAST_BUILD="$(/usr/bin/python3 - appcast.xml <<'PY'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
builds = [(item.findtext(S + "version") or "").strip() for item in ET.parse(sys.argv[1]).getroot().iter("item")]
print(max((int(b) for b in builds if b.isdigit()), default=0))
PY
)"
[ "$BUILD" -gt "$LAST_BUILD" ] || fail "build $BUILD is not above the newest build in appcast.xml ($LAST_BUILD)"

# Developer ID, the notary profile and Sparkle's tools.
identities() { security find-identity -v -p codesigning 2>/dev/null || true; }
IDENTITY="${NOTCHBUDDY_SIGN_IDENTITY:-$(identities | awk '/"Developer ID Application: / {print $2; exit}')}"
[ -n "$IDENTITY" ] || fail "no \"Developer ID Application\" certificate in the keychain"
identities | grep -F -- "$IDENTITY" | grep -q '"Developer ID Application: ' \
  || fail "$IDENTITY is not a valid \"Developer ID Application\" identity"
export NOTCHBUDDY_SIGN_IDENTITY="$IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || fail "notarytool cannot use the keychain profile '$NOTARY_PROFILE' (xcrun notarytool store-credentials $NOTARY_PROFILE)"

SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve >/dev/null
[ -x "$SPARKLE_BIN/sign_update" ] || fail "Sparkle's sign_update not found in $SPARKLE_BIN"
KEY_ARGS=()
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
  [ -f "$SPARKLE_KEY_FILE" ] || fail "no Sparkle key file at $SPARKLE_KEY_FILE"
  case "$(cd "$(dirname "$SPARKLE_KEY_FILE")" && pwd)/" in
    "$PWD"/*) fail "keep the Sparkle key file outside the repository ($SPARKLE_KEY_FILE)" ;;
  esac
  KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
elif [ -n "${SPARKLE_ACCOUNT:-}" ]; then
  KEY_ARGS=(--account "$SPARKLE_ACCOUNT")
fi

# The app checks every update against SUPublicEDKey; a release signed with another key could never be installed.
PUBLIC_KEY="$("$PLISTBUDDY" -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
if [ -z "$PUBLIC_KEY" ] || [ "$PUBLIC_KEY" = SPARKLE_PUBLIC_KEY_PLACEHOLDER ]; then
  fail "SUPublicEDKey in $PLIST is not set. Run $SPARKLE_BIN/generate_keys once and put the public key it prints there."
fi
# sign_ed <file>: the EdDSA signature and length from sign_update, as "<signature> <length>".
sign_ed() {
  local signed signature length
  signed="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$1")" || return 1
  signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signed")"
  length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$signed")"
  [ -n "$signature" ] && [ -n "$length" ] || { echo "sign_update gave no signature: $signed" >&2; return 1; }
  echo "$signature $length"
}
# verify_ed <file> <signature>: the signature checks out against SUPublicEDKey (not just against the key that made it).
verify_ed() {
  xcrun swift - "$PUBLIC_KEY" "$2" "$1" <<'SWIFT'
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard arguments.count == 4, let key = Data(base64Encoded: arguments[1]), let signature = Data(base64Encoded: arguments[2]),
      let data = FileManager.default.contents(atPath: arguments[3]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(2) }
exit(publicKey.isValidSignature(signature, for: data) ? 0 : 1)
SWIFT
}
printf 'Notchbuddy %s\n' "$VERSION" > "$WORK/probe"
PROBE="$(sign_ed "$WORK/probe")" || fail "could not sign with Sparkle's key"
read -r PROBE_SIGNATURE _ <<<"$PROBE"
verify_ed "$WORK/probe" "$PROBE_SIGNATURE" || fail "Sparkle's private key does not match SUPublicEDKey in $PLIST"

# The notes file is usable (checked again when the notes are written).
scripts/release-notes.sh "${PREV:--}" "$TAG" "$NOTES_SRC" >/dev/null

# ---------------------------------------------------------------------------------------------------------------------
# 2. Version. A plain substitution keeps the file's layout (PlistBuddy would rewrite all of it).
VERSION="$VERSION" BUILD="$BUILD" perl -0pi -e '
  s{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)}{$1$ENV{VERSION}$2};
  s{(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)}{$1$ENV{BUILD}$2};
' "$PLIST"
plutil -lint -s "$PLIST"
[ "$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] || fail "could not set the version"
[ "$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD" ] || fail "could not set the build number"

# 3. The app.
scripts/build-app.sh --release
[ "$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || fail "$APP does not carry version $VERSION"

# 4. Notarization. notarize <file>: submits it, waits for Apple's verdict and prints the log unless it is Accepted.
notarize() {
  local result id status
  echo "notarizing $(basename "$1")…"
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  read -r id status < <(/usr/bin/python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    d = {}
print(d.get("id") or "-", d.get("status") or "-")' <<<"$result")
  if [ "$status" != Accepted ]; then
    echo "$result" >&2
    [ "$id" != - ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$1") ended with status $status"
  fi
  echo "notarized $(basename "$1") ($id)"
}
ditto -c -k --keepParent "$APP" "$WORK/NotchBuddy.zip"
notarize "$WORK/NotchBuddy.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Archives, from the stapled app.
mkdir -p "$OUT"
rm -f "$ZIP" "$DMG" "$NOTES"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
scripts/make-dmg.sh --release "$APP" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# Gatekeeper, as a downloaded copy would meet it.
spctl -a -vvv -t exec "$APP" 2>&1 | tee "$WORK/spctl-app"
grep -q 'source=Notarized Developer ID' "$WORK/spctl-app" || fail "Gatekeeper does not see $APP as notarized"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tee "$WORK/spctl-dmg"
grep -q 'source=Notarized Developer ID' "$WORK/spctl-dmg" || fail "Gatekeeper does not see $DMG as notarized"
mkdir "$WORK/unzipped"
ditto -x -k "$ZIP" "$WORK/unzipped"
codesign --verify --deep --strict "$WORK/unzipped/NotchBuddy.app"
xcrun stapler validate "$WORK/unzipped/NotchBuddy.app"

# 6. Notes, signature and feed. The signature and length describe the final, stapled zip.
scripts/release-notes.sh "${PREV:--}" "$TAG" "$NOTES_SRC" > "$NOTES"
SIGNED="$(sign_ed "$ZIP")" || fail "could not sign $ZIP"
read -r SIGNATURE LENGTH <<<"$SIGNED"
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --verify "$ZIP" "$SIGNATURE" >/dev/null
verify_ed "$ZIP" "$SIGNATURE" || fail "the signature of $ZIP does not verify against SUPublicEDKey"
RELEASE_TAG="$TAG" scripts/appcast.sh "$VERSION" "$BUILD" "$SIGNATURE" "$LENGTH" "$NOTES"

# ---------------------------------------------------------------------------------------------------------------------
ABS_OUT="$PWD/$OUT"
cat <<EOF

Release $VERSION (build $BUILD) is ready in $OUT, signed with Developer ID, notarized and stapled:
  $(basename "$DMG")  $(du -h "$DMG" | cut -f1 | tr -d ' ')
  $(basename "$ZIP")  $(du -h "$ZIP" | cut -f1 | tr -d ' ')
  $(basename "$NOTES")  (tag $TAG, previous release: ${PREV:-none})

Nothing has been committed, tagged or published. The app reads appcast.xml from the main branch, so the feed goes
up only after the files it points to.
EOF
# How the files reach GitHub: a new tag gets its own release; an existing one (RELEASE_TAG) gets the files added.
if [ "$EXISTING_TAG" = 1 ]; then
  UPLOAD="gh release upload $TAG \"$ABS_OUT/$(basename "$DMG")\" \"$ABS_OUT/$(basename "$ZIP")\" --repo $REPO"
  UPLOAD_NOTE="(no --clobber: files already on the release stay as they are; to use the notes as the release text,
     gh release edit $TAG --repo $REPO --notes-file \"$ABS_OUT/$(basename "$NOTES")\")"
else
  UPLOAD="gh release create $TAG \"$ABS_OUT/$(basename "$DMG")\" \"$ABS_OUT/$(basename "$ZIP")\" --repo $REPO --verify-tag \\
       --title \"Notchbuddy $VERSION\" --notes-file \"$ABS_OUT/$(basename "$NOTES")\""
  UPLOAD_NOTE=""
fi
if git merge-base --is-ancestor "$REMOTE/main" HEAD 2>/dev/null; then
  if [ "$EXISTING_TAG" = 1 ]; then PUSH="git push $REMOTE main"; else PUSH="git tag $TAG && git push --atomic $REMOTE main $TAG"; fi
  cat <<EOF

This checkout continues $REMOTE/main, so it can be published from here:

  git add $PLIST && git commit -m "Version $VERSION"
  $PUSH
  $UPLOAD
  ${UPLOAD_NOTE:+$UPLOAD_NOTE
  }git add appcast.xml && git commit -m "Appcast: $VERSION" && git push $REMOTE main
EOF
else
  if [ "$EXISTING_TAG" = 1 ]; then
    STEP1="commit it as \"Version $VERSION\" (the tag $TAG stays where it is)."
    PUSH="git push origin main"
  else
    STEP1="commit it as \"Version $VERSION\" and tag it $TAG."
    PUSH="git push --atomic origin main $TAG"
  fi
  cat <<EOF

This checkout does not continue $REMOTE/main: push nothing from here, not even a tag (a tag would publish this
history). Publish from the public checkout instead:

  1. Bring the released source over, with CFBundleShortVersionString $VERSION and CFBundleVersion $BUILD in
     $PLIST, $STEP1
  2. $PUSH
  3. $UPLOAD
  ${UPLOAD_NOTE:+   $UPLOAD_NOTE
  }4. Once the files are up: copy $PWD/appcast.xml over the public appcast.xml, commit it as
     "Appcast: $VERSION" and git push origin main.
EOF
fi
