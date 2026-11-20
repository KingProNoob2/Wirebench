import Foundation

extension PLCProjectCompiler {
    /// The role lists for the classes in `had.pcc`, **verified byte for byte** against `had.dmp`.
    ///
    /// These are the mapping the writer's code implies, written out per class: one role per word the
    /// record carries, in the order `TMP1Module.ExportFile` stage 8 walks (`module+0x7C`, then `+0x84`,
    /// then the out-pins at `+0x80`). The *values* that fill them come from the project file (constants),
    /// the symbol table (slots and terminals) and the wiring; the lists only say which value lands where,
    /// and `Tests/WirebenchTests/ProjectCompilerTests.swift`'s *Record reproduction* suite asserts that
    /// they rebuild all nine records of `had.dmp` byte for byte.
    ///
    /// The flag byte is deliberately absent: it is the module's hidden pins' own values, not a class
    /// property (the two `TMBoolVar`s carry `0x00` and `0xC0`), so it travels on `Module.flag`.
    /// The whole library: `classShapesFromP1` (read out of `P1.bpl`) with the nine entries `had.dmp`
    /// verifies laid over it. The nine win because for three of them the decomp's own counts are known to
    /// miss (`TMCounter`, `TMComparator`, `TMIntSwitch`), and because their `.terminal` words are pinned
    /// against the dump.
    /// Entries read from a class's own `ExportFile`, for the 24 classes that override the base writer.
    /// `TMDigitalInputs.ExportFile` (P1.bpl 0x41AEEC) is the first: it walks an array of up to sixteen pin
    /// pointers and gives each one `pin[0x64] = i` and `pin[0x60] = pin[0x68]`, so the class's record is
    /// one word per out-pin — its own terminal — for however many the project configures.
    public static let classShapesFromOverrides: [String: ClassShape] = [
        // The capture shows one word, the slot: `09 80 | 1001`.
        "TMDigitalInputs": .init(id: 9, roles: [.slot]),
        // The display classes are modules in the sheet but not part of the program: `had.pcc` holds a
        // `Segment1` whose module is present, and `had.dmp`'s record walk accounts for the other nine
        // modules and neither of the two displays. Saying so explicitly is what lets a build report tell
        // "writes no record" apart from "no shape yet".
        "TDispSegmentModule": .init(id: nil, roles: [], contributesRecord: false),
        // The value display is the same kind of module: `TDispValueModule` has its own `Load`, `Save` and
        // `DrawValues` in `Dirigo.exe` (the editor), and neither display class is in `P1.bpl`, the library the
        // program is made of. Without this a `Value` that sits on a thread was reported as "no record shape yet".
        "TDispValueModule": .init(id: nil, roles: [], contributesRecord: false),
    ]

    public static let classShapes: [String: ClassShape] = {
        var merged = classShapesFromP1
        for (cls, shape) in classShapesFromOverrides { merged[cls] = shape }
        for (cls, shape) in hadProjectShapes { merged[cls] = shape }
        return merged
    }()

    public static let hadProjectShapes: [String: ClassShape] = {
        let wire = ClassShape.Role.wire
        return [
            // PulseGen1: its own Cnt terminal as a wire, then its two declared constants, then the slot.
            // `[IN1][P0][P1][slot][Out]` — IN0 is a word only when wired (see `records`), and the Out terminal
            // follows the slot: `10 00 | 0600 0401 C001 C001 | 1007 | 0700` in the capture, `10 80 | 0100 C003
            // C003 | 1002 | 0000` in `had.dmp`, whose trailing `00 00` is that terminal and not a record.
            "TMPulseGenerator": .init(id: 16, roles: [.inPinOrValue(1), .paramPinOrValue(0), .paramPinOrValue(1),
                                                      .slot, .ownTerminal(svorka: 1)]),
            // A boolean variable writes no record: the two 2-byte records `had.dmp` was read as having are
            // the PulseGen's Out terminal and a constant.
            "TMBoolVar":        .init(id: nil, roles: [], contributesRecord: false),
            // Its third input is fed by its own hidden `LastState` out-pin — see `Role.feedback`. With a
            // plain `wire` there, an unconnected pin wrote constant 0 and the record differed from
            // `had.dmp` in exactly that word.
            "TMCounter":        .init(id: 15, roles: [wire, wire, .feedback(svorka: 0), .slot]),
            // `TMSetPins`: the constructor sets its id to 0x52 (`movl $0x52, 0xa4(%ebx)`, P1.bpl 0x415A47),
            // and the captured records start `52 04`. The record is `[En][X][P]`: the in-pins in order, then the
            // parameter. Each is its wire's terminal or, when unwired, its constant. The captured `*kostka`
            // record is `52 04 | 00 08 | 7F C0 | 03 10` (En from And5, X unwired at 127, P from ISwitch1), and
            // the `-mod3` save, with ISwitch1 moved to X, is `52 04 | 00 08 | 03 10 | 00 C0`.
            "TMSetPins":        .init(id: 82, roles: [.inPin(0), .inPinOrConstant(1),
                                                      .paramPinOrConstant(0), .hidden(0x04)]),

            // Captured in `Serial packet capture/` (2026-10-15). Both instances are 26 bytes, flag `0xA4`:
            // `*had`  0F A4 | 04 01 | 04 03 | 00 C0 | 00 C0 | 00 C0 | 00 C0 | 08 C0 | 00 C0 | 04 02 | 0A 10 | 04 03 | 04 04
            // `*kostka` 0F A4 | 00 07 | 08 10 | 00 C0 | 00 C0 | 00 C0 | 00 C0 | 05 C0 | 00 C0 | 00 09 | 08 10 | 00 0A | 00 0B
            // Inputs Tr, Rst, Pres, EnH, EnL are the five wires (`En` is not in the record); PV is the zero
            // parameter, Max the project's value (8 or 5), Min the zero parameter. Then the hidden Boolean
            // that holds the previous Tr (allocated before H and L), the Y word (a slot), H and L.
            // `St` (1) is not written. The `*kostka` Rst is wired from Y, a word, so it is a slot.
            "TMAdvCounter":     .init(id: 15, roles: [.inPinOrValue(1), .inPinOrValue(2), .inPinOrValue(3), .inPinOrValue(4),
                                                      .inPinOrValue(5), .paramPinOrValue(0), .paramPinOrValue(1),
                                                      .paramPinOrValue(2), .ownTerminal(svorka: 0), .slot,
                                                      .ownTerminal(svorka: 2), .ownTerminal(svorka: 3),
                                                      .hidden(0xA4)]),
            // `[In1][In2][its hidden Boolean][slot]`, as in `kostka-dir.pbd`: `Move` registers a Boolean at pin 0 like `Counter`.
            "TMMove":           .init(id: 28, roles: [wire, wire, .ownTerminal(svorka: 0), .slot]),
            "TMDigitalOutputs": .init(id: 10, roles: [.digitalOutputs]),
            // Eight bit inputs, then its own word (`kostka-dir.pbd`, Dirigo's own export of `kostka 1.pcc`); the library's declaration lists one wire.
            "TMBits2Int":       .init(id: 52, roles: (1...8).map { .inPinOrValue($0) } + [.slot], inPinFlagUnit: 0x04),
            // Six source wires, then its six **masks** as declared constants, then the slot. The masks
            // were `wire`s here because the dump test fed their values in as wires; a real build has no
            // wire for them at all and takes them from the project's `IN_PIN` values (`1, 2, 4, 8, 16,
            // 32`), which is what `had.dmp` carries as `C001 C002 C004 C008 C010 C020`. A build that
            // treated them as wires wrote `C000` six times.
            "TMIntSwitch":      .init(id: 30, roles: [.restOfInPins, .slot], inPinFlagUnit: 0x04),
            // Comparator1: a slot from elsewhere, its constant, two terminals, then its own output.
            // The out-pin writes its *own allocated* terminal. `had.dmp` alone made it look like a fixed
            // pair — `Comparator1` is module 6 and `Or1` module 7 there — but in `kostička` the same
            // classes are modules 6 and 2 and their terminals are different, which is what a
            // cross-project check caught.
            // One wire (its `<CONNECTION>`), one constant, then its **three** own out-pin terminals —
            // `AGtB`, `AEqB` and `ALtB`, which `had.dmp` carries as `0400 0500 0600`. They used to be
            // written as two `wire`s plus one terminal, because the old hand-fed test path had no
            // allocation to resolve an out-pin's address from; it does now, so the shape says what it means.
            "TMComparator":     .init(id: 6, roles: [wire, .unassigned, .ownTerminal(svorka: 0),
                                                     .ownTerminal(svorka: 1), .ownTerminal(svorka: 2)]),
            "TMOr":             .init(id: 20, roles: [wire, wire, .ownTerminal(svorka: 0)]),
            // `22 C0 | 100E | C00A | 2000 | 100F`: the dividend's wire, the divisor (a constant 10), the Long
            // quotient (`0x2000 + index`) and the int remainder.
            "TMDiv":            .init(id: 34, roles: [wire, .inPinOrValue(2), .ownTerminal(svorka: 0),
                                                      .ownTerminalIfPin(svorka: 1)]),
            // `[In1][In2][its Long]`, each input its wire or its constant (`kostka-dir.pbd`).
            "TMIntMul":         .init(id: 18, roles: [.inPinOrValue(1), .inPinOrValue(2), .ownTerminal(svorka: 0)]),
            "TMIntAdd":         .init(id: 12, roles: [.inPinOrValue(1), .inPinOrValue(2), .slot]),
            "TSystemCommand":   .init(id: 81, roles: [.systemCommand]),
            // Two classes compile to nothing at all: two byte-identical exports prove it.
            "TMInt2Bits":       .init(id: nil, roles: [], contributesRecord: false),
            // A variable holds a value for others to read and writes no record (`kostka-dir.pbd` has none for the `IntVar` in `*Demux`).
            "TMIntVar":         .init(id: nil, roles: [], contributesRecord: false),
        ]
    }()
}
