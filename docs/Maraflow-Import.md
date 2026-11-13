# Opening Maraflow projects (`.mfl`)

Maraflow is the Java FBD/LD/ST IDE this port started from. Wirebench can open its `.mfl` projects, map the FBD sheet
onto its own model, and save the result as a native `.wbp`.

## The file

`.mfl` is not JSON or Dirigo XML: it is a Java `Properties` document written with `storeToXML`, with the blocks and
wires flattened into numbered keys:

```xml
<properties>
  <entry key="project.name">Demo</entry>
  <entry key="project.pageCount">1</entry>
  <entry key="page.0.name">Main</entry>
  <entry key="page.0.block.0.defId">Bool.And</entry>
  <entry key="page.0.block.0.in.0.short">En</entry>
  <entry key="page.0.block.0.in.0.type">BOOL</entry>
  <entry key="page.0.block.0.in.0.const">1</entry>
  <entry key="page.0.wire.0.srcBlock">…uuid…</entry>
  <entry key="page.0.wire.0.srcPin">0</entry>
  <entry key="page.0.wire.0.dstBlock">…uuid…</entry>
  <entry key="page.0.wire.0.dstPin">1</entry>
</properties>
```

The reader is content-based: a `<properties>` document is Maraflow, a `PCC_PROJECT` document is Dirigo, and a JSON
object is a native `.wbp`. The extension only guides the file panels.

## What is mapped

Blocks are identified by their Maraflow definition id (`Bool.And`, `Math.Add`, `IO.8xDO`, …). The importer uses a
table for the definitions with a close Wirebench counterpart:

- **Bool:** `And`, `Or`, `Xor`, `Not`, `RS`; `Nand`/`Nor`/`Xnor` map to their base block with the consumer pin
  inverted; `SR` maps to `RS` with a note.
- **Math:** `Add`→`IAdd`, `Sub`→`ISub`, `Mul`→`IMul`, `Div`→`Div` (the error output is dropped), `Abs`→`IAbs`,
  `Neg`→`INeg`, `Sqrt`/`Sin`/`Cos`→`FSqrt`/`FSin`/`FCos`.
- **Comparators:** `EQ`/`NE`/`GT`/`GE`/`LT`/`LE` all become Dirigo's single `Comparator`; the right output
  (`AGtB`, `AEqB`, `ALtB`) is picked and inverted where needed. `InRange` becomes `InRange` with Min/Max on its
  Low/High parameters.
- **Conversion:** `PackBits`→`Bits2Int`, `UnpackBits`→`Int2Bits` (the latter drops `En`).
- **Switches:** `Sel`→`ISwitch`, `Demux`→`IDemux`.
- **I/O:** `IO.8xDI`/`IO.8xDO` map directly; single-channel `IO.DI`/`IO.DO`/`IO.AI` map to channel 0 of the
  corresponding 8-channel block.
- **Visual:** `Segment`, `Value`, `BoolVar`, `IntVar`, `LongVar` map directly.

Everything else — PID, filters, timers and counters (their pin sets differ), communication, virtual registers,
safety, ladder contacts/coils, macro boundaries — becomes an inert **Unresolved** block with the original pins and
values. The topology is preserved, the block does not simulate, and the import report names each type.

Wires are rebuilt from the source/target block ids and pin indices through the same mapping; their route points and
buses are not imported (Wirebench routes its own elbows). Hidden wires become normal wires with a note.

## Limits

- **Ladder pages** keep their page but not their rungs; the report gives the rung count.
- **Structured Text pages** keep their page but not their source; the report names them. Converting that source
  through the ST compiler is a later step.
- **Macros** are imported as normal pages; calls to them are inert placeholders, so their internals are visible but
  not executable.
- Maraflow's target (`STM32F407-…`) has no Wirebench hardware profile; the project uses the default profile, noted
  in the import report.
- The original `.mfl` is never overwritten: Save asks for a `.wbp` destination, as with a legacy `.pcc`.

## Where it lives

- `Sources/WirebenchModel/MaraflowFormat.swift` — the Java-properties reader and the on-disk DTOs.
- `Sources/WirebenchModel/MaraflowImporter.swift` — the definition table, pin remapping, placeholders and notes.
- `Sources/WirebenchModel/ProjectFile.swift` — format detection and the single read/write entry point.
- `Tests/WirebenchTests/MaraflowImportTests.swift` — a hand-written `.mfl` covering mapped blocks, a placeholder,
  inverted outputs, wires, the app's import/Save As flow, and a non-project file.

Open one with **File ▸ Open**, `wirebench-cli info project.mfl`, or any other CLI command that takes a project.
