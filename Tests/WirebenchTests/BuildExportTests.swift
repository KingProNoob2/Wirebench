import Testing
import Foundation
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel
@testable import WirebenchHardware

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
        #expect(table.bytes.count == table.sentinelOffset + PLCProgramTable.trailerLength,
                "the table ends a trailer after its sentinel")
    }

    /// The *Export* menu's two commands, which run the same actions the build report's buttons do.
    /// Each compiles when nothing is built yet, arms its own file panel, and then writes the artefact
    /// that panel promised — the variables `.csv` and the program binary.
    @Test("Both export commands arm their panel and write their file")
    @MainActor
    func exportCommandsWriteTheirFiles() throws {
        let url = Self.root.appendingPathComponent("had+1block.pcc")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let model = AppModel()
        model.loadProject(url: url)

        let directory = FileManager.default.temporaryDirectory
        let csvURL = directory.appendingPathComponent("variables-\(UUID()).csv")
        let pbdURL = directory.appendingPathComponent("program-\(UUID()).pbd")
        defer {
            try? FileManager.default.removeItem(at: csvURL)
            try? FileManager.default.removeItem(at: pbdURL)
        }

        // Nothing has been built yet, so each command has to compile first rather than fail quietly.
        #expect(model.buildReport == nil)

        model.exportSymbolTable()
        #expect(model.pendingFilePanel == .exportSymbolTable)
        model.finishSymbolTableExport(to: csvURL)
        // Dirigo's own file, not merely something with a `.csv` extension.
        let expected = try String(contentsOf: Self.root.appendingPathComponent("had+1block.csv"),
                                  encoding: .utf8)
        #expect(try String(contentsOf: csvURL, encoding: .utf8) == expected,
                "the exported variable list must be the .csv Dirigo wrote")

        model.exportCompiledProgram()
        #expect(model.pendingFilePanel == .exportProgramBinary)
        model.finishProgramBinaryExport(to: pbdURL)
        let image = try PLCProgramImage.load(contentsOf: pbdURL)
        #expect(image.blocks.contains { $0.id == PLCProgramImage.programTableSection },
                "the exported binary must carry the program table")
    }

    @Test("With the build report up, its own copy of the save panels presents; otherwise the main view's does")
    @MainActor
    func reportOwnsThePanelsWhileUp() throws {
        let model = AppModel()
        model.loadProject(url: Self.root.appendingPathComponent("had+1block.pcc"))

        for panel in [AppModel.FilePanel.exportProgramBinary, .exportSymbolTable, .exportProgramVariables] {
            model.isShowingBuildReport = false
            model.pendingFilePanel = panel
            #expect(model.isPresenting(panel, inReport: false) && !model.isPresenting(panel, inReport: true))

            model.buildAndShowReport()
            model.pendingFilePanel = panel
            #expect(model.isBuildReportVisible)
            #expect(model.isPresenting(panel, inReport: true) && !model.isPresenting(panel, inReport: false),
                    "\(panel) must not be left to the view behind the report")
        }
        // A panel that was not asked for is shown by neither.
        model.pendingFilePanel = .exportSymbolTable
        #expect(!model.isPresenting(.exportProgramBinary, inReport: true))
    }

    @Test("Messages raised while the report is up appear on it, not as an alert that cannot show")
    @MainActor
    func messagesGoToTheReportWhileUp() throws {
        let model = AppModel()
        model.loadProject(url: Self.root.appendingPathComponent("had+1block.pcc"))

        model.presentMessage(title: "Elsewhere", message: "no report", kind: .info)
        #expect(model.pendingAlert?.title == "Elsewhere" && model.buildReportNotice == nil)
        model.pendingAlert = nil

        model.buildAndShowReport()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID()).csv")
        model.finishSymbolTableExport(to: destination)
        #expect(model.pendingAlert == nil, "an alert behind the report would never be seen")
        #expect(model.buildReportNotice?.title == "Exported \(destination.lastPathComponent)")
        #expect(model.buildReportNotice?.kind == .info)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        try? FileManager.default.removeItem(at: destination)

        // The notice belongs to one showing of the report.
        model.isShowingBuildReport = false
        #expect(model.buildReportNotice == nil)
    }

    @Test("The variables panel suggests the project's name without an extension, as the others do")
    @MainActor
    func variablesNameHasNoExtension() throws {
        let model = AppModel()
        model.loadProject(url: Self.root.appendingPathComponent("had+1block.pcc"))
        // `.dbf` is a type some Macs do not know, and a panel then appends its own extension to the name.
        #expect(model.programVariablesDefaultName == "had+1block")
        #expect(model.programBinaryDefaultName == "had+1block")
    }

    @Test("Value displays on a thread write no record and are not reported as missing a shape")
    @MainActor
    func valueDisplaysAreNotMissingShapes() throws {
        for name in ["ruleta_kostka_had.pcc", "rulkoshaddirigo.pcc"] {
            let model = AppModel()
            model.loadProject(url: Self.root.appendingPathComponent(name))
            let report = try #require(model.compileProject(), "\(name) should build")
            #expect(report.unshaped.isEmpty, "\(name): \(report.unshaped) \(report.unshapedModules)")
            #expect(report.build.report.isComplete)
        }
    }
}


/// There is no Connect button: an upload opens the serial port itself and closes it again, so nothing is held between uploads.
@Suite("Upload opens its own link")
@MainActor
struct UploadLinkTests {
    @Test("An upload to a port that cannot be opened fails with the reason, and leaves no link open")
    func refusedPort() async throws {
        let model = AppModel()
        model.selectedPortPath = "/dev/dirigo-no-such-port"
        let table = try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640))
        model.isUploading = true
        await model.upload(table: table)
        #expect(!model.isUploading)
        #expect(!model.isHardwareConnected)
        #expect(model.uploadStatus.contains("dirigo-no-such-port"), "the reason the port was refused should be shown: \(model.uploadStatus)")
    }

    @Test("An upload with no port chosen says so instead of asking for a connection")
    func noPort() async throws {
        let model = AppModel()
        model.selectedPortPath = ""
        model.uploadPhase = "Upload complete · 100%"      // left from an earlier upload: must not hide the new message
        model.isUploading = true
        await model.upload(table: try PLCProgramTable(bytes: [UInt8](repeating: 0x5A, count: 640)))
        #expect(!model.isUploading && !model.isHardwareConnected)
        #expect(model.uploadPhase.isEmpty)
        #expect(model.uploadStatus.contains("No serial port"), "\(model.uploadStatus)")
        #expect(!model.uploadStatus.lowercased().contains("connect"))
    }
}
