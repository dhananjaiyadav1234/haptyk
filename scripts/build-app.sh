#!/bin/bash
# Builds Thock.app (and optionally a DMG) into ./dist.   Usage: scripts/build-app.sh [--dmg]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${THOCK_VERSION:-1.0.0}"
BUNDLE_ID="com.dhananjai.thock"
DIST="dist"
APP="$DIST/Thock.app"

echo "▸ Building release binary (universal if the toolchain allows)"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=".build/apple/Products/Release/Thock"
else
  echo "  universal build unavailable here; building for the host architecture only"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Thock"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Thock"

echo "▸ Generating icon"
ICONSET="$(mktemp -d)/Thock.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Thock.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Thock</string>
  <key>CFBundleDisplayName</key><string>Thock</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Thock</string>
  <key>CFBundleIconFile</key><string>Thock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal-use software. No data leaves your Mac.</string>
</dict></plist>
PLIST

echo "▸ Ad-hoc signing"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature OK (ad-hoc)"

if [ "${1:-}" = "--dmg" ]; then
  echo "▸ Creating DMG"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp docs/INSTALL.txt "$STAGE/Read Me First.txt" 2>/dev/null || true
  rm -f "$DIST/Thock-$VERSION.dmg"
  hdiutil create -volname "Thock" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Thock-$VERSION.dmg" >/dev/null
  echo "  $DIST/Thock-$VERSION.dmg"
fi
echo "✔ $APP"
