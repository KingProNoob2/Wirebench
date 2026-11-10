import Testing
import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

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
        let before = model.project

        model.createNewProject()
        #expect(model.pendingUnsavedIntent == .newProject, "New asks before replacing the project")
        model.answerUnsavedChanges(.cancel)
        #expect(model.pendingUnsavedIntent == nil)

        model.openProjectFile()
        #expect(model.pendingUnsavedIntent == .open, "Open asks too")
        model.answerUnsavedChanges(.cancel)
        #expect(model.project == before, "Cancel leaves the project exactly as it was")
    }

    @Test("Don't Save goes ahead without writing")
    func discardGoesAhead() throws {
        let model = try Self.model()
        _ = model.deleteModule(id: 2)
        let url = try #require(model.currentFileURL)
        let onDisk = try Data(contentsOf: url)

        model.createNewProject()
        model.answerUnsavedChanges(.discard)

        #expect(model.project?.modules.isEmpty == true, "the empty project replaced it")
        #expect(!model.hasSignificantChanges)
        #expect(try Data(contentsOf: url) == onDisk, "Don't Save must not write")
    }

    @Test("Save writes the file first, then carries the action out")
    func saveThenGoAhead() throws {
        let model = try Self.model()
        _ = model.deleteModule(id: 2)
        let url = try #require(model.currentFileURL)
        let before = try Data(contentsOf: url)

        model.createNewProject()
        model.answerUnsavedChanges(.save)

        #expect(try Data(contentsOf: url) != before, "the deletion was saved")
        #expect(model.project?.modules.isEmpty == true, "and then New went ahead")
        #expect(!model.hasSignificantChanges)
    }

    @Test("Quit asks first, and Cancel keeps the app up")
    func quitWaitsForAnswer() throws {
        let model = try Self.model()
        _ = model.deleteModule(id: 2)
        var quits = 0
        model.quitHandler = { quits += 1 }

        #expect(!model.shouldTerminateNow(), "there is work to lose, so AppKit must not terminate")
        #expect(model.pendingUnsavedIntent == .quit)
        model.answerUnsavedChanges(.cancel)
        #expect(quits == 0, "Cancel never asks AppKit again")

        #expect(!model.shouldTerminateNow())
        model.answerUnsavedChanges(.discard)
        #expect(quits == 1, "Don't Save asks AppKit again, and that request terminates")
        #expect(model.isTerminationApproved)
        #expect(model.shouldTerminateNow(), "the second request is let through")

        model.clearTerminationApproval()
        #expect(!model.shouldTerminateNow(), "a quit AppKit refused asks again next time")
    }

    @Test("Quit with nothing to lose does not ask")
    func cleanQuitDoesNotAsk() throws {
        let model = try Self.model()
        #expect(model.shouldTerminateNow())
        #expect(model.pendingUnsavedIntent == nil)
    }
}
