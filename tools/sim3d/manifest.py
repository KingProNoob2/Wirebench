#!/usr/bin/env python3
"""Generate board-manifest.json for the Duino-S simulator 3D view.

Reads the KiCad netlist (XML) and maps every channel LED (D4..D27) to its DIO channel through
the R5k series resistor. Run after changing the schematic:

    kicad-cli sch export netlist --format kicadxml --output /tmp/duino-s.xml Duino-S.kicad_sch
    python3 tools/sim3d/manifest.py /tmp/duino-s.xml --output Sources/WirebenchApp/SimulatorAssets/board-manifest.json
"""
import argparse, json, re
import xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("netlist")
ap.add_argument("--shield", help="Duino-S-Shield KiCad XML netlist")
ap.add_argument("--output", required=True)
args = ap.parse_args()

tree = ET.parse(args.netlist)
nets = []
for net in tree.iter("net"):
    refs = [(node.get("ref"), node.get("pin")) for node in net.iter("node")]
    nets.append((net.get("name"), refs))
by_ref = {}
for name, refs in nets:
    for ref, pin in refs:
        by_ref.setdefault(ref, []).append((name, pin))

def channel(net):
    m = re.fullmatch(r"/\*?(\d+)", net or "")
    return int(m.group(1)) if m else None

leds = {}
for number in range(4, 28):
    ref = f"D{number}"
    anode = next((n for n, _ in by_ref.get(ref, [])
                  if n != "GND" and not (n or "").endswith("-K)")), None)
    if anode is None:
        continue
    for name, refs in nets:
        if name != anode:
            continue
        for rref, _ in refs:
            if not re.fullmatch(r"R\d+", rref or ""):
                continue
            other = [n for n, _ in by_ref.get(rref, []) if n != anode]
            ch = channel(other[0]) if other else None
            if ch is not None:
                leds[ref] = ch

buttons = {}
analog_inputs = {}
shield_leds = {}
if args.shield:
    shield_tree = ET.parse(args.shield)
    shield_nets = []
    for net in shield_tree.iter("net"):
        refs = [(node.get("ref"), node.get("pin")) for node in net.iter("node")]
        shield_nets.append((net.get("name"), refs))
    shield_by_ref = {}
    for name, refs in shield_nets:
        for ref, pin in refs:
            shield_by_ref.setdefault(ref, []).append((name, pin))

    for ref in ("SW1", "SW2", "SW4"):
        net = next(n for n, p in shield_by_ref[ref] if p == "1")
        buttons[f"Shield.{ref}"] = {"board": "shield", "node": ref,
                                    "channel": channel(net), "activeLow": False}
    for ref in ("SW3", "SW4"):
        net = next(n for n, p in by_ref[ref] if p == "1")
        buttons[f"Board.{ref}"] = {"board": "board", "node": ref,
                                   "channel": channel(net), "activeLow": True}

    for ref in ("R16", "R9", "R18", "R22"):
        net = next(n for n, p in shield_by_ref[ref] if p == "2")
        analog_inputs[ref] = {"board": "shield", "node": ref, "kind": "potentiometer",
                              "channel": int(re.search(r"A(\d+)", net).group(1))}
    analog_inputs["R24"] = {"board": "shield", "node": "R24", "kind": "ldr", "channel": 3}

    for ref in ("D1", "D2", "D4"):
        anode = next(n for n, p in shield_by_ref[ref] if p == "2")
        resistor = next(r for n, refs in shield_nets if n == anode
                        for r, _ in refs if re.fullmatch(r"R\d+", r or ""))
        source = next(n for n, _ in shield_by_ref[resistor] if n != anode)
        shield_leds[ref] = channel(source)

manifest = {
    "board": "board.usdc",
    "shield": "shield.usdc",
    "leds": dict(sorted(leds.items(), key=lambda kv: int(kv[0][1:]))),
    "shieldLeds": shield_leds,
    "display": {"node": "LED1", "board": "shield"},
    "power": {"node": "J7", "board": "board"},
    "buttons": buttons,
    "analogInputs": analog_inputs,
    "analogSelector": {"board": "shield", "node": "SW3", "channel": 3},
}
with open(args.output, "w") as fh:
    json.dump(manifest, fh, indent=2)
print(f"wrote {args.output}: {len(leds)} LEDs,", 
      "missing:", [f"D{n}" for n in range(4, 28) if f"D{n}" not in leds],
      "dupes:", len(set(leds.values())) != len(leds))
