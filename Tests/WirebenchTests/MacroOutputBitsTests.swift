import Testing
import Foundation
@testable import WirebenchHardware
import WirebenchLibrary

/// `rulkoshaddirigo` drives its seven-segment digits through `8xDO` blocks fed by `Int2Bits`, and each `Int2Bits` reads a *macro call's*
/// output (`rultea1.OutA`, `kostka1.Out…`, `had1.OutA`). The compiler looked the call up for the word to split, found none, and put all of
/// those bits on row 0, on top of other blocks' bits: the segments on the PLC lit in the wrong places. Dirigo's own table for the project
/// (`Tests/Fixtures/rulkoshad-sevenseg.pbd`, the program binary it built) is the reference.
@Suite("Int2Bits fed by a macro output")
struct MacroOutputBitsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func build() throws -> PLCProjectBuild {
        let xml = try String(contentsOf: Self.fixtures.appendingPathComponent("rulkoshad-sevenseg.pcc"), encoding: .utf8)
        let template = try #require(PLCProgramTable.buildTemplate())
        return try PLCProjectBuild.compile(xml: xml, classForGUID: BlockTypeCatalog.classNamesByGUID, template: template)
    }

    @Test("The program binary is the one Dirigo built for the project, byte for byte")
    func matchesDirigo() throws {
        let build = try build()
        let mine = try PLCProgramImage.programBinary(table: build.table, projectName: "rulkoshaddirigo.pcc")
        // Compared inflated: two zlib streams of the same bytes need not be the same bytes.
        let real = try PLCProgramImage.inflate([UInt8](try Data(contentsOf: Self.fixtures.appendingPathComponent("rulkoshad-sevenseg.pbd"))))
        let made = try PLCProgramImage.inflate(mine)
        #expect(made.count == real.count)
        let differing = (0..<min(real.count, made.count)).filter { made[$0] != real[$0] }
        #expect(differing.isEmpty, "differing bytes: \(differing.prefix(16).map { String($0, radix: 16) })")
    }

    @Test("Each Int2Bits splits the word of the block behind the macro, and no two of them share a bit")
    func bitsAreDistinct() throws {
        let rows = try build().symbols
        func row(_ name: String) -> PLCProjectCompiler.Symbol? { rows.first { $0.name == name } }
        let source = try #require(row("rultea1.OutA"))
        let bit = try #require(row("Int2Bits4.B0"))
        #expect(bit.rowIndex == source.rowIndex, "the bits live in the word the macro's output is")
        var seen: Set<String> = []
        for r in rows where r.type == 6 && r.name.hasPrefix("Int2Bits") && r.name != "Int2Bits2.B0" && r.name != "Int2Bits2.B1" {
            #expect(seen.insert("\(r.rowIndex):\(r.index)").inserted, "\(r.name) shares a bit with another Int2Bits")
        }
    }
}

/// `kostka 1.pcc` is the project that calls `*Demux`, `*Int2Seg` and `*XorShift` several times, with `Move`, `IAdd`, `IMul`, `Div`, `AdvCounter`,
/// `Xor`, `Bits2Int` and a 26-pin `ISwitch` on a `Sybas Duino-E`. The fixtures are what Dirigo itself wrote for it: the program binary and the symbol table.
@Suite("kostka 1 against Dirigo's own export")
struct KostkaFidelityTests {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    @Test("The program binary and the symbol table are Dirigo's, byte for byte")
    func matchesDirigo() throws {
        let xml = try String(contentsOf: Self.fixtures.appendingPathComponent("kostka-1.pcc"), encoding: .utf8)
        let template = try #require(PLCProgramTable.buildTemplate())
        let build = try PLCProjectBuild.compile(xml: xml, classForGUID: BlockTypeCatalog.classNamesByGUID, template: template)
        // `Sybas Duino-E` inherits `EepromWriteBlock=128` from `Sybas K5-ETH`; the P3's is 8.
        let mine = try PLCProgramImage.programBinary(
            table: build.table, projectName: "kostka 1.pcc",
            trailer: PLCProgramImage.trailerPayload(eepromOffset: 16, eepromWriteBlock: 128))
        let real = try PLCProgramImage.inflate([UInt8](try Data(contentsOf: Self.fixtures.appendingPathComponent("kostka-1.pbd"))))
        let made = try PLCProgramImage.inflate(mine)
        #expect(made.count == real.count)
        let differing = (0..<min(real.count, made.count)).filter { made[$0] != real[$0] }
        #expect(differing.isEmpty, "differing bytes: \(differing.prefix(16).map { String($0, radix: 16) })")

        let csv = try String(contentsOf: Self.fixtures.appendingPathComponent("kostka-1.csv"), encoding: .utf8)
        func lines(_ text: String) -> [String] { text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init) }
        #expect(lines(build.symbolCSV) == lines(csv), "the symbol table differs from Dirigo's")
    }
}
