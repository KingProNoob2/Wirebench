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

- **Ladder pages** convert the simple rung shape: series NO/NC contacts on `DI0…DI7` become an `8xDI` reading and
  `And`/`Not` logic, and normal/negated coils on `DO0…DO7` drive an `8xDO`. Parallel branches, function-block
  elements, edge contacts, latching coils and analog coils are reported and skipped, since partially converting a
  rung would change its meaning.
- **Structured Text pages** are converted when they use the editor's generated block-call form: the `VAR…END_VAR`
  declarations become variable blocks, `<var> := Type(args)` and `Instance(args, Out => var)` become blocks plus
  `Set` writes, and literal or declared-variable arguments are wired. General expressions (for example `a + 1`),
  `IF`/loops and undeclared variables are reported and skipped, not guessed. The report gives the number of blocks
  converted.
- **Macros** are converted: a macro page keeps its `*Name` caption, `MacroIn`/`MacroOut` become the `Inputs`/`Outputs`
  interface blocks, and `Macro.User.*` blocks become Wirebench macro calls with the same pins. A call whose page is
  missing stays inert.
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

## Definition reference

Every definition in Maraflow's `BlockCatalog` and what the importer does with it. `inert` means an Unresolved placeholder with the original pins and constants: the topology is kept, simulation is not.

| Maraflow definition | Wirebench | Note |
|---|---|---|
| `Bool.And` | native | exact Maraflow pins |
| `Bool.Nand` | native | exact Maraflow pins |
| `Bool.Or` | native | exact Maraflow pins |
| `Bool.Nor` | native | exact Maraflow pins |
| `Bool.Xor` | native | exact Maraflow pins |
| `Bool.Xnor` | native | exact Maraflow pins |
| `Bool.Not` | native | exact Maraflow pins |
| `Bool.RS` | native | exact Maraflow pins |
| `Bool.SR` | native | exact Maraflow pins |
| `Math.Add` | `IAdd` |  |
| `Math.Sub` | `ISub` |  |
| `Math.Mul` | `IMul` |  |
| `Math.Div` | `Div` | Err output dropped |
| `Math.Min` | inert |  |
| `Math.Max` | inert |  |
| `Math.Mod` | inert |  |
| `Math.Pow` | inert |  |
| `Math.Abs` | `IAbs` |  |
| `Math.Neg` | `INeg` |  |
| `Math.Sqrt` | `FSqrt` |  |
| `Math.Sin` | `FSin` |  |
| `Math.Cos` | `FCos` |  |
| `Math.Clamp` | inert |  |
| `Math.Random` | inert |  |
| `Math.Scale` | inert |  |
| `Math.PID` | inert |  |
| `IO.DI` | `8xDI` | channel 0 |
| `IO.DO` | `8xDO` | channel 0 |
| `IO.8xDI` | `8xDI` |  |
| `IO.8xDO` | `8xDO` |  |
| `IO.AI` | `8xAI` | channel 0 |
| `IO.AO` | `2xAO` | channel 0; Ok dropped |
| `IO.PWM` | inert |  |
| `IO.Encoder` | `IRC` | Vel lands on Null |
| `Comm.ModbusRTU.MbRtuRead` | inert |  |
| `Comm.ModbusRTU.MbRtuWrite` | inert |  |
| `Comm.ModbusTCP.MbTcpRead` | inert |  |
| `Comm.ModbusTCP.MbTcpWrite` | inert |  |
| `Comm.REST.RestGet` | inert |  |
| `Comm.REST.RestPost` | inert |  |
| `Comm.DS18B20.DS18B20Read` | inert |  |
| `Comm.I2C.I2CRead` | inert |  |
| `Comm.I2C.I2CWrite` | inert |  |
| `Comm.SPI.SPITransfer` | inert |  |
| `Main.Arrays.ArrayRead` | inert |  |
| `Main.Arrays.ArrayWrite` | inert |  |
| `Main.Comparators.EQ` | `Comparator` | AEqB |
| `Main.Comparators.NE` | `Comparator` | AEqB inverted |
| `Main.Comparators.GT` | `Comparator` | AGtB |
| `Main.Comparators.GE` | `Comparator` | ALtB inverted |
| `Main.Comparators.LT` | `Comparator` | ALtB |
| `Main.Comparators.LE` | `Comparator` | AGtB inverted |
| `Main.Comparators.InRange` | `InRange` | Min/Max to Low/High parameters |
| `Main.Comparators.Hysteresis` | inert |  |
| `Main.Conversion.PackBits` | `Bits2Int` |  |
| `Main.Conversion.UnpackBits` | `Int2Bits` | En dropped |
| `Main.Execution.ReadReg` | inert |  |
| `Main.Execution.WriteReg` | inert |  |
| `Main.Execution.Interrupt` | inert |  |
| `Main.Safety.EStop` | inert |  |
| `Main.Filters.MovingAvg` | inert |  |
| `Main.Filters.LowPass` | inert |  |
| `Main.Filters.Debounce` | `DelayFilter` | Tms counts cycles |
| `Main.Switches.Sel` | `ISwitch` |  |
| `Main.Switches.Mux` | inert |  |
| `Main.Switches.Demux` | `IDemux` |  |
| `Main.Timers.DateTime` | inert |  |
| `Main.Timers.DecodeDate` | `DecodeDate` | date fields kept; time dropped |
| `Main.Timers.EncodeDate` | `EncodeDate` | date fields kept; time dropped |
| `Main.Timers.PulseGen` | `PulseGen` | Act held true; THi/TLo to TOn/TOff |
| `Main.Timers.PulseLen` | inert |  |
| `Main.Timers.SinglePulse` | `SinglePulse` | In to Tr; TOn defaults to one cycle |
| `Main.Timers.Timer` | `Timer` | PT to Dly; Q/ET to outputs |
| `Main.Timers.Counter` | inert |  |
| `Macro.MacroIn` | Inputs interface | macro sheet input |
| `Macro.MacroOut` | Outputs interface | macro sheet output |
| `Macro.User.*` | `Macro` call | macro page by name |
| `Visual.Segment` | `Segment` |  |
| `Visual.Value` | `Value` |  |
| `Visual.Vars.BoolVar` | `BoolVar` |  |
| `Visual.Vars.IntVar` | `IntVar` |  |
| `Visual.Vars.LongVar` | `LongVar` |  |
| `Ladder.Contact.NO` | rung logic | 8xDI contact |
| `Ladder.Contact.NC` | rung logic | 8xDI + Not |
| `Ladder.Contact.POS` | inert |  |
| `Ladder.Contact.NEG` | inert |  |
| `Ladder.Coil.NORMAL` | rung logic | 8xDO coil |
| `Ladder.Coil.NEGATED` | rung logic | 8xDO + Not |
| `Ladder.Coil.SET` | inert |  |
| `Ladder.Coil.RESET` | inert |  |
| `Ladder.Coil.POS` | inert |  |
| `Ladder.Coil.NEG` | inert |  |
| `Ladder.Coil.WRITE_REG` | inert |  |
| `Ladder.Coil.ANALOG` | inert |  |

Counts: 54 mapped, 40 inert placeholders.

The **Bool**, **Math**, **Main.Comparators**, **Main.Conversion** and **Main.Switches** groups now import as native
`MaraflowBlock` entries (deterministic UUID v5, exact pins, C++ semantics), not as Dirigo approximations. This includes
Maraflow's own silent no-ops (`Math.Pow`, `Math.PID`, `InRange`, `Hysteresis`, `Demux`), which remain no-ops exactly as
in its `SimulationEngine`. The table's per-row Wirebench target still describes the Stage-1 fallback for the groups not
yet native; the remaining definitions move over stage by stage.
