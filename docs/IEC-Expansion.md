# Expanding Structured Text beyond BOOL

The compiler currently lowers a Boolean dataflow: `BoolExpr` in `SourceCompiler.swift`, `BoolVar`/`Set` for state,
and every expression must be Boolean. This is the staged plan to reach IEC 61131-3 values. Each stage ends with
parser + compiler + engine tests, an updated `docs/Structured-Text.md`, a green `swift test` (including the
144-block differential suite), `xcodebuild` for the app and CLI, and `tools/build-qt.sh`.

## Stage 1: typed variables and numeric expressions

**Language.** `VAR n : INT; l : LONG; r : REAL; END_VAR`, initialisers (`n : INT := 5`), real literals (`1.5`),
arithmetic `+ - * / MOD`, comparisons `= <> < > <= >=` used where a Boolean is expected.
Pins (`AT %IXn` / `AT %QXn`) and `VAR_INPUT`/`VAR_OUTPUT` stay BOOL in this stage: typed values are internal.

**Type rules.** An integer literal is `INT`; a real literal is `REAL`. Widening only: `INT -> LONG -> REAL`.
A binary arithmetic node takes the wider operand type and converts the narrower side. `MOD` is integer-only.
A comparison takes both sides' common type and produces BOOL. Boolean operators and `NOT` stay BOOL-only.
`REAL` comparisons are refused until a float comparator block exists (the catalogue has `Comparator` for Int and
`LComparator` for Long, no float comparator).

**AST (`SourceParser.swift`).**
- `enum SourceType { case bool, int, long, real }`.
- `SourceVariable` gains `type: SourceType` and a typed `initial` literal; `SourceVariable.initial` is no longer `Bool`.
- `SourceExpr.Kind` gains `.real(Double)`; the ST lexer accepts `12`, `12.5`, and exponent-free reals.
- `typeName()` accepts `INT/LONG/REAL` as scalar declarations; identifier types remain instances.

**Lowering (`SourceCompiler.swift`).**
- Replace the single `BoolExpr` output of `lower` with a typed value: keep `BoolExpr` and add `NumExpr`
  (`IntExpr`/`RealExpr`), wrapped by `enum ValueExpr { case bool(BoolExpr); case number(NumExpr) }` with a static
  type. `lower` becomes type-directed; assignments require the variable's type, and an output pin requires BOOL.
- `NumExpr` cases: `constant(PinValue)`, `variable(String)`, `add/sub/mul/div/mod(NumExpr, NumExpr, SourceType)`,
  and `select(BoolExpr, NumExpr, NumExpr)` used by IF merges.
- IF merging: Boolean outputs use `BoolExpr.select` as now; numeric variables use `select`, which the emitter
  lowers to `ISwitch`/`LSwitch`/`FSwitch` (`Sw` = condition, `X0`/`X1` = branches).

**Emitter.**
- Reads: `IntVar`/`LongVar`/`FloatVar` block output pin 0; the block is created per declared variable, initial
  value written to its output pin.
- Writes: `Set` with `X` wired to the numeric value and `P1` connected to the variable's output (the same
  write-through the BOOL path uses; verify the core's `applySetWriteThrough` copies a non-BOOL value).
- Arithmetic blocks: `IAdd/ISub/IMul/IDiv` for INT, `LAdd/LSub/LMul/LDiv` for LONG, `FAdd/FSub/FMul/FDiv` for
  REAL, each `En := TRUE`, `X0`/`X1` wired.
- Comparisons: `Comparator` (INT) or `LComparator` (LONG); pick the output pin by operator — `AGtB` for `>`,
  `ALtB` for `<`, `AEqB` for `=`, and `NOT AEqB` for `<>`; `<=`/`>=` are `< OR =` / `> OR =`.
- Constants become `PinValue.int32/.int64/.float` on the consumer pin.

**Decompiler.** `IntVar`/`LongVar`/`FloatVar` + a typed `Set` recover to a typed `VAR`; if the typed write path
cannot be proven faithful, list those blocks as not recovered rather than inventing a value.

**Tests.** An arithmetic expression (`n := (a + b) * 2`), a variable incremented per scan (`n := n + 1`), a
comparison driving a `%QX` output, widening (`INT + LONG`), an IF on a numeric variable, initial values, and the
refusals: assigning REAL to INT, REAL comparison, writing a pin with a number, reading an output before assignment.
Simulation through `CxxSimulationCore` and a `.pcc` round trip of the emitted project.

## Stage 2: CASE (done)

Implemented by parsing CASE into an IF/ELSIF chain of selector comparisons (equality for a single label, `>=`/`<=`
for a range), so the existing merge/type rules apply. Overlapping labels, a REAL selector and a missing `END_CASE`
are refused; labels may be negative; tests cover selection, ranges and the refusals.

`CASE selector OF 1: ... 2, 3: ... ELSE ... END_CASE`. Selector is INT/LONG. Lower through `ISwitch`/`LSwitch`
or comparison chains; each arm merges per the IF rules. Refuse REAL selectors and overlapping labels.

## Stage 3: FOR / WHILE / REPEAT

A loop is not expressible as dataflow without unrolling or a state machine. Decide per construct:
`FOR` with constant bounds and no early `EXIT` can unroll (bounded by a documented maximum, e.g. 10 000
iterations) at compile time; `WHILE`/`REPEAT` need a counted state machine or are refused. Document the choice
in `docs/Structured-Text.md`; tests must pin the semantics, including the iteration cap.

## Stage 4: functions and arrays

Functions (`FUNCTION f : INT ... END_FUNCTION`) lower to a macro-style page plus a call block, or are refused
until the macro backend supports typed interfaces. Arrays need `ArrayRead`/`ArrayWrite` (or the catalogue's
`ReadIntArray`/`WriteIntArray` family) and the core's array store; array declarations (`ARRAY[0..N] OF INT`)
follow once typed values work.

## Pitfalls found while planning

- `Set`'s template has `X` typed Long and `P1…Pn` as BOOL-ish input pins; the engine's write-through copies
  `inPins[1]` into the producers, so a numeric `Set` depends on the producers accepting a typed value — verify
  with an `IntVar` before relying on it.
- `VAR` initial values currently only support BOOL; keep initialisers typed and refuse a mismatched one.
- The decompiler's `Set` handling is BOOL-specific (`booleanValue`); extend it with the type from the producer
  (`BoolVar`/`IntVar`/`LongVar`/`FloatVar`) or list the block.
- `PCCDecompiler` already emits `IntVar : IntVar` library instances; do not confuse those with typed variables.
- Keep the parser's case-insensitive names and keyword escaping (a block type named `INT` would be ambiguous).
