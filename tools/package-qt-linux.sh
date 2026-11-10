#!/bin/bash
# Packs the built Qt app (tools/build-qt.sh) with just what it needs besides the system's Qt, as a zip that runs where Qt 6.5+ is installed.
# Usage: tools/package-qt-linux.sh [output.zip]     Result: wirebench-qt-linux-x86_64.zip   (Linux; needs patchelf and zip)
#
# In the zip: the app, the Swift bridge, and the Swift runtime libraries the bridge links (the machine need not have Swift).
# Not in it: Qt and the few system libraries, which every desktop has or gets from its package manager (see README.txt in the zip).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(realpath -m "${1:-wirebench-qt-linux-x86_64.zip}")
APP=build/qt/wirebench-qt
[ -x "$APP" ] || { echo "build first: tools/build-qt.sh Release" >&2; exit 1; }
BRIDGE=$(find .build -type f -name 'libWirebenchBridge.so' | head -1)
[ -n "$BRIDGE" ] || { echo "libWirebenchBridge.so not found under .build" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DIR="$STAGE/wirebench-qt"
mkdir -p "$DIR/lib"
cp "$APP" "$DIR/wirebench-qt"
cp "$BRIDGE" "$DIR/lib/"

# The Swift runtime: every library the bridge resolves from the toolchain's own directory (ldd is already transitive).
SWIFT_LIBS=$(ldd "$BRIDGE" | awk '$3 ~ /\/swift\// {print $3}' | sort -u)
[ -n "$SWIFT_LIBS" ] || { echo "found no Swift runtime libraries to bundle (is ldd's output what we expect?)" >&2; exit 1; }
for lib in $SWIFT_LIBS; do cp -L "$lib" "$DIR/lib/"; done

# Everything finds its neighbours by relative path, so the folder can be put anywhere.
patchelf --set-rpath '$ORIGIN/lib' "$DIR/wirebench-qt"
for lib in "$DIR"/lib/*.so*; do patchelf --set-rpath '$ORIGIN' "$lib"; done
strip --strip-unneeded "$DIR/wirebench-qt" "$DIR/lib/libWirebenchBridge.so" 2>/dev/null || true

# Nothing may be missing but Qt and the system's own libraries.
MISSING=$(ldd "$DIR/wirebench-qt" | grep 'not found' | grep -v -e 'libQt6' || true)
[ -z "$MISSING" ] || { echo "the bundle still needs:" >&2; echo "$MISSING" >&2; exit 1; }

cat > "$DIR/README.txt" <<'TXT'
Wirebench (Qt) for 64-bit Linux.

Run:    ./wirebench-qt [project.pcc]

Needs Qt 6.5 or newer (Quick, Controls, Layouts, Shapes, Dialogs) and a few system libraries. On Ubuntu 26.04 and Debian:

  sudo apt install libqt6quick6 libqt6quickcontrols2-6 qt6-qpa-plugins \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window \
    qml6-module-qtquick-templates qml6-module-qtquick-shapes qml6-module-qtquick-dialogs libxml2-16 libcurl4t64

Other distributions: the Qt Base, Declarative (Quick, Controls, Layouts, Shapes, Dialogs) packages, libxml2 and libcurl.
Swift is not needed: its runtime is in lib/. To upload to a PLC the user needs serial access: sudo usermod -aG dialout $USER.
With no display, run with QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software.
TXT

rm -f "$OUT"
(cd "$STAGE" && zip -qr -X "$OUT" wirebench-qt)
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)):"
zip -sf "$OUT"
