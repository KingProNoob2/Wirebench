# Wirebench

Wirebench is an editor, simulator and compiler for function-block PLC programs. It works with the project format
of Dirigo, a Windows tool for Sybas PLCs (P3, Duino and others), and was written against Dirigo's files and
binaries. It is an independent project, not affiliated with Dirigo's makers.

There are two front ends on one Swift model: a macOS SwiftUI app and a Qt Quick app that also builds on Linux.

## What it does

- **Projects.** Opens and saves Dirigo `.pcc` files, including the attributes and sections the model does not
  understand. Re-saving a project does not change it: every project in the test corpus is written back byte for
  byte.
- **Simulation.** Runs a program on a C++ core. 144 of the 147 catalogued block types run on it; the exceptions
  are under [Limits](#limits).
- **Compiling.** Produces the PLC program (`.pbd`) and the symbol table (`.csv`). For the projects whose Dirigo
  output is in `Tests/Fixtures`, both match byte for byte.
- **Uploading.** Sends a compiled program over a serial link, following the DbNet frames Dirigo uses.
- **Export Legacy .PCC.** Writes a copy in Dirigo's own sheet layout for a project edited here, without changing
  the open document.
- **Reference and agent.** A searchable block reference in English and Czech, and an optional chat panel that
  can read and edit the open project.

## Build

Swift 6 is needed for everything, Qt 6.5 or newer for the Qt app.

```bash
swift build
swift test            # on Linux add --skip CxxBlockFuzzTests; that suite needs more than 8 GB
```

On Linux install `zlib1g-dev` first. Under a file sandbox, add `--disable-sandbox` to both commands.

### macOS app

```bash
xcodegen generate             # after adding, renaming or deleting a source file
open Wirebench.xcodeproj      # or ./bundle-app.sh for a release Wirebench.app
```

The app is signed ad hoc, so macOS treats each rebuild as a new app and asks for Keychain access again (that is
where the agent keeps its API key). To avoid this, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig`, put one of your signing identities in it (`security find-identity -v -p codesigning`),
and run `xcodegen generate` again.

### Qt app

Needs cmake and optionally ninja, in addition to Swift and Qt.

```bash
# macOS
brew install qt ninja

# Debian and Ubuntu
sudo apt install build-essential git cmake ninja-build pkg-config zlib1g-dev libgl1-mesa-dev \
  qt6-base-dev qt6-declarative-dev qt6-declarative-dev-tools qt6-shadertools-dev \
  qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-window \
  qml6-module-qtquick-templates qml6-module-qtquick-shapes qml6-module-qtquick-dialogs

# Arch
sudo pacman -S --needed base-devel git cmake ninja pkgconf zlib mesa qt6-base qt6-declarative qt6-shadertools

# Fedora
sudo dnf install gcc-c++ git cmake ninja-build pkgconf-pkg-config zlib-devel mesa-libGL-devel \
  qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtshadertools-devel

tools/build-qt.sh Release     # Swift bridge, then the app: build/qt/wirebench-qt
build/qt/wirebench-qt [project.pcc]
```

If a package is missing, the build needs Qt Base, Declarative (Quick, Controls, Layouts, Shapes, Dialogs) and
ShaderTools. On an older distribution, install Qt 6.5 or newer from qt.io and point `CMAKE_PREFIX_PATH` at it.

- Serial uploads need access to the port: `sudo usermod -aG dialout $USER` (`uucp` on Arch), then log in again.
  The app says why a port will not open.
- Without a display: `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software`.
- `tools/bridge-smoke.sh [project.pcc]` builds the bridge and runs a C test that opens, plays and compiles a
  project, without Qt.

The Qt app has its own notes on architecture, diagnostics and packaging: [`qt/README.md`](qt/README.md).

## Using it

Open a project (File ▸ Open, drop it on the window, or pass it on the command line), drag blocks from the
library onto a sheet, drag from pin to pin to wire them, press play, double-click a block to configure it. Undo
and redo cover every edit.

**Pages and macros.** The SwiftUI sidebar lists the sheets; the Qt app shows them as tabs. Right-click a sheet to
rename or delete it. Renaming a page moves its blocks, graphics and PLC configuration with it; renaming a macro
renames the sheet and every call, including calls inside other macros. Both are saved in the `.pcc` and written
out by the legacy export.

**Wiring.** Drag from a pin to a pin. The cable is drawn as an elbow, and it snaps to the pin under the pointer
with a ring around it; the drop connects the pin that was ringed. An input takes one wire, so connecting to an
occupied input replaces it; an output can feed several. Click a wire to select it and press Delete to remove it,
or right-click it for the same.

**PLC Configuration** (Build ▸ PLC Configuration…, ⌥⌘K; Ctrl+Alt+K in Qt). A `SystemCmd` block sends one command
to the PLC's firmware, most often *Configure Pins* (`0x0302`), which sets which pins are inputs. That is a
property of the PLC rather than part of the circuit, so it is a list in the project: pick a command, enter
`Par1`/`Par2` as decimal, `0x…` or `$…`, or take a preset. Configure Pins has a grid of the basic PLC's 14 I/O
pins with I/O0 and I/O1 fixed as the serial link; higher pins (the Duino-E has up to 20) are typed in. The
Hardware menu picks the project's profile, and the profile decides which commands are offered. A new project
starts on `Sybas Duino-E`. Loading a `.pcc` moves each plain `SystemCmd` block (constant inputs, enabled, nothing
wired to it) into this list; a wired one stays on the sheet. Build and Export Legacy put them back as blocks in
their old places, and a native save keeps them in a `PLC_CONFIGURATION` section that Dirigo ignores.

**Export Legacy .PCC** (⇧⌘E; Ctrl+Shift+E in Qt) writes a copy for Dirigo. Its sheet and block sizes come from
Dirigo's fonts and printer, so a layout that does not fit is moved onto the sheet and then, if it still does not
fit, its distances shrink. Blocks keep their size. The open project is not changed, and the message afterwards
says what was done.

**Block reference.** Help ▸ Block Reference (⌘? in SwiftUI, F1 in Qt) opens a searchable manual of every block:
pins with types and defaults, and the rules each one follows, in English or the original Czech. "Help for this
block" in a block's menu opens its entry.

**Agent.** A chat panel (⌘⇧A; Ctrl+Shift+A in Qt) for any OpenAI-compatible service, with presets for OpenAI,
Anthropic, Gemini, OpenRouter, Groq, Mistral, DeepSeek, xAI, Ollama and LM Studio, plus a custom address. The API
key goes to the macOS Keychain, or on Linux to the Secret Service through `secret-tool` (`libsecret-tools`); it is
never written to a file, and requests use https unless the address is this computer. The agent reads pages, blocks
and live values and looks up the reference. With "Allow editing the project" on (it is off by default) it can add,
wire, move, configure and delete blocks, manage pages and macros, run the simulation and save. Its edits are
ordinary edits, so Undo takes them back. It cannot upload or change settings. What it reads is sent to the service
you choose.

**Hardware profiles.** The 22 profiles (thread periods, memory sizes, the commands each offers) and the `SystemCmd`
command table are compiled in, in `Sources/WirebenchCore/BuiltInProfiles.swift`, which `tools/gen_profiles.py`
writes. A running app never reads a profile file.

## Command line

```bash
swift run wirebench-cli info      project.pcc      # modules, pages, wiring
swift run wirebench-cli blocks    project.pcc      # how each module resolves to a block type
swift run wirebench-cli sim       project.pcc 20000
swift run wirebench-cli build     project.pcc      # writes the program (.pbd) and symbol table (.csv)
swift run wirebench-cli roundtrip project.pcc      # open, save, compare: nothing may be lost
```

## Layout

```
Sources/
  WirebenchCore       .pcc model, parser, serializer, hardware profiles, wire router
  WirebenchLibrary    function blocks and the recovered block-type catalogue
  WirebenchEngine     the simulation, wrapping the C++ core
  WirebenchHardware   serial port, DbNet upload, program compiler, symbol table
  WirebenchModel      editor state and commands, no view code; shared by both apps
  WirebenchBridge     C interface over WirebenchModel, used by the Qt app
  WirebenchApp        macOS SwiftUI app
  WirebenchCLI        wirebench-cli
  WirebenchSimCxx     the C++ simulation core
qt/                   the Qt Quick app
Tests/                swift test; Tests/Fixtures holds Dirigo's own program binaries and a symbol table
tools/                build and packaging scripts, and gen_profiles.py
```

Adding or removing a Swift file needs `xcodegen generate` afterwards; a test fails if a file is missing from the
Xcode project. The two apps are meant to offer the same functions, so a change to one usually means a change to
the other.

## Limits

- **Block types.** `Switch8` has no implementation. `Switch2`, `2xAO`, `IIC_3xDO`, `IIC_8xAO`, `IIC_8xDO`, `IQRF`,
  `UserComm`, `SaveData` and `P3Menu` keep their pins and do nothing else. `LLimiter`, `LComparator`, `LDemux` and
  `LongVar` use 32-bit integer arithmetic, so values above 2³¹ wrap. Hardware blocks (`SystemCmd`, `ReadDallas`,
  `8xPWM`, the D3-Net family) report zero, since there is no unit attached to them.
- **Layout.** Dirigo derives sheet and block sizes from its fonts and the printer. The legacy export approximates a
  block at 110 pt wide with 16 pt pin rows, which is what decides whether a layout is squashed. Wire routes drawn
  by hand in a file are followed only at that 16 pt layout and routed afresh otherwise; the file is not changed.

## Licence

[GNU General Public License v3.0](LICENSE). The profile data in `BuiltInProfiles.swift` and the files in
`Tests/Fixtures` come from Dirigo and are not covered by that licence.
