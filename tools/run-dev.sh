#!/bin/bash
# Build (incremental, ~2s) then run in a real app bundle so the window server gives it a window.
set -e
cd "/Users/erik/Nextcloud/Random Stuff/dirigo-antigravity/DirigoSwift"
swift build --disable-sandbox 2>&1 | grep -E "error:|Build complete" | tail -2
cp .build/debug/DirigoApp /tmp/wrap/T.app/Contents/MacOS/DirigoApp
codesign --force --sign - /tmp/wrap/T.app >/dev/null 2>&1
pkill -f "/tmp/wrap/T.app/Contents/MacOS/DirigoApp" 2>/dev/null || true
sleep 0.5
open -a /tmp/wrap/T.app "$1"
