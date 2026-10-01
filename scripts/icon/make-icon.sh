#!/bin/bash
# Regenerates Resources/AppIcon.icns from the SwiftUI art in this folder.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swiftc -parse-as-library -O -o "$TMP/icon" NotchShape.swift IconArt.swift
"$TMP/icon" "$TMP/icon-1024.png" "$PWD/mascot-claude.png"
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o ../../Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Resources/AppIcon.icns"
