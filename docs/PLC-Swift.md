# PLC Swift

Wirebench compiles a small subset of Swift — written in the shape of Embedded Swift — into a Dirigo `.pcc` project. The
source becomes blocks and wires, and the project then behaves like any other: it opens in the editor, runs on the
simulation core, compiles to the PLC program and uploads.

The syntax is **real Swift**: the front end is `swift-syntax`, the parser Swift itself uses, so the IDE can reuse the same
tree for highlighting and positions. What the compiler *accepts* is a subset; everything outside it is refused with a line
and a reason, because a compiler that guessed at the rest would quietly produce a different circuit. It is not the Swift
compiler: there is no type checker, no standard library and no machine code.

## Example

```swift
import PLC

@main
struct Lamp {
    @DI(0) var button: Bool
    @DO(1) var lamp: Bool

    var on: Bool = false              // a stored property: the program's state

    func scan() {
        let toggle = Toggle(value: button)
        if toggle.result { on = !on } // toggle when the button is down
        lamp = on
    }
}

// Every struct is a page; @macro makes it a macro page, and its pins are the call's.
@macro
struct Toggle {
    @Input(0) var value: Bool
    @Output(0) var result: Bool

    func scan() {
        result = !value
    }
}
```

This compiles to two pages — `Lamp` and `*Toggle` — with a `Macro` call block on `Lamp`, and the block editor's
sidebar lists the macro under **Macros**.

```bash
swift run wirebench-cli swift Lamp.swift --out .
# Compiled Lamp.swift (scan): 9 blocks
#   inputs  DI0
#   outputs DO1
#   /path/to/Lamp.pcc
```

## The language

**Every `struct` is a page.** One of them is `@main` (the page the project opens on); `@macro` makes a struct a macro
page. A struct holds its pins, its state and one `scan`.

| | |
|---|---|
| Pages | `struct Lamp { … }` is the page `Lamp`; `@main` marks the page the document opens on |
| Macros | `@macro struct Toggle { … }` is the page `*Toggle`, called from another page |
| Pins | a page: `@DI(0) var button: Bool`, `@DO(1) var lamp: Bool`; a macro: `@Input(0)`, `@Output(0)` |
| State | `var on: Bool = false` is a stored property: it keeps its value between scans |
| Statements | `let name = expr`, `let t = Macro(label: expr)`, `name = expr`, `if cond { … } else { … }`, `return` |
| Expressions | names, `t.output`, `true`, `false`, `!`, `&&`, `\|\|`, `==`, `!=`, parentheses, `pulse(ms:)` |
| Any block | `let b = Block.IAdd(true, x, y)` — a constructor per catalogued block, inputs positionally, parameters by label |
| Wiring | `b.set(2, other.Y)` — wires input 2 after creation, which is what lets feedback loops be written |
| Numbers | only in pin numbers and times: `@DI(7)`, `pulse(ms: 500)` |

Everything else is refused: integer signals, arithmetic, numeric comparisons, local `var`, loops, parameters, return
values, other attributes, types other than `Bool`. Each refusal names the line.

## How it becomes blocks

| Source | Blocks |
|---|---|
| `@DI(n)` | one `8xDI` for the program; the property reads output `DIn` |
| `@DO(n)` | one `8xDO` for the program; assigning the property drives input `DOn` |
| `var` property | one `BoolVar` (its initial value) and one `Set` that writes it once a scan |
| `@macro struct` | a `*Name` page with an `Inputs` and an `Outputs` block; its `scan` is the blocks between them |
| `let t = Toggle(value: x)` | a `Macro` block on the caller's page, its input pins wired from the arguments |
| `t.result` | the call block's `result` output pin |
| `!a` | `Not` |
| `a && b` | `And` |
| `a \|\| b` | `Or` |
| `a == b` | `Not` of `Xor` |
| `a != b` | `Xor` |
| `if c { … } else { … }` | a selection: `(c && then) || (!c && else)` for each output and variable |
| `pulse(ms:)` | `PulseGen`, its time split into cycles of the thread's period |
| `Block.<Type>(...)` | the catalogued block with that name; its input pins set from the positional arguments |
| `b.set(pin, value)` | wires that input pin; used for feedback, where the source cannot be an expression yet |

**A stored property is read at the start of the scan and written at its end.** The `BoolVar` holds the value; the `Set`
block writes it, and it is the last block in the order, so every read in the same scan sees the value the scan began
with. `lamp = on` therefore shows a change one scan after `on` changed — the usual behaviour of a PLC variable.

**`if` is a selection, not a conditional write.** Each branch lowers into a copy of the output and variable values, and
the copies are merged with the condition. The result is a value, not a branch of the block graph, so it is independent of
block order. An output a branch does not write keeps the value it had; an output nothing has written yet is `false`.

**Constants fold.** `if c { lamp = true } else { lamp = false }` is `c` itself: the input is wired straight to the output.

**Order is dependency order.** Every block is created after the blocks it consumes, so the `ORDER` values are also a valid
execution order; the `Set` blocks are created last, which is what makes the read-at-start rule hold.

**Time is milliseconds.** `pulse(ms: 500)` divides the time by the scan period to get cycles. The program runs on the
profile's **fastest thread** — for `Sybas Duino-E` that is thread 4 at 50 ms, because thread 1 is the 1000 ms "Timer 1s"
and cannot express a half-second pulse. A pulse shorter than that scan is refused rather than rounded away.

## Limits

- One `scan` per struct; pages run on the profile's fastest thread, macro pages on thread 0, as Dirigo stores them.
- A macro call cannot be inside `if` yet: the call is a block that runs every scan where it is written, and a
  conditional call has no lowering yet. A macro cannot start a timer either.
- Boolean signals only: no integers, arithmetic, numeric comparisons, timers with an input, counters or macros.
- `let` is not shared: a name used twice is materialised twice, which is correct but not deduplicated.
- The file is written natively, so an `if` leaves no `If`/`EndIf` markers in it.

## The editor

**View ▸ PLC Swift Editor** (⌥⌘E) opens a window with the source on the left and the compiler's report on the right. It
compiles as you type: colours come from the same parse the compiler uses, the report updates after a short pause, and a
diagnostic names its line and jumps to it when clicked.

- **Compile** (⌘R) compiles now; a change does so automatically a moment after typing stops.
- **Open in Wirebench** adopts the compiled project as the open document — it becomes the sheet on `main`, ready to look
  at, simulate, build or save. It replaces whatever was open, so unsaved work should be saved first.
- **Save .pcc…** writes the compiled project to a file without touching the open document.

The editor is an `NSTextView` with a line-number gutter, because SwiftUI's `TextEditor` can neither number lines nor
colour ranges. The text is the document; colours are attributes on its storage, so changing them does not touch the text
or its undo stack.

## Recovering source from a sheet

A `.pcc` stores blocks and wires, not text. When the IDE is opened on a project that has no source, it writes one back
(`PCCDecompiler`): each page becomes a struct, `8xDI`/`8xDO` pins become `@DI`/`@DO` properties, `BoolVar`s become
variables, `Macro` blocks become `let` calls, and `And`/`Or`/`Not`/`Xor`/`PulseGen` become expressions. Every other block is recovered through the library: `Block.<Type>(...)` creates it with its parameters, and
`name.set(pin, value)` wires each input afterwards, so counters and arithmetic with feedback come back too.

An `If`/`Else`/`EndIf` range is recovered as a source `if` **only when that cannot change the circuit**: the blocks
inside are combinational, and the writes are `Set` writes to variables, which the language's `if` merges exactly (its
else-less branch keeps the variable, as the gate does). A range holding a counter, a timer, an `8xDO` or a macro call is
listed in a `// Not recovered:` comment instead, and the report warns that compiling replaces the document with what was
recovered.

## Where the code is

| | |
|---|---|
| `Sources/WirebenchSource/SourceParser.swift` | the syntax tree and its construction from `swift-syntax` |
| `Sources/WirebenchSource/SourceCompiler.swift` | lowering, constant folding, and the block/wire emitter |
| `Sources/WirebenchSource/Highlighter.swift` | the editor's colours, from the same parse |
| `Sources/WirebenchSource/PCCDecompiler.swift` | the sheet back into source, for a document that has none |
| `Sources/WirebenchApp/SourceEditor.swift` | the `NSTextView` editor and its line-number gutter |
| `Sources/WirebenchApp/SwiftIDEView.swift` | the window: editor, diagnostics, and the compile/open/save actions |
| `Tests/WirebenchTests/SourceCompilerTests.swift` | the graph, a simulation of a compiled program, and the save/compile round trip |
| `docs/PLC-Swift.md` | this file |

The compiler builds both ways. In Xcode `WirebenchSource` is a **static framework**, which is what makes swift-syntax work
there: Xcode does not pass a package dependency's C include paths to a *static library* target, so `SwiftParser`'s
`_SwiftSyntaxCShims` stays unresolved; a framework links the package products and finds the module map, and
`MACH_O_TYPE = staticlib` keeps it an archive, with nothing to embed. The CLI scheme builds `wirebench-cli` against it —
`build/Build/Products/Debug/wirebench-cli` is the Xcode build of the compiler.

The test suite runs with `swift test`: the Xcode test target imports `WirebenchApp`, which an Xcode test bundle cannot link
without a test host, and that predates the compiler.

Next in line: integer signals and comparisons, timers with an input, counters, macros, and then the IDE that edits the
source in the app.
