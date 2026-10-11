import Testing
import Foundation
@testable import DirigoApp
@testable import DirigoHardware

/// The *Build* menu's path, end to end, on the one project that has a real symbol table to compare with.
///
/// `compileProject()` is what the menu item calls: it takes the live project, serializes it, compiles the
/// records, builds the symbol table and wraps a program binary. The expectation for the symbol table is
/// not written here — it is the file Dirigo itself wrote.
@Suite("Building a project from the app")
struct BuildExportTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Building had+1block produces the symbol table Dirigo wrote, and a loadable program binary")
    @MainActor
    func buildProducesBothArtefacts() throws {
        let url = Self.root.appendingPathComponent("had+1block.pcc")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let model = AppModel()
        model.loadProject(url: url)
        #expect(model.project != nil, "the project should have loaded")

        let report = try #require(model.compileProject(), "the build should have produced a report")

        // The symbol table, against the real file rather than against our own reading.
        let expected = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"),
                                  encoding: .utf8)
        #expect(report.symbolCSV == expected, "the generated symbol table must be the real one")

        // Every module is accounted for: compiled, a display block, a macro, or a named gap.
        #expect(report.compiledModules + report.displayModules + report.macros.count
                + report.unshapedModules.count == report.moduleCount)
        #expect(report.unshaped.isEmpty, "unshaped classes: \(report.unshaped)")
        #expect(report.recordBytes > 0)
        #expect(report.symbolRows > 0)

        // The program binary is a real container: it inflates, parses, and its table is the built one.
        let image = try PLCProgramImage.parse(try PLCProgramImage.inflate(report.programBinary))
        let section = try #require(image.blocks.first { $0.id == PLCProgramImage.programTableSection })
        #expect(section.payload.count == 8 + 256)
        #expect(Array(section.payload[8...]) == report.table)
        #expect(image.blocks.contains { $0.id == PLCProgramImage.trailerSection })
        #expect(try PLCProgramTable(bytes: report.table).checksumIsValid,
                "the compiler's own checksum must verify")
    }

    @Test("The program binary's records are the ones the compiler produced")
    @MainActor
    func binaryCarriesTheRecords() throws {
        let model = AppModel()
        model.loadProject(url: Self.root.appendingPathComponent("had+1block.pcc"))
        let report = try #require(model.compileProject())
        let table = try PLCProgramTable(bytes: report.table)
        // The table's body is the record region, and it round-trips through the checksum.
        #expect(table.checksumIsValid)
        #expect(table.moduleTable.contains { $0 != 0 }, "the records should not be empty")
        #expect(table.realLength <= 256)
    }
}
