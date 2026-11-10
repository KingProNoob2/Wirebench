import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchHardware
@testable import WirebenchModel

/// The PLC configuration replaces `SystemCmd` blocks on the sheet: loading a legacy `.pcc` turns them into entries, and building or exporting
/// turns them back into the blocks they were.
@Suite("PLC configuration")
@MainActor
struct PLCConfigurationTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let kostka = fixtures.appendingPathComponent("kostka-1.pcc")

    private func original() throws -> PCCProject { try PCCParser().parse(fileAt: Self.kostka) }

    @Test("Loading a legacy .pcc moves its SystemCmd block off the sheet into the configuration, as it was")
    func loadConvertsTheBlock() throws {
        let block = try #require(try original().modules.first { $0.guid == SystemCmdBlock.guid })
        let model = AppModel()
        model.loadProject(url: Self.kostka)
        let project = try #require(model.project)
        #expect(!project.modules.contains { $0.guid == SystemCmdBlock.guid }, "no SystemCmd block is left on a sheet")
        let entry = try #require(project.plcConfiguration.first)
        #expect(project.plcConfiguration.count == 1)
        var held = entry
        #expect(held.rawAttributes.removeValue(forKey: PLCConfiguration.positionKey) != nil, "it remembers where it stood in the file")
        #expect(held == block, "the entry is the block itself")
        #expect(entry.plcCommandWord == 0x302 && entry.plcParameter(1) == 112 && entry.plcParameter(2) == 0)
        #expect(!model.isDocumentEdited, "converting on load is not an edit")
    }

    @Test("Putting the configuration back gives the original project: the same blocks, in the same places")
    func injectingRestoresTheBlock() throws {
        let before = try original()
        let model = AppModel()
        model.loadProject(url: Self.kostka)
        let after = PLCConfiguration.injecting(try #require(model.project))
        #expect(after.plcConfiguration.isEmpty)
        #expect(Set(after.modules.map(\.id)) == Set(before.modules.map(\.id)))
        for module in before.modules { #expect(after.modules.first { $0.id == module.id } == module, "\(module.name) changed") }
        #expect(after.modules.map(\.id) == before.modules.map(\.id), "and in the same order")
    }

    @Test("A project loaded from a legacy file builds to Dirigo's own program binary and symbol table, byte for byte")
    func buildsLikeTheOriginal() throws {
        let model = AppModel()
        model.optimizeProgram = false        // the optimiser drops and moves blocks; Dirigo's own output is the plain build
        model.loadProject(url: Self.kostka)
        let report = try #require(model.compileProject())
        let real = try PLCProgramImage.inflate([UInt8](try Data(contentsOf: Self.fixtures.appendingPathComponent("kostka-1.pbd"))))
        let made = try PLCProgramImage.inflate(report.programBinary)
        let differing = (0..<min(real.count, made.count)).filter { made[$0] != real[$0] }
        #expect(made.count == real.count)
        // Only the project's name in the header may differ (the fixture is `kostka-1.pcc`; Dirigo wrote `kostka 1.pcc`). The table, and the trailer with
        // the profile's EEPROM write block, must match.
        #expect(differing.allSatisfy { $0 >= 0x11 && $0 < 0x20 }, "differing bytes: \(differing.prefix(12).map { String($0, radix: 16) })")
        let csv = try String(contentsOf: Self.fixtures.appendingPathComponent("kostka-1.csv"), encoding: .utf8)
        func lines(_ text: String) -> [String] { text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init) }
        let ours = lines(report.symbolCSV), theirs = lines(csv)
        #expect(ours == theirs)
    }

    @Test("A native save keeps the configuration as its own section, and reading it back gives the same entries")
    func nativeRoundTrip() throws {
        let model = AppModel()
        model.loadProject(url: Self.kostka)
        let xml = PCCSerializer().serialize(project: try #require(model.project))
        #expect(xml.contains("<\(PCCElement.plcConfiguration)"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plc-config-\(UUID().uuidString).pcc")
        defer { try? FileManager.default.removeItem(at: url) }
        try xml.write(to: url, atomically: true, encoding: .utf8)
        let back = try PCCParser().parse(fileAt: url)
        #expect(back.plcConfiguration == model.project?.plcConfiguration)
        #expect(!back.modules.contains { $0.guid == SystemCmdBlock.guid })
    }

    @Test("A SystemCmd block with something wired to it stays a block: it is a circuit, not a setting")
    func wiredBlockStays() throws {
        var project = try original()
        let block = try #require(project.modules.first { $0.guid == SystemCmdBlock.guid })
        let other = try #require(project.modules.first { $0.id != block.id })
        let unwired = project
        project.inConnections.append(Connection(inModuleId: block.id, inPinId: block.inPins[1].id, outModuleId: other.id, outPinId: 0))
        #expect(!PLCConfiguration.isConfiguration(block, in: project))
        #expect(PLCConfiguration.isConfiguration(block, in: unwired))
        let extracted = PLCConfiguration.extracting(project)
        #expect(extracted.plcConfiguration.isEmpty)
        #expect(extracted.modules.contains { $0.id == block.id })
    }

    @Test("Export Legacy .PCC writes the entries back as SystemCmd blocks, with no configuration section")
    func legacyExportHasBlocks() throws {
        let model = AppModel()
        model.loadProject(url: Self.kostka)
        model.exportForDirigo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plc-export-\(UUID().uuidString).pcc")
        defer { try? FileManager.default.removeItem(at: url) }
        model.finishExport(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("<\(PCCElement.plcConfiguration)"))
        let exported = try PCCParser().parse(fileAt: url)
        #expect(exported.modules.filter { $0.guid == SystemCmdBlock.guid }.count == 1)
        #expect(exported.plcConfiguration.isEmpty)
    }

    @Test("Adding, changing, setting and removing commands edits the project and marks it changed")
    func editing() throws {
        let model = AppModel()
        model.loadProject(url: Self.kostka)
        #expect(!model.isDocumentEdited)
        model.addPLCCommand()
        #expect(model.plcCommands.count == 2 && model.isDocumentEdited)
        let added = try #require(model.plcCommands.last)
        #expect(added.plcCommandWord == 0x302)
        #expect(model.plcGuide(of: added)?.parameters.count == 2)
        model.setPLCParameter(at: 1, 1, value: 0x3FFC)
        #expect(model.plcCommands[1].plcParameter(1) == 0x3FFC)
        model.setPLCParameter(at: 7, 1, value: 1)            // out of range: ignored
        model.removePLCCommand(at: 0)
        #expect(model.plcCommands.count == 1 && model.plcCommands[0].plcParameter(1) == 0x3FFC)
        #expect(model.project?.modules.contains { $0.guid == SystemCmdBlock.guid } == false)
        // The new entry is placed on a sheet when the project is built or exported.
        let blocks = PLCConfiguration.injecting(try #require(model.project), defaultThread: model.configurationThread)
        #expect(blocks.modules.filter { $0.guid == SystemCmdBlock.guid }.count == 1)
    }
}

