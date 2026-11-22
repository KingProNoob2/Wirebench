# Duino-S Simulator 3D UI — implementation plan

_Status: implemented in the SwiftUI app. This is the original design plan; current behavior and
architecture are documented in `DUINO-S-HANDOVER.md` under “Simulator 3D UI”._

## Goal

A "Simulate Duino-S" feature in the macOS app: a 3D model of the KiCad board that mirrors the
running simulator live — the 24 DIO LEDs light with the DO map, the shield's 7-segment display
shows what the CH455G shows, the buttons are clickable, and the pin headers can be poked. Next to
the 3D view: simulator transport controls (start/pause/stop), temperature sliders for the TMP75 /
DS18B20, a big e-stop button, and the connection address (`127.0.0.1:5020`) so Maraflow or a
second Wirebench window can attach to the same simulated board.

## Key decision: in-app RealityKit, not KiCad's viewer, not live Blender

- **KiCad's 3D renderer** is a GUI viewer with no embeddable API and no way to drive state per
  frame. What KiCad *is* good for here is the export: `kicad-cli pcb export step` produces the
  board with its 3D models in one STEP file. It is step 1 of the asset pipeline, nothing more.
- **The running Blender instance** could be driven over a socket-embedded Python script, but it is
  a separate app and window, render-streaming is fragile and slow for an interactive UI, and the
  feature would die with the Blender session. Rejected as the UI; **Blender is still used** —
  headless (`blender -b`), as one link in the one-time asset conversion (it is already installed).
- **RealityKit** (macOS 14+; the app targets it) loads USDZ natively, does PBR + emissive
  materials, per-frame updates, tap/hover picking, and lives inside the app window next to
  Hardware Link. This is the render engine.

## Asset pipeline (one-time, scripted — `tools/sim3d/export-board.sh`)

1. `kicad-cli pcb export step --subst-models --no-unspecified --grid-origin` for
   `Duino-S.kicad_pcb` and `Duino-S-Shield.kicad_pcb` → `board.step`, `shield.step`.
   (`--subst-models` resolves the STEP files in `EASYEDA_MODELS/`; whatever has no model exports
   as its footprint outline, see Risks.)
2. `assimp export board.step board.glb -fglb2` (assimp is on PATH).
3. Blender headless: `blender -b -P tools/sim3d/glb2usdc.py -- board.glb board.usdc`
   (import glb, export USD). Output `.usdc` next to the app as a bundle resource.
4. **Spike first**: a throwaway RealityKit view that loads `board.usdc` and screenshots it, run
   before any UI work — if assimp's STEP triangulation is ugly, fall back to exporting two
   separate glbs (board body from KiCad's VRML path, models from STEP) or accept the triangulation.
5. `tools/sim3d/manifest.py` reads the `.kicad_sch` net names and emits `board-manifest.json`:
   - `DIO_LED[channel] -> node name` for D4…D27 (each LED sits behind an R5k network on a DIOx net),
   - the 7-segment display node + its digit positions,
   - the buttons (SW1/SW2/SW4 shield, SW3/SW4 main) and their DIO nets,
   - the pin-header positions per channel (J2/J4 digital, J8 analog) for tap targets.

## Runtime

**Model layer (`WirebenchModel/DuinoSimSession.swift`)** — an `@Observable` session:

- Owns `DuinoSim` (port 5020 default; error if busy) and reads its state directly through the C
  API at ~30 Hz (DO map, CH455G `display`, AI map) — same process, no protocol overhead. The
  protocol path (watch/upload over TCP) stays for real boards and is already tested.
- Publishes: `leds: [Bool]` (24), `display: DuinoSim.Display`, `digitalInputs`, `analogInputs`,
  `vmState`, `eStopActive`, `temperatures`. Writes go through: `toggleDI`, `setAI`,
  `setTemperature`, `tripEStop`, `controlVM`.

**3D layer (`WirebenchApp/Simulator3DView.swift`)** — SwiftUI `RealityView`:

- Scene: `board.usdc` + `shield.usdc` stacked at the header offsets, studio lighting (HDR
  environment), default ¾ camera; `OrbitGesture`/`RotateGesture` (careful: no spring, per the
  pan/zoom lesson in `docs/HANDOVER.md` §13).
- Update binding (30 Hz `TimelineView`): for each `DIO_LED` manifest entry set the node's
  material emissive color (off: dark PCB green; on: LED color from the schematic value, with a
  short fade). The display: four digit quads in front of the display cutout, each with an
  emissive segment texture; the segment bitmaps come from decoding `sim.display.text` through a
  7-seg font table; decimal points from the text.
- Picking: tap a button footprint → press-in animation + `setDigitalInput` pulse; tap a pin on a
  header → a small pin inspector chip (toggle for DI, slider for AI). Hover highlights the
  pickable node (`Entity.components[HoverEffectComponent]` + our outline).

**Control overlay** (SwiftUI HUD over the 3D view): transport buttons (VM start/pause/stop with
live state from the sim), upload state, TMP75/DS18B20 sliders, the red e-stop mushroom
(down = trip with mask 1, twist = clear), EEPROM-backed indicator, and a copyable
`127.0.0.1:5020` address chip.

**Entry point**: Hardware Link gains a "Simulate Duino-S…" button (Duino-S family only). It starts
a `DuinoSimSession` and opens the simulator window (`Window("Duino-S Simulator", id: "duinosim")`,
like the ST editor window).

**Tests**: manifest validation (every DO channel 0...23 maps to a node; display digits present);
`DuinoSimSession` state mirroring against a live sim; LED update applied to an `Entity` from a
fixture state; picking mapping table (tap coordinate → channel) as a pure function.

## Phases

1. **Asset spike** — export/convert/load in RealityKit, screenshot, judge quality. (~half day)
2. **Manifest** — schematic net reading + `board-manifest.json` + validation test. (~half day)
3. **Viewer** — window, model, lighting, camera, picking scaffolding. (~1 day)
4. **Live binding + controls** — LEDs, display, buttons, pin inspector, HUD. (~1–2 days)
5. **Polish** — LED fades, hover outlines, camera bookmarks (¾ / top / IO side), e-stop animation.
   (~half day)

## Risks / open questions

- **Missing 3D models**: `EASYEDA_MODELS/` holds only 5 STEP models; most footprints (MCU, PHY,
  passives) will export as outlines or nothing. Mitigation: the visually important parts
  (connectors, CH455G, TMP75, display, buttons) get simple extruded-rectangle models generated
  from footprint dimensions if KiCad's substitution is too bare; the PCB itself carries the look.
  Decide at the spike.
- **LED↔channel mapping**: assumed 1:1 by net (`DIO0…D23`); the manifest script proves or
  disproves it from the nets.
- **Display digits**: rendering via emissive textures is straightforward; a physically segmented
  model is nicer but needs digit meshes — do textures first.
- **Qt**: out of scope (macOS app only for the 3D view; the sim itself stays cross-platform).
- **One sim per process**: the window owns the sim; a second window says so. The 5020 port means
  only one instance can bind it — if a real board is on 5020, the UI offers another port.
