import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchSource
@testable import WirebenchModel

/// A picked wire belongs to the document that was open when it was picked. Replacing the document, or deleting one of
/// its blocks, must drop it: module ids restart at 1, so a stale pick could delete an unrelated wire in the next one.
@Suite("Wire selection is dropped with its document")
struct SelectionResetTests {
    private func project() -> PCCProject {
        var project = PCCProject(name: "sel", profile: "Sybas Duino-E")
        project.pages = [ProjectPage(caption: "main")]
        let di = BlockFactory.makeModule(guid: EightDIBlock.guid, id: 1, name: "8xDI1",
                                         x: 0, y: 0, order: 10, threadId: 1, page: "main")
        let out = BlockFactory.makeModule(guid: EightDOBlock.guid, id: 2, name: "8xDO1",
                                          x: 200, y: 0, order: 20, threadId: 1, page: "main")
        project.modules = [di, out]
        project.inConnections = [Connection(inModuleId: out.id, inPinId: 1, outModuleId: di.id, outPinId: 0)]
        return project
    }

    @Test("Opening another project drops the picked wire")
    @MainActor
    func adoptClearsWire() throws {
        let model = AppModel()
        model.project = project()
        model.selectWire(RoutedWire.Key(outModule: 1, outPin: 0, inModule: 2, inPin: 1))
        #expect(model.selectedWire != nil)
        let compiled = try SourceCompiler().compile("""
        PROGRAM Gate
        VAR
            a AT %IX0 : BOOL;
            lamp AT %QX0 : BOOL;
        END_VAR
            lamp := a;
        END_PROGRAM
        """)
        model.adoptCompiledProject(compiled.project)
        #expect(model.selectedWire == nil)
    }

    @Test("Deleting a block drops a wire picked on it")
    @MainActor
    func deletingBlockClearsWire() throws {
        let model = AppModel()
        model.project = project()
        model.selectWire(RoutedWire.Key(outModule: 1, outPin: 0, inModule: 2, inPin: 1))
        model.selectedModuleIds = [2]
        model.selectedModuleId = 2
        model.deleteSelectedModule()
        #expect(model.selectedWire == nil)
        #expect(model.project?.inConnections.isEmpty == true, "the block's wire goes with it")
    }
}
