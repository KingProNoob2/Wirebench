#!/bin/bash
# Builds the Swift bridge and the Qt frontend. Usage: tools/build-qt.sh [Debug|Release]   Result: build/qt/wirebench-qt
# On macOS, Qt from Homebrew (`brew install qt`) is found automatically.
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-Release}
swift build -c "$(echo "$CONFIG" | tr A-Z a-z)" --product WirebenchBridge
LIB=$(dirname "$(find .build -type f -path "*$CONFIG*" -not -path "*.dSYM*" -name 'libWirebenchBridge.*' \( -name '*.so' -o -name '*.dylib' \) | head -1)")

ARGS=(-DCMAKE_BUILD_TYPE="$CONFIG" -DWIREBENCH_BRIDGE_DIR="$PWD/$LIB")
command -v ninja >/dev/null && ARGS+=(-G Ninja)
if [ -z "$CMAKE_PREFIX_PATH" ] && command -v brew >/dev/null && brew --prefix qt >/dev/null 2>&1; then
    ARGS+=(-DCMAKE_PREFIX_PATH="$(brew --prefix qt)")
fi
cmake -S qt -B build/qt "${ARGS[@]}"
cmake --build build/qt
echo "built build/qt/wirebench-qt"
