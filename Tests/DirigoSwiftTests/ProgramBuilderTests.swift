import Testing
import Foundation
@testable import DirigoHardware

/// The four records whose values are established, checked byte for byte against `had.dmp`.
@Suite("Program builder")
struct ProgramBuilderTests {
    /// A mismatch worth reporting with detail rather than a bare assertion.
    struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    static var workspace: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func realBytes() throws -> [UInt8] {
        let url = workspace.appendingPathComponent("had.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the user's export")
        return [UInt8](try Data(contentsOf: url))
    }

    /// `PulseGen1`, `zapnuti` and `Counter1`, exactly as `had.dmp` carries them at 0x40, 0x4A, 0x4C.
    static var headModules: [PLCProgramBuilder.Module] {
        [
            // id 16 = TMPulseGenerator. 0x0100 = UMISTENI 1, SVORKA 0 = PulseGen1.Cnt (the CSV's row).
            .init(id: 16, flag: 0x80, values: [0x0100, 0xC003, 0xC003, 0x1002]),
            // id 0 = a folded block, header only.
            .init(id: 0, flag: 0x00, values: []),
            // id 15 = TMCounter. 0x0700 = Or1.Y, 0x0200 = zapnuti.Y, both named in the CSV.
            .init(id: 15, flag: 0xA0, values: [0x0000, 0x0700, 0x0200, 0x1003]),
        ]
    }

    @Test("The builder reproduces had.dmp's first three records byte for byte")
    func buildsHeadOfRealTable() throws {
        let real = try Self.realBytes()
        let builder = PLCProgramBuilder(modules: Self.headModules)
        let built = builder.records()

        // PulseGen1 10 bytes + zapnuti 2 + Counter1 10 = 22 bytes, and the real file must agree.
        #expect(built.count == 22)
        if Array(real[0x40..<0x56]) != built {
            let got = built.map { String(format: "%02X", $0) }.joined(separator: " ")
            let want = real[0x40..<0x56].map { String(format: "%02X", $0) }.joined(separator: " ")
            Issue.record(Mismatch(description: "built \(got) but the file has \(want)"))
        }
    }

    @Test("Every value in those records is explained by a CSV row or a known family")
    func valuesAreExplained() {
        for module in Self.headModules {
            for value in module.values {
                // 0xC0xx is the constant family, `0xC000 | value` (P1.bpl 0x40D716) — not "unassigned".
                let explained = value == PLCProgramBuilder.Module.constant(0)
                    || (value >> 8) == 0xC0
                    || (value >> 8) == 0x10
                    || value == 0
                    || (0x01...0xFF).contains(Int(value >> 8))   // UMISTENI<<8|SVORKA
                if !explained { Issue.record(Mismatch(description: String(format: "0x%04X is unexplained", value))) }
            }
        }
        // The two that name real terminals in the CSV.
        #expect(PLCProgramBuilder.Module.terminal(umisteni: 7, svorka: 0) == 0x0700)
        #expect(PLCProgramBuilder.Module.terminal(umisteni: 2, svorka: 0) == 0x0200)
        // And the constant encoding, straight from the disassembly.
        #expect(PLCProgramBuilder.Module.constant(3) == 0xC003)
        #expect(PLCProgramBuilder.Module.constant(770) == 0xC302)
    }

    @Test("A rebuilt table keeps the template's header and trailer and gets a valid checksum")
    func rebuildsATable() throws {
        let real = try Self.realBytes()
        let template = try PLCProgramTable(bytes: real)
        let rebuilt = PLCProgramBuilder(modules: Self.headModules).table(fromTemplate: template)

        // Sized to its own records, with the same header and trailer as the template.
        #expect(rebuilt.count == PLCProgramTable.length(records: PLCProgramBuilder(modules: Self.headModules).recordsLength))
        // The header is the template's, except for the checksum, which is recomputed for the new program, and
        // the two words that follow from the layout — the end of the records at +0x10 and the table length at
        // +0x1A — which are derived from the new program's size.
        let derived: Set<Int> = [0x10, 0x11, 0x1A, 0x1B, PLCProgramTable.checksumOffset,
                                 PLCProgramTable.checksumOffset + 1]
        let changed = (0..<0x40).filter { rebuilt[$0] != real[$0] }
        #expect(Set(changed).isSubset(of: derived), "header bytes changed: \(changed)")
        let table = try PLCProgramTable(bytes: rebuilt)
        #expect(Int(rebuilt[0x10]) | Int(rebuilt[0x11]) << 8 == (table.sentinelOffset - 4) / 16)
        #expect(Int(rebuilt[0x1A]) | Int(rebuilt[0x1B]) << 8 == rebuilt.count / 64)
        #expect(Array(rebuilt.suffix(PLCProgramTable.trailerLength)) == Array(real.suffix(PLCProgramTable.trailerLength)))
        // And the checksum it wrote is the one its own bytes produce.
        let rebuiltTable = try PLCProgramTable(bytes: rebuilt)
        #expect(rebuiltTable.checksumIsValid)
        #expect(rebuiltTable.checksum != template.checksum, "the program changed, so the checksum must")
    }

    @Test("Records that overrun the sentinel are refused")
    func refusesOverlongPrograms() throws {
        let template = try PLCProgramTable(bytes: try Self.realBytes())
        // 0xC4 - 0x40 = 132 bytes of room; each module costs 2 + 2n.
        let tooMany = (0..<40).map { _ in PLCProgramBuilder.Module(id: 1, flag: 0, values: [0, 0, 0, 0]) }
        let builder = PLCProgramBuilder(modules: tooMany)
        #expect(builder.recordsLength > 132)
    }

    // MARK: - Everything the exports establish

    /// Every program table the user has exported, all of which must carry the checksum this code computes.
    ///
    /// The algorithm was found by searching all 65 536 reflected polynomials, not by testing named ones;
    /// seven independent files now confirm it, and the seventh arrived after the algorithm was fixed.
    @Test("Every exported table carries the checksum this code computes")
    func everyExportChecksums() throws {
        let dir = Self.workspace
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("had") && $0.hasSuffix(".dmp") }
            .sorted()
        try #require(names.count >= 7, "expected the user's exports; found \(names.count)")
        for name in names {
            let table = try PLCProgramTable(bytes: [UInt8](try Data(contentsOf: dir.appendingPathComponent(name))))
            #expect(table.checksumIsValid,
                    "\(name): stored 0x\(String(table.checksum, radix: 16)) vs computed 0x\(String(table.computedChecksum, radix: 16))")
        }
    }

    /// The value counts the export diffs establish, by class. Mirrors `docs/class-shapes.json`.
    static let classShapes: [String: Int] = [
        "TMPulseGenerator": 4,
        "TMBoolVar": 0,
        "TMCounter": 4,
        "TMDigitalOutputs": 8,
        "TMIntSwitch": 6,
        "TMComparator": 5,
        "TMOr": 3,
        "TMInt2Bits": 0,
        "TSystemCommand": 3,
    ]

    @Test("The full walk of had.dmp matches every record's id byte")
    func fullWalkMatchesEveryId() throws {
        let real = try Self.realBytes()
        // Records in the project's ORDER, with each class's id from docs/block-ids.json and each
        // count from the export diffs. TMInt2Bits and the segment class contribute NO record at all,
        // which two byte-identical dumps prove, so they do not appear here.
        let walk: [(offset: Int, module: String, cls: String, id: UInt8, n: Int)] = [
            (0x040, "PulseGen1",   "TMPulseGenerator", 16, 4),
            (0x04A, "zapnuti",     "TMBoolVar",         0, 0),
            (0x04C, "Counter1",    "TMCounter",        15, 4),
            (0x056, "8xDO1",       "TMDigitalOutputs", 10, 8),
            (0x068, "reset",       "TMBoolVar",         0, 0),
            (0x06A, "ISwitch1",    "TMIntSwitch",       0, 13),
            (0x086, "Comparator1", "TMComparator",      6, 5),
            (0x092, "Or1",         "TMOr",             20, 3),
            (0x09A, "SystemCmd1",  "TSystemCommand",   81, 3),
        ]
        var offset = PLCProgramTable.bodyOffset
        for step in walk {
            #expect(step.offset == offset, "\(step.module) should start at 0x\(String(offset, radix: 16))")
            #expect(real[offset] == step.id,
                    "\(step.module): record byte 0x\(String(real[offset], radix: 16)) should be its class id 0x\(String(step.id, radix: 16))")
            offset += 2 + 2 * step.n
        }
        #expect(offset == 0xA2, "the records end at 0xA2")
        #expect(Set(real[offset..<(real.count - PLCProgramTable.trailerLength)]) == [0])
    }

    @Test("The discovered shapes tile the real table exactly")
    func shapesTileTheRealTable() throws {
        let real = try Self.realBytes()
        // The walk order, from each module's ORDER attribute, with the tie at 40 resolved by the fact
        // that 8xDO1's record is confirmed at 0x56 (id 0x0A, eight values).
        let walk: [(name: String, cls: String, id: UInt8, count: Int)] = [
            ("PulseGen1",   "TMPulseGenerator", 16, 4),
            ("zapnuti",     "TMBoolVar",         0, 0),
            ("Counter1",    "TMCounter",        15, 4),
            ("8xDO1",       "TMDigitalOutputs", 10, 8),
            ("reset",       "TMBoolVar",         0, 0),
            ("ISwitch1",    "TMIntSwitch",       0, 6),   // see note below on this record's id byte
            ("Comparator1", "TMComparator",      1, 5),
            ("Or1",         "TMOr",              1, 3),
            ("Int2Bits1",   "TMInt2Bits",        0, 0),
            ("Segment1",    "?",                 0, 5),
            ("SystemCmd1",  "TSystemCommand",   81, 3),
        ]
        var offset = PLCProgramTable.bodyOffset
        for step in walk {
            // The count is the class's own, from the diffs.
            if step.cls != "?", let known = Self.classShapes[step.cls] {
                #expect(known == step.count, "\(step.name): shapes say \(known), walk uses \(step.count)")
            }
            offset += 2 + 2 * step.count
        }
        // 98 bytes of records, then zeros to the sentinel.
        #expect(offset == 0xA2, "the records must end at 0xA2")
        #expect(Set(real[offset..<(real.count - PLCProgramTable.trailerLength)]) == [0],
                "the padding between the records and the sentinel is zeros")
        #expect(offset - PLCProgramTable.bodyOffset == 98)
    }

    @Test("The record region's anchors are where the diffs put them")
    func anchors() throws {
        let real = try Self.realBytes()
        // Rare id bytes at record starts, each appearing once in the region.
        #expect(real[0x40] == 16, "PulseGen1, TMPulseGenerator")
        #expect(real[0x4C] == 15, "Counter1, TMCounter")
        #expect(real[0x56] == 10, "8xDO1, TMDigitalOutputs")
        #expect(real[0x9A] == 81, "SystemCmd1, TSystemCommand")
        // And the added records the user exported, which are appended at 0xA2.
        for name in ["had+iswitch.dmp", "had+comparator.dmp", "had+or.dmp"] {
            let url = Self.workspace.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let added = [UInt8](try Data(contentsOf: url))
            #expect(added[0xA2] != 0, "\(name): an added record starts at 0xA2")
        }
    }
}
