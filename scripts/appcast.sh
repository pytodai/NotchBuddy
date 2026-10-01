#!/bin/bash
# Adds a release to the Sparkle feed (appcast.xml at the repository root, read by the app from the main branch).
#   scripts/appcast.sh <version> <build> <ed-signature> <length> <notes.md> [appcast.xml]
# The feed is cumulative, newest item first, and builds only go up: Sparkle compares sparkle:version (<build>,
# CFBundleVersion), so an item replaced under a build number already published would never reach anyone who has
# that build. REPLACE=1 allows replacing an item with the same build anyway (a release that was never published).
# <version> is CFBundleShortVersionString. The signature and length come from Sparkle's sign_update for
# Notchbuddy-<version>.zip, <notes.md> from scripts/release-notes.sh (scripts/release.sh passes them all). The notes
# go into the feed as Markdown, so the update window needs no web page; the GitHub release is linked as the full
# changelog. PUB_DATE overrides the item's date (RFC 822, e.g. "Mon, 06 Jan 2025 18:00:00 +0000"). RELEASE_TAG is the
# GitHub release that holds the zip, v<version> by default.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 5 ] || [ $# -gt 6 ]; then
  echo "usage: $0 <version> <build> <ed-signature> <length> <notes.md> [appcast.xml]" >&2
  exit 2
fi
VERSION="$1"
BUILD="$2"
SIGNATURE="$3"
LENGTH="$4"
NOTES="$5"
FEED="${6:-appcast.xml}"
REPO="${NOTCHBUDDY_REPO:-pytodai/NotchBuddy}"
PUB_DATE="${PUB_DATE:-$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')}"
TAG="${RELEASE_TAG:-v$VERSION}"

VERSION="$VERSION" BUILD="$BUILD" SIGNATURE="$SIGNATURE" LENGTH="$LENGTH" NOTES="$NOTES" FEED="$FEED" REPO="$REPO" \
PUB_DATE="$PUB_DATE" TAG="$TAG" REPLACE="${REPLACE:-0}" /usr/bin/python3 - <<'PY'
import base64, os, re, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

def fail(message):
    print(f"appcast.sh: {message}", file=sys.stderr)
    sys.exit(1)

version, build = os.environ["VERSION"], os.environ["BUILD"]
signature, length = os.environ["SIGNATURE"], os.environ["LENGTH"]
notes_path, feed = os.environ["NOTES"], os.environ["FEED"]
repo, pub_date, tag = os.environ["REPO"], os.environ["PUB_DATE"], os.environ["TAG"]
replace = os.environ["REPLACE"] == "1"

if not re.fullmatch(r"\d+(\.\d+){1,2}", version):
    fail(f"version {version!r} is not like 1.2 or 1.2.3")
if not re.fullmatch(r"v\d+(\.\d+){1,2}", tag):
    fail(f"tag {tag!r} is not like v1.2 or v1.2.3")
if not re.fullmatch(r"\d+", build):
    fail(f"build {build!r} is not a whole number")
if not re.fullmatch(r"\d+", length) or int(length) == 0:
    fail(f"length {length!r} is not a byte count")
try:
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError
except ValueError:
    fail("the signature is not a base64 Ed25519 signature")
try:
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read().strip()
except OSError as error:
    fail(f"cannot read the release notes: {error}")
if not notes:
    fail(f"{notes_path} is empty")

def s(tag):
    return f"{{{SPARKLE}}}{tag}"

if os.path.exists(feed):
    tree = ET.parse(feed)
    rss = tree.getroot()
    channel = rss.find("channel")
    if channel is None:
        fail(f"{feed} has no <channel>")
else:
    rss = ET.Element("rss", {"version": "2.0"})
    tree = ET.ElementTree(rss)
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Notchbuddy"
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}/releases"
    ET.SubElement(channel, "description").text = "Notchbuddy updates"
    ET.SubElement(channel, "language").text = "en"

def item_build(item):
    text = (item.findtext(s("version")) or "").strip()
    return int(text) if text.isdigit() else -1

items = channel.findall("item")
newer = [item_build(i) for i in items if item_build(i) > int(build)]
if newer:
    fail(f"the feed already has a newer build ({max(newer)}); builds only go up")
if any(item_build(i) == int(build) for i in items) and not replace:
    fail(f"the feed already has build {build}; a published build cannot be replaced (REPLACE=1 if it never was)")
items = [i for i in items if item_build(i) != int(build)]
for old in channel.findall("item"):
    channel.remove(old)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, s("version")).text = build
ET.SubElement(item, s("shortVersionString")).text = version
ET.SubElement(item, s("minimumSystemVersion")).text = "14.0"
ET.SubElement(item, "description", {s("format"): "markdown"}).text = notes
ET.SubElement(item, s("fullReleaseNotesLink")).text = f"https://github.com/{repo}/releases/tag/{tag}"
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/{repo}/releases/download/{tag}/Notchbuddy-{version}.zip",
    "length": length,
    "type": "application/octet-stream",
    s("edSignature"): signature,
})

for entry in sorted([item] + items, key=item_build, reverse=True):
    channel.append(entry)

# Every item's notes go out as CDATA: Markdown stays readable in the feed instead of turning into entities.
cdata = {}
for index, description in enumerate(channel.iter("description")):
    if description.get(s("format")) and description.text:
        token = f"@@notes-{index}@@"
        cdata[token] = "<![CDATA[" + description.text.replace("]]>", "]]]]><![CDATA[>") + "]]>"
        description.text = token

ET.indent(tree, space="  ")
xml = ET.tostring(rss, encoding="unicode")
for token, section in cdata.items():
    if xml.count(token) != 1:
        fail("could not place the release notes")
    xml = xml.replace(token, section)
with open(feed, "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="utf-8"?>\n' + xml + "\n")
print(f"{feed}: {version} (build {build}) added, {len(items) + 1} item(s)")
PY
