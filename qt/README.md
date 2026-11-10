# Wirebench for Qt

A Qt Quick frontend for the Wirebench editor that builds on **Linux and macOS**. It is a second face on the same Swift code the
SwiftUI app uses: the project model, the block library, the simulation core, the PLC compiler and uploader, and the app's own
state and commands (`WirebenchModel`) all run unchanged. Only the drawing is new.

```
 QML (qt/qml)  ◀──▶  Controller (qt/src, C++)  ◀──▶  libWirebenchBridge (Swift, @_cdecl C API)  ◀──▶  WirebenchModel + the rest
 drawing, input        QObject, list models, timer        JSON scene out, JSON commands in
```

## How it fits together

* **`WirebenchModel`** (`Sources/WirebenchModel`) is the app's brain with no view code: `AppModel`, card and wire geometry
  (`CardGeometry`, `WireLayout`), palette search, block configuration (`BlockConfig`), the inspector and scene snapshots. The
  SwiftUI app sits on it too. It imports no SwiftUI and no AppKit, so it builds on Linux.
* **`WirebenchBridge`** (`Sources/WirebenchBridge`, header `include/wirebench_bridge.h`) is a flat C interface over the model:
  `wirebench_scene` returns the current page as JSON (blocks with pin labels and live values, routed wires, shapes, pages, play state,
  settings, hardware); `wirebench_command` takes a JSON command (open, save, select, move, connect, build, upload, …; the list is in
  `BridgeCommands.swift`); `wirebench_tick` advances the simulation by the elapsed wall-clock time; `wirebench_pump` lets main-actor work
  (an upload) advance. Everything runs on one thread, the frontend's main thread.
* **Why a pump and a tick.** Swift's main-actor timer is not drained by Qt's event loop, so the Qt timer drives the simulation
  (`AppModel.hostPlay` / `hostTick`) and calls `wirebench_pump`, which runs the main run loop once; main-actor tasks advance under it
  on both macOS and Linux (checked).
* **`Controller`** (`src/Controller.cpp`) wraps the bridge for QML: the scene becomes list models (`JsonListModel`, which updates
  rows in place so a simulation step does not rebuild delegates) and properties. Rarely changing state has its own change signals
  (`projectChanged`, `settingsChanged`, `hardwareChanged`, `inspectorChanged`) so a step does not re-evaluate every card.
* **Geometry is shared.** Block size and pin positions come from `CardGeometry`, which the wire router also uses. The Qt app sets a
  roomier pin pitch (20, not the SwiftUI card's 16) and centres the pin rows; the SwiftUI app keeps 16, so its layout is unchanged.
  Hand-routed wires (stored `POINTS`) were drawn for the 16 pt layout, so they are followed only at that layout, and only when the stored
  route arrives at its pin (last point level with it, to its left); otherwise that wire is routed afresh. The file is never changed either way.
* **Parameters are pins here too.** The scene's `paramPins` are drawn as rows under the inputs (shaded, with the value as a chip) and a cable can end on one
  (`pinAt` also finds them, with `param: true`; `connect` and `disconnect` take `inParam`). A wire carries `inParam`, and its key ends in `p`.
* **A `Segment`'s display is shared too.** The scene carries its window and eight bars (`segmentWindow`, `segmentBars`, in card coordinates, from
  `SegmentDisplayLayout.fitting`), so the QML draws the same digit as the SwiftUI card, sized from the card's body: a dark window in both
  appearances, dim bars when stopped, lit ones while playing. An input such as a `SystemCmd`'s `Cmd` is shown the way the model writes it
  (`PinDisplay`: hex, `0x302`) in the inspector.

## Build

Needs Swift 6, Qt 6.5 or newer (Quick, QuickControls2, QuickDialogs, ShaderTools), cmake, and ninja (optional).

```bash
# macOS
brew install qt ninja
tools/build-qt.sh Release            # builds the Swift bridge, then the app → build/qt/wirebench-qt

# Debian / Ubuntu
sudo apt install build-essential git cmake ninja-build pkg-config zlib1g-dev qt6-base-dev qt6-declarative-dev \
  qt6-declarative-dev-tools qt6-shadertools-dev qml6-module-qtquick qml6-module-qtquick-controls \
  qml6-module-qtquick-layouts qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtquick-shapes \
  qml6-module-qtquick-dialogs libgl1-mesa-dev
tools/build-qt.sh Release

build/qt/wirebench-qt [project.pcc]
```

The Swift package builds on Linux with the toolchain from swift.org (tested: Swift 6.4.2, Ubuntu 26.04, x86_64) and zlib's headers.
`swift test` runs everything but the SwiftUI app's own tests there; skip `CxxBlockFuzzTests` on a machine with under about
8 GB (it peaks at 5.7 GB on macOS and 16 GB on Linux). `tools/bridge-smoke.sh [project.pcc]` builds the bridge and runs a C test
that opens a project, plays it, builds and queries the palette.

## What it does

Open, save and save-as through the platform's file dialogs (or drop a `.pcc` on the window); pan, zoom and fit; select (click or a
selection box), move, wire (drag from an output pin to an input pin), delete, undo and redo; the block library with search;
rectangles, ellipses and text; play, pause, step and reset with live values on pins and wires and a lit `Segment` display; an
inspector with live signals and editable values; a configuration dialog for most block kinds (shared with the SwiftUI dialog through
`BlockConfig`); a build report with `.pbd`, `.csv`, `.dbf` and legacy `.pcc` exports; the PLC link (serial ports; *Build & upload* opens the port
itself and closes it after, with phases and a log); settings.

**Top bar and menu:** the bar holds the menu, the library toggle, undo and redo, the project name, play/pause/step/reset, the page tabs and the
inspector toggle; the hamburger menu holds Open, Save, Save As, the shape and text tools, Auto-arrange (the SwiftUI app's Organize Blocks, also
`Ctrl+Shift+L`), Build, PLC and Settings. The bar is a layout that drops its words and then the project name as the window narrows, and the side
panels hide under 860 px (inspector) and 640 px (library).

**Keyboard shortcuts** are the SwiftUI app's, key for key (Ctrl here is its ⌘, and Meta its ⌃), and, like its menu items, work only with a project open (New and
Open aside): New/Open/Save/Save As, Undo/Redo, Copy/Cut/Paste, Add Block `Ctrl+K`, Add Text `Ctrl+Shift+T`, Add Rectangle/Circle `Meta+Ctrl+R`/`C`, Organize
`Ctrl+Shift+L`, Reset Wire Routing `Ctrl+Shift+R`, Build `Ctrl+B`, Export Program Binary `Ctrl+Shift+B`, Export Program Variables `Ctrl+Shift+V`, Export Legacy .PCC `Ctrl+Shift+E`, Upload to PLC `Ctrl+Shift+U`, Settings `Ctrl+,`, Delete Block
`Ctrl+Backspace`, Delete Object `Ctrl+Alt+Backspace`, the zoom keys `Ctrl++`/`-`/`0`/`9`, Toggle Inspector `Meta+Ctrl+I` and `Space` to run or pause.

**Mouse:** left-drag on the sheet draws a selection box; **middle-drag pans**; the wheel zooms (Settings can make it pan, with
Ctrl+wheel zooming); a trackpad's two-finger scroll pans. Panels block the wheel and clicks from reaching the sheet beneath them.

**Settings:** appearance (system, light, dark), snap to grid, scroll-wheel behaviour, roomier blocks (pin pitch 20 or 16), the
optimiser, and the frosted glass (a switch, and a blur radius slider).

**Feature parity with the SwiftUI app.** Checked against its menu commands and context menus. Covered: new, open, save, save as, the "save changes?" question
before a project is replaced or the window closed (the model asks; Qt shows it), open by drop; add block (library), text, rectangle, circle; organize blocks;
reset wire routing; build, the exports, the build template, export legacy `.pcc`; pages (new page, new macro page, rename macro, delete page with a
confirmation, block counts); right-click a block (configure, rename, reset, delete), a wire (delete connection) or a page tab; click a wire to pick it
and `Delete` to remove it; zoom in and out, actual size, fit and the preset list (click the percentage); undo and redo; settings; the inspector, the
configuration dialogs and the PLC link.

**Not in the Qt app (the SwiftUI app has them):** the inspector for a shape or a text object (pen, brush, font, geometry); dragging a text object (neither
app drags text, but SwiftUI edits it from the inspector); the sidebar's search that highlights matching blocks on the sheet; assigning a block to an
`If`/`Switch` container from its menu; reordering switch cases; the category sidebar and macro rows in the add-block picker; keyboard shortcuts that use
⌃⌘ (Add Rectangle, Add Circle, Export Legacy) — those are in the menu.

## Drawing, and what it costs

* **Exact curves, not tessellated rectangles.** Qt's `Rectangle` and a plain `Shape`'d rounded rect show facets when magnified, so
  cards (`CardFrame`: body, header, hairline and outline as one shape), badges and the sheet's boxes (`SmoothRect`) and pin dots are
  `Shape`s with the curve renderer. A card is one scene-graph shape; a block's shadow is three stacked translucent rectangles.
* **The grid is a fragment shader** (`shaders/grid.frag`), one dot per intersection worked out per pixel; the software renderer, which
  has no shaders, draws it on a `Canvas` instead. A CPU canvas cost about 49 ms of GUI-thread time per pan step.
* **Frosted glass** (`shaders/gauss.frag`, `glass.frag`, `qml/Panel.qml`, the chain in `qml/Main.qml`). The sheet is drawn once a frame at
  full size with mip levels (half size for a wide blur), read down by a separable two-pass Gaussian (weights computed from sigma, tap
  pairs folded into one bilinear fetch, kernel to 3 sigma) in 16-bit float textures at 1, 2, 4 or 8 times smaller depending on the radius;
  each panel is then a rounded window onto the result under its tint, saturated a little and dithered by half a level. The slider is the
  exponent of the radius, 4 px to 64 px (`AppTheme.blurSigma`), because equal-looking steps of blur are equal ratios. With the blur off,
  panels are solid grey and none of this runs. It needs the GPU renderer: Metal on macOS, which is the default.
* **Opening and closing** (`qml/Panel.qml`): the library and inspector fade as `progress` runs 0 to 1 (340 ms in, 260 ms out, ease in-out), and
  while they fade their own picture goes through the same Gaussian (`gauss.frag`, two
  passes, 22 px at its widest) so the contents sharpen as the panel arrives and blur away as it goes; the dialogs fade and grow without
  the blur. The software renderer gets the fade and the scale only. `WIREBENCH_TOGGLE_MS`, `WIREBENCH_START_HIDDEN` and
  `WIREBENCH_SHOT_AFTER_TOGGLE_MS` with `WIREBENCH_SHOT_PATH` flip the panels and save a frame mid-motion.
* **Measured** on an M4 (Metal), panning `ruleta_kostka_had.pcc` continuously: the grid shader took the GUI thread's polish from 48 ms to
  0.3 ms; panning went from about 18 to about 55 frames a second; per-frame render 5 to 11 ms depending on the blur radius. Jitter
  between frames of a smoothly moving sheet inside a panel (a sheet moved 0.37 px per frame; mean change in levels of 255) fell from
  0.025 to 0.009 when the sheet was prefiltered instead of drawn into a small texture.

## Diagnostics (environment variables)

`QSG_INFO=1` names the graphics backend (Metal on macOS); `QSG_RENDER_TIMING=1` prints frame times.
`WIREBENCH_SCREENSHOT=out.png` saves one frame and quits (the app's own render, so it works headless: `QT_QPA_PLATFORM=offscreen
QT_QUICK_BACKEND=software` on a box with no display; the software renderer has no blur and no grid shader).
`WIREBENCH_PLAY_MS=1500` plays first; `WIREBENCH_LIGHT=1` forces light mode; `WIREBENCH_ZOOM=2` zooms; `WIREBENCH_PAN=dx,dy` offsets the sheet;
`WIREBENCH_BENCH=1` pans continuously; `WIREBENCH_GRABS=dir` saves 40 consecutive frames, the sheet moved 0.37 px each, for flicker
measurements; `WIREBENCH_PRE='[{"cmd":"select","name":"Counter2"}]'` runs bridge commands first; `WIREBENCH_DIALOG=build|hardware|settings|open`
or `WIREBENCH_CONFIG=1` opens a dialog; `WIREBENCH_BLUR=0|1` and `WIREBENCH_BLUR_DEPTH=0…1` override the glass for one run without saving.
(A separate native window, such as a file dialog, is not part of the saved picture.)

## Checklist for a real window

Most of this has been checked through the app's own renders and the C smoke test, not by clicking. Use a real project
(`rulkoshaddirigo.pcc`, `ruleta_kostka_had.pcc`) and a copy you can lose.

**Sheet**
- [ ] The project opens fitted to the window; **Fit**, **+**, **−** and the wheel zoom about the pointer; middle-drag pans.
- [ ] Left-drag on empty sheet draws a selection box and selects what it touches; a plain click clears the selection.
- [ ] Scrolling a panel's list does not zoom the sheet; clicking a panel does not clear the selection.
- [ ] Page tabs switch pages (and scroll when there are many); macro pages (`*name`) show their Inputs/Outputs blocks.
- [ ] Dark and light themes: blocks, grid and wires are readable in both; Settings ▸ Appearance follows the choice.

**Editing**
- [ ] Click selects a block; dragging moves it and the wires attached to it follow; releasing keeps it.
- [ ] Drag from an output pin to an input pin makes a wire; dropping on nothing makes none.
- [ ] `Delete` removes the selection; Undo and Redo (buttons and shortcuts) bring it back.
- [ ] The library searches; clicking a block adds it to the middle of the sheet; `Ctrl+K` focuses the search.
- [ ] Insert a rectangle, an ellipse and a text; select, move, resize shapes by the corner, double-click the text to edit it.

**Simulation**
- [ ] Play, Pause, Step and Reset work; `Space` toggles play; pins and wires light with the signal; a `Segment` lights its bars.
- [ ] Inspector: click a boolean input to flip it; type over a number; the block reacts.

**Dialogs, build, PLC**
- [ ] Double-click a block (or Inspector ▸ Configure…): the fields match the SwiftUI dialog; Apply changes it, Cancel does not.
  Try BoolVar, PulseGen, Counter, Timer, IntVar, Switch cases, 8xDI/8xDO, a macro's Inputs, a macro call.
- [ ] Menu ▸ PLC Configuration… (Ctrl+Alt+K) on `kostka 1.pcc`: one Configure Pins command, `Par1` 112 with I/O4–6 *In*; clicking a pin changes the
  number, typing a number changes the pins, Presets and Change command use the themed list (`PopupList.qml`), Hardware lists the profiles. On a new
  project Add Command works (it starts on Sybas Duino-E). Export Legacy .PCC of it contains a `SystemCmd` block and no `PLC_CONFIGURATION`.
- [ ] Open, Save, Save As… use the platform's dialogs; Save on a new project asks where. Save, then reopen in the SwiftUI app: intact,
  including shapes and text.
- [ ] Build shows the report; the `.pbd`, `.csv`, `.dbf` and legacy `.pcc` exports match the SwiftUI app's for the same project
  (`cmp`), and the legacy `.pcc` opens in the original Dirigo.
- [ ] PLC tab lists serial ports (on Linux `/dev/ttyUSB*`, `ttyACM*`; you need to be in `dialout`, or `uucp` on Arch); **Build & upload** (it opens the port itself)
  to a real PLC shows phases, progress and the log and ends with the PLC running the program.

**Blur and speed** (macOS, Metal)
- [ ] `QSG_INFO=1` says Metal; panels over blocks show a smooth Gaussian, the slider changes it from 4 to 64 px, and off gives solid grey.
- [ ] Panning is smooth with no shimmer under the panels, and a zoomed card stays sharp.

## Sharing a build (macOS)

The `wirebench-qt` binary alone only runs on a Mac with this checkout and Homebrew's Qt: it loads Qt from `/opt/homebrew` and the Swift bridge
from `.build`. To hand someone a build, make the self-contained bundle:

```
tools/bundle-qt.sh        # about 12 s once built; result: build/Wirebench-Qt.app
```

It copies in only the Qt the app uses (the macOS window plugin, the QML modules it imports and the Basic style, and the libraries those
need), points every path inside the bundle, signs each file ad hoc, and fails if anything still refers outside it (`tools/bundle-qt.py`,
which replaces `macdeployqt`: that scans every style and plugin Qt has and took minutes). Zip `Wirebench-Qt.app` and send it. It is unsigned for
distribution, so on another Mac the first launch needs right-click > Open, or `xattr -dr com.apple.quarantine Wirebench-Qt.app`. It is an
Apple-silicon build; an Intel Mac needs its own. On Linux, build with `tools/build-qt.sh` on the target machine.

