import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchModel

/// Maraflow `.mfl` export: the preserved table plus the current pages, native blocks and wires.
@Suite("Maraflow export")
struct MaraflowExportTests {
    @Test("An imported sheet exports and re-imports with its blocks, wires and metadata")
    func roundTrip() throws {
        let imported = try ProjectFile.read(data: MaraflowImportTests.demoProject(), filename: "demo")
        let exported = try MaraflowExporter.export(imported.project)
        #expect(String(decoding: exported.data, as: UTF8.self).contains("<properties>"))
        #expect(exported.notes.isEmpty)

        let again = try ProjectFile.read(data: exported.data, filename: "demo")
        #expect(again.format == .maraflow)
        #expect(again.project.pages.map(\.caption) == imported.project.pages.map(\.caption))
        #expect(again.project.modules.count == imported.project.modules.count)
        #expect(again.project.inConnections.count == imported.project.inConnections.count)
        #expect(again.project.modules.map(\.name).sorted() == imported.project.modules.map(\.name).sorted())
        #expect(again.project.modules.first { $0.name == "And1" }?.guid == MaraflowCatalog.byId["Bool.And"]?.guid)
        #expect(again.project.maraflow?.properties["project.name"] == "Demo")
    }

    @Test("Preserved fields survive an export unchanged")
    func preservedFields() throws {
        var entries: [(String, String)] = [
            ("project.name", "Extra"),
            ("project.author", "Mat"),
            ("project.pageCount", "1"),
            ("project.tagCount", "1"),
            ("project.tag.0.name", "Speed"),
            ("project.tag.0.type", "FLOAT"),
            ("project.estop.enabled", "true"),
            ("project.estop.ruleCount", "1"),
            ("project.estop.rule.0.channel", "DI3"),
            ("page.0.name", "Main"),
            ("page.0.language", "FBD"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.0.graphicCount", "1"),
            ("page.0.graphic.0.kind", "RECTANGLE"),
            ("page.0.graphic.0.text", "Pump"),
        ]
        let imported = try ProjectFile.read(
            data: MaraflowImportTests.propertiesXML(entries), filename: "extra")
        let exported = try MaraflowExporter.export(imported.project)
        let again = try ProjectFile.read(data: exported.data, filename: "extra")
        #expect(again.project.maraflow?.properties["project.tag.0.name"] == "Speed")
        #expect(again.project.maraflow?.properties["project.estop.rule.0.channel"] == "DI3")
        #expect(again.project.maraflow?.properties["page.0.graphic.0.text"] == "Pump")
        #expect(again.project.graphics.count == 1)
    }

    @Test("ST and ladder pages keep their source/rungs")
    func pagesRoundTrip() throws {
        var entries: [(String, String)] = [
            ("project.name", "Pages"),
            ("project.pageCount", "2"),
            ("page.0.name", "Logic"),
            ("page.0.language", "ST"),
            ("page.0.stCode", "VAR n : INT := 0; END_VAR n := n + 1; REG_0 := n;"),
            ("page.0.blockCount", "0"),
            ("page.0.wireCount", "0"),
            ("page.1.name", "Relays"),
            ("page.1.language", "LD"),
            ("page.1.rungCount", "1"),
            ("page.1.rung.0.threadId", "2"),
            ("page.1.rung.0.order", "10"),
            ("page.1.rung.0.mainCount", "1"),
            ("page.1.rung.0.main.0.kind", "NO_CONTACT"),
            ("page.1.rung.0.main.0.operand", "DI0"),
            ("page.1.rung.0.coilCount", "1"),
            ("page.1.rung.0.coil.0.kind", "NORMAL_COIL"),
            ("page.1.rung.0.coil.0.operand", "DO0"),
        ]
        let imported = try ProjectFile.read(data: MaraflowImportTests.propertiesXML(entries), filename: "pages")
        let exported = try MaraflowExporter.export(imported.project)
        let again = try ProjectFile.read(data: exported.data, filename: "pages")
        #expect(again.project.pages.map(\.caption) == ["Logic", "Relays"])
        #expect(again.project.modules.contains { $0.guid == MaraflowStPage.guid })
        #expect(again.project.modules.contains { $0.guid == MaraflowLdPage.guid })
        #expect(again.project.maraflow?.properties["page.0.stCode"]?.contains("n := n + 1") == true)
    }

    @MainActor
    @Test("The app prepares and writes the export")
    func appExport() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("export-import-\(UUID()).mfl")
        try MaraflowImportTests.demoProject().write(to: source)
        let model = AppModel()
        model.loadProject(url: source)
        model.exportMaraflow()
        #expect(model.pendingFilePanel == .exportMaraflow)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).mfl")
        model.finishMaraflowExport(to: target)
        #expect(FileManager.default.fileExists(atPath: target.path))
        let again = try ProjectFile.read(at: target)
        #expect(again.project.modules.count == model.project?.modules.count)
    }

    @Test("A native project exports a minimal Maraflow envelope and reports skipped blocks")
    func nativeProjectExports() throws {
        var project = PCCProject(name: "Native")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [BlockFactory.makeModule(guid: BlockTypeCatalog.info(forBlockName: "And")!.guid,
                                                   id: 1, name: "And1", x: 0, y: 0, order: 10,
                                                   threadId: 2, page: "main")]
        let result = try MaraflowExporter.export(project)
        #expect(result.notes.contains { $0.contains("And1") })
        let again = try ProjectFile.read(data: result.data, filename: "native")
        #expect(again.format == .maraflow)
        #expect(again.project.pages.map(\.caption) == ["main"])
        #expect(again.project.modules.isEmpty, "a Dirigo block has no Maraflow representation")
    }
}
