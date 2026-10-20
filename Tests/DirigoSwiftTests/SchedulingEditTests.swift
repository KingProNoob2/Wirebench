import Testing
import Foundation
import DirigoCore
import DirigoLibrary
@testable import DirigoApp

/// Thread and execution order are document data that drive the engine's schedule, so editing them
/// has to rebuild the runtime. A plain field write would leave the block running on its old thread.
@MainActor
@Suite("Scheduling edits")
struct SchedulingEditTests {

    private func makeModel() throws -> (AppModel, URL) {
        var project = PCCProject(name: "sched")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .int32(0))]),
            PCCModule(id: 2, guid: NotBlock.guid, name: "Not1", x: 200, y: 0, order: 20,
                      threadId: 2, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true))], outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sched-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        return (model, url)
    }

    @Test("The engine schedules every thread a project uses")
    func schedulesEveryThread() throws {
        let (model, _) = try makeModel()
        #expect(model.executionOrder(forThread: 1) == [1])
        #expect(model.executionOrder(forThread: 2) == [2])
    }

    @Test("Changing a module's thread moves it in the schedule")
    func threadEditRebuildsTheSchedule() throws {
        let (model, _) = try makeModel()
        model.updateModuleThread(id: 1, threadId: 3)

        #expect(model.module(id: 1)?.threadId == 3, "the document must record the new thread")
        // Thread 1 has no modules left, so the runtime must no longer run it — this only holds if
        // the engine was rebuilt rather than the field quietly changed.
        #expect(model.executionOrder(forThread: 1) == [], "thread 1 has no modules left")
        #expect(model.executionOrder(forThread: 3) == [1])
        #expect(model.isDocumentEdited)
    }

    @Test("Changing the execution order re-sorts the thread")
    func orderEditRebuildsTheSchedule() throws {
        let (model, _) = try makeModel()
        // Put both blocks on one thread so their relative order is observable.
        model.updateModuleThread(id: 2, threadId: 1)
        #expect(model.executionOrder(forThread: 1) == [1, 2], "orders 10 then 20")

        // Pushing PulseGen past Not1 must move it later in the thread, not just in the document.
        model.updateModuleOrder(id: 1, order: 99)
        #expect(model.executionOrder(forThread: 1) == [2, 1])
    }

    @Test("Edits are undoable and clamped to sane ranges")
    func editsAreUndoableAndClamped() throws {
        let (model, _) = try makeModel()
        let before = model.history.undoCount

        model.updateModuleThread(id: 1, threadId: 3)
        #expect(model.history.undoCount == before + 1, "a scheduling edit is a document edit")

        model.undo()
        #expect(model.module(id: 1)?.threadId == 1, "undo must restore the old thread")

        // Out-of-range values are clamped rather than written through.
        model.updateModuleThread(id: 1, threadId: -5)
        #expect(model.module(id: 1)?.threadId == 0)
        model.updateModuleOrder(id: 1, order: -1)
        #expect(model.module(id: 1)?.order == 0)

        // A no-op edit must not add an undo step.
        let afterClamp = model.history.undoCount
        model.updateModuleThread(id: 1, threadId: 0)
        #expect(model.history.undoCount == afterClamp)
    }

    @Test("Renaming a block edits the document and ends the edit")
    func renamesABlock() throws {
        let (model, _) = try makeModel()
        let before = model.history.undoCount

        model.renamingModuleId = 1
        model.renameModule(id: 1, name: "Starter")
        #expect(model.module(id: 1)?.name == "Starter")
        #expect(model.renamingModuleId == nil, "the edit ends whether or not it changed anything")
        #expect(model.history.undoCount == before + 1)
        #expect(model.isDocumentEdited)

        // A blank name is refused rather than emptying the block's label.
        model.renameModule(id: 1, name: "   ")
        #expect(model.module(id: 1)?.name == "Starter")
        #expect(model.history.undoCount == before + 1, "a refused rename is not a document edit")

        model.undo()
        #expect(model.module(id: 1)?.name == "PulseGen1")
    }
}
