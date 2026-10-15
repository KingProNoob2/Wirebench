import Testing
import Foundation
@testable import DirigoHardware

/// The shape of each class's record, read from `had.dmp` and asserted as a rule.
///
/// The *values* of a record depend on a project's wiring, but its **shape** — how many values are data
/// slots, terminals, constants or empty, and in what order — is fixed per class. That makes it checkable
/// without a matching export.
///
/// `0xC0xx` is named `constant` rather than `unassigned`: `TMP1Module.InPinBinaryOutput`
/// (P1.bpl 0x40D3F4) ends `andw $0x3fff, %bx; orw $0xc000, %bx` (0x40D716) for an input pin with no
/// source, so the family is `0xC000 | value` — the constant 0 when the project gives no value.
///
/// This test validates the *format* rather than the compiler's output; the record *values* are checked
/// against the project file in `ConstantEncodingTests`.
@Suite("Record shape")
struct RecordShapeTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// How one value is used.
    enum Role: String {
        case slot        // 0x10xx — a data slot, 0x1000 + n
        case terminal    // (module << 8) | pin
        case constant    // 0xC0xx, `0xC000 | value`
        case empty       // 0x0000
        case other       // not yet catalogued
    }

    static func role(_ value: UInt16) -> Role {
        if value == 0 { return .empty }
        switch value >> 8 {
        case 0xC0, 0xC1, 0xC2, 0xC3, 0xC4: return .constant
        case 0x10: return .slot
        case 0x01...0x0B: return .terminal     // modules 1..11 in had.pcc
        default: return .other
        }
    }

    static func records() throws -> [(name: String, cls: String, roles: [Role])] {
        let url = root.appendingPathComponent("had.dmp")
        try #require(FileManager.default.fileExists(atPath: url.path), "needs the user's export")
        let d = [UInt8](try Data(contentsOf: url))
        func word(_ offset: Int) -> UInt16 { UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8) }
        // The solved walk: offset, name, class, value count.
        let walk: [(Int, String, String, Int)] = [
            (0x040, "PulseGen1",   "TMPulseGenerator", 4),
            (0x04A, "zapnuti",     "TMBoolVar",         0),
            (0x04C, "Counter1",    "TMCounter",         4),
            (0x056, "8xDO1",       "TMDigitalOutputs",  8),
            (0x068, "reset",       "TMBoolVar",         0),
            (0x06A, "ISwitch1",    "TMIntSwitch",      13),
            (0x086, "Comparator1", "TMComparator",      5),
            (0x092, "Or1",         "TMOr",              3),
            (0x09A, "SystemCmd1",  "TSystemCommand",    3),
        ]
        return walk.map { offset, name, cls, n in
            (name, cls, (0..<n).map { role(word(offset + 2 + 2 * $0)) })
        }
    }

    @Test("Each class's record has the shape the format implies")
    func shapes() throws {
        // TMBoolVar appears twice (zapnuti, reset); the first occurrence is enough.
        let byClass = Dictionary(try Self.records().map { ($0.cls, $0.roles) }, uniquingKeysWith: { a, _ in a })

        // Counts, not order, so a wrong pin keying shows up as a count mismatch.
        func counts(_ roles: [Role]) -> [Role: Int] {
            roles.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        // From had.dmp: one data slot for TMPulseGenerator/TMCounter/TMComparator/TSystemCommand,
        // two for TMIntSwitch, none for the others.
        #expect(counts(byClass["TMPulseGenerator"]!)[.slot] == 1)
        #expect(counts(byClass["TMCounter"]!)[.slot] == 1)
        #expect(counts(byClass["TMComparator"]!)[.slot] == 1)
        #expect(counts(byClass["TSystemCommand"]!)[.slot] == 1)
        #expect(counts(byClass["TMIntSwitch"]!)[.slot] == 2)
        #expect(counts(byClass["TMOr"]!)[.slot] == nil, "Or1 carries no data slot")
        #expect(counts(byClass["TMDigitalOutputs"]!)[.slot] == nil, "8xDO1 carries no data slot")

        // And the slot's position differs by class: Comparator1's is first, Counter1's last.
        #expect(byClass["TMComparator"]!.first == .slot)
        #expect(byClass["TMCounter"]!.last == .slot)
        #expect(byClass["TMPulseGenerator"]!.last == .slot)
        #expect(byClass["TSystemCommand"]!.last == .slot)

        // Every value is in a known family except the two named as uncatalogued.
        let known: Set<Role> = [.slot, .terminal, .constant, .empty]
        let unknown = try Self.records().flatMap { $0.roles.filter { !known.contains($0) } }
        #expect(unknown.count == 2, "ISwitch1 carries exactly two uncatalogued forms: 0x0001 and 0x941E")
        // Of which 0x941E is the encoder's *raw* 16-bit constant branch (P1.bpl 0x40D68F:
        // `pin[0x4D] == 2` -> `value = pin[0x4E]`), so only 0x0001 is genuinely unnamed.
    }

    @Test("The record region is exactly the nine records, and nothing else")
    func region() throws {
        let url = Self.root.appendingPathComponent("had.dmp")
        let d = [UInt8](try Data(contentsOf: url))
        let total = try Self.records().reduce(0) { $0 + 2 + 2 * $1.roles.count }
        #expect(total == 98, "the records occupy 0x40..0xA2")
        #expect(Set(d[(0x40 + total)..<(d.count - PLCProgramTable.trailerLength)]) == [0])
    }
}
