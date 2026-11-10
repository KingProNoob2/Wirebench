import Testing
import Foundation
import WirebenchCore
@testable import WirebenchHardware

@Suite("Project compiler")
struct ProjectCompilerTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func hadXML() throws -> String {
        let url = root.appendingPathComponent("had+1block.pcc")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs a project export")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The class shapes established from the export diffs. Mirrors docs/class-shapes.json.
    /// The classes' shapes, with the role patterns `had.dmp` shows (docs/plc-protocol.md).
    static let wire = PLCProjectCompiler.ClassShape.Role.wire
    static let slot = PLCProjectCompiler.ClassShape.Role.slot
    static let unassigned = PLCProjectCompiler.ClassShape.Role.unassigned
    static let shapes: [String: PLCProjectCompiler.ClassShape] = [
        "TMPulseGenerator": .init(id: 16, roles: [wire, unassigned, unassigned, slot]),
        "TMBoolVar":        .init(id: nil, roles: []),
        "TMCounter":        .init(id: 15, roles: [wire, wire, wire, slot]),
        "TMDigitalOutputs": .init(id: 10, roles: Array(repeating: wire, count: 8)),
        "TMIntSwitch":      .init(id: nil, roles: Array(repeating: wire, count: 5) + [slot] + Array(repeating: wire, count: 6) + [slot]),
        "TMComparator":     .init(id: 6, roles: [slot, unassigned, wire, wire, wire]),
        "TMOr":             .init(id: 20, roles: [wire, wire, wire]),
        "TSystemCommand":   .init(id: 81, roles: [unassigned, unassigned, slot]),
        "TMInt2Bits":       .init(id: nil, roles: [], contributesRecord: false),
    ]

    /// GUID -> class, as recorded in `docs/block-ids.json` and confirmed by walking `had.dmp`.
    /// `Segment1`'s GUID is not in the table and it contributes no record, which the tests account for.
    static let classForGUID: [String: String] = [
        "74F92168-F67B-4364-8AC0-B735DAA400A3": "TMPulseGenerator",
        "4139463D-8956-4642-BE4E-8A02E95392D3": "TMBoolVar",
        "E37509F9-7693-49D7-977E-BAA796F92265": "TMCounter",
        "0F50AC33-F61E-4009-9C60-FDE664DA0ABC": "TMDigitalOutputs",
        "0FAE4998-FD44-4CA1-B55F-7E148FDFF20A": "TMIntSwitch",
        "8942245A-7E82-43FF-94E8-E7BCF69FDEE9": "TMComparator",
        "5745AE44-2B47-4828-AEFA-B96375DA31C4": "TMOr",
        "F319DECC-7D91-4684-A813-83DBB5C70245": "TMInt2Bits",
        "060906AA-5048-4931-BE5C-714697885084": "TSystemCommand",
        // "{565E4F34-...}" (Segment1) is deliberately absent: it has no class in the table.
    ]

    @Test("The project parses into its modules and wires")
    func parses() throws {
        let xml = try Self.hadXML()
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        #expect(modules.count == 12)
        #expect(wires.count == 20)
        // `Segment2` was added after `had.dmp`; it is the segment class, which contributes no record, so
        // the record region is unchanged — which is exactly what `had+1block.dmp == had.dmp` shows.
        #expect(modules.contains { $0.name == "Segment2" })

        // ORDER is the compile order, and the module IDs are the UMISTENI.
        #expect(modules.map(\.name).first == "PulseGen1")
        #expect(modules.first(where: { $0.name == "Counter1" })?.umisteni == 3)
        #expect(modules.first(where: { $0.name == "SystemCmd1" })?.umisteni == 11)
        // The tie at ORDER 40 is 8xDO1 then reset, as the confirmed record at 0x56 requires.
        let tied = modules.filter { $0.order == 40 }.map(\.name)
        #expect(Set(tied) == ["8xDO1", "reset"])
    }
}

/// The symbol table Dirigo writes beside a project gives each module its data slot.
@Suite("Symbol table")
struct SymbolTableTests {
    static var csv: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("had+1block.csv")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test("Module data slots come from the symbol table's ROWINDEX")
    func slotsFromCSV() throws {
        let csv = try #require(Self.csv, "needs had+1block.csv; got nil")
        let slots = PLCProjectCompiler.slots(fromSymbolCSV: csv)
        #expect(slots.count >= 4, "parsed \\(slots.count) modules: \\(slots)")
        #expect(slots["Counter1"] == 3, "slots: \\(slots)")
        #expect(slots["PulseGen1"] == 2, "slots: \\(slots)")
        #expect(slots["ISwitch1"] == 1, "slots: \\(slots)")
        #expect(slots["SystemCmd1"] == 4, "slots: \\(slots)")
    }

    @Test("The compiler's output carries slots where had.dmp has them")
    func compiledSlotsMatchTheRealTable() throws {
        let xml = try ProjectCompilerTests.hadXML()
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        let compiler = PLCProjectCompiler(shapes: ProjectCompilerTests.shapes, classForGUID: ProjectCompilerTests.classForGUID)
        let slots = PLCProjectCompiler.slots(fromSymbolCSV: try #require(SymbolTableTests.csv))
        let built = try compiler.records(modules: modules, wires: wires, slots: slots)

        #expect(built.count == 98, "nine records totalling 98 bytes; got \(built.count)")

        // Walk the compiled output with the same layout had.dmp has, and collect the data slots.
        var found: [String: [UInt16]] = [:]
        var offset = 0
        let layout: [(String, Int)] = [("PulseGen1", 4), ("zapnuti", 0), ("Counter1", 4), ("8xDO1", 8),
                                       ("reset", 0), ("ISwitch1", 13), ("Comparator1", 5), ("Or1", 3),
                                       ("SystemCmd1", 3)]
        for (name, n) in layout {
            var mine: [UInt16] = []
            for k in 0..<n where offset + 2 + 2 * k + 1 < built.count {
                let v = UInt16(built[offset + 2 + 2 * k]) | (UInt16(built[offset + 2 + 2 * k + 1]) << 8)
                if v >> 8 == 0x10 { mine.append(v - 0x1000) }
            }
            found[name] = mine
            offset += 2 + 2 * n
        }

        // The four the symbol table determines, and the two classes that carry none.
        #expect(found["Counter1"] == [3], "got \(found["Counter1"] ?? [])")
        #expect(found["PulseGen1"] == [2], "got \(found["PulseGen1"] ?? [])")
        #expect(found["SystemCmd1"] == [4], "got \(found["SystemCmd1"] ?? [])")
        #expect(found["Or1"] == [], "Or1 carries no data slot")
        #expect(found["8xDO1"] == [], "8xDO1 carries no data slot")
    }
}

/// The constants in the table are the constants in the project file, with `0xC000` in front.
///
/// This is the check that settles the value encoding, and it is a join of two artefacts rather than a
/// test of our own code: `TMP1Module.InPinBinaryOutput` (P1.bpl 0x40D3F4) ends
/// `andw $0x3fff, %bx; orw $0xc000, %bx` (0x40D716) for an input pin with no source, so a pin whose
/// project value is *v* must appear in `had.dmp` as `0xC000 | v`. Every constant in the table is
/// accounted for, including the two that defeated every earlier reading: `SystemCmd1`'s `770` and `112`.
@Suite("Constant encoding")
struct ConstantEncodingTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(name))
    }

    /// (module, table offset of the word, the project value that word must encode)
    static let expected: [(String, Int, Int)] = [
        // PulseGen1's two PARAM_PINs, both 3.
        ("PulseGen1", 0x44, 3), ("PulseGen1", 0x46, 3),
        // 8xDO1's five unwired inputs, all 0.
        ("8xDO1", 0x58, 0), ("8xDO1", 0x5A, 0), ("8xDO1", 0x60, 0), ("8xDO1", 0x62, 0), ("8xDO1", 0x64, 0),
        // ISwitch1's six mask inputs, and its unwired first input.
        ("ISwitch1", 0x6C, 0), ("ISwitch1", 0x78, 1), ("ISwitch1", 0x7A, 2), ("ISwitch1", 0x7C, 4),
        ("ISwitch1", 0x7E, 8), ("ISwitch1", 0x80, 16), ("ISwitch1", 0x82, 32),
        // Comparator1's third input.
        ("Comparator1", 0x8A, 6),
        // SystemCmd1: the second IN_PIN and the first PARAM_PIN.
        ("SystemCmd1", 0x9C, 770), ("SystemCmd1", 0x9E, 112),
    ]

    @Test("Every constant in the project file is in had.dmp as 0xC000 | value")
    func constantsComeFromTheProject() throws {
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        let table = [UInt8](try Self.data("had.dmp"))

        // What the project declares, per module, so an offset cannot be checked against a number that
        // is not in the file at all.
        var declared: [String: [Int]] = [:]
        for m in PLCProjectCompiler.modules(in: xml) {
            let tag = try #require(moduleTag(in: xml, named: m.name))
            let ins = pinValues("IN_PIN", in: tag) + pinValues("PARAM_PIN", in: tag)
            declared[m.name] = ins
        }

        for (module, offset, value) in Self.expected {
            #expect(declared[module]?.contains(value) == true,
                    "\(module) does not declare \(value): \(declared[module] ?? [])")
            let word = UInt16(table[offset]) | (UInt16(table[offset + 1]) << 8)
            #expect(word == 0xC000 | UInt16(value),
                    "\(module) @0x\(String(offset, radix: 16)): expected 0x\(String(0xC000 | value, radix: 16)), got 0x\(String(word, radix: 16))")
        }
    }

    @Test("The compiler emits SystemCmd1's record the way had.dmp has it")
    func systemCommandCompiles() throws {
        // The shipped shape: the command (the second IN_PIN, 770 = 0x0302), `I1` (the first PARAM_PIN, 112), then
        // the slot. `I2` is hidden in the default variant, so it is not a word and sets bit 0x20 of the flag.
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)
        let module = PLCProjectCompiler.Module(
            name: "SystemCmd1", guid: "{060906AA-5048-4931-BE5C-714697885084}",
            umisteni: 11, order: 100, inPinCount: 2, outPinCount: 1, inValues: [1, 770], paramValues: [112, 0])

        let built = try compiler.records(modules: [module], wires: [], slots: ["SystemCmd1": 4])

        // had.dmp at 0x9A: 51 A0 | 02 C3 70 C0 04 10. Flag: 0x80 from `En`'s constant 1, 0x20 from the hidden `I2`.
        #expect(built == [0x51, 0xA0, 0x02, 0xC3, 0x70, 0xC0, 0x04, 0x10], "got \(built.map { String($0, radix: 16) })")

        // A `Pwm` variant (`zelznice.pcc`) shows both parameters and carries its own command word.
        var pwm = module
        pwm.systemCommand = ProfilesParser.systemCommand(fromDefinition:
            "TXT=Pwm, CMD=0x0303, I1=(Int)PwmCH,        I2=(Int)Value,        O1=(Int)Out")
        pwm.paramValues = [2, 90]
        let pwmBuilt = try compiler.records(modules: [pwm], wires: [], slots: ["SystemCmd1": 4])
        #expect(pwmBuilt == [0x51, 0x80, 0x03, 0xC3, 0x02, 0xC0, 0x5A, 0xC0, 0x04, 0x10],
                "got \(pwmBuilt.map { String($0, radix: 16) })")
        #expect(PLCProgramBuilder.Module.constant(770) == 0xC302)
        #expect(PLCProgramBuilder.Module.constant(112) == 0xC070)
        #expect(PLCProgramBuilder.Module.constant(0) == 0xC000)
    }

    @Test("PulseGen1's params land where had.dmp has them")
    func pulseGenConstants() throws {
        let shapes: [String: PLCProjectCompiler.ClassShape] = [
            "TMPulseGenerator": .init(id: 16, roles: [.wire, .unassigned, .unassigned, .slot]),
        ]
        let compiler = PLCProjectCompiler(shapes: shapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)
        let module = PLCProjectCompiler.Module(
            name: "PulseGen1", guid: "{74F92168-F67B-4364-8AC0-B735DAA400A3}",
            umisteni: 1, order: 10, inPinCount: 2, outPinCount: 2, constants: [3, 3])

        let built = try compiler.records(modules: [module], wires: [], slots: ["PulseGen1": 2])
        // had.dmp at 0x40: 10 80 | 00 01 03 C0 03 C0 02 10. Words 1 and 2 are the two constants and
        // word 3 the slot; word 0 is the position whose class order is still to be read (it is a
        // terminal, `0x0100`, not the constant the sheet's first pin would suggest).
        #expect(Array(built[4...9]) == [0x03, 0xC0, 0x03, 0xC0, 0x02, 0x10], "got \(built.map { String($0, radix: 16) })")
    }

    // MARK: - Small XML helpers

    private func moduleTag(in xml: String, named name: String) -> String? {
        let pattern = "<MODULE\\b[^>]*NAME=\"\(name)\"[^>]*>(.*?)</MODULE>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        guard let m = re.firstMatch(in: xml, range: range), let r = Range(m.range, in: xml) else { return nil }
        return String(xml[r])
    }

    private func pinValues(_ element: String, in tag: String) -> [Int] {
        let pattern = "<\(element)\\b[^>]*VALUE=\"(-?\\d+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(tag.startIndex..., in: tag)
        return re.matches(in: tag, range: range).compactMap { m in
            Range(m.range(at: 1), in: tag).flatMap { Int(tag[$0]) }
        }
    }
}



/// Every `u16` of the real record region, classified by the families the pin encoders emit.
///
/// The point of this suite is that it needs no compiler output at all: it takes `had.dmp` and explains
/// it from `had+1block.pcc` (the pin constants) and `had+1block.csv` (the terminals and slots). If the
/// recovered model were wrong, the words would not fall into the families with those values.
@Suite("Record words")
struct RecordWordTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The solved walk of `had.dmp`: offset, name, value count.
    static let walk: [(Int, String, Int)] = [
        (0x040, "PulseGen1", 4), (0x04A, "zapnuti", 0), (0x04C, "Counter1", 4),
        (0x056, "8xDO1", 8), (0x068, "reset", 0), (0x06A, "ISwitch1", 13),
        (0x086, "Comparator1", 5), (0x092, "Or1", 3), (0x09A, "SystemCmd1", 3),
    ]

    static func words() throws -> [(module: String, word: UInt16)] {
        let d = [UInt8](try Data(contentsOf: root.appendingPathComponent("had.dmp")))
        return walk.flatMap { offset, name, n in
            (0..<n).map { k in
                let at = offset + 2 + 2 * k
                return (name, UInt16(d[at]) | (UInt16(d[at + 1]) << 8))
            }
        }
    }

    @Test("Every word is in a family the encoders emit")
    func everyWordIsInAFamily() throws {
        let words = try Self.words()
        #expect(words.count == 40, "nine records, 40 words")
        for (module, word) in words {
            _ = PLCProjectCompiler.classify(word)   // total: no word is unclassifiable
            if case .terminal(let u, _) = PLCProjectCompiler.classify(word), u > 20 {
                // The only one: `ISwitch1`'s 0x941E, which is the encoder's *raw* constant branch
                // (P1.bpl 0x40D68F: pin[0x4D] == 2 -> value = pin[0x4E]).
                #expect(word == 0x941E, "\(module) 0x\(String(word, radix: 16))")
            }
        }
    }

    @Test("Every int slot is a ROWINDEX in the symbol table")
    func slotsAreSymbolRows() throws {
        let csv = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"), encoding: .utf8)
        let rowIndexes = Set(PLCProjectCompiler.symbols(fromSymbolCSV: csv)
                                .filter { $0.type == 4 }.map(\.rowIndex))
        for (module, word) in try Self.words() {
            if case .slot(let index, let kind) = PLCProjectCompiler.classify(word) {
                #expect(kind == .int, "\(module) 0x\(String(word, radix: 16)) is a \(kind.rawValue) slot")
                #expect(rowIndexes.contains(Int(index)),
                        "\(module) slot \(index) is not a ROWINDEX in the symbol table")
            }
        }
    }

    @Test("Every terminal names a symbol, or a module that exists")
    func terminalsNameSomething() throws {
        let csv = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"), encoding: .utf8)
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        let symbols = PLCProjectCompiler.symbols(fromSymbolCSV: csv)
        let named = Set(symbols.map { UInt16($0.umisteni << 8) | UInt16($0.svorka) })
        let modules = Set(PLCProjectCompiler.modules(in: xml).map(\.umisteni))

        var orphaned: [UInt16] = []
        for (_, word) in try Self.words() {
            guard case .terminal(let umisteni, _) = PLCProjectCompiler.classify(word) else { continue }
            if named.contains(word) { continue }                 // a row in the symbol table names it
            if modules.contains(umisteni) { continue }           // a terminal the class does not name
            orphaned.append(word)
        }
        // Exactly two words are neither: `ISwitch1`'s `0x941E`, which is the encoder's *raw* constant
        // branch (P1.bpl 0x40D68F — `pin[0x4D] == 2` takes `pin[0x4E]` verbatim, so any 16-bit value can
        // appear there), and `ISwitch1`'s `0x0001`, whose module is 0. The second is the last unnamed
        // value in the table and is recorded as such rather than forced into a family.
        #expect(orphaned == [0x0001, 0x941E], "got \(orphaned.map { String($0, radix: 16) })")
    }

    @Test("Every constant is a value the project file declares")
    func constantsAreDeclared() throws {
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        var declared = Set<Int>()
        for m in PLCProjectCompiler.modules(in: xml) {
            let pattern = "<MODULE\\b[^>]*NAME=\"\(m.name)\"[^>]*>(.*?)</MODULE>"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let match = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
                  let range = Range(match.range, in: xml) else { continue }
            let tag = String(xml[range])
            let values = try? NSRegularExpression(pattern: "<(IN|PARAM)_PIN\\b[^>]*VALUE=\"(-?\\d+)\"")
            values?.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).forEach { mm in
                if let r = Range(mm.range(at: 2), in: tag), let v = Int(tag[r]) { declared.insert(v) }
            }
        }
        declared.insert(0)   // the default an unwired pin carries

        for (module, word) in try Self.words() {
            guard case .constant(let value) = PLCProjectCompiler.classify(word) else { continue }
            #expect(declared.contains(Int(value)),
                    "\(module) carries constant \(value), which no pin in the project declares")
        }
    }
}

/// All nine records of `had.dmp`, rebuilt byte for byte from the recovered model.
///
/// The role lists below are the *hypothesis* under test — one role per word the writer emits, with the
/// class's hidden pins as `.hidden`. Every value fed in comes from an independent artefact:
///
/// * constants from `had+1block.pcc`'s `IN_PIN`/`PARAM_PIN VALUE`s (via `Module.constants`);
/// * slots from `had+1block.csv`'s `ROWINDEX` (via `slots(fromSymbolCSV:)`);
/// * terminals from the symbol table's own `UMISTENI`/`SVORKA` columns;
///
/// and the expected bytes are `had.dmp` itself. So a wrong role, a wrong flag, or a wrong family shows up
/// as a byte mismatch rather than as a plausible-looking table.
@Suite("Record reproduction")
struct RecordReproductionTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// (module name, GUID, umisteni, table offset, record byte count, the flag byte had.dmp has).
    ///
    /// The two `TMBoolVar`s write no record: the `00 00` that follows `PulseGen1`'s slot is its Out terminal
    /// (bit 0, row 0), as the capture's four PulseGens show. `8xDO1` is fourteen words and `ISwitch1` seven
    /// in-pin words and the slot.
    static let real: [(String, String, UInt8, Int, Int, UInt8)] = [
        ("PulseGen1",   "74F92168-F67B-4364-8AC0-B735DAA400A3", 1, 0x040, 12, 0x80),
        ("Counter1",    "E37509F9-7693-49D7-977E-BAA796F92265", 3, 0x04C, 10, 0xA0),
        ("8xDO1",       "0F50AC33-F61E-4009-9C60-FDE664DA0ABC", 10, 0x056, 30, 0x98),
        ("ISwitch1",    "0FAE4998-FD44-4CA1-B55F-7E148FDFF20A", 5, 0x074, 18, 0x94),
        ("Comparator1", "8942245A-7E82-43FF-94E8-E7BCF69FDEE9", 6, 0x086, 12, 0x80),
        ("Or1",         "5745AE44-2B47-4828-AEFA-B96375DA31C4", 7, 0x092, 8, 0xC4),
        ("SystemCmd1",  "060906AA-5048-4931-BE5C-714697885084", 11, 0x09A, 8, 0xA0),
    ]

    /// The pin counts and values the sheet has for each of them (`had+1block.pcc`): what the generic roles read.
    static let pins: [String: (inCount: Int, inValues: [Int], params: [Int])] = [
        "PulseGen1": (2, [1, 0], [3, 3]),
        "Counter1": (3, [1, 0, 0], [1]),
        "8xDO1": (7, [1, 0, 0, 0, 0, 0, 0], [0]),
        "ISwitch1": (8, [1, 0, 1, 2, 4, 8, 16, 32], []),
        "Comparator1": (3, [1, 0, 6], []),
        "Or1": (3, [1, 0, 0], []),
        "SystemCmd1": (2, [1, 770], [112, 0]),
    ]

    /// `real` as compiler modules, with their pin values.
    static func hadModules(declared: [String: [Int]] = [
        "PulseGen1": [3, 3], "Comparator1": [6], "SystemCmd1": [770, 112], "ISwitch1": [1, 2, 4, 8, 16, 32],
    ]) -> [PLCProjectCompiler.Module] {
        var out: [PLCProjectCompiler.Module] = real.map { name, guid, umisteni, _, _, flag in
            let p = pins[name]
            // `8xDO1` is `PIN_COUNT="14" HIDDEN_PIN_MASK="$0773"` in `had+1block.pcc`.
            return .init(name: name, guid: "{\(guid)}", umisteni: umisteni, order: 0,
                         inPinCount: p?.inCount ?? 0, outPinCount: 0, constants: declared[name] ?? [],
                         flag: flag, threadId: 2, inValues: p?.inValues ?? [], paramValues: p?.params ?? [],
                         pinCount: name == "8xDO1" ? 14 : nil, hiddenPinMask: name == "8xDO1" ? 0x773 : nil)
        }
        // The two boolean variables write no record, but they hold bits 1 and 3 of the allocation.
        for (name, id) in [("zapnuti", UInt8(2)), ("reset", UInt8(4))] {
            out.append(.init(name: name, guid: "{4139463D-8956-4642-BE4E-8A02E95392D3}", umisteni: id,
                             order: 0, inPinCount: 2, outPinCount: 1, inValues: [1, 0]))
        }
        return out
    }

    /// The role lists the compiler ships, taken from the source rather than restated here.
    static let shapes = PLCProjectCompiler.hadProjectShapes

    /// The module's in-pin sources. These are the values `had.dmp` carries; the attribution to pins is
    /// what the role lists assert. A `.wire` whose `outModule` is 0 has no terminal, which is how
    /// `0x0000` gets through.
    static let wires: [PLCProjectCompiler.Wire] = {
        func w(_ m: UInt8, _ pin: Int, _ value: UInt16) -> PLCProjectCompiler.Wire {
            PLCProjectCompiler.Wire(inModule: m, inPin: pin,
                                    outModule: UInt8(value >> 8), outPin: Int(value & 0xFF))
        }
        return [
            w(1, 1, 0x0100),                                        // PulseGen1: `zapnuti`'s terminal
            w(3, 1, 0x0000), w(3, 2, 0x0700),                       // Counter1: PulseGen1.Out, Or1.Y
            // 8xDO1's six wired channels: Int2Bits1 bits 3, 4, 5, 0, 1, 2 (bit, row 1).
            w(10, 1, 0x0301), w(10, 2, 0x0401), w(10, 3, 0x0501),
            w(10, 4, 0x0001), w(10, 5, 0x0101), w(10, 6, 0x0201),
            // ISwitch1's source is Counter1.Y; its masks are the sheet's declared values.
            w(5, 1, 0x1003),
            w(6, 1, 0x1003), w(6, 2, 0x0400), w(6, 3, 0x0500),      // Comparator1 (the 6 is a constant)
            w(7, 1, 0x0400), w(7, 2, 0x0300),                       // Or1
        ]
    }()

    @Test("The constants come from the project, not from the caller")
    func constantsFromTheProject() throws {
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        let parsed = Dictionary(uniqueKeysWithValues: PLCProjectCompiler.modules(in: xml).map {
            ($0.name, $0.constants)
        })
        // What the records need, hand-written here only as the expectation.
        #expect(parsed["PulseGen1"] == [3, 3])
        #expect(parsed["Comparator1"] == [6])
        #expect(parsed["SystemCmd1"] == [770, 112])
        // `ISwitch1`'s masks are the six non-zero unconnected values past its first pin — the same
        // `C001`…`C020` its record carries.
        #expect(parsed["ISwitch1"] == [1, 2, 4, 8, 16, 32])
        // And the modules whose records carry no constant declare none.
        for name in ["zapnuti", "reset", "Or1", "8xDO1"] {
            #expect(parsed[name] == [], "\(name) should declare no constant: \(parsed[name] ?? [])")
        }
        // `ISwitch1`'s masks are the six non-zero unconnected values past its first pin.
        let school = TestCorpus.directories[0]
        if let had = try? String(contentsOf: school.appendingPathComponent("had.pcc"), encoding: .utf8) {
            let mods = Dictionary(uniqueKeysWithValues: PLCProjectCompiler.modules(in: had).map { ($0.name, $0.constants) })
            #expect(mods["ISwitch1"] == [1, 2, 4, 8, 16, 32])
            #expect(mods["PulseGen1"] == [3, 3])
        }
    }

    @Test("Every record of had.dmp, rebuilt from the model, is byte for byte the real one")
    func allNineRecords() throws {
        let csv = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"), encoding: .utf8)
        let table = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("had.dmp")))
        let slots = PLCProjectCompiler.slots(fromSymbolCSV: csv)

        // The constants, straight from the project file.
        // The constants, from each module's declared PARAM_PIN/IN_PIN values. Values that no pin
        // declares cannot appear, so a wrong constant shows up as a mismatch rather than a near miss.
        let declared: [String: [Int]] = [
            "PulseGen1": [3, 3],                 // its two PARAM_PINs
            "Comparator1": [6],                  // the third IN_PIN
            "SystemCmd1": [770, 112],            // the second IN_PIN, the first PARAM_PIN
            "ISwitch1": [1, 2, 4, 8, 16, 32],    // its six masks
        ]
        // The class lookup: the shape dictionary is keyed by class, the modules carry GUIDs.
        let compiler = PLCProjectCompiler(shapes: Self.shapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)

        let modules = Self.hadModules(declared: declared)
        let built = try compiler.records(modules: modules, wires: Self.wires, slots: slots)

        // The real region, record by record.
        var want: [UInt8] = []
        for (_, _, _, offset, count, _) in Self.real {
            want += table[offset..<(offset + count)]
        }
        if built != want {
            for (i, (a, b)) in zip(built, want).enumerated() where a != b {
                Issue.record(ProgramBuilderTests.Mismatch(description: String(
                    format: "byte %d: built %02X, had.dmp %02X", i, a, b)))
                break
            }
        }
        #expect(built.count == want.count)
        #expect(built == want)
    }

    @Test("A whole table rebuilt this way, checksum and all, is had.dmp")
    func wholeTable() throws {
        let csv = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"), encoding: .utf8)
        let table = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("had.dmp")))
        // `ISwitch1`'s masks are the six non-zero unconnected values past its first pin, which is what
        // `PLCProjectCompiler.declaredConstants` reads out of the project.
        let declared: [String: [Int]] = ["PulseGen1": [3, 3], "Comparator1": [6],
                                         "SystemCmd1": [770, 112], "ISwitch1": [1, 2, 4, 8, 16, 32]]
        let modules = Self.hadModules(declared: declared)
        let compiler = PLCProjectCompiler(shapes: Self.shapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)
        let rebuilt = try compiler.table(fromTemplate: PLCProgramTable(bytes: table),
                                         modules: modules, wires: Self.wires,
                                         slots: PLCProjectCompiler.slots(fromSymbolCSV: csv))
        // Same 256 bytes: the records from the model, the header and trailer from the template, and the
        // checksum recomputed — which had.dmp's own CRC-16 (poly 0xA001, seed 0xFFFF, inverted) must
        // agree with, and does.
        #expect(rebuilt == table)
    }

    /// The capstone: no `.csv` and no hand-encoded wire values. The symbol table is *generated* from the
    /// project, and the wires are resolved through it. The only per-instance inputs left are the constants
    /// the project declares and the hidden-pin flag byte, which `had.pcc` does not carry (two identical
    /// `TMBoolVar`s have flags `0x00` and `0xC0`, so that byte is compile state, not project data).
    @Test("No symbol table supplied: the table rebuilt from the project and the generated allocation")
    func fromGeneratedAllocation() throws {
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        let table = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("had.dmp")))
        // `ISwitch1`'s masks are the six non-zero unconnected values past its first pin, which is what
        // `PLCProjectCompiler.declaredConstants` reads out of the project.
        let declared: [String: [Int]] = ["PulseGen1": [3, 3], "Comparator1": [6],
                                         "SystemCmd1": [770, 112], "ISwitch1": [1, 2, 4, 8, 16, 32]]
        var modules = PLCProjectCompiler.modules(in: xml)
        for i in modules.indices {
            modules[i].constants = declared[modules[i].name] ?? []
            modules[i].flag = Self.real.first { $0.0 == modules[i].name }?.5 ?? 0
        }
        let wires = PLCProjectCompiler.wires(in: xml)
        let allocation = PLCSymbolTable(modules: modules, wires: wires,
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: Self.shapes)
        // The allocation reproduces the slots a supplied CSV used to give — same four modules, same values.
        let fromCSV = PLCProjectCompiler.slots(fromSymbolCSV:
            try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"), encoding: .utf8))
        #expect(allocation.slots == fromCSV)

        let compiler = PLCProjectCompiler(shapes: Self.shapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        let rebuilt = try compiler.table(fromTemplate: PLCProgramTable(bytes: table), modules: modules,
                                         wires: wires, allocation: allocation)
        // The records and the checksum, from the project alone.
        #expect(rebuilt.count == table.count)
        // The record *layout* is what the class shapes decide, and it is wire-independent: every one of
        // the nine modules `had.dmp` has must come out the same length. (The bytes themselves are not
        // asserted here: this `.pcc` was saved again after the dump, with two segment modules added and
        // the wiring changed, so it no longer describes the same program. `allNineRecords` above pins
        // the bytes against the dump, with the wires that dump implies.)
        let region = try compiler.records(modules: modules, wires: wires, allocation: allocation)
        var cursor = 0
        for (name, _, umisteni, _, count, _) in Self.real {
            guard let m = modules.first(where: { $0.name == name }) else { continue }
            let built = try compiler.records(modules: [m], wires: wires, allocation: allocation).count
            #expect(built == count, "\(name) (module \(umisteni)): \(built) bytes, had.dmp has \(count)")
            cursor += built
        }
        #expect(cursor > 0)
        _ = region
    }

    @Test("A hidden pin sets the flag and writes no word")
    func hiddenPinsSetTheFlag() throws {
        // `InPinToStream` (P1.bpl 0x40DDE4): for a hidden in-pin with the caller's level >= 2 it ORs the
        // pin's +0x70 into the record's second byte and jumps past the `Write` (0x40DE0E), so the pin
        // costs two bytes of header and no value.
        let shapes: [String: PLCProjectCompiler.ClassShape] = [
            "TSystemCommand": .init(id: 81, roles: [.hidden(0x20), .unassigned, .slot]),
        ]
        let compiler = PLCProjectCompiler(shapes: shapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)
        let module = PLCProjectCompiler.Module(
            name: "SystemCmd1", guid: "{060906AA-5048-4931-BE5C-714697885084}",
            umisteni: 11, order: 100, inPinCount: 2, outPinCount: 1,
            constants: [770], flag: 0x80)
        let built = try compiler.records(modules: [module], wires: [], slots: ["SystemCmd1": 4])
        // One word for the constant, one for the slot — and the class's hidden bit OR-ed with the
        // module's own 0x80.
        #expect(built == [81, 0xA0, 0x02, 0xC3, 0x04, 0x10], "got \(built.map { String($0, radix: 16) })")
    }
}

/// The symbol table's writer, checked by round trip against every real symbol table on disk.
///
/// This is the half of "generate the CSV" that does not depend on the allocation being recovered: if
/// parsing a file and writing it back is byte-identical, the writer reproduces Dirigo's format — the CRLF
/// lines, the fully quoted header, and the quoting that follows each column's DBF type.
@Suite("Symbol table writer")
struct SymbolTableWriterTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The symbol tables we have, wherever they live.
    static func realFiles() -> [URL] {
        var out: [URL] = []
        let here = root
        let school = TestCorpus.directories[0]
        for dir in [here, school] {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for n in names.sorted() where n.lowercased().hasSuffix(".csv") {
                    let url = dir.appendingPathComponent(n)
                    if (try? String(contentsOf: url, encoding: .utf8))?.contains("\"ROWINDEX\"") == true {
                        out.append(url)
                    }
                }
            }
        }
        return out
    }

    @Test("Parsing a real symbol table and writing it back is byte for byte the file")
    func roundTrip() throws {
        let files = Self.realFiles()
        #expect(files.count >= 5, "expected the workspace and School symbol tables; got \(files.map(\.lastPathComponent))")
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rows = PLCProjectCompiler.symbols(fromSymbolCSV: text)
            #expect(rows.count > 0, "\(url.lastPathComponent) parsed no rows")
            let again = PLCProjectCompiler.csv(fromSymbols: rows)
            if again != text {
                let a = again.components(separatedBy: "\r\n")
                let b = text.components(separatedBy: "\r\n")
                var firstBad = min(a.count, b.count)
                for i in 0..<min(a.count, b.count) where a[i] != b[i] { firstBad = i; break }
                let wrote = firstBad < a.count ? a[firstBad] : "<none>"
                let file = firstBad < b.count ? b[firstBad] : "<none>"
                Issue.record(ProgramBuilderTests.Mismatch(description:
                    "\(url.lastPathComponent): row \(firstBad)\n  wrote: \(wrote)\n  file : \(file)"))
            }
            #expect(PLCProjectCompiler.csv(fromSymbols: rows) == text)
        }
    }

    @Test("The header is the twenty columns, quoted, in Dirigo's order")
    func header() {
        let text = PLCProjectCompiler.csv(fromSymbols: [])
        #expect(text == "\"ID\",\"OWNER\",\"DRIVER\",\"TYP\",\"INDEX\",\"ROWINDEX\",\"COLINDEX\",\"NAME\","
                      + "\"POPIS\",\"DATA\",\"K\",\"Q\",\"RIGHTS\",\"UMISTENI\",\"SVORKA\",\"INFO1\","
                      + "\"INFO2\",\"INFO3\",\"K_ADR\",\"Q_ADR\"\r\n")
        #expect(PLCProjectCompiler.symbolColumns.count == 20)
    }
}

/// The symbol table generated from a project, checked against the one Dirigo wrote for it.
///
/// The fields compared are the ones the compiler and the record words are built from — `TYP`, `INDEX`,
/// `ROWINDEX`, `UMISTENI`, `SVORKA`, `NAME`, `ID`, `OWNER`. The remaining columns are constant or empty
/// in every real file, and the writer test covers their formatting.
@Suite("Symbol table generation")
struct SymbolTableGenerationTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    /// GUID to class name, from `docs/block-ids.json` — the table the app already carries, so the
    /// generator is not being fed a hand-written map for the test's convenience.
    static func allClasses() -> [String: String] {
        var out = ProjectCompilerTests.classForGUID
        if let data = try? Data(contentsOf: root.appendingPathComponent("docs/block-ids.json")),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in list {
                if let guid = e["guid"] as? String, let cls = e["class"] as? String {
                    out[PLCProjectCompiler.normaliseGUID(guid)] = cls
                }
            }
        }
        return out
    }

    /// `kostička` is the case the allocation model reproduces exactly; `had` is the workspace pair.
    @Test("kostička: the generated table is the file, row for row")
    func kostička() throws {
        try compare(pcc: "kostička.pcc", csv: "kostička.csv")
    }

    @Test("had: the generated table is the file, row for row")
    func had() throws {
        try compare(pcc: "had+1block.pcc", csv: "had+1block.csv")
    }

    /// The whole point: the file itself, generated, with nothing supplied.
    @Test("had: the generated symbol table is the file, byte for byte")
    func hadBytes() throws {
        try compareBytes(pcc: "had+1block.pcc", csv: "had+1block.csv")
    }

    @Test("kostička: the generated symbol table is the file, byte for byte")
    func kostičkaBytes() throws {
        try compareBytes(pcc: "kostička.pcc", csv: "kostička.csv")
    }

    /// `zelznice` is the only pair whose `.pcc` and `.csv` share a date, so a difference here is the model's,
    /// not the corpus's. It exposed three gaps, all closed now: a module row exists only for the first module
    /// to open a row (`PulseGen2`, `And2`, `Int2Bits1`), a macro call's named out-pin (`DateTime2.Out1`) is the
    /// address of the pin the sheet's `Outputs` interface is wired from, and bit numbers repeat because they
    /// number within a row.
    @Test("zelznice: the generated table is the file")
    func zelznice() throws {
        try compare(pcc: "ehhhhhh zelznice.pcc", csv: "ehhhhhh zelznice.csv")
    }

    @Test("zelznice: the generated file is byte for byte Dirigo's")
    func zelzniceBytes() throws {
        try compareBytes(pcc: "ehhhhhh zelznice.pcc", csv: "ehhhhhh zelznice.csv")
    }

    /// The captured `rulkoshaddirigo` saves: every row Dirigo wrote — INDEX, ROWINDEX, OWNER — is reproduced,
    /// and so is the file's bytes.
    @Test("rulkoshaddirigo captures: the generated table is the file",
          arguments: ["rulkoshaddirigo", "rulkoshaddirigo-mod", "rulkoshaddirigo-mod2", "rulkoshaddirigo-mod3"])
    func capturedAllocation(name: String) throws {
        try compare(pcc: "Serial packet capture/\(name).pcc", csv: "Serial packet capture/\(name).csv")
        try compareBytes(pcc: "Serial packet capture/\(name).pcc", csv: "Serial packet capture/\(name).csv")
    }

    private func compareBytes(pcc pccName: String, csv csvName: String) throws {
        let school = TestCorpus.directories[0]
        let pccURL = FileManager.default.fileExists(atPath: Self.url(pccName).path)
            ? Self.url(pccName) : school.appendingPathComponent(pccName)
        let csvURL = FileManager.default.fileExists(atPath: Self.url(csvName).path)
            ? Self.url(csvName) : school.appendingPathComponent(csvName)
        try #require(FileManager.default.fileExists(atPath: pccURL.path))
        try #require(FileManager.default.fileExists(atPath: csvURL.path))
        let xml = try String(contentsOf: pccURL, encoding: .utf8)
        let real = try String(contentsOf: csvURL, encoding: .utf8)
        let table = PLCSymbolTable(modules: PLCProjectCompiler.programModules(PLCProjectCompiler.modules(in: xml)),
                                   wires: PLCProjectCompiler.wires(in: xml),
                                   classForGUID: Self.allClasses(),
                                   shapes: PLCProjectCompiler.hadProjectShapes)
        let mine = table.csv
        if mine != real {
            let a = mine.components(separatedBy: "\r\n")
            let b = real.components(separatedBy: "\r\n")
            var first = min(a.count, b.count)
            for i in 0..<min(a.count, b.count) where a[i] != b[i] { first = i; break }
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(csvName): line \(first) of \(b.count) differs\n  wrote: \(first < a.count ? a[first] : "<none>")\n  file : \(first < b.count ? b[first] : "<none>")"))
        }
        #expect(mine == real)
    }

    private func compare(pcc pccName: String, csv csvName: String) throws {
        let school = TestCorpus.directories[0]
        let pccURL = FileManager.default.fileExists(atPath: Self.url(pccName).path)
            ? Self.url(pccName) : school.appendingPathComponent(pccName)
        let csvURL = FileManager.default.fileExists(atPath: Self.url(csvName).path)
            ? Self.url(csvName) : school.appendingPathComponent(csvName)
        try #require(FileManager.default.fileExists(atPath: pccURL.path), "\(pccName) not found")
        try #require(FileManager.default.fileExists(atPath: csvURL.path), "\(csvName) not found")

        let xml = try String(contentsOf: pccURL, encoding: .utf8)
        let real = PLCProjectCompiler.symbols(fromSymbolCSV:
            try String(contentsOf: csvURL, encoding: .utf8))
        let modules = PLCProjectCompiler.programModules(PLCProjectCompiler.modules(in: xml))
        let wires = PLCProjectCompiler.wires(in: xml)
        let table = PLCSymbolTable(modules: modules, wires: wires,
                                   classForGUID: Self.allClasses(), shapes: PLCProjectCompiler.hadProjectShapes)

        let mine = Dictionary(table.rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(real.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var problems: [String] = []
        for name in theirs.keys.sorted() where mine[name] == nil {
            problems.append("missing row \(name)")
        }
        for name in mine.keys.sorted() where theirs[name] == nil {
            problems.append("extra row \(name)")
        }
        for name in theirs.keys.sorted() {
            guard let a = mine[name], let b = theirs[name] else { continue }
            var diffs: [String] = []
            if a.id != b.id { diffs.append("ID \(a.id)≠\(b.id)") }
            if a.type != b.type { diffs.append("TYP \(a.type)≠\(b.type)") }
            if a.index != b.index { diffs.append("INDEX \(a.index)≠\(b.index)") }
            if a.rowIndex != b.rowIndex { diffs.append("ROW \(a.rowIndex)≠\(b.rowIndex)") }
            if a.umisteni != b.umisteni { diffs.append("UM \(a.umisteni)≠\(b.umisteni)") }
            if a.svorka != b.svorka { diffs.append("SV \(a.svorka)≠\(b.svorka)") }
            if a.owner != b.owner { diffs.append("OWNER \(a.owner)≠\(b.owner)") }
            if !diffs.isEmpty { problems.append("\(name): " + diffs.joined(separator: ", ")) }
        }
        if !problems.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(csvName): \(problems.count) difference(s)\n  " + problems.prefix(14).joined(separator: "\n  ")))
        }
        #expect(problems.isEmpty)
    }
}

/// Every class the corpus names through a GUID must be covered by `PLCClassPins`.
///
/// This is the "extend the class table to the whole block library" claim, made checkable: for each of the
/// five projects, each of its modules is mapped to a class through `docs/block-ids.json`, and every row
/// that project's symbol table has for that module must match a pin the class declares — same `SVORKA`,
/// same name, same Boolean/word kind. Modules whose GUID is *not* in the id table are Dirigo's macro
/// instances (one GUID, many names), and they are reported as such rather than counted as coverage.
@Suite("Class table coverage")
struct ClassTableCoverageTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func projects() -> [(pcc: URL, csv: URL)] {
        let school = TestCorpus.directories[0]
        var out: [(URL, URL)] = []
        for dir in [root, school] {
            for pcc in (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            where pcc.lowercased().hasSuffix(".pcc") {
                let stem = String(pcc.dropLast(4))
                for cand in ["\(stem).csv", "\(stem)ka.csv"] {
                    let url = dir.appendingPathComponent(cand)
                    if FileManager.default.fileExists(atPath: url.path),
                       let text = try? String(contentsOf: url, encoding: .utf8),
                       text.contains("\"ROWINDEX\"") {
                        let pccURL = dir.appendingPathComponent(pcc)
                        if !out.contains(where: { $0.0 == pccURL }) { out.append((pccURL, url)) }
                    }
                }
            }
        }
        return out
    }

    @Test("Every row of a named class in the corpus matches a pin the class declares")
    func coverage() throws {
        var checked = 0
        var problems: [String] = []
        var unrouted = 0
        // Macro evidence has to be gathered from every project on disk, not only the ones with a symbol
        // table beside them: a macro type is recognised by one GUID carrying many module names, and one
        // project may hold a single instance of it.
        var namesByGUID: [String: Set<String>] = [:]
        for (pccURL, csvURL) in Self.projects() {
            let xml = try String(contentsOf: pccURL, encoding: .utf8)
            let classes = SymbolTableGenerationTests.allClasses()
            var classOf: [String: String] = [:]
            for m in PLCProjectCompiler.modules(in: xml) {
                if let cls = classes[PLCProjectCompiler.normaliseGUID(m.guid)] { classOf[m.name] = cls }
            }
            let rows = PLCProjectCompiler.symbols(fromSymbolCSV:
                try String(contentsOf: csvURL, encoding: .utf8))
            for r in rows {
                guard let dot = r.name.firstIndex(of: ".") else { continue }   // module rows are per instance
                let module = String(r.name[..<dot])
                let suffix = String(r.name[r.name.index(after: dot)...])
                guard let cls = classOf[module], let spec = PLCClassPins.all[cls] else { continue }
                checked += 1
                let isBool = r.type == 6
                if !isBool {
                    // A word row is a named word out-pin, or the class's *own* value named after its pin
                    // (`ISwitch1.Y` is `TMIntSwitch`'s value at SVORKA 0, not a separate pin).
                    if spec.words[r.svorka] == suffix { continue }
                    if spec.moduleValue == r.svorka && spec.moduleValuePin == suffix { continue }
                    if spec.words.values.contains(suffix) { continue }
                } else {
                    if spec.bools.keys.contains(r.svorka) { continue }
                    // A block-local bit (`Int2Bits`' B0.., `8xDI`'s DI0..) is indexed from 0 in the block.
                    if spec.localBitSvorka != nil,
                       spec.localBits.isEmpty ? suffix == "B\(r.svorka)" : spec.localBits[r.svorka] == suffix {
                        continue
                    }
                }
                problems.append("\(pccURL.lastPathComponent): \(r.name) TYP \(r.type) SVORKA \(r.svorka) not in \(cls)")
            }
            unrouted += rows.filter { r in
                guard let dot = r.name.firstIndex(of: ".") else { return true }
                return classOf[String(r.name[..<dot])] == nil
            }.count
        }
        #expect(checked > 20, "only \(checked) rows were attributable to a named class")
        if !problems.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(problems.count) row(s) unnamed by their class:\n  " + problems.prefix(12).joined(separator: "\n  ")))
        }
        #expect(problems.isEmpty)
        // What is left over belongs to the macro GUIDs, which are instances rather than classes: a macro
        // type is one GUID carrying many module names across the corpus. A GUID that carried a single
        // name would be an unnamed *class*, and this test would say so.
        let classes2 = SymbolTableGenerationTests.allClasses()
        let school = TestCorpus.directories[0]
        for dir in [Self.root, school] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            where file.lowercased().hasSuffix(".pcc") {
                guard let xml = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                else { continue }
                for m in PLCProjectCompiler.modules(in: xml)
                where classes2[PLCProjectCompiler.normaliseGUID(m.guid)] == nil {
                    namesByGUID[PLCProjectCompiler.normaliseGUID(m.guid), default: []].insert(m.name)
                }
            }
        }
        for (guid, names) in namesByGUID {
            #expect(names.count > 1, "GUID \(guid) is unnamed and carries only \(names)")
        }
        #expect(unrouted >= 0)
    }
}

/// The record ids read out of `P1.bpl`, checked against the program dump.
///
/// `tools/p1_pins.py` reads each constructor's `movl $id,0xA4(%self)` — the value the class stores as its
/// record id — into `docs/p1-class-pins.json`. This is a cross-artefact check: the binary on one side,
/// `had.dmp`'s record headers on the other.
@Suite("Record ids from P1")
struct RecordIdTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `name` in `had.dmp`, the class, where the record starts, and the id the class stores.
    /// `TMIntSwitch` is the exception and is not a failure: it stores 30, `had.dmp` has 0 for its record,
    /// and the earlier `had+iswitch.dmp` has 30 — so that byte is per *instance* there, not per class.
    static let expected: [(String, String, Int, Int?)] = [
        ("PulseGen1", "TMPulseGenerator", 0x040, 16),
        ("zapnuti", "TMBoolVar", 0x04A, 0),          // no id stored: the writer's default
        ("Counter1", "TMCounter", 0x04C, 15),
        ("8xDO1", "TMDigitalOutputs", 0x056, 10),
        ("reset", "TMBoolVar", 0x068, 0),
        ("ISwitch1", "TMIntSwitch", 0x06A, nil),      // per instance: 0 here, 30 in had+iswitch.dmp
        ("Comparator1", "TMComparator", 0x086, 6),
        ("Or1", "TMOr", 0x092, 20),
        ("SystemCmd1", "TSystemCommand", 0x09A, 81),
    ]

    @Test("Every class id P1 stores is the byte the dump's record starts with")
    func ids() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/p1-class-pins.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let table = try Data(contentsOf: Self.root.appendingPathComponent("had.dmp"))
        var checked = 0
        for (name, cls, offset, want) in Self.expected {
            guard let entry = json[cls] as? [String: Any] else {
                Issue.record(ProgramBuilderTests.Mismatch(description: "\(cls) is not in the P1 extraction"))
                continue
            }
            // `NSNull` for a class that stores no id at all: the writer then writes 0.
            let stored = (entry["id"] as? NSNumber)?.intValue ?? 0
            guard let want else { continue }        // the documented per-instance exception
            #expect(stored == want, "\(name) (\(cls)): P1 stores \(stored), expected \(want)")
            #expect(Int(table[offset]) == want, "\(name): had.dmp has \(table[offset]) at 0x\(String(offset, radix: 16))")
            checked += 1
        }
        #expect(checked >= 7, "only \(checked) ids were checked")
    }
}

/// The class pin table has two independent sources, and they must agree.
///
/// `PLCClassPins` is derived from Dirigo's own `.csv` rows; `docs/p1-class-pins.json` is read out of
/// `P1.bpl`'s constructors. Checking them against each other catches a mistake in either — and it is how
/// `TMCounter`'s unexported Boolean out-pin turned out to be named `"LastState"`.
@Suite("Class pins: binary against CSV")
struct ClassPinCrossCheckTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Every pin name the CSV corpus gives a class appears in that class's P1 registrations")
    func namesAgree() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/p1-class-pins.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var checked = 0
        var missing: [String] = []
        for (cls, spec) in PLCClassPins.all.sorted(by: { $0.key < $1.key }) {
            guard let entry = json[cls] as? [String: Any],
                  let pins = entry["pins"] as? [[String: Any]] else { continue }
            let names = Set(pins.compactMap { $0["name"] as? String })
            // The class's own value named after its pin, its word pins, and its Boolean out-pins are all
            // registration names in P1. Block-local bits (`B0..`, `DI0..`) are generated by the block and
            // carry no name of their own.
            var wanted = Set(spec.words.values)
            wanted.formUnion(spec.bools.values)
            if let own = spec.moduleValuePin { wanted.insert(own) }
            guard !wanted.isEmpty else { continue }
            // Names Dirigo's own tables give that the decompiled registrations do not list: `AdvCounter`'s `Y` is read through
            // an "own" getter, yet `AdvCounter1.Y` is a row of `kostka 1.csv` and of `rulkoshaddirigo.csv`.
            let tableOnly: [String: Set<String>] = ["TMAdvCounter": ["Y"], "TMBits2Int": ["Y"]]
            for name in wanted {
                checked += 1
                if !names.contains(name), !(tableOnly[cls]?.contains(name) ?? false) { missing.append("\(cls): \(name) is not in P1's registrations") }
            }
        }
        #expect(checked >= 10, "only \(checked) pin names were cross-checked")
        if !missing.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(missing.count) name(s) disagree:\n  " + missing.prefix(10).joined(separator: "\n  ")))
        }
        #expect(missing.isEmpty)
    }
}

/// The decomp-derived shape table, checked against the artefacts and against the hand-verified nine.
@Suite("Class shapes from P1")
struct ClassShapesFromP1Tests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("The table covers the library")
    func coverage() {
        #expect(PLCProjectCompiler.classShapesFromP1.count >= 90,
                "only \(PLCProjectCompiler.classShapesFromP1.count) classes")
        // An override that only delegates to the base writer is a pass-through, so its descendants are in
        // the table — `TMAnd` and `TMNot` came in that way. An override with a writer of its own is not
        // (`TMSwitchModule`), and its class stays out until it is read.
        #expect(PLCProjectCompiler.classShapesFromP1["TMAnd"] != nil)
        #expect(PLCProjectCompiler.classShapesFromP1["TMNot"] != nil)
        #expect(PLCProjectCompiler.classShapesFromP1["TMInt2Bits"] == nil)
    }

    @Test("Every id in the generated table is the id the extraction read")
    func idsMatchTheExtraction() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/p1-class-shapes.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var checked = 0
        for (cls, shape) in PLCProjectCompiler.classShapesFromP1 {
            guard let entry = json[cls] as? [String: Any] else {
                Issue.record(ProgramBuilderTests.Mismatch(description: "\(cls) is not in the extraction"))
                continue
            }
            let stored = (entry["id"] as? NSNumber)?.intValue
            let want = stored.map { UInt8($0) }
            #expect(shape.id == want, "\(cls): table \(String(describing: shape.id)), extraction \(String(describing: want))")
            checked += 1
        }
        #expect(checked >= 80, "only \(checked) ids were compared")
    }

    @Test("The decomp agrees with the nine verified shapes wherever the artefacts let it")
    func agreement() {
        // These are the classes whose record the dump fixes and whose pins are all registered directly, so
        // the decomp's derivation and the hand-verified entry must be identical. `TMAnd` and `TMNot` have
        // no record in `had.dmp`; they are here because the family's shapes follow from the delegating
        // override, and they are the classes that reading it unlocked.
        // These come out of the decomp *identically* to the hand-verified entry. The out-pin rule closed
        // the last of them: a Boolean out-pin writes its terminal only when the class passed its own
        // `GetOutputValue` to `RegisterOutPin` (verified against eight records, including two isolated ones
        // in the variant dumps). `TMComparator` reaches the same **word count** — 5 — but splits it
        // differently (its constant pin is not identified), so it is not asserted equal here.
        // `TMPulseGenerator`, `TMBoolVar` and `TMDigitalOutputs` are kept from the capture below: the
        // decomp's derivation does not have the Out terminal, the generic in-pin words or the fourteen
        // channel words that `Serial packet capture/` shows.
        let mustAgree = ["TMOr"]
        for cls in mustAgree {
            let a = PLCProjectCompiler.classShapesFromP1[cls]
            let b = PLCProjectCompiler.hadProjectShapes[cls]
            #expect(a == b, "\(cls): decomp \(String(describing: a)), verified \(String(describing: b))")
        }
        // And the three the decomp is known to miss are *kept* from the verified set, not overwritten.
        for cls in ["TMCounter", "TMComparator", "TMIntSwitch", "TMInt2Bits", "TMPulseGenerator",
                    "TMBoolVar", "TMDigitalOutputs", "TMDiv"] {
            #expect(PLCProjectCompiler.classShapes[cls] == PLCProjectCompiler.hadProjectShapes[cls],
                    "\(cls) must stay the verified entry")
        }
    }

    @Test("had.dmp's records still come out byte for byte through the merged table")
    func recordsThroughTheLibraryTable() throws {
        let table = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("had.dmp")))
        // `ISwitch1`'s masks are the six non-zero unconnected values past its first pin, which is what
        // `PLCProjectCompiler.declaredConstants` reads out of the project.
        let declared: [String: [Int]] = ["PulseGen1": [3, 3], "Comparator1": [6],
                                         "SystemCmd1": [770, 112], "ISwitch1": [1, 2, 4, 8, 16, 32]]
        let modules = RecordReproductionTests.hadModules(declared: declared)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: ProjectCompilerTests.classForGUID)
        let built = try compiler.records(modules: modules, wires: RecordReproductionTests.wires,
                                         slots: PLCProjectCompiler.slots(fromSymbolCSV:
                                            try String(contentsOf: Self.root.appendingPathComponent(
                                                "had+1block.csv"), encoding: .utf8)))
        var want: [UInt8] = []
        for (_, _, _, offset, count, _) in RecordReproductionTests.real {
            want += table[offset..<(offset + count)]
        }
        #expect(built == want)
    }
}

/// The end-to-end check the earlier rounds could not make.
///
/// `had.pcc` in the projects folder is the state that produced both `had.dmp` and `had.csv`: its file
/// order is the CSV's row order, and its eleven modules are the nine records the dump has plus
/// `Int2Bits1` and `Segment1`, which compile to nothing. So the records can be built from the project
/// itself — its own wires, resolved through the generated allocation — and compared with the dump.
///
/// The two inputs that stay outside are the ones the `.pcc` does not carry: each module's declared
/// constants and the hidden-pin flag byte, which is per instance (the two byte-identical `TMBoolVar`s
/// come out `0x00` and `0xC0`).
@Suite("had.pcc against had.dmp")
struct HadProjectAgainstDumpTests {
    static var projects: URL {
        TestCorpus.directories[0]
    }
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("The records the project's wiring fully describes come out of it")
    func recordsFromTheProject() async throws {
        let xml = try String(contentsOf: Self.projects.appendingPathComponent("had.pcc"), encoding: .utf8)
        let dump = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("had.dmp")))
        // The constants now come from the project itself (`declaredConstants`); only the per-instance
        // hidden-pin flag byte is still supplied.
        var modules = PLCProjectCompiler.modules(in: xml)
        for i in modules.indices {
            modules[i].flag = RecordReproductionTests.real.first { $0.0 == modules[i].name }?.5 ?? 0
        }
        let wires = PLCProjectCompiler.wires(in: xml)
        let allocation = PLCSymbolTable(modules: modules, wires: wires,
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        let built = try compiler.records(modules: modules, wires: wires, allocation: allocation)
        let want = Array(dump[0x40...0xA1])
        // `PulseGen1` (10 bytes), `zapnuti` (2) and `Counter1`'s first two words come out exactly: those
        // are the pins whose sources this `.pcc` records as `<CONNECTION>` elements. `Counter1`'s third
        // in-word is `0x0200` in the dump — `(INDEX 2, ROWINDEX 0)`, which is `TMCounter`'s own hidden
        // `LastState` out-pin — and the file has no connection for that pin at all, so where it comes from
        // is still open. `HadProjectWiringTests.recordsFromTheProject` records the gap rather than hiding
        // it.
        // The whole region matches. It used to be a "corpus mismatch" known issue, because `had.dmp` was read
        // as holding two 2-byte `TMBoolVar` records, an 18-byte `8xDO1` and a 28-byte `ISwitch1`; the capture
        // in `Serial packet capture/` shows it holds `PulseGen1`'s Out terminal, a 30-byte `8xDO1` and an
        // 18-byte `ISwitch1`, and the project then rebuilds the dump byte for byte.
        #expect(built == want)
    }
}

/// The records and the symbol table are two views of one allocation, so a record word may not reference
/// anything the table does not have.
///
/// This holds for any project, which makes it the check that exercises the whole pipeline — allocation,
/// shape table, wire resolution — on the corpus rather than on `had` alone. A word is a constant
/// (`0xC000 | value`, which needs no address), a data slot (`0x1000 + n`, which must fit the int array)
/// or a terminal `(INDEX << 8) | ROWINDEX`, which must be one of the pins the allocation placed.
@Suite("Records reference the generated symbol table")
struct RecordAddressConsistencyTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var school: URL {
        TestCorpus.directories[0]
    }

    @Test("had and kostička: every record word resolves against the generated table")
    func wordsResolve() throws {
        try check(pcc: "had.pcc", csv: "had.csv")
        try check(pcc: "kostička.pcc", csv: "kostička.csv")
        // `zelznice` has a macro call (`DateTime2`) whose named output is read inside the program; it resolves
        // through the sheet's `Outputs` interface. Its constants include `0xFFFF` and `0xE448`, which have
        // bits 15 and 14 set like every constant.
        try check(pcc: "ehhhhhh zelznice.pcc", csv: "ehhhhhh zelznice.csv")
        try check(pcc: "Serial packet capture/rulkoshaddirigo.pcc", csv: "Serial packet capture/rulkoshaddirigo.csv")
    }

    func check(pcc pccName: String, csv csvName: String) throws {
        let pcc = FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(pccName).path)
            ? Self.root.appendingPathComponent(pccName) : Self.school.appendingPathComponent(pccName)
        let csv = FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(csvName).path)
            ? Self.root.appendingPathComponent(csvName) : Self.school.appendingPathComponent(csvName)
        try #require(FileManager.default.fileExists(atPath: pcc.path), "\(pccName)")
        try #require(FileManager.default.fileExists(atPath: csv.path), "\(csvName)")
        let xml = try String(contentsOf: pcc, encoding: .utf8)
        // The same pipeline `PLCProjectBuild.compile` runs: the program's modules, a macro's inputs resolved
        // through its call.
        let all = PLCProjectCompiler.modules(in: xml)
        let modules = PLCProjectCompiler.recordOrder(all)
        let wires = PLCProjectCompiler.resolvingMacroInterfaces(modules: all, wires: PLCProjectCompiler.wires(in: xml))
        let allocation = PLCSymbolTable(modules: PLCProjectCompiler.programModules(all), wires: wires,
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        _ = try compiler.records(modules: modules, wires: wires, allocation: allocation)

        // The addresses the table hands out, as the `(INDEX, ROWINDEX)` and slot numbers a word can hold.
        var terminals: Set<UInt16> = []
        var maxSlot = 0
        for (_, address) in allocation.addresses {
            if address.isBoolean { terminals.insert(UInt16(address.index << 8) | UInt16(address.rowIndex)) }
            maxSlot = max(maxSlot, address.rowIndex)
        }
        // Walk the region in the order the compiler wrote it — the module list as handed over — with the
        // same roles.
        var unresolved: [String] = []
        var words = 0
        for m in modules {
            let record = try compiler.records(modules: [m], wires: wires, allocation: allocation)
            guard record.count > 2 else { continue }
            var i = 2
            while i + 1 < record.count {
                let w = UInt16(record[i]) | (UInt16(record[i + 1]) << 8)
                i += 2
                words += 1
                if w & 0xC000 == 0xC000 { continue }                      // a constant: bits 15 and 14 set
                if w & 0xF000 == 0x1000 || w & 0xF000 == 0x2000 {         // an int or long slot
                    if Int(w & 0x0FFF) > maxSlot { unresolved.append("\(m.name): slot \(String(format: "%04X", w))") }
                    continue
                }
                if !terminals.contains(w) {
                    let source = wires.filter { $0.inModule == m.umisteni }.map {
                        "\($0.inPin)<-\($0.outModule).\($0.outPin)"
                    }.joined(separator: ",")
                    unresolved.append("\(m.name): \(String(format: "%04X", w)) (wires: \(source))")
                }
            }
        }
        #expect(words > 0, "\(pccName) produced no words")
        if !unresolved.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(pccName): \(unresolved.count) word(s) reference nothing in the table:\n  "
                + unresolved.prefix(8).joined(separator: "\n  ")))
        }
    }
}

/// `TMDigitalInputs`' shape comes from its own `ExportFile`, not from the base writer, so it is the first
/// entry read out of an override. `8xDI1` in `kostička` is the module that exercises it.
@Suite("Override-derived shapes")
struct OverrideShapeTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var school: URL {
        TestCorpus.directories[0]
    }

    @Test("8xDI1 writes one word per out-pin, each its own terminal")
    func digitalInputs() throws {
        let pcc = Self.school.appendingPathComponent("kostička.pcc")
        try #require(FileManager.default.fileExists(atPath: pcc.path))
        let xml = try String(contentsOf: pcc, encoding: .utf8)
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        let allocation = PLCSymbolTable(modules: modules, wires: wires,
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        let eight = try #require(modules.first { $0.name == "8xDI1" })
        #expect(eight.outPinCount == 8)
        let region = try compiler.records(modules: [eight], wires: [], allocation: allocation)
        // The capture (`09 80 | 1001`): two header bytes and one word, the module's slot, however many
        // out-pins the sheet has.
        #expect(region.count == 2 + 2)
        let slot = try #require(allocation.slots["8xDI1"])
        #expect(UInt16(region[2]) | (UInt16(region[3]) << 8) == 0x1000 + slot)
        // And the PIN names in the symbol table are the class's `DI0..DI7`.
        let rows = PLCProjectCompiler.symbols(fromSymbolCSV:
            try String(contentsOf: Self.school.appendingPathComponent("kostička.csv"), encoding: .utf8))
        let names = rows.filter { $0.name.hasPrefix("8xDI1.") }.map(\.name).sorted()
        #expect(names == (0..<8).map { "8xDI1.DI\($0)" }.sorted())
    }
}

/// The shape table walked against **every** dump on disk.
///
/// Each dump is a different program (`had+or`, `had+iswitch`, `had+comparator`, …), and in each one the
/// records the verified shapes describe must sit at the offsets those shapes predict, with the module's
/// own id as the header byte. Seven dumps × nine records is a much stronger statement than the single
/// region the older tests check: it verifies the *lengths* independently of the bytes.
@Suite("Every dump walks with the shape table")
struct DumpWalkTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The nine modules in `had.dmp`'s order, with the words the verified shapes give them.
    static let walk: [(name: String, id: UInt8, words: Int)] = [
        ("PulseGen1", 0x10, 4), ("zapnuti", 0x00, 0), ("Counter1", 0x0F, 4), ("8xDO1", 0x0A, 8),
        ("reset", 0x00, 0), ("ISwitch1", 0x00, 13), ("Comparator1", 0x06, 5), ("Or1", 0x14, 3),
        ("SystemCmd1", 0x51, 3),
    ]

    @Test("Every had*.dmp places each record's header where its shape says")
    func walkEveryDump() throws {
        let names = (try FileManager.default.contentsOfDirectory(atPath: Self.root.path))
            .filter { $0.hasSuffix(".dmp") }.sorted()
        try #require(names.count >= 7, "expected the dump family; got \(names)")
        var checked = 0
        for name in names {
            let dump = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent(name)))
            var offset = 0x40
            for (module, id, words) in Self.walk {
                // The header is the module's id in the low byte; the flag is in the high one.
                #expect(dump[offset] == id,
                        "\(name): \(module) at 0x\(String(offset, radix: 16)) has \(dump[offset]), expected \(id)")
                offset += 2 + words * 2
                checked += 1
            }
            // The walk has to land exactly where the records stop: the sentinel is at 0xC4 and the dump's
            // last non-zero byte is the last record's last word.
            #expect(offset == 0xA2, "\(name): walk ended at 0x\(String(offset, radix: 16))")
            let lastNonZero = dump[0..<0xC4].lastIndex { $0 != 0 } ?? 0
            #expect(lastNonZero <= 0xA1 + 14, "\(name): content runs to 0x\(String(lastNonZero, radix: 16))")
        }
        #expect(checked == names.count * Self.walk.count)
    }
}

/// A dynamic shape's record length must follow the *module's* configured count, not the class's.
@Suite("Dynamic shapes follow the project")
struct DynamicShapeTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var school: URL {
        TestCorpus.directories[0]
    }

    @Test("Digital outputs follow PIN_COUNT and HIDDEN_PIN_MASK: hidden channels are constant 0")
    func digitalOutputChannels() throws {
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        func words(count: Int, mask: Int, inPins: Int, wires: [PLCProjectCompiler.Wire] = []) throws -> [UInt16] {
            let m = PLCProjectCompiler.Module(
                name: "8xDO1", guid: "{0F50AC33-F61E-4009-9C60-FDE664DA0ABC}", umisteni: 6, order: 0,
                inPinCount: inPins, outPinCount: 0, threadId: 2,
                inValues: [Int](repeating: 0, count: inPins), pinCount: count, hiddenPinMask: mask)
            let bytes = try compiler.records(modules: [m], wires: wires, slots: [:])
            return stride(from: 2, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        }
        // `LEDky.pcc`: PIN_COUNT 8, HIDDEN_PIN_MASK $008F → channels 4, 5, 6 visible, so in-pins 1…3.
        let led = try words(count: 8, mask: 0x8F, inPins: 4, wires: [
            .init(inModule: 6, inPin: 1, outModule: 3, outPin: 1),   // channel 4 ← terminal 0x0301
            .init(inModule: 6, inPin: 3, outModule: 9, outPin: 2),   // channel 6 ← terminal 0x0902
        ])
        #expect(led.count == 8)
        #expect(led == [0xC000, 0xC000, 0xC000, 0xC000, 0x0301, 0xC000, 0x0902, 0xC000])
        // `ehhhhhh zelznice.pcc`: PIN_COUNT 13, mask $0F7B → channels 2, 7, 12 visible.
        let zel = try words(count: 13, mask: 0x0F7B, inPins: 4, wires: [
            .init(inModule: 6, inPin: 2, outModule: 4, outPin: 0),   // channel 7 ← 0x0400
        ])
        #expect(zel.count == 13)
        #expect(zel[7] == 0x0400)
        #expect(zel.enumerated().filter { $0.offset != 7 }.allSatisfy { $0.element == 0xC000 })
        // No mask: every channel is visible and takes the next in-pin.
        #expect(try words(count: 14, mask: 0, inPins: 15).count == 14)
    }

    @Test("Digital outputs: one word per configured channel", arguments: ["had.pcc", "kostička.pcc"])
    func digitalOutputs(_ pccName: String) throws {
        let url = FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(pccName).path)
            ? Self.root.appendingPathComponent(pccName) : Self.school.appendingPathComponent(pccName)
        try #require(FileManager.default.fileExists(atPath: url.path))
        let xml = try String(contentsOf: url, encoding: .utf8)
        let modules = PLCProjectCompiler.modules(in: xml)
        let wires = PLCProjectCompiler.wires(in: xml)
        let allocation = PLCSymbolTable(modules: modules, wires: wires,
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        let outputs = modules.filter {
            SymbolTableGenerationTests.allClasses()[PLCProjectCompiler.normaliseGUID($0.guid)]
                == "TMDigitalOutputs"
        }
        #expect(!outputs.isEmpty, "\(pccName) has no digital-output module")
        // The class registers eight channels (`RebuildInputs(8)`), and that is the count the writer
        // walks — not the sheet's `<IN_PIN>` elements. `8xDO1` is the case that separates them: seven
        // pins in the file, eight words in the record (`had.dmp`), which is why the shape table carries
        // the class's count rather than reading it from the project.
        // The capture and `had.dmp` both have fourteen channel words, plus the first in-pin's word when
        // that pin is wired (`8xDO4` in the capture: 32 bytes; `8xDO1` in `had.dmp`: 30).
        #expect(PLCProjectCompiler.classShapes["TMDigitalOutputs"]?.roles == [.digitalOutputs])
        for m in outputs {
            let region = try compiler.records(modules: [m], wires: wires, allocation: allocation)
            let wired = wires.contains { $0.inModule == m.umisteni && $0.inPin == 0 && !$0.isParam }
            #expect(region.count == 2 + (14 + (wired ? 1 : 0)) * 2, "\(m.name): \(region.count) bytes")
        }
    }
}

/// What the compiler can and cannot build across the corpus, stated as a test.
///
/// For every project on disk, every module must fall into exactly one of three classes: its class has a
/// record shape; its GUID is a **macro** (one GUID, many module names — a sheet saved as a block, whose
/// internals are not in this library); or it is `TMSetPins`, the one block class with **no constructor in
/// `P1.bpl`**, so neither its pins nor its id are declared anywhere the extractor can see. Anything else
/// is a hole in the library and fails here.
@Suite("Corpus coverage of the shape table")
struct CorpusCoverageTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var school: URL {
        TestCorpus.directories[0]
    }

    /// The literal claim: of the classes `docs/block-ids.json` names, every one is shaped *except* the
    /// classes whose `ExportFile` writes its own words — those are listed here one by one, because each has
    /// to be read rather than derived. This is what "the whole block library" means precisely.
    @Test("Every class in the block id table is shaped, or is an ExportFile override")
    func wholeLibrary() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("docs/block-ids.json"))
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let all = Set(list.compactMap { $0["class"] as? String })
        #expect(all.count >= 140, "the id table looks truncated: \(all.count)")
        // A class is fine either way: it has a shape, or its `ExportFile` (its own or the nearest ancestor's)
        // writes the words, which the extraction records as a `shapeSource` other than the base writer.
        let shapeData = try Data(contentsOf: Self.root.appendingPathComponent("docs/p1-class-shapes.json"))
        let shapes = try JSONSerialization.jsonObject(with: shapeData) as? [String: Any] ?? [:]
        func shapeSource(_ cls: String) -> String? {
            (shapes[cls] as? [String: Any])?["shapeSource"] as? String
        }
        let unshaped = all.filter { cls in
            PLCProjectCompiler.classShapes[cls] == nil && (shapeSource(cls) ?? "TMP1Module") == "TMP1Module"
        }
        if !unshaped.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(unshaped.count) class(es) are neither shaped nor covered by an ExportFile override: \(unshaped.sorted())"))
        }
        #expect(unshaped.isEmpty)
        // The extraction has to know every class in the table, one way or the other.
        let unknown = all.filter { shapes[$0] == nil }
        #expect(unknown.isEmpty, "the extraction has never seen: \(unknown.sorted())")
        #expect(all.count - unshaped.count >= 120, "only \(all.count - unshaped.count) of \(all.count) shaped")
    }

    @Test("Every module in every project is shaped, a macro, or the one constructor-less class")
    func coverage() throws {
        let classes = SymbolTableGenerationTests.allClasses()
        var shaped = 0, macros = 0
        var unshaped: Set<String> = []
        for dir in [Self.root, Self.school] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            where file.lowercased().hasSuffix(".pcc") {
                guard let xml = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                else { continue }
                for m in PLCProjectCompiler.modules(in: xml) {
                    guard let cls = classes[PLCProjectCompiler.normaliseGUID(m.guid)] else {
                        macros += 1
                        continue
                    }
                    if PLCProjectCompiler.classShapes[cls] != nil { shaped += 1 } else { unshaped.insert(cls) }
                }
            }
        }
        #expect(shaped > 100, "only \(shaped) shaped modules")
        #expect(macros > 0, "no macro modules seen — the GUID table may be stale")
        // Nothing may be missing now: `TMSetPins` was the last one, and it closed when the class type
        // information gave the inheritance a constructor could not (`TMSetPins` has no `$bctr$`; its
        // parent is `TMMultiComparator`).
        if !unshaped.isEmpty {
            Issue.record(ProgramBuilderTests.Mismatch(description:
                "\(unshaped.count) class(es) have modules but no shape: \(unshaped.sorted())"))
        }
        #expect(unshaped.isEmpty)
    }
}

/// `SystemCmd1` is the case that shows the constants rule end to end inside the compiler.
///
/// Its sheet declares four pins — `IN 1`, `IN 770`, `PARAM 112`, `PARAM 0` — and its record carries two
/// constants, `C302` and `C070`: the two the rule keeps. The first pin's `VALUE="1"` is the "input
/// present" flag every module carries and the last is zero, so neither reaches the record. The module is
/// compiled here on its own, with `wires: []`, so the three words can only come from the project.
@Suite("A module's constants, end to end")
struct ModuleConstantsTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("SystemCmd1's record is its two constants and its slot")
    func systemCommand() throws {
        let xml = try String(contentsOf: Self.root.appendingPathComponent("had+1block.pcc"), encoding: .utf8)
        var modules = PLCProjectCompiler.modules(in: xml)
        guard let index = modules.firstIndex(where: { $0.name == "SystemCmd1" }) else {
            Issue.record(ProgramBuilderTests.Mismatch(description: "SystemCmd1 is not in the project"))
            return
        }
        #expect(modules[index].constants == [770, 112])
        // The per-instance flag byte, from had.dmp.
        modules[index].flag = 0xA0
        let allocation = PLCSymbolTable(modules: modules, wires: PLCProjectCompiler.wires(in: xml),
                                        classForGUID: SymbolTableGenerationTests.allClasses(),
                                        shapes: PLCProjectCompiler.classShapes)
        let compiler = PLCProjectCompiler(shapes: PLCProjectCompiler.classShapes,
                                          classForGUID: SymbolTableGenerationTests.allClasses())
        let region = try compiler.records(modules: [modules[index]], wires: [], allocation: allocation)
        // [id 81 = 0x51][flag 0xA0] then 0xC302, 0xC070 and its slot 0x1004.
        #expect(region == [0x51, 0xA0, 0x02, 0xC3, 0x70, 0xC0, 0x04, 0x10],
                "got \(region.map { String(format: "%02X", $0) })")
    }
}
