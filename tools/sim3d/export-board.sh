#!/bin/bash
# Regenerate the simulator's 3D assets from the KiCad projects.
# Usage: tools/sim3d/export-board.sh [path-to-KiCad-folder]
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
KICAD="${1:-$HOME/Downloads/KiCad}"
KICAD_CLI="/Volumes/Data/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
# The footprint 3D model paths use ${KICAD10_3DMODEL_DIR}; the GUI sets it, the CLI does not.
export KICAD10_3DMODEL_DIR="/Volumes/Data/Applications/KiCad/KiCad.app/Contents/SharedSupport/3dmodels"
BLENDER="/Volumes/Data/Applications/Blender.app/Contents/MacOS/Blender"
WORK="$ROOT"
ASSETS="$(cd "$ROOT/../.." && pwd)/Sources/WirebenchApp/SimulatorAssets"

"$KICAD_CLI" pcb export glb --subst-models --grid-origin --output "$WORK/board.glb" "$KICAD/Duino-S/Duino-S.kicad_pcb"
"$KICAD_CLI" pcb export glb --subst-models --grid-origin --output "$WORK/shield.glb" "$KICAD/Duino-S-Shield/Duino-S-Shield.kicad_pcb"
"$BLENDER" -b --factory-startup -P "$ROOT/glb2usdc.py" -- "$WORK/board.glb" "$WORK/board.usdc"
"$BLENDER" -b --factory-startup -P "$ROOT/glb2usdc.py" -- "$WORK/shield.glb" "$WORK/shield.usdc"
rm -f "$ASSETS/board.usdz" "$ASSETS/shield.usdz"
usdzip "$ASSETS/board.usdz" "$WORK/board.usdc"
usdzip "$ASSETS/shield.usdz" "$WORK/shield.usdc"

"$KICAD_CLI" sch export netlist --format kicadxml --output /tmp/duino-s-netlist.xml "$KICAD/Duino-S/Duino-S.kicad_sch"
"$KICAD_CLI" sch export netlist --format kicadxml --output /tmp/duino-s-shield-netlist.xml "$KICAD/Duino-S-Shield/Duino-S-Shield.kicad_sch"
python3 "$ROOT/manifest.py" /tmp/duino-s-netlist.xml --shield /tmp/duino-s-shield-netlist.xml --output "$ASSETS/board-manifest.json"
echo "Assets regenerated in $ASSETS"
