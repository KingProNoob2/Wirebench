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

Every key read from the `.mfl` is also kept verbatim in `project.maraflow.properties` in the native `.wbp`, including
tags, E-Stop configuration, graphic objects, bus ids, wire route points and ST/rung data that the importer does not yet
interpret. This is the lossless fallback for the compatibility stages; it is preserved by save and by the JSON format's
version 2.

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
- **Timers:** `Timer`→`Timer` (PT to Dly, Q/ET to its outputs), `SinglePulse`→`SinglePulse`, `PulseGen`→`PulseGen`
  (Act held true); `DecodeDate`/`EncodeDate` map their date fields (time fields are dropped).
- **Filters:** `Debounce`→`DelayFilter` (Tms counts cycles).
- **Switches:** `Sel`→`ISwitch`, `Demux`→`IDemux`.
- **I/O:** `IO.8xDI`/`IO.8xDO` map directly; single-channel `IO.DI`/`IO.DO`/`IO.AI` map to channel 0 of the
  corresponding 8-channel block; `IO.AO` goes to `2xAO` channel 0 and `IO.Encoder` to `IRC`.
- **Visual:** `Segment`, `Value`, `BoolVar`, `IntVar`, `LongVar` map directly.

Everything else — PID, filters, timers and counters (their pin sets differ), communication, virtual registers,
safety, ladder contacts/coils, macro boundaries — becomes an inert **Unresolved** block with the original pins and
values. The topology is preserved, the block does not simulate, and the import report names each type.

Wires are rebuilt from the source/target block ids and pin indices through the same mapping; their route points and
buses are not imported (Wirebench routes its own elbows). Hidden wires become normal wires with a note.

## Limits

- **Ladder pages** run through a native evaluator: series NO/NC/edge contacts, parallel branches with their
  start/end columns, normal/negated/set/reset/edge coils, analog moves, immediate operand writes and per-element
  edge memory. Rungs are grouped by thread so scheduler order matches Maraflow. **Function-block elements** execute
  too: `En` comes from rung power, every other input is resolved from its operand/literal, outputs are written to
  their bound operands, the first BOOL output gates power onward, and the block keeps its state between scans.
  Operands may be plain names, literals or dotted `Block.Pin` references.

## Where it lives

- `Sources/WirebenchModel/MaraflowFormat.swift` — the Java-properties reader and the on-disk DTOs.
- `Sources/WirebenchModel/MaraflowImporter.swift` — the definition table, pin remapping, placeholders and notes.
- `Sources/WirebenchModel/ProjectFile.swift` — format detection and the single read/write entry point.
- `Tests/WirebenchTests/MaraflowImportTests.swift` — a hand-written `.mfl` covering mapped blocks, a placeholder,
  inverted outputs, wires, the app's import/Save As flow, and a non-project file.

Open one with **File ▸ Open**, `wirebench-cli info project.mfl`, or any other CLI command that takes a project.

## Definition reference

All 93 statically registered Maraflow definitions are native `MaraflowBlock` entries in the C++ core with exact
pins; `Macro.User.*` is dynamic and becomes a macro call. Definitions with no evaluator in Maraflow's own
`SimulationEngine` are native no-ops, matching it.

| Maraflow definition | Type | Status |
|---|---|---|
| `Bool.And` | And | native |
| `Bool.Nand` | Nand | native |
| `Bool.Or` | Or | native |
| `Bool.Nor` | Nor | native |
| `Bool.Xor` | Xor | native |
| `Bool.Xnor` | Xnor | native |
| `Bool.Not` | Not | native |
| `Bool.RS` | RS | native |
| `Bool.SR` | SR | native |
| `Math.Add` | Add | native |
| `Math.Sub` | Sub | native |
| `Math.Mul` | Mul | native |
| `Math.Min` | Min | native |
| `Math.Max` | Max | native |
| `Math.Div` | Div | native |
| `Math.Mod` | Mod | native |
| `Math.Pow` | Pow | native |
| `Math.Abs` | Abs | native |
| `Math.Neg` | Neg | native |
| `Math.Sqrt` | Sqrt | native |
| `Math.Sin` | Sin | native |
| `Math.Cos` | Cos | native |
| `Math.Clamp` | Clamp | native |
| `Math.Random` | Random | native |
| `Math.Scale` | Scale | native |
| `Math.PID` | PID | native |
| `IO.DI` | DI | native |
| `IO.DO` | DO | native |
| `IO.8xDI` | 8x DI | native |
| `IO.8xDO` | 8x DO | native |
| `IO.AI` | AI | native |
| `IO.AO` | AO | native |
| `IO.PWM` | PWM | native |
| `IO.Encoder` | Encoder | native |
| `Comm.ModbusRTU.MbRtuRead` | MbRtuRead | native |
| `Comm.ModbusRTU.MbRtuWrite` | MbRtuWrite | native |
| `Comm.ModbusTCP.MbTcpRead` | MbTcpRead | native |
| `Comm.ModbusTCP.MbTcpWrite` | MbTcpWrite | native |
| `Comm.REST.RestGet` | RestGet | native |
| `Comm.REST.RestPost` | RestPost | native |
| `Comm.DS18B20.DS18B20Read` | DS18B20 | native |
| `Comm.I2C.I2CRead` | I2CRead | native |
| `Comm.I2C.I2CWrite` | I2CWrite | native |
| `Comm.SPI.SPITransfer` | SPITransfer | native |
| `Main.Arrays.ArrayRead` | ArrayRead | native |
| `Main.Arrays.ArrayWrite` | ArrayWrite | native |
| `Main.Comparators.EQ` | EQ | native |
| `Main.Comparators.NE` | NE | native |
| `Main.Comparators.GT` | GT | native |
| `Main.Comparators.GE` | GE | native |
| `Main.Comparators.LT` | LT | native |
| `Main.Comparators.LE` | LE | native |
| `Main.Comparators.InRange` | InRange | native |
| `Main.Comparators.Hysteresis` | Hysteresis | native |
| `Main.Conversion.PackBits` | PackBits | native |
| `Main.Conversion.UnpackBits` | UnpackBits | native |
| `Main.Execution.ReadReg` | ReadReg | native |
| `Main.Execution.WriteReg` | WriteReg | native |
| `Main.Execution.Interrupt` | Interrupt | native |
| `Main.Safety.EStop` | EStop | native |
| `Main.Filters.MovingAvg` | MovingAvg | native |
| `Main.Filters.LowPass` | LowPass | native |
| `Main.Filters.Debounce` | Debounce | native |
| `Main.Switches.Sel` | Sel | native |
| `Main.Switches.Mux` | Mux | native |
| `Main.Switches.Demux` | Demux | native |
| `Main.Timers.DateTime` | DateTime | native |
| `Main.Timers.DecodeDate` | DecodeDate | native |
| `Main.Timers.EncodeDate` | EncodeDate | native |
| `Main.Timers.PulseGen` | PulseGen | native |
| `Main.Timers.PulseLen` | PulseLen | native |
| `Main.Timers.SinglePulse` | SinglePulse | native |
| `Main.Timers.Timer` | Timer | native |
| `Main.Timers.Counter` | Counter | native |
| `Macro.MacroIn` | MacroIn | native |
| `Macro.MacroOut` | MacroOut | native |
| `Visual.Segment` | Segment | native |
| `Visual.Value` | Value | native |
| `Visual.Vars.BoolVar` | BoolVar | native |
| `Visual.Vars.IntVar` | IntVar | native |
| `Visual.Vars.LongVar` | LongVar | native |
| `Ladder.Contact.NO` | NO Contact (--| |--) | native |
| `Ladder.Contact.NC` | NC Contact (--|/|--) | native |
| `Ladder.Contact.POS` | Rising Contact (--|P|--) | native |
| `Ladder.Contact.NEG` | Falling Contact (--|N|--) | native |
| `Ladder.Coil.NORMAL` | Normal Coil (--( )--) | native |
| `Ladder.Coil.NEGATED` | Negated Coil (--(/)--) | native |
| `Ladder.Coil.SET` | Set Coil (--(S)--) | native |
| `Ladder.Coil.RESET` | Reset Coil (--(R)--) | native |
| `Ladder.Coil.POS` | Rising Coil (--(P)--) | native |
| `Ladder.Coil.NEG` | Falling Coil (--(N)--) | native |
| `Ladder.Coil.WRITE_REG` | Write Register (--[REG :=]--) | native |
| `Ladder.Coil.ANALOG` | Analog Output / Move (--[AO :=]--) | native |

Counts: 93 native, 0 inert placeholders.
