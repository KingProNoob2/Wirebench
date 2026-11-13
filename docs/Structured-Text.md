# Structured Text

Wirebench's source language is IEC 61131-3 **Structured Text** (ST), not a Swift lookalike. A file compiles to a Dirigo
project: every `PROGRAM` is a page, every `FUNCTION_BLOCK` a macro page. The editor lives in **⌥⌘E** (Wirebench ▸
Structured Text Editor), colours the text as you type, compiles as you pause, and **Open in Wirebench** puts the result
on the sheet.

The compiler is `WirebenchSource`, a plain static library with its own lexer and parser — no parser package and no C
module — so the whole app, the CLI and the tests build in Xcode as well as with SwiftPM.

## The subset

```pascal
PROGRAM Gate
VAR
    button AT %IX0 : BOOL;      (* a digital input pin *)
    lamp   AT %QX0 : BOOL;      (* a digital output pin *)
    on     : BOOL;              (* stored state, FALSE at start *)
    debounce : PulseGen;        (* an instance of a catalogued block *)
END_VAR
    debounce(En := TRUE, Act := TRUE, TOn := 10, TOff := 10);
    IF button AND debounce.Output THEN
        on := NOT on;
    END_IF;
    lamp := on;
END_PROGRAM
```

- **Programs.** `PROGRAM Name … END_PROGRAM`; the first one is the page the document opens on. Every program is a page.
- **Pins.** `name AT %IXn : BOOL` is digital input *n*, `name AT %QXn : BOOL` output *n*, 0–7. A program gets one `8xDI`
  and one `8xDO`; a variable is read at the scan's start.
- **Arrays.** `a : ARRAY[0..15] OF INT;` declares an array in the PLC data area (INT, LONG or REAL; a REAL array uses
  `CreateLongArray`, which allocates Long or Float slots, with `ReadFloatArray`/`WriteFloatArray`). `a[3] := 5;` writes a slot and `x := a[3];` reads one; the declared lower bound is
  subtracted because the array blocks are 0-based. A literal index outside the declaration is a compile error; a
  computed one is range-checked by the block at run time. A read sees the value the scan began with; writes happen
  after the scan's other work, in source order. At most 16 arrays (the PLC's Id range 0–15), and only in a
  `PROGRAM`: a function block's array would share those Ids with the rest of the PLC data area.
- **State.** A value declared in `VAR` without an address is a stored variable — a `BoolVar`/`IntVar`/`LongVar`/
  `FloatVar` plus the `Set` that writes it. It becomes visible from the next scan, exactly like Dirigo's own clocked
  behaviour. An initialiser (`:= 5`) is the variable's configured value (`INIT_VALUE`).
- **Types.** `BOOL`, `INT`, `LONG` and `REAL` are supported for internal variables. A number widens `INT -> LONG ->
  REAL`; narrowing is refused. `+ - * /` on `INT`, `+ -` on `LONG`, and `+ - * / MOD` on `REAL` are lowered to
  `IAdd`/`ISub`/`IMul`/`Div`, `LAdd`/`LSub` and `FAdd`/`FSub`/`FMul`/`FDiv`/`FMod`. Comparisons `= <> < > <= >=`
  lower to `Comparator` (INT) or `LComparator` (LONG) — the catalogue has no float comparator, so a `REAL` comparison
  is refused; so are `LONG` multiply/divide and `INT` modulo, which have no block. Pins are still BOOL.
- **Expressions.** `AND`, `OR`, `XOR`, `NOT`, `=`, `<>`, parentheses. `TRUE`/`FALSE` and integer literals. Numeric
  arithmetic is refused with a message; this subset is Boolean.
- **Statements.** `name := expression;`, `instance(arguments);`, `IF … THEN … ELSIF … ELSE … END_IF;`,
  `CASE selector OF 1: … 2, 3: … 5..7: … ELSE … END_CASE;`, and
  `FOR i := 1 TO n [BY step] DO … END_FOR;`. FOR bounds and step must be whole-number literals and the body is
  unrolled at compile time (at most 256 iterations); the index is a compile-time binding, not a runtime variable after
  the loop (a read of `i` after `END_FOR` yields its value at the start of the scan, not the final index). Reads of
  variables assigned unconditionally earlier in the unrolled body are substituted with those
  expressions, so `n := n + 1` counts correctly; a conditional write is not substituted (it falls back to the
  variable's value at the start of the scan). `WHILE` and `REPEAT` are refused: a loop over a live condition cannot be
  expressed as dataflow — use FOR with constant bounds or a counter.
  CASE labels are whole numbers or ranges and must not
  overlap; the selector must be `INT`/`LONG` (a `REAL` selector needs a float comparator, which the catalogue lacks).
  CASE is lowered to the same comparisons and merges as an IF chain.
- **Functions.** `FUNCTION Add : INT VAR_INPUT a : INT; b : INT; END_VAR Add := a + b; END_FUNCTION` declares a pure
  function; a call `Add(1, 2)` is inlined into the caller's expression at compile time. A body may declare `VAR`
  locals (with optional initialisers) and contains **straight-line assignments** to those locals and to the function's
  own name (its result, last assignment wins); assignments are substituted in order, so locals need no storage.
  Parameters are read-only, a local must be assigned (or initialised) before it is read, and instances, arrays and
  control flow are not allowed inside a function. Argument count and the declared return type are checked at the call;
  recursion and very large expansions are refused. Calls are expressions, not statements.
- **Function blocks.** `FUNCTION_BLOCK Name VAR_INPUT … VAR_OUTPUT … END_FUNCTION_BLOCK` is a macro page. Its inputs and
  outputs are the interface blocks; declaring `t : Name;` makes a `Macro` block, `t(value := x);` wires it, and
  `t.result` reads its output.
- **Catalogued blocks.** Every block type in the catalogue is a type: `sum : IAdd;` declares one, `sum(X0 := a, X1 := 5);`
  sets its inputs and parameters by name, and `sum.Y` reads its output. The names are the block's pin abbreviations — `En`,
  `X0`, `X1`, `TOn`, `Par1`. A block whose name is a keyword (`AND`, `NOT`, `XOR`) is written with a trailing underscore:
  `a : And_;`.
- **Comments.** `(* … *)` (nested) and `//`.
- **Case.** Keywords are case-insensitive, as in ST; identifiers keep the case you wrote.

## What it becomes

| Source | Blocks |
|---|---|
| a program | a page |
| `AT %IXn` / `AT %QXn` | one `8xDI` / one `8xDO`, pins in order |
| stored `BOOL` | `BoolVar` + `Set` |
| stored `INT`/`LONG`/`REAL` | `IntVar`/`LongVar`/`FloatVar` + `Set`; value in `INIT_VALUE` |
| array | `CreateIntArray`/`CreateLongArray` + `Read…Array`/`Write…Array` |
| arithmetic/comparison | `IAdd`/`ISub`/`IMul`/`Div`, `LAdd`/`LSub`, `FAdd`/`FSub`/`FMul`/`FDiv`/`FMod`, `Comparator`/`LComparator` |
| numeric `IF` merge | `ISwitch`/`LSwitch`/`FSwitch` |
| `IF` | a selection of wires (`select`), folded where the condition is constant |
| `AND`/`OR`/`XOR`/`NOT` | `And`/`Or`/`Xor`/`Not` |
| a function block | a `*` macro page: `Inputs`/`Outputs` interface, body in between |
| `t : Name;` + `t(…)` | a `Macro` call block |
| `x : IAdd;` + `x(…)` | the catalogued block's module |
| pin write | a wire into the `8xDO` |
| variable write | a wire into the variable's `Set` |

Everything lands on the profile's fastest thread (Sybas Duino-E: 50 ms), so the sheet and the hardware behave alike. A
`PulseGen`'s `TOn`/`TOff` are in **scans**, not milliseconds — 20 scans at 50 ms is one second.

## Recovery

Opening a `.pcc` with an empty editor recovers it to ST: programs, `%IX`/`%QX` pins, stored variables, block and macro
instances, calls, Boolean operators, and `IF`/`ELSE` ranges of `Set` writes. A project with only macro sheets gets a
`PROGRAM Main` so the text is a program. What the subset cannot express — a counter, a timer, a graphic, a nested
conditional, a non-Boolean pin — is listed under `(* Not recovered: … *)` rather than invented, and a fractional float
parameter is left out instead of rounded.

Recovery is a readable description, not a byte-level promise: pin and variable names are lost in a `.pcc`, so they come
back as `di0`, `do0`, `state`. Digital I/O is recovered by **hardware channel**: a masked `8xDI` (`PIN_MASK`) or a
counted/hidden `8xDO` (`PIN_COUNT`, `HIDDEN_PIN_MASK`) declares the channels it exposes (`AT %IX4`, `AT %QX1`). A channel
above 7 has no spelling in the subset and is listed instead of moved to another pin.

## Verification

Stages 1–4 (typed values, CASE, FOR, arrays) are covered by `StructuredTextTests`; the full suite, the 144-block
differential suite, the Xcode app/CLI and Qt builds are green as of the array/loop work.

## Recovery and typed values

A typed variable is **not** recovered as a typed `VAR` yet: the `Set` that writes it is listed under
`(* Not recovered: … (typed variable write) *)`. An `IntVar`/`LongVar`/`FloatVar` instance still comes back as a
catalogued block instance, so its output reads as a BOOL wire rather than a number.

## Command line

```sh
wirebench-cli st Program.st --out build --name Blink
```

`st` compiles to `<name>.pcc` (`--name` sets that name); the app's **Compile** button and its report come from the
same compiler.

## Limits

- `BOOL` pins only: `AT %IXn`/`%QXn` and `VAR_INPUT`/`VAR_OUTPUT` are BOOL; typed values are internal variables.
- `REAL` comparisons, `LONG` multiply/divide and `INT` modulo have no block and are refused. Arrays, structures,
  `VAR_GLOBAL` and direct addresses other than `%IX`/`%QX` are refused.
- `CASE` labels must be disjoint whole numbers or ranges; a `REAL` selector and overlapping labels are refused.
- A `FUNCTION` body is straight-line assignments to its locals and its name: no control flow, no instances/arrays;
  calls are inlined (parameters substituted, locals as ordered bindings), so a recursive function is refused
  (nesting/expansion cap).
- `FOR` needs literal bounds/step and unrolls to at most 256 iterations; an instance cannot be called once per
  iteration (the same block call twice in one scan is refused). `WHILE` and `REPEAT` are refused.
- Arrays are INT/LONG/REAL, at most 16, and cannot be written inside IF or CASE. A read in the same scan as a write
  sees the value from before the scan.
- A variable written inside a conditional in a FOR body is read back as the scan-start value, not the value the
  previous iteration wrote (the dataflow model's general rule).
- A block call cannot sit inside `IF` (its wiring has no condition); create the block before the branch.
- A `%QX` output must be assigned before it is read, and an output written only inside `IF` must also be written before the
  `IF` or in both branches — otherwise the compiler refuses it rather than silently driving the pin.
- An instance must be called before its outputs are read, and a call site cannot be re-used twice in one scan.
- A nested `IF` inside `IF` is not recovered; the range stays skipped and is listed.
- The `IF` recovery only covers `Set` writes and combinational blocks; gated counters and timers are listed.
