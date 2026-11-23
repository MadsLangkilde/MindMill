#!/bin/bash
# Builds Mindmill.app and packs it into build/Mindmill-<version>.dmg to send to someone: the app, a link to Applications,
# and how to open it the first time. The app is signed ad hoc (KB_SIGN_IDENTITY for a real certificate), so macOS
# asks the user to allow it once.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Mindmill.app/Contents/Info.plist)"
STAGE=build/dmg
DMG="build/Mindmill-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Mindmill.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Mindmill $VERSION

1. Drag Mindmill to Applications.
2. Open Mindmill. The first time, macOS says it can't check it: open System Settings → Privacy & Security,
   scroll down and click Open Anyway next to Mindmill. (Or right-click Mindmill in Applications and choose Open.)
3. Mindmill walks you through the rest: Claude Code, signing in, where your knowledge base lives, and your tools.

Mindmill needs macOS 14 or later.
TXT
hdiutil create -volname "Mindmill $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Packed $(pwd)/$DMG"
