#!/bin/bash
# Build the shared version of Eyes Only and package it to send to people:
#   Eyes-Only.dmg  — the usual Mac installer: open it, drag Eyes Only onto Applications
#   Eyes-Only.zip  — the same files as a zip
set -euo pipefail
cd "$(dirname "$0")/.."
SHIP=1 Scripts/build.sh
STAGE="$(mktemp -d)/Eyes Only"
mkdir -p "$STAGE"
cp -R "build-ship/Eyes Only.app" "$STAGE/"
cp "Packaging/READ ME FIRST.md" "Packaging/Fix Permissions.command" "$STAGE/"
chmod +x "$STAGE/Fix Permissions.command"
rm -f Eyes-Only.zip
ditto -c -k --norsrc --keepParent "$STAGE" Eyes-Only.zip   # --norsrc: no __MACOSX junk
# Disk image: the app next to a shortcut to Applications.
ln -s /Applications "$STAGE/Applications"
rm -f Eyes-Only.dmg
hdiutil create -volname "Eyes Only" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov Eyes-Only.dmg >/dev/null
echo "Done: $PWD/Eyes-Only.dmg"
echo "Done: $PWD/Eyes-Only.zip"
