import Foundation

/// Everything worth restoring when an edit is undone.
public struct UndoSnapshot: Equatable, Sendable {
    public var project: PCCProject
    public var selectedModuleId: Int?
    public var selectedPage: String

    public init(project: PCCProject, selectedModuleId: Int?, selectedPage: String) {
        self.project = project
        self.selectedModuleId = selectedModuleId
        self.selectedPage = selectedPage
    }
}

/// A snapshot-based undo stack.
///
/// Snapshotting rather than command objects is the right trade here because `PCCProject` is a value
/// type: taking one copies a handful of array headers under copy-on-write, not the whole document.
/// It also means no edit can ever be missed by forgetting to write an inverse operation.
///
/// Edits that happen in a burst are **coalesced**. Some mutations loop — changing a block's input
/// count appends pins one at a time — and without coalescing a single user action would leave a
/// dozen undo steps behind. A short window merges them while keeping separate deliberate edits
/// (toggling two pins a second apart) distinct.
public struct UndoHistory: Sendable {
    /// Maximum number of undo steps retained.
    public var limit: Int
    /// Edits recorded within this interval of each other merge into one step.
    public var coalescingWindow: TimeInterval

    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private var lastRecorded: Date?

    public init(limit: Int = 100, coalescingWindow: TimeInterval = 0.25) {
        self.limit = limit
        self.coalescingWindow = coalescingWindow
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }

    /// Records the state as it was *before* an edit.
    public mutating func record(_ before: UndoSnapshot, at now: Date = Date()) {
        let merge = lastRecorded.map { now.timeIntervalSince($0) < coalescingWindow } ?? false
        if !(merge && !undoStack.isEmpty) {
            undoStack.append(before)
            if undoStack.count > limit { undoStack.removeFirst() }
        }
        lastRecorded = now
        redoStack.removeAll()
    }

    /// Returns the state to restore, given the state being left behind.
    public mutating func undo(current: UndoSnapshot) -> UndoSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastRecorded = nil
        return previous
    }

    public mutating func redo(current: UndoSnapshot) -> UndoSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastRecorded = nil
        return next
    }

    /// Drops all history — used when a different document is opened.
    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastRecorded = nil
    }

    /// Ends the current coalescing group, so the next edit starts a fresh undo step.
    public mutating func endGroup() {
        lastRecorded = nil
    }
}
