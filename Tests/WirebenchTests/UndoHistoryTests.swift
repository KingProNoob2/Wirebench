import Testing
import Foundation
@testable import WirebenchCore

@Suite("Undo and redo")
struct UndoHistoryTests {
    static func snapshot(_ name: String) -> UndoSnapshot {
        var project = PCCProject(name: name)
        project.modules = [
            PCCModule(id: 1, guid: UUID(), name: "M1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main"),
        ]
        return UndoSnapshot(project: project, selectedModuleId: 1, selectedPage: "main")
    }

    @Test("Undo restores the previous state and redo puts it back")
    func undoRedoRoundTrip() {
        var history = UndoHistory()
        let before = Self.snapshot("before")
        let after = Self.snapshot("after")

        #expect(!history.canUndo)
        history.record(before, at: Date())
        #expect(history.canUndo)
        #expect(!history.canRedo)

        let restored = history.undo(current: after)
        #expect(restored == before)
        #expect(!history.canUndo)
        #expect(history.canRedo)

        let reapplied = history.redo(current: before)
        #expect(reapplied == after)
        #expect(history.canUndo)
        #expect(!history.canRedo)
    }

    @Test("A burst of edits collapses into one undo step")
    func coalescing() {
        var history = UndoHistory(coalescingWindow: 0.25)
        let start = Date()
        // e.g. changing a block's input count appends pins one at a time.
        for i in 0..<8 {
            history.record(Self.snapshot("step\(i)"), at: start.addingTimeInterval(Double(i) * 0.001))
        }
        #expect(history.undoCount == 1, "a single action must not leave 8 undo steps")

        // A deliberate later edit is its own step.
        history.record(Self.snapshot("later"), at: start.addingTimeInterval(5))
        #expect(history.undoCount == 2)
    }

    @Test("A new edit clears the redo stack")
    func redoIsInvalidated() {
        var history = UndoHistory()
        history.record(Self.snapshot("a"), at: Date())
        _ = history.undo(current: Self.snapshot("b"))
        #expect(history.canRedo)

        history.record(Self.snapshot("c"), at: Date().addingTimeInterval(10))
        #expect(!history.canRedo, "editing after an undo must drop the redo branch")
    }

    @Test("History is bounded, and clears between documents")
    func boundedAndClearable() {
        var history = UndoHistory(limit: 5, coalescingWindow: 0)
        for i in 0..<20 {
            history.record(Self.snapshot("s\(i)"), at: Date().addingTimeInterval(Double(i)))
        }
        #expect(history.undoCount == 5)

        history.clear()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test("Undoing past the start is a no-op, not a crash")
    func undoOnEmptyHistory() {
        var history = UndoHistory()
        #expect(history.undo(current: Self.snapshot("x")) == nil)
        #expect(history.redo(current: Self.snapshot("x")) == nil)
    }
}
