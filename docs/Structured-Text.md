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
- **Statements.** `name := expression;`, `instance(arguments);`, `IF … THEN … ELSIF … ELSE … END_IF;`, and
  `CASE selector OF 1: … 2, 3: … 5..7: … ELSE … END_CASE;`. CASE labels are whole numbers or ranges and must not
  overlap; the selector must be `INT`/`LONG` (a `REAL` selector needs a float comparator, which the catalogue lacks).
  CASE is lowered to the same comparisons and merges as an IF chain.
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
  `FOR`, `WHILE`, `REPEAT`, `VAR_GLOBAL` and direct addresses other than `%IX`/`%QX` are refused.
- `CASE` labels must be disjoint whole numbers or ranges; a `REAL` selector and overlapping labels are refused.
- A block call cannot sit inside `IF` (its wiring has no condition); create the block before the branch.
- A `%QX` output must be assigned before it is read, and an output written only inside `IF` must also be written before the
  `IF` or in both branches — otherwise the compiler refuses it rather than silently driving the pin.
- An instance must be called before its outputs are read, and a call site cannot be re-used twice in one scan.
- A nested `IF` inside `IF` is not recovered; the range stays skipped and is listed.
- The `IF` recovery only covers `Set` writes and combinational blocks; gated counters and timers are listed.
