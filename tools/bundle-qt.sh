#!/bin/bash
# Packs the Qt app into a self-contained macOS bundle that runs on a Mac without Homebrew or this checkout.
# Usage: tools/bundle-qt.sh   Result: build/Wirebench-Qt.app (ad-hoc signed; see the notes at the end)
set -e
cd "$(dirname "$0")/.."
# Every slow step has a time limit, so a hung tool ends the script with a message instead of leaving it stuck.
within() { local seconds=$1; shift; if command -v timeout >/dev/null; then timeout "$seconds" "$@" || { echo "error: '$1' did not finish (limit ${seconds}s, or it failed)"; exit 1; }; else "$@"; fi; }
[ "$(uname)" = Darwin ] || { echo "bundle-qt.sh makes a macOS .app; on Linux build with tools/build-qt.sh on the target machine"; exit 1; }

within 900 tools/build-qt.sh Release
BRIDGE=$(find .build -type f -path "*Release*" -not -path "*.dSYM*" -name 'libWirebenchBridge.dylib' | head -1)
QT_PREFIX=$(brew --prefix qt)
APP=build/Wirebench-Qt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

cp build/qt/wirebench-qt "$APP/Contents/MacOS/Wirebench-Qt"
cp "$BRIDGE" "$APP/Contents/Frameworks/libWirebenchBridge.dylib"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Wirebench-Qt</string>
  <key>CFBundleIdentifier</key><string>com.wirebench.WirebenchQt</string>
  <key>CFBundleName</key><string>Wirebench (Qt)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>PCC Project File</string>
    <key>CFBundleTypeExtensions</key><array><string>pcc</string></array>
    <key>CFBundleTypeRole</key><string>Editor</string>
  </dict></array>
</dict></plist>
PLIST

# The Qt the app uses, and what that needs, copied in and re-pointed (see the script for why this is not macdeployqt).
within 300 python3 tools/bundle-qt.py "$APP" "$BRIDGE"

echo "built $APP ($(du -sh "$APP" | cut -f1))"
echo "Unsigned for distribution: the first time on another Mac, right-click > Open, or: xattr -dr com.apple.quarantine Wirebench-Qt.app"
