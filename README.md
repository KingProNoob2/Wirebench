# DirigoSwift

A native Swift reimplementation of **Dirigo** — a legacy Windows/Delphi PLC
Function-Block-Diagram (FBD) programming, simulation and download environment.

Reverse-engineered from the original 32-bit Delphi binaries (`Dirigo.exe`, `P1.bpl`,
`PccBase.bpl`), their IDR decompiler projects (`*.idp`), `Profiles.ini`, the CHM help and the
Czech manuals. The reverse-engineering record lives in [`../docs/`](../docs/PROJECT-OVERVIEW.md).

---

## Status

| Area | State |
|---|---|
| `.pcc` project loading | Complete. Reads every element and attribute of a real project |
| `.pcc` project saving | **Byte-for-byte lossless** for current-format projects, verified against Dirigo's own output |
| Block-type dispatch | Driven by the 144-entry registry recovered from `P1.idp` |
| Block library | 147 catalogued types: 144 resolve to a block class, of which 9 are shape-only stand-ins with no behaviour. `Switch8` does not resolve |
| Simulation | Deterministic, topological by `ORDER`; optional hardware-profile thread scheduling |
| Hardware profiles | `Profiles.ini` fully parsed: 22 profiles, thread tables, memory models, 41 `SystemCmd` definitions |
| Compile and upload | Compiles a project to Dirigo's program table and symbol `.csv` (byte-identical for the four captured saves, `zelznice`, `had`, `kostička`) and uploads it over serial with a live log. Not yet run against a PLC here — see [`compile-and-upload.md`](../docs/compile-and-upload.md) |
| Serial/hardware I/O | The `DbNet` serial upload, and the Duino-E subset (`0x300`–`0x303`) |
| Conditional execution | Implemented per block: `If`/`Else`/`EndIf`/`Switch`/`Case`/`Default`/`EndSwitch` gate the blocks they enclose. No range skipping; `Results` encoding is unattested in any sample project |

Known gaps, unsupported blocks and per-module differences are catalogued in
[`../docs/module-coverage.md`](../docs/module-coverage.md).

---

## Fidelity

Saving a project is lossless and, for projects written by current Dirigo builds, **byte-identical**
to the original file — including attribute order, attribute spelling, indentation, self-closing
style and the numeric character references Dirigo uses for tabs and newlines.

What changed to make that true:

* the parser reads `PIN_NAME` / `DISPLAY_FORMAT` (not `NAME` / `FORMAT`), so pin names survive;
* every element keeps the attributes it was read with, in order (`AttributeBag`), and modelled
  values are merged *into* them rather than replacing them;
* sections, elements and subtrees the model does not understand are kept verbatim
  (`RawXMLNode`) and written back untouched — `CONSTANTS`, `PEN`/`BRUSH`/`FONT` and any future
  addition are no longer dropped.

Verified by `Tests/DirigoSwiftTests/PCCFidelityTests.swift` against `rulkoshaddirigo.pcc` and
Dirigo's own `__history` snapshots.

> Note: `ruleta_kostka_had.pcc` in this workspace is **not** a Dirigo-saved file. It is
> single-line, has no `__history` entry, and carries `COLOR="/bin/zsh"` where a colour value
> belongs — a shell-expansion artefact of earlier tooling. It is useful as a block-coverage
> corpus but must not be used as format ground truth.

---

## Building and testing

### SwiftPM (command line)

```bash
cd DirigoSwift
swift build --disable-sandbox
swift test  --disable-sandbox
```

`--disable-sandbox` is required in sandboxed environments: SwiftPM shells out through
`sandbox-exec`, which a host file sandbox denies, and SwiftPM then reports a misleading
`Invalid manifest` error. The same restriction breaks Swift macro expansion (`@Observable`)
under `xcodebuild`; adding `OTHER_SWIFT_FLAGS="-disable-sandbox"` works around it.

### Xcode

```bash
xcodegen generate          # regenerate Dirigo.xcodeproj from project.yml
open Dirigo.xcodeproj
```

**Run `xcodegen generate` after adding, renaming or deleting any source file.** SwiftPM globs
`Sources/` and `Tests/`, but an Xcode target lists its files explicitly, so a new file is simply
not compiled and Xcode reports `cannot find type 'X' in scope` while `swift build` succeeds.
The `Xcode project membership` test suite fails if the two ever drift apart.

`./bundle-app.sh` runs `xcodegen generate` and an `xcodebuild` release build, then copies the
resulting `Dirigo.app` next to the package and to the workspace root.

376 tests across 96 suites, all passing, with no known issues. Measured 2026-10-15.

---

## Compiling and uploading

The sidebar's *Hardware Link* block is the whole workflow:

1. **Connect** — choose the serial port (`cu.usbserial-…`) and press *Connect*.
2. **Compile Project** — compiles the open project and opens the build report (blue once connected).
3. **Upload to PLC…** — the report's default button. The report closes, the upload runs, and the
   **Upload Log** under the buttons shows the stage, a percentage and every frame; *Copy* puts the log on
   the clipboard.

The report can also export the symbol table (`.csv`) and the program binary (`.pbd`). From the command line,
`dirigo-cli build project.pcc` writes both. How the table and records are built, and which parts are
verified against Dirigo's own output, is in [`compile-and-upload.md`](../docs/compile-and-upload.md).

---

## Command line

```bash
# Inspect a project
swift run dirigo-cli info  ../rulkoshaddirigo.pcc

# Show how every module resolves to a block type, and flag anything unsupported
swift run dirigo-cli blocks ../rulkoshaddirigo.pcc

# Show the hardware profile the project selects, its threads and its SystemCmd catalogue
swift run dirigo-cli profile ../rulkoshaddirigo.pcc ../Profiles.ini

# Simulation benchmark
swift run dirigo-cli sim ../rulkoshaddirigo.pcc 20000

# Simulation using the profile's real thread periods instead of every-tick
swift run dirigo-cli sim ../rulkoshaddirigo.pcc 20000 --profile-scheduling

# Round-trip fidelity check
swift run dirigo-cli roundtrip ../rulkoshaddirigo.pcc
```

Measured on this machine (release build, `rulkoshaddirigo.pcc`, 57 modules / 114 wires):

| Mode | Throughput |
|---|---|
| every-tick scheduling | ~7,000 ticks/s (0.14 ms/tick) |
| profile-interval scheduling | ~7,500 ticks/s (0.13 ms/tick) |

The earlier claim of "10,900 ticks/s / 0.09 ms per tick" was never reproducible; these are the
real figures.

---

## Running the GUI

```bash
cd DirigoSwift
xcodegen generate          # after adding/removing files
xcodebuild -project Dirigo.xcodeproj -scheme Dirigo -configuration Debug build
open .build/Debug/Dirigo.app
```

Canvas editor with pan/zoom, live wire probing, a 7-segment LED panel for `Segment` blocks,
clickable `BoolVar`/`8xDI` inputs and a module inspector.

### Visual design

Flat by design. `Sources/DirigoApp/Theme.swift` holds the shared vocabulary —
`glassPanel`/`glassCapsule` modifiers, the panel hairline, the signal bead, and
`AmbientBackdrop`.

* **No gradients, no glows.** The canvas background is a single flat colour, panel edges are a
  flat hairline, block headers are a flat fill, pin beads are plain dots and wires are a single
  weight. This is deliberate: the gradients were also costing real frame time (see below).
* On **macOS 26 and later** chrome panels use the real `glassEffect(_:in:)` API. Below 26 they
  fall back to an ultra-thin material with the same shapes and hairlines, so the app looks
  coherent on every supported system (deployment target is macOS 14).
* Blocks are tinted by their **Dirigo block-palette category** (`Bool` blue, `I/O` teal,
  `Visual` pink, …), taken from the recovered registry. The tint is flat; if you ever want
  monochrome blocks it is the `.background(tint.opacity(0.22))` line on the card header.
* Chrome (zoom control, inspector tiles, dialogs) uses Liquid Glass; block cards deliberately
  use a plain material. `glassEffect` samples and blurs the backdrop per shape, and there are
  dozens of cards — this was the single biggest rendering cost before it was removed.

### Adding blocks

**Add Block** is the toolbar's **+** button (⇧⌘A, or *File ▸ Add Block…*) — adding to the
document is the common action, so it gets the prominent affordance, while *New Project* lives in
the File menu (⌘N) where document creation belongs.

It opens a searchable object-library style picker: categories down
the left, blocks on the right, filterable by name, Delphi class, description or category.
Double-click… rather, a single click inserts the block **in the middle of the visible canvas**,
nudged along if that spot is taken, and selects it.

Being able to insert a block means knowing its pins — and a `.pcc` **does not store pin names**.
Dirigo derives the labels from the Delphi class, and writes only `VALUE`/`RIGHTS` per pin, so a new
module just has to get the pin *counts* and defaults right. Those come from
`PinTemplateCatalog`, generated from the verbatim input/output tables in the help:

```
python3 tools/gen_pin_catalog.py --write     # 133 of 144 block types recovered
```

That generator is worth knowing about: it reproduces Dirigo's own convention for a block with a
configurable input count, where the help lists the first two operands *plus* a general `X(N-1)` row.
The general row **replaces** the operands, so `And` with N = 2 becomes `En, X0, X1` — exactly what
Dirigo writes. Types with no recovered layout still get a placeholder input and output rather than
an unselectable block with no pins.

New modules get a free ID, the next `<Type><n>` name, and an execution order of ten past the last
block on the page, matching Dirigo's numbering.

### Deleting blocks

Select a block and press **⌫**, or use *Edit ▸ Delete Block* (⌘⌫), or right-click the block.

Deletion also removes every connection that referred to the block, in both directions and including
parameter connections. That is not cosmetic: a `<CONNECTION>` naming a module that no longer exists
still parses — here and in Dirigo — but it is a wire to nowhere, and it would silently resurface as
a stray cable if a later block happened to reuse the id. `PCCProject.danglingConnectionCount()`
exists to assert the invariant, and a test checks it after a save/reload.

⌫ is handled with `.onDeleteCommand` on the canvas rather than as a global menu shortcut, so it
cannot steal the key from a search field or the inspector; the menu item uses ⌘⌫ for the same
reason. There is no confirmation dialog — undo is the safety net, and a modal on every delete gets
tiresome.

### The BoolVar button

`BoolVarBlock` has three modes and they do not share an interaction:

* **push button** (`.pushButton`) — momentary. On for exactly as long as the control is held.
* **toggle / latch** (`.toggleSwitch`) and **slider** (`.slider`) — the value flips and stays.

A momentary control needs the press *and* the release, so the card's button is a
`DragGesture(minimumDistance: 0)` rather than a `Button`, which only ever reports the tap, and the
model exposes `setModuleInputPressed(moduleId:pinIndex:isPressed:)` next to `toggleModuleInput`.
Getting this wrong is easy to miss visually — the old code fired a fixed two-tick pulse, which looks
plausible until you hold the mouse down and the output drops out.

There is deliberately no timeout on a held button: `process` only expires a *single-shot* pulse,
which is what `trigger()` produces for an activation with no matching release (the inspector's
button, a menu command). A hold outranks a pulse that was already running.

### Undo and redo

⌘Z / ⇧⌘Z, backed by `UndoHistory` in `DirigoCore`.

It snapshots rather than recording inverse operations, which is the right trade because
`PCCProject` is a value type: a snapshot copies a few array headers under copy-on-write, not the
document. It also means **no edit can be missed by forgetting to write an inverse** — recording
happens in a single `didSet` on `AppModel.project`, and every mutation in the app goes through that
property. The simulation loop never writes it, so ticks do not pollute the stack.

Bursts are coalesced (0.25 s). Some mutations loop — changing a block's input count appends pins one
at a time — and without coalescing a single user action would leave a dozen undo steps behind. The
history is capped at 100 steps and is cleared when a different document is opened.

Dragging a block already commits once, in the gesture's `onEnded`, so one drag is naturally one
step. If you add a gesture that mutates continuously, call `history.endGroup()` when it finishes.

### Workspace, and exporting back to Dirigo

This editor gives you an **unbounded workspace**. The original Dirigo does not: it gives a project
one fixed sheet, chosen under *File ▸ Velikost papíru* ("paper size"), which the help describes as
"the size of the graphical part of the project window, which represents one printed page". Dirigo
offers A4, A4 Extra, A3, A3 Extra and A2, and **in practice only A3 lays out correctly** — A2 and
the rest do not work.

The sheet is drawn on the canvas as a dashed outline, so it is obvious what will fit. It is only a
reference: nothing clamps to it, and the canvas frame grows with your content.

**File ▸ Export Legacy .PCC** (⇧⌘E) writes a `.pcc` the original can open. It reconciles the
two in the least destructive order available:

1. If the layout already fits the sheet, it is written **untouched** — only `PAGESIZE` is pinned.
2. Otherwise it is **translated** so its bounding box starts at the sheet margin. Moving a
   schematic does not change it, so this is always preferred.
3. Only if it still overflows is it **scaled down** uniformly, and it says so. Below 50% it also
   warns, because at that point the drawing is no longer readable and wants splitting across pages.

Wire routes (`POINTS` are stored as offsets from the source pin) and graphics nodes are transformed
along with the modules.

#### How `PAGESIZE` is decoded

`PAGESIZE` is a single integer — `60` in every project here — which is only possible because all
five sizes share the ISO aspect ratio, so the number encodes the width. It is the width in
**5 mm units**, rounded up: A4 = 42, A4 Extra = 47, **A3 = ceil(297/5) = 60**, A3 Extra = 65, A2 = 84.
That reading of the unit is the Dirigo file format's, and it is what the stored value means.

The canvas scale is a separate question. `PaperSize.unitsPerMillimetre` is **7.0** canvas units per
millimetre. An earlier value of 5.0 made the A3 sheet 1485 units wide, narrower than real content (the
widest module in `AHOJ - JEDNOSEGMENT.pcc` sits at x=1692), so export rescaled 18 of 24 projects on disk.
7.0 is the smallest whole-unit multiple of 297 mm that clears the content, and no project on disk is
scaled by export at this value.

The value is never written by this editor — it is preserved verbatim on save, and the export pins it
to `60`. A wrong reading here would therefore be cosmetic only.

### Cable routing

Wires leave and enter a pin through a short stub, so they never merge into the block edge. A forward
run turns once, in the gap between the two pins, and the corridor is **searched for so that it clears
every block** — the obvious "turn at the midpoint" lands inside whatever block sits between the two
pins, which is what made cables appear to cut through blocks. Each wire gets a small **lane offset**
so parallel runs sit side by side rather than stacking into one thick line. Corners are rounded.

Two cases that used to look wrong and are worth not regressing:

* **Neighbouring blocks.** The forward/backward decision compares the *pins*, not the stub positions.
  Testing the stubs meant any gap narrower than two stubs (36 units) flipped a cable into the
  backward branch and drew a pointless loop beside the block.
* **The backward detour** goes above *or* below, whichever is nearer, bounded by the connected
  blocks' own extent (`clearAbove`/`clearBelow`) and by every block in the way.

**Canvas ▸ Reset Wire Routing** (⇧⌘R) tidies hand-drawn routes on the current page back to
Dirigo's default, mirroring the IDE's own *Default points* command. It reuses the point value the
page already uses rather than inventing one (Dirigo's writers are inconsistent: 30, 56, 70 across
the sample projects), and serialises as an ordinary single-point route.

Dirigo's own routing is still respected: `POINTS` are user-editable (the IDE has *Add point* /
*Default points* / *Delete point* commands), so a connection with **two or more** stored points was
routed deliberately and is followed exactly. A single stored point is just the stub Dirigo writes
for a freshly drawn wire, and those are re-routed. Nothing is written back either way.

### Block functionality

`docs/block-functionality-audit.md` is a block-by-block check of all 147 catalog types against the
original help. The headline finding is one systemic bug worth knowing about before touching any
block:

**The engine binds pins by index** (`SimulationEngine.setupRuntime` copies `module.inPins[i]` into
`block.inPins[i]`), and the help **always lists `En` first**. Around twenty implementations omitted
that pin, so the module's `En` landed in the block's first operand slot, every operand shifted by
one, and the last input was dropped — silently, with plausible-looking wrong values. A fresh `IOr`
returned 1 instead of 0; a `Timer` was triggered by its own `En` wire; `8xDO` reported `En` as
`DO0`.

Fourteen blocks were fixed and two guards added:

* `BlockPinContractTests.noNewPinContractViolations` — fails on any block whose pin counts disagree
  with the module built for it, beyond an explicit `knownGaps` list that **may only ever shrink**.
  Fixing a listed block without delisting it fails too, so the list cannot rot.
* `BlockPinContractTests.restoredEnablePinsStayAligned` — a positive guard on the repaired blocks.

`dirigo-cli audit-blocks` reproduces the mechanical half at any time: it instantiates every type in
the catalog, steps it, and reports placeholders, pin-count mismatches and non-finite outputs.

Still open, as of 2026-10-15: the nine shape-only blocks are inert; `LLimiter`, `LComparator`, `LDemux`
and `LongVar` reuse 32-bit Int implementations; `PulseGen` clears its outputs on `En = 0`, where the
library's convention is to hold; and `Switch8` is unresolved. `dirigo-cli audit-blocks` reports the
mechanical part of this. The fuller list is in §6 of the audit.

### Canvas performance

The canvas is the hot path: a full sheet re-renders on every simulation tick and on every frame
of a pan or zoom. It is now built so SwiftUI can skip almost all of it:

* `ModuleCardView` and `WireLayer` are `Equatable` and take **plain values** (pin value arrays,
  a compact wire-endpoint array) rather than a live engine node plus a global version counter.
  They are rendered through `.equatable()`, so a tick only re-renders the blocks that actually
  changed. Passing a `simulationVersion` into every card — the previous design — forced all 57
  cards to rebuild ~30 times a second.
* Wire endpoints are resolved through a dictionary. The previous lookup was
  O(connections x modules), ~6,500 comparisons per frame.
* Cards are rasterised at up to 2x and scaled back down, which keeps text crisp when zoomed in.
  `AppModel.isZoomSettled` applies that sharpening **only once the gesture has stopped**: changing
  it mid-pinch re-rasterises every card in one frame, which measured as a ~95 ms hitch on
  essentially every zoom step. `renderScale(for:)` can therefore be a smooth function of zoom —
  it is evaluated once, at rest.

**Measured on a 57-module sheet, Debug build, driving a continuous pinch (frame budget 16.7 ms):**

| | mean | p50 | p95 | worst frame |
|---|---|---|---|---|
| Original | 150 ms | 167 ms | 184 ms | 206 ms |
| After the equatable/value refactor | 20.7 ms | 18.3 ms | 20.8 ms | 119 ms |
| After settle-based sharpening | **18.6 ms** | **18.7 ms** | **20.2 ms** | **21 ms** |

Steady-state zooming now produces **no frames over 33 ms at all**, against 1–8 per two seconds
before.

Three cautions for anyone measuring this again:

1. **Sampling CPU% with `top` is not reliable here.** Window occlusion throttles AppKit
   rendering, so the same build measures anywhere from 10% to 38% depending on whether the
   window is frontmost — differences far larger than the effect being measured. Measure the
   frame cadence from inside the app instead (time the interval between iterations of the
   simulation loop, or drive `zoomScale` from a task and time it).
2. **The grid was not the cause of the zoom spikes.** Disabling `CanvasGrid` entirely changed
   the frame profile by nothing measurable; the spikes were the card supersampling step-change.
   The grid is already a `Canvas(rendersAsynchronously: true)`, so its drawing is off the main
   thread. Check the hypothesis before optimising the wrong component.
3. The `equatable()` skipping is easy to break without noticing: if you pass a value that changes
   every tick into a card, everything re-renders again. Verify liveness after touching this code
   by diffing two screenshots taken a fraction of a second apart during simulation — but pick a
   signal period that does not alias with the sampling interval.

Two more things worth knowing before changing this code:

1. **Do not wrap canvas content in `GlassEffectContainer`.** It does not preserve the coordinate
   space that a `ForEach` of `.position`-placed views lays out in — cards end up hundreds of
   points from their model position, mostly off-screen. The block cards are independent panes,
   not a merging cluster, so the container buys nothing.
2. **A block's affordances come from its type, not its name.** `BlockInteraction.classify`
   (in `DirigoLibrary`) decides whether a block gets a control, per-pin toggles, or nothing.
   A name-substring heuristic is what previously gave `ISwitch` — a multiplexer — a push-button
   that toggled its enable pin. `BlockInteractionTests` guards this.

---

## Examples

```bash
# 57 modules across 4 pages: dice, roulette and snake on two 7-segment displays
swift run dirigo-cli info  ../rulkoshaddirigo.pcc
swift run dirigo-cli blocks ../rulkoshaddirigo.pcc

# Round-trip and confirm nothing is lost
swift run dirigo-cli roundtrip ../rulkoshaddirigo.pcc
```

---

## Project layout

```
DirigoSwift/
├── Sources/
│   ├── DirigoCore/        # PCC XML model, parser, serializer, AttributeBag, Profiles.ini
│   ├── DirigoLibrary/     # Function blocks + the recovered BlockTypeCatalog registry
│   ├── DirigoEngine/      # Deterministic simulation and thread scheduling
│   ├── DirigoHardware/    # Serial port, DbNet upload, program-table compiler, symbol table, Duino-E
│   ├── DirigoCLI/         # info | blocks | profile | sim | roundtrip | build | symbols | pins
│   └── DirigoApp/         # macOS SwiftUI editor and live simulator
├── Tests/DirigoSwiftTests/
└── ../../docs/            # Reverse-engineering record (see below)
└── ../../tools/           # idp_dump.py, gen_block_catalog.py
```

## Related documentation

| Document | Contents |
|---|---|
| [`PROJECT-OVERVIEW.md`](../docs/PROJECT-OVERVIEW.md) | Architecture, verified defects, gaps, roadmap |
| [`dirigo-modules.md`](../docs/dirigo-modules.md) | Every documented block, with pins and formulas |
| [`module-coverage.md`](../docs/module-coverage.md) | Per-block gap analysis of `DirigoLibrary` |
| [`dirigo-block-guid-table.md`](../docs/dirigo-block-guid-table.md) | The recovered block-type registry |
| [`compile-and-upload.md`](../docs/compile-and-upload.md) | Compiling a project and uploading it: the table, the records, the symbol table, what is verified |
| [`plc-protocol.md`](../docs/plc-protocol.md) | The serial protocol and table format, with the evidence for each finding |
| [`profiles-and-system-commands.md`](../docs/profiles-and-system-commands.md) | Hardware profiles and the `SystemCmd` catalogue |
| [`idp-format.md`](../docs/idp-format.md) | The `.idp` container format |
