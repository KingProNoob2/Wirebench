#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "⚙️  Generating Xcode project with xcodegen..."
xcodegen generate

echo "🔨 Building Dirigo scheme in Release configuration using xcodebuild..."
xcodebuild -project Dirigo.xcodeproj -scheme Dirigo -configuration Release build

DERIVED_DATA_DIR=$(xcodebuild -project Dirigo.xcodeproj -scheme Dirigo -configuration Release -showBuildSettings | grep -m 1 "TARGET_BUILD_DIR" | awk '{print $3}')
BUILT_APP="$DERIVED_DATA_DIR/Dirigo.app"

if [ ! -d "$BUILT_APP" ]; then
    echo "❌ Error: Could not find built application bundle at $BUILT_APP"
    exit 1
fi

APP_NAME="Dirigo.app"
APP_DIR="$SCRIPT_DIR/$APP_NAME"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

echo "📦 Copying Xcode-built bundle..."
rm -rf "$APP_DIR"
cp -R "$BUILT_APP" "$APP_DIR"

rm -rf "$PARENT_DIR/$APP_NAME"
cp -R "$APP_DIR" "$PARENT_DIR/$APP_NAME"

echo ""
echo "✅ Success! Dirigo.app created via Xcode build system at:"
echo "   1) $APP_DIR"
echo "   2) $PARENT_DIR/$APP_NAME"
echo ""
echo "🚀 To run it:"
echo "   open \"$PARENT_DIR/$APP_NAME\""
echo "   or open \"$SCRIPT_DIR/Dirigo.xcodeproj\" directly in Xcode!"
