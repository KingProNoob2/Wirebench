#!/bin/bash
# Build (incremental, ~2s) then run in a real app bundle so the window server gives it a window.
# Usage: tools/run-dev.sh [project.pcc]
set -e
cd "$(dirname "$0")/.."
APP=/tmp/wrap/T.app

swift build --disable-sandbox 2>&1 | grep -E "error:|Build complete" | tail -2

# The bundle is only a wrapper around the debug binary; make it the first time.
if [ ! -d "$APP" ]; then
    mkdir -p "$APP/Contents/MacOS"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WirebenchApp</string>
<key>CFBundleIdentifier</key><string>com.wirebench.WirebenchApp.dev</string>
<key>CFBundleName</key><string>Wirebench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
fi

cp .build/debug/WirebenchApp "$APP/Contents/MacOS/WirebenchApp"
codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -f "$APP/Contents/MacOS/WirebenchApp" 2>/dev/null || true
sleep 0.5
open -a "$APP" "$@"
