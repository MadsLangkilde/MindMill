#!/bin/bash
# Builds Mindmill.app into macos/build. With --install, also copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

swift build -c release
BIN="$(swift build -c release --show-bin-path)/KB"

APP=build/Mindmill.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mindmill"

ICON=build/AppIcon.icns
LOGO=../art/mindmill-logo.png
if [ ! -f "$ICON" ] || [ Scripts/make-icon.swift -nt "$ICON" ] || [ "$LOGO" -nt "$ICON" ]; then
  swiftc -O -o build/make-icon Scripts/make-icon.swift
  rm -rf build/AppIcon.iconset
  build/make-icon "$LOGO" build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# The plugin goes inside the app, so a new Mac needs nothing else: sessions load it with --plugin-dir.
PLUGIN="$APP/Contents/Resources/plugin"
mkdir -p "$PLUGIN"
for part in .claude-plugin scripts skills hooks bin strategies docs README.md; do
  [ -e "../$part" ] && cp -R "../$part" "$PLUGIN/"
done
find "$PLUGIN" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$PLUGIN" -name .DS_Store -delete
VERSION="$(python3 -c 'import json;print(json.load(open("../.claude-plugin/plugin.json"))["version"])' 2>/dev/null || echo 0.1.0)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mindmill</string>
  <key>CFBundleDisplayName</key><string>Mindmill</string>
  <key>CFBundleExecutable</key><string>Mindmill</string>
  <key>CFBundleIdentifier</key><string>dk.langkilde.kb</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>KBGitCommit</key><string>$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo dev)$(git -C "$(dirname "$0")" diff --quiet HEAD 2>/dev/null || echo "+")</string>
  <key>KBBuildDate</key><string>$(date "+%Y-%m-%d %H:%M")</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>Mindmill transcribes a meeting on this Mac when you turn on Transcribe. The audio is never stored or sent anywhere.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Mindmill turns meeting audio into text on this Mac, without sending it anywhere.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dk.langkilde.kb</string>
      <key>CFBundleURLSchemes</key><array><string>kb</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# macOS keys privacy permissions (Screen & System Audio Recording, Microphone, Speech Recognition) to the app's
# designated requirement. An ad-hoc signature's default one is the build's hash, so every rebuild looked like a new
# app and lost them while System Settings still showed the app as allowed. Naming the bundle id keeps them across builds.
# KB_SIGN_IDENTITY signs with a real certificate instead.
if [ -n "${KB_SIGN_IDENTITY:-}" ]; then
  codesign -s "$KB_SIGN_IDENTITY" --force --deep "$APP"
else
  codesign -s - --force --deep -r='designated => identifier "dk.langkilde.kb"' "$APP"
fi
echo "Built $(pwd)/$APP"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Mindmill.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -f "$DEST" || true
  echo "Installed $DEST"
  # The app was called KB before; take the old copy away so kb:// links and Spotlight find only Mindmill.
  OLD="$HOME/Applications/KB.app"
  if [ -d "$OLD" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" = dk.langkilde.kb ]; then
    "$LSREGISTER" -u "$OLD" || true
    rm -rf "$OLD"
    echo "Removed the old $OLD"
  fi
fi
