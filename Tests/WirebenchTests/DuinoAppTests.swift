import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
import WirebenchModel
import WirebenchSource

@Suite("Duino-S app path")
@MainActor
struct DuinoAppTests {
    private func model() -> AppModel {
        let model = AppModel()
        var project = PCCProject(name: "duino")
        project.pages = [ProjectPage(caption: "Main")]
        project.modules = [PCCModule(id: 1, guid: UUID(), name: "Block", x: 0, y: 0,
                                     order: 10, threadId: 1, page: "Main")]
        model.project = project
        model.hardwareFamily = .duinoS
        return model
    }

    @Test("Ethernet without an address is not treated as configured")
    func ethernetNeedsHost() {
        let model = model()
        model.duinoTransport = .ethernet
        model.duinoHost = ""
        #expect(!model.isDuinoLinkConfigured)
        model.startDuinoWatch()
        #expect(!model.isWatchingDuino)
        #expect(model.duinoWatchStatus.contains("IP address"))
    }

    @Test("Emulator transport requires the shared local simulator")
    func emulatorNeedsSession() {
        let model = model()
        model.duinoTransport = .emulator
        #expect(!model.isDuinoLinkConfigured)
        #expect(model.duinoLinkMissingMessage.contains("Start the Duino-S emulator"))
        model.startDuinoWatch()
        #expect(!model.isWatchingDuino)
        #expect(DuinoTransport.allCases.map(\.title) == ["USB", "Ethernet", "Emulator"])
    }

    @Test("Build Project produces the Duino-S report when that family is selected")
    func buildShowsDuinoReport() throws {
        let model = model()
        let definition = try #require(MaraflowCatalog.byId["Bool.And"])
        model.project?.modules = [PCCModule(
            id: 1, guid: definition.guid, name: "And1", x: 0, y: 0, order: 10, threadId: 1, page: "Main",
            inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true)),
                     Pin(id: 2, value: .bool(true))],
            paramPins: [], outPins: [Pin(id: 0, value: .bool(false))],
            rawAttributes: AttributeBag([("MARAFLOW_DEF", "Bool.And")]))]
        model.buildAndShowReport()
        #expect(model.duinoBuildResult != nil)
        #expect(model.isBuildReportVisible)
        #expect(model.buildReport == nil)
    }

    @Test("Watch without a port does not open a session")
    func watchWithoutPort() {
        let model = model()
        model.selectedPortPath = ""
        model.startDuinoWatch()
        #expect(!model.isWatchingDuino)
        #expect(model.duinoWatchStatus.contains("No serial port"))
    }

    @Test("The Hardware Link family picker routes the upload action to the Duino-S")
    func familyRoutes() {
        let model = model()
        #expect(model.hardwareFamily == .duinoS)
        model.hardwareFamily = .dirigo
        #expect(model.hardwareFamily.shortTitle == "Duino-P")
        #expect(model.hardwareFamily.title == "Sybas Duino-P (legacy)")
    }

    @Test("Sheet edits bump the ST-sync revision; adoption and loading do not")
    func sheetEditRevision() throws {
        let model = AppModel()
        model.createNewProject(platform: .wirebench)
        let baseline = model.sheetEditRevision
        _ = model.addBlock(guid: AndBlock.guid)
        #expect(model.sheetEditRevision > baseline)
        // Undo is a sheet edit like any other.
        let editedAt = model.sheetEditRevision
        model.undo()
        #expect(model.sheetEditRevision > editedAt)
        // The ST editor's own adoption restores around the set: it must not sync the buffer back.
        let adoptedAt = model.sheetEditRevision
        let compiled = try SourceCompiler().compile("""
        PROGRAM P
        VAR lamp AT %QX0 : BOOL; END_VAR
        lamp := TRUE;
        END_PROGRAM
        """)
        model.adoptCompiledProject(compiled.project)
        #expect(model.sheetEditRevision == adoptedAt)
    }

    @Test("New projects are created per platform and the palette follows the mode")
    func newProjectPlatforms() {
        let mara = AppModel()
        mara.createNewProject(platform: .maraflow)
        #expect(mara.projectPlatform == .maraflow)
        #expect(mara.project?.maraflow != nil)
        #expect(mara.hardwareFamily == .duinoS)
        #expect(mara.project?.profile == "")

        let legacy = AppModel()
        legacy.createNewProject(platform: .wirebench)
        #expect(legacy.projectPlatform == .wirebench)
        #expect(legacy.project?.maraflow == nil)
        #expect(legacy.hardwareFamily == .dirigo)

        // The modes are separate: neither palette offers the other's blocks.
        let maraAnd = MaraflowCatalog.byId["Bool.And"]!
        let dirigoAnd = BlockTypeCatalog.info(forBlockName: "And")!
        #expect(BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: maraAnd.guid)!, in: .maraflow))
        #expect(!BlockPaletteSearch.isOffered(dirigoAnd, in: .maraflow))
        #expect(!BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: maraAnd.guid)!, in: .wirebench))
        #expect(BlockPaletteSearch.isOffered(dirigoAnd, in: .wirebench))
        // The bare macro call type stays unoffered in both modes (macro rows insert working ones);
        // the Maraflow ST/LD page types only belong to Maraflow.
        #expect(!BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: MacroBlock.guid)!, in: .wirebench))
        #expect(!BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: MacroBlock.guid)!, in: .maraflow))
        #expect(BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: MaraflowStPage.guid)!, in: .maraflow))
        #expect(!BlockPaletteSearch.isOffered(BlockTypeCatalog.info(forGuid: MaraflowStPage.guid)!, in: .wirebench))
    }
}
