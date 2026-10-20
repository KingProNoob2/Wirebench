import Testing
import Foundation
@testable import DirigoCore
@testable import DirigoLibrary
@testable import DirigoApp

/// Which edits ask to be saved before New, Open or Quit: content does, layout does not.
@Suite("Unsaved changes")
@MainActor
struct UnsavedChangesTests {
    static func model() throws -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unsaved-\(UUID()).pcc")
        try PCCSerializer().serialize(project: BlockDeletionTests.project()).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return model
    }

    @Test("Moving blocks, organizing and resetting wires are not worth asking about")
    func layoutIsNotSignificant() throws {
        let model = try Self.model()
        #expect(!model.hasSignificantChanges)
        model.updateModulePosition(id: 1, deltaX: 140, deltaY: -30)
        model.moveModules([2, 3], lead: 2, deltaX: 10, deltaY: 10)
        model.organizeBlocks()
        model.resetWireRouting()
        #expect(!model.hasSignificantChanges)
    }

    @Test("Deleting a block is, and saving or undoing it back clears it")
    func contentIsSignificant() throws {
        let model = try Self.model()
        #expect(model.deleteModule(id: 2))
        #expect(model.hasSignificantChanges)
        model.undo()
        #expect(!model.hasSignificantChanges, "back to what is on disk")
        _ = model.deleteModule(id: 2)
        try model.saveProject(to: try #require(model.currentFileURL))
        #expect(!model.hasSignificantChanges)
    }

    @Test("Cancel in the dialog keeps the project open")
    func cancelKeepsProject() throws {
        let model = try Self.model()
        _ = model.deleteModule(id: 2)
        var asked = 0
        model.confirmDiscardingChanges = { asked += 1; return false }
        let before = model.project
        model.createNewProject()
        model.openProjectFile()
        #expect(asked == 2)
        #expect(model.project == before)
    }
}
