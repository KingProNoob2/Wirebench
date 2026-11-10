#!/bin/bash
# Builds the C bridge and runs the C smoke test against a project. Usage: tools/bridge-smoke.sh [project.pcc]
set -e
cd "$(dirname "$0")/.."
PROJECT=${1:-../rulkoshaddirigo.pcc}
swift build --product WirebenchBridge >/dev/null
LIB=$(dirname "$(find .build -name 'libWirebenchBridge.*' \( -name '*.so' -o -name '*.dylib' \) | head -1)")
OUT=$(mktemp -d)
cc -I Sources/WirebenchBridge/include Tests/BridgeSmoke/smoke.c -L "$LIB" -lWirebenchBridge -Wl,-rpath,"$PWD/$LIB" -o "$OUT/smoke"
"$OUT/smoke" "$PROJECT"
