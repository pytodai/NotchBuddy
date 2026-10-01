#!/bin/bash
# Prints a GitHub release body in the usual "What's Changed" shape:
#   scripts/release-notes.sh <prev-tag|-> <new-tag> <bullets-file>
#   scripts/release-notes.sh v1.0 v1.1 notes.txt > build/release/notes-1.1.md
#   scripts/release-notes.sh - v1.1 notes.txt          # no earlier release to compare with
# The bullets file holds one change per line ("-", "*" or nothing in front); blank lines are skipped. The notes are
# written by hand on purpose: commit subjects are not release notes. <prev-tag> is the previous public release's
# tag, for the "Full Changelog" compare link.
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: $0 <prev-tag|-> <new-tag> <bullets-file>" >&2
  exit 2
fi
PREV="$1"
NEW="$2"
NOTES="$3"
REPO_URL="https://github.com/${NOTCHBUDDY_REPO:-pytodai/NotchBuddy}"
case "$PREV" in -|none) PREV="" ;; esac
fail() { echo "release-notes.sh: $*" >&2; exit 1; }

TAG_RE='^v[0-9]+(\.[0-9]+){1,2}$'
[[ "$NEW" =~ $TAG_RE ]] || fail "'$NEW' is not a tag like v1.2 or v1.2.3"
[ -z "$PREV" ] || [[ "$PREV" =~ $TAG_RE ]] || fail "'$PREV' is not a tag like v1.2 or v1.2.3"
[ "$PREV" != "$NEW" ] || fail "the previous tag is the new one"
[ -f "$NOTES" ] || fail "no bullets file at $NOTES"

LINES="$(sed -E -e 's/^[[:space:]]*[-*][[:space:]]+//' -e 's/[[:space:]]+$//' "$NOTES" | grep -v '^$' || true)"
[ -n "$LINES" ] || fail "$NOTES has no bullets"

echo "## What's Changed"
echo
while IFS= read -r line; do echo "* $line"; done <<<"$LINES"
echo
if [ -n "$PREV" ]; then
  echo "**Full Changelog**: $REPO_URL/compare/$PREV...$NEW"
else
  echo "**Full Changelog**: $REPO_URL/commits/$NEW"
fi
