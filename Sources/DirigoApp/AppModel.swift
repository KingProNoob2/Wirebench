import Foundation
import SwiftUI
import DirigoCore
import DirigoLibrary
import DirigoEngine
import DirigoHardware


/// Everything a block card draws, as plain value data.
///
/// The canvas used to read live pin values straight out of the engine — a plain, non-observable
/// class — during `body`, and leaned on a version counter to force re-evaluation. That is fragile:
/// correct only if every invalidation path is remembered, and impossible for SwiftUI to diff,
/// because the data it compares is owned by an object it cannot see change. Capturing the values
/// into an observable value type makes the dependency explicit and the diff ordinary.
public struct BlockSnapshot: Equatable, Sendable {
    public var inValues: [PinValue] = []
    public var paramValues: [PinValue] = []
    public var outValues: [PinValue] = []
    public var segments: [Bool] = []
    public var boolVarMode: BoolVarBlock.Mode?

    public init() {}
}

/// A module's live pins, read out of the core: what `getNode` returns.
///
/// A value, not a live block. Nothing writes through it — every edit goes through the model (`setModuleInput`,
/// `updateModuleParam`, ...), which writes the core — so a caller cannot change a pin the simulation never sees.
public struct RuntimePins: Equatable, Sendable {
    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]
}

public struct RuntimeNode: Sendable {
    public let module: PCCModule
    public let block: RuntimePins
}

/// What kind of block a module is, from its type GUID — the question views used to answer by casting the
/// Swift block object (`node.block is IntVarBlock`).
public enum BlockRole {
    /// A `BoolVar`'s mode, as the registry builds it: `SimulMode`, or a push button by default.
    public static func boolVarMode(of module: PCCModule) -> BoolVarBlock.Mode? {
        guard module.guid == BoolVarBlock.guid else { return nil }
        let raw = module.simulMode ?? (module.rawAttributes["SimulMode"].flatMap { Int($0) } ?? 2)
        return BoolVarBlock.Mode(rawValue: raw) ?? (raw == 1 ? .toggleSwitch : .pushButton)
    }

    /// The Delphi class of the module's type, which is how the core tells blocks apart.
    public static func delphiClass(of module: PCCModule) -> String? {
        BlockTypeCatalog.info(forGuid: module.guid)?.delphiClass
    }

    public static func isIntVariable(_ module: PCCModule) -> Bool {
        ["TMIntVar", "TMLongVar"].contains(delphiClass(of: module) ?? "")
    }

    public static func isFloatVariable(_ module: PCCModule) -> Bool { delphiClass(of: module) == "TMFloatVar" }

    /// Blocks whose *outputs* a person drives by clicking: the macro `Inputs` interface and `8xDI`.
    public static func hasClickableOutputs(_ module: PCCModule) -> Bool {
        if module.guid == EightDIBlock.guid { return true }
        guard module.guid == InputsBlock.guid else { return false }
        return (module.rawAttributes["KIND"] ?? "0") != "1" && !module.name.lowercased().hasPrefix("output")
    }

    /// A seven-segment display's lit segments, from its pins (`SegmentBlock.segmentsState`).
    public static func segments(of module: PCCModule, inPins: [PinValue]) -> [Bool] {
        guard module.guid == SegmentBlock.guid else { return [] }
        guard inPins.count >= 9, inPins[0].asBool else { return Array(repeating: false, count: 8) }
        return (1...8).map { inPins[$0].asBool }
    }
}

@Observable
public final class AppModel: @unchecked Sendable {
    public var project: PCCProject? {
        didSet {
            // One choke point for undo. Every edit to the document goes through this property, so
            // no mutator can forget to record itself.
            guard !isRestoringUndo,
                  let previous = oldValue,
                  let current = project,
                  previous != current else { return }
            history.record(UndoSnapshot(project: previous,
                                        selectedModuleId: selectedModuleId,
                                        selectedPage: selectedPage))
        }
    }

    /// Undo/redo for document edits.
    public private(set) var history = UndoHistory()
    private var isRestoringUndo = false

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    public func undo() {
        guard let current = project,
              let snapshot = history.undo(current: UndoSnapshot(project: current,
                                                               selectedModuleId: selectedModuleId,
                                                               selectedPage: selectedPage))
        else { return }
        restore(snapshot)
    }

    public func redo() {
        guard let current = project,
              let snapshot = history.redo(current: UndoSnapshot(project: current,
                                                               selectedModuleId: selectedModuleId,
                                                               selectedPage: selectedPage))
        else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: UndoSnapshot) {
        isRestoringUndo = true
        project = snapshot.project
        selectedModuleId = snapshot.selectedModuleId
        selectedPage = snapshot.selectedPage
        // Text objects are selected by index, and the restored array may hold different ones there.
        clearAnnotationSelection()
        isRestoringUndo = false
        engine = installEngine(project: snapshot.project)
        refreshSnapshots()
        isDocumentEdited = true
    }
    public var selectedPage: String = "main"
    public var selectedModuleId: Int? {
        // Selecting a block outside the marquee group (or nothing) ends the group.
        didSet { if let id = selectedModuleId, selectedModuleIds.contains(id) { return }; selectedModuleIds = [] }
    }
    /// Blocks picked together with the selection rectangle; they move and delete as one. Empty for a plain selection.
    public var selectedModuleIds: Set<Int> = []
    public var isPlaying: Bool = false
    /// How fast simulated time runs, as a multiple of the *base speed*: 1.0 — shown as 100% — is a tenth of the
    /// PLC's real time. At the PLC's own speed a fast project (a 71 ms `Tick` thread driving the dice or the
    /// snake) flashes past faster than it can be watched, so the base is the pace that can. Threads keep their
    /// profile periods; this scales how much time passes per wall-clock second.
    public var simulationSpeed: Double = 1.0
    /// Real time is this many times the base speed (1000%).
    public static let baseSpeed = 0.1
    /// The speeds the toolbar offers, slowest first, as multiples of the base. Past 1000% (real time) a thread
    /// that is due every few milliseconds cannot keep up, because a step runs each due thread once.
    public static let speedSteps: [Double] = [0.1, 0.25, 0.5, 1, 2, 4, 10]
    /// Simulated seconds per wall-clock second.
    var effectiveSpeed: Double { simulationSpeed * Self.baseSpeed }
    public var tickCount: UInt64 = 0
    public var simulationVersion: UInt64 = 0

    /// Live block values, refreshed from the engine whenever it advances. Views read this, never the
    /// engine, so SwiftUI always has a change it can actually see.
    public private(set) var snapshots: [Int: BlockSnapshot] = [:]

    /// The model the app delegate reaches documents through.
    ///
    /// Set by `init`, so a project opened from Finder — `open`, or a double-click — lands in the
    /// same model the window is already showing. `nonisolated(unsafe)` because `init` is nonisolated
    /// and the assignment happens once per process, on the main thread, before any view exists.
    nonisolated(unsafe) public static weak var shared: AppModel?

    /// The running play loop, cancelled and replaced by `play()`/`pause()`.
    private var simulationTimerTask: Task<Void, Never>?

    /// The simulation: the C++ core, which owns every pin value the canvas, the inspector and the
    /// dialogs show. Rebuilt on any structural change, which is why `play()` re-reads it every iteration
    /// instead of capturing it.
    private var engine: CxxSimulationCore?

    /// The push buttons currently held down, so a release only clears the button a press set.
    private var heldButtons: Set<Int> = []

    // MARK: - Hardware link

    /// Path of the selected serial port, and the ports found on this machine.
    public var selectedPortPath: String = ""
    public var availablePorts: [SerialPort.PortInfo] = []

    /// The serial link to the PLC. `SerialPort` is a plain class, so its open/closed state is
    /// mirrored into `isHardwareConnected` for the UI.
    private let serialPort = SerialPort()

    /// Whether the serial link to the PLC is open.
    public var isHardwareConnected: Bool = false

    // MARK: - Uploading a program to the PLC

    /// The addresses from *Unit config*: the PLC is 1, the PC is 31. They are the frame's `DA` and
    /// `SA`, and the captured upload uses exactly these.
    public var plcAddress: UInt8 = 1
    public var pcAddress: UInt8 = 31

    /// True while an upload is in progress; the work runs off the main thread.
    public var isUploading: Bool = false
    /// A one-line status for the UI, updated between steps.
    public var uploadStatus: String = ""

    /// One line of the upload log.
    public struct UploadLogEntry: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case stage, request, reply, error, info }
        public let id: Int
        public let time: Date
        public let kind: Kind
        public let text: String
    }
    /// What the last upload did, newest last. Capped so a long session cannot grow it without bound.
    public var uploadLog: [UploadLogEntry] = []
    private var uploadLogCounter = 0

    /// Appends a line to the upload log. Safe to call from the upload's background thread.
    public func logUpload(_ text: String, kind: UploadLogEntry.Kind = .info) {
        let time = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadLogCounter += 1
            self.uploadLog.append(UploadLogEntry(id: self.uploadLogCounter, time: time, kind: kind, text: text))
            if self.uploadLog.count > 500 { self.uploadLog.removeFirst(self.uploadLog.count - 500) }
        }
    }

    public func clearUploadLog() { uploadLog.removeAll(); uploadPhase = ""; uploadProgress = nil }

    /// A stage announced by the uploader, as a sentence.
    nonisolated static func phaseText(for stage: String) -> String {
        switch stage {
        case "GetStatus": return "Contacting the PLC…"
        case "Stop the PLC": return "Stopping the PLC…"
        case "Read the run/stop register": return "Checking the PLC is stopped…"
        case "Start the PLC": return "Starting the PLC…"
        default:
            if stage.hasPrefix("Table frame ") {
                return "Writing table " + stage.dropFirst("Table frame ".count)
                    .replacingOccurrences(of: " of ", with: "/")
            }
            return stage
        }
    }

    /// Moves the percentage on after each reply, keeping the words the stage set.
    nonisolated func uploadProgressTick(_ fraction: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.uploadProgress = fraction
            if let dot = self.uploadPhase.range(of: " · ") {
                self.uploadPhase = String(self.uploadPhase[..<dot.lowerBound])
            }
            if self.isUploading { self.uploadPhase += " · \(Int(fraction * 100))%" }
        }
    }

    /// What the upload is doing, in words — "Connection established", "Writing table 3 of 5" — and how far along
    /// it is, 0…1. `nil` progress means no upload has run.
    public var uploadPhase: String = ""
    public var uploadProgress: Double?

    /// Updates the phase and progress from any thread.
    nonisolated func setUploadPhase(_ phase: String, progress: Double?) {
        DispatchQueue.main.async { [weak self] in
            self?.uploadPhase = phase
            if let progress { self?.uploadProgress = progress }
        }
    }

    /// Counts replies so the percentage is steps done over steps in all. A lock, because the transport callback
    /// runs on the upload's thread.
    final class UploadTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var replies = 0
        let total: Int
        init(total: Int) { self.total = total }
        func reply() -> Double {
            lock.lock(); defer { lock.unlock() }
            replies += 1
            return min(1, Double(replies) / Double(total))
        }
    }

    /// The log as text, for the clipboard.
    public var uploadLogText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return uploadLog.map { "\(f.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
    }

    /// A frame as a short hex string: the first 24 bytes, then how many there are.
    nonisolated static func hexSummary(_ bytes: [UInt8]) -> String {
        let head = bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > 24 ? "\(head) … (\(bytes.count) bytes)" : "\(head) (\(bytes.count) bytes)"
    }

    /// Uploads a program table exported from Dirigo (a `.pbd` file) to the PLC.
    ///
    /// The sequence is the captured one: stop the PLC, write the table as matrix frames, start it.
    /// Everything it needs was recovered from the wire and the decomp, so nothing here is estimated.
    public func uploadProgram(from url: URL) {
        guard !isUploading else { return }
        isUploading = true
        uploadStatus = "Reading \(url.lastPathComponent)…"

        if !isHardwareConnected { connectHardware() }
        guard isHardwareConnected else {
            uploadStatus = "No serial link. Choose a port and connect first."
            isUploading = false
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let image = try PLCProgramImage.load(contentsOf: url)
                guard let block = image.blocks.first(where: { $0.id == 525 }) else {
                    await MainActor.run {
                        self.uploadStatus = "That file has no program table (no 525 section)."
                        self.isUploading = false
                    }
                    return
                }
                // The block's payload is an eight-byte sub-header then the table.
                let body = Array(block.payload.dropFirst(8))
                let table = try PLCProgramTable(bytes: body)
                await self.upload(table: table)
            } catch {
                await MainActor.run {
                    self.uploadStatus = "Upload failed: \(error)"
                    self.isUploading = false
                }
            }
        }
    }

    /// Sends one prepared table to the PLC. Shared by the file path and by *Build → Upload Compiled
    /// Program*, which produces the table in-process instead of reading a `.pbd`.
    public func upload(table: PLCProgramTable) async {
        if !isHardwareConnected { connectHardware() }
        guard isHardwareConnected else {
            uploadStatus = "No serial link. Choose a port and connect first."
            isUploading = false
            return
        }
        do {
            await MainActor.run { self.uploadStatus = "Stopping the PLC…" }
            await MainActor.run {
                self.uploadLog.removeAll()
                self.uploadPhase = "Connecting…"
                self.uploadProgress = 0
            }
            // GetStatus, stop, read, one write per 128-byte chunk, start.
            let chunks = (table.uploadedBytes.count + 127) / 128
            let tracker = UploadTracker(total: 4 + chunks)
            self.logUpload("Upload started: \(table.uploadedBytes.count)-byte table in \(chunks) frame(s) · "
                           + "PLC address \(self.plcAddress), PC address \(self.pcAddress), \(self.selectedPortPath)",
                           kind: .info)
            var established = false
            let logged = LoggingDbNetTransport(wrapping: SerialDbNetTransport(port: self.serialPort)) { [weak self] direction, bytes in
                guard let self else { return }
                if direction.hasPrefix("✗") {
                    self.logUpload("Link error: \(direction.dropFirst(2))", kind: .error)
                } else if direction == "→" {
                    self.logUpload("  → \(AppModel.hexSummary(bytes))", kind: .request)
                } else {
                    let fraction = tracker.reply()
                    self.logUpload("  ← \(AppModel.hexSummary(bytes))", kind: .reply)
                    if !established {
                        established = true
                        self.logUpload("Connection established — the PLC answered.", kind: .stage)
                        self.setUploadPhase("Connection established · \(Int(fraction * 100))%", progress: fraction)
                    }
                    self.uploadProgressTick(fraction)
                }
            }
            let session = DbNetSession(transport: logged, address: UInt32(self.plcAddress))
            let uploader = PLCUploader(session: session,
                                       destination: self.plcAddress,
                                       source: self.pcAddress)
            uploader.onStage = { [weak self] stage in
                guard let self else { return }
                self.logUpload(stage, kind: .stage)
                self.setUploadPhase(AppModel.phaseText(for: stage), progress: nil)
            }
            await MainActor.run { self.uploadStatus = "Writing \(table.uploadedBytes.count) bytes…" }
            let frames = try uploader.upload(table: table)
            self.logUpload("Upload complete — \(frames) table frame(s) written, the PLC is running.", kind: .stage)
            await MainActor.run {
                self.uploadPhase = "Upload complete · 100%"
                self.uploadProgress = 1
                self.uploadStatus = "Uploaded \(frames) frame(s). The PLC is running."
                self.isUploading = false
            }
        } catch {
            self.logUpload("Upload failed: \(error)", kind: .error)
            await MainActor.run {
                self.uploadPhase = "Upload failed"
                self.uploadStatus = "Upload failed: \(error)"
                self.isUploading = false
            }
        }
    }

    /// Asks for a `.pbd` and uploads it.
    public func uploadProgramFile() {
        pendingFilePanel = .uploadProgram
    }

    public init() {
        AppModel.shared = self
        observeActivation()
    }

    /// Bumps the version that tells the canvas its live values have changed.
    ///
    /// This must be a **plain assignment**. `simulationVersion &+= 1` compiles to a `_modify`
    /// accessor rather than the property setter, and `@Observable`'s mutation hook is not invoked
    /// for it — so every view that read this property was never invalidated. The symptom was a
    /// canvas that silently never repainted while the simulation ran: the engine advanced, the
    /// toolbar's tick counter (a plain assignment) kept up, and every block stayed frozen until
    /// some *other* observed property happened to change and forced a repaint.
    /// Re-captures every block's live values and reports whether anything actually changed.
    ///
    /// The "did anything change" answer matters: republishing identical values invalidates every
    /// card on the sheet for nothing. A settled project was re-rendering ~17 times a second with
    /// byte-identical data, which is pure waste and made the canvas look busy while nothing moved.
    @discardableResult
    public func refreshSnapshots() -> Bool {
        guard let project else {
            guard !snapshots.isEmpty else { return false }
            snapshots = [:]
            publishedPinDigest = nil
            return true
        }
        // The cheap question first. Measured on `had+1block.pcc` the snapshot data changes on 2 ticks out
        // of 460, so this returns before allocating the dictionary, the per-module snapshots and the
        // comparison on 99.6% of ticks. `pinsDigest` is faithful, and the comparison below still runs
        // whenever it does not match, so a digest that under-reported could only cost a frame — never a
        // stale value on the canvas.
        let previousDigest = pinsDigest()
        if !snapshots.isEmpty, let previousDigest, previousDigest == publishedPinDigest {
            return false
        }
        snapshotRebuildCount += 1
        var next: [Int: BlockSnapshot] = [:]
        next.reserveCapacity(project.modules.count)
        for module in project.modules {
            guard let node = getNode(id: module.id) else { continue }
            var snapshot = BlockSnapshot()
            snapshot.inValues = node.block.inPins
            snapshot.paramValues = node.block.paramPins
            snapshot.outValues = node.block.outPins
            snapshot.segments = BlockRole.segments(of: module, inPins: node.block.inPins)
            snapshot.boolVarMode = BlockRole.boolVarMode(of: module)
            next[module.id] = snapshot
        }
        guard next != snapshots else {
            // Values agree, so remember the digest just measured and stop re-comparing against an
            // unchanged set. `previousDigest` rather than a second `pinsDigest()` call: measuring it once
            // is the whole point of the shortcut, and the values cannot have moved in between.
            publishedPinDigest = previousDigest
            return false
        }
        // Assigned once, not mutated in place, so observers see a single change per refresh.
        snapshots = next
        publishedPinDigest = previousDigest
        return true
    }

    /// The digest the published `snapshots` correspond to. See `refreshSnapshots`.
    private var publishedPinDigest: UInt64?

    /// How many times `refreshSnapshots` has actually built a new snapshot dictionary.
    ///
    /// The point of the digest shortcut is that most refreshes build nothing: on `had+1block.pcc` the
    /// values change on 2 ticks out of 460, so 99.6% of refreshes should return before allocating. That
    /// is a property of *work done*, and no assertion about the returned value can observe it — a
    /// shortcut that ran the whole rebuild and then returned the same `false` would look identical from
    /// outside. This counter is how the tests observe the difference.
    public private(set) var snapshotRebuildCount = 0

    /// Digests the values the published `snapshots` are built from: every pin in the core, plus each
    /// `BoolVar`'s mode — the one thing a snapshot carries that the pins do not imply, which decides how
    /// the control draws.
    ///
    /// Published because the "did anything change?" shortcut in `refreshSnapshots` is only safe while the
    /// digest is faithful, and a test can only check that from outside.
    public func pinsDigest() -> UInt64? {
        guard let engine else { return nil }
        var digest = engine.pinsDigest()
        for module in project?.modules ?? [] {
            guard let mode = BlockRole.boolVarMode(of: module) else { continue }
            digest = (digest ^ UInt64(bitPattern: Int64(module.id &* 31 &+ mode.rawValue))) &* 0x0000_0100_0000_01b3
        }
        return digest
    }

    // MARK: - The simulation core

    /// Whether the project is simulated by the C++ core — always, once a project is loaded. Kept for the
    /// tests and the UI that asked while there was a Swift engine beside it.
    public var isUsingCxxCore: Bool { engine != nil }

    /// The wall clock a step is stamped with. A property, not a `Date()` call, so a test can pin the
    /// instant a time-dependent block (`DateTime`) reads.
    public var now: () -> Date = { Date() }

    /// Whether the app is frontmost.
    ///
    /// The simulation keeps running when it is not — it is wall-clock driven, so stopping it would lose
    /// simulated time — but the *redraw* is skipped, because nothing is on screen to redraw. Measured
    /// per-tick cost is ~21 µs of work against milliseconds of SwiftUI re-evaluation, so this is where
    /// an idle background app's CPU actually goes.
    public var isAppActive = true

    private func observeActivation() {
        let centre = NotificationCenter.default
        centre.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAppActive = true
                // Catch up once, so the canvas shows the current state rather than the last one drawn.
                self.simulationDidChange()
            }
        }
        centre.addObserver(forName: NSApplication.willResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAppActive = false }
        }
    }

    /// One cycle. Reports whether a thread ran.
    @discardableResult
    private func stepBackend(deltaMs: Double) -> Bool {
        guard let engine else { return false }
        let ran = engine.step(deltaMs: deltaMs, now: now())
        tickCount = engine.tickCount
        return ran
    }

    /// The simulation moved: refresh the values the canvas draws — and, only if they really moved,
    /// tell the views. A settled simulation therefore stops invalidating anything at all.
    public func simulationDidChange() {
        if refreshSnapshots() { bumpSimulationVersion() }
    }

    private func bumpSimulationVersion() {
        simulationVersion = simulationVersion &+ 1
    }

    public var zoomScale: CGFloat = 1.0
    public var panOffset: CGSize = CGSize(width: 40, height: 40)
    public var dragStartPan: CGSize = CGSize(width: 40, height: 40)
    public var viewportSize: CGSize = CGSize(width: 1200, height: 800)

    public var canvasGlobalFrame: CGRect = .zero

    public var currentFileURL: URL? = nil
    public var isDocumentEdited: Bool = false

    /// The project as last opened, created or saved, with its layout left out (`content(of:)`).
    private var savedContent: PCCProject?

    /// Whether anything that matters changed since the last save: blocks, wires, values, names, pages, text.
    /// Layout does not count — moving blocks or text, *Organize Blocks*, re-routing wires — so closing after
    /// only tidying the sheet does not ask to save.
    public var hasSignificantChanges: Bool {
        guard let project else { return false }
        return Self.content(of: project) != savedContent
    }

    /// The project without where things are on the sheet.
    static func content(of project: PCCProject) -> PCCProject {
        var copy = project
        copy.projectPath = ""
        for i in copy.modules.indices {
            copy.modules[i].x = 0
            copy.modules[i].y = 0
        }
        for i in copy.inConnections.indices {
            copy.inConnections[i].points = []
            copy.inConnections[i].nameX = 0
            copy.inConnections[i].nameY = 0
        }
        for i in copy.paramConnections.indices {
            copy.paramConnections[i].points = []
            copy.paramConnections[i].nameX = 0
            copy.paramConnections[i].nameY = 0
        }
        for i in copy.graphics.indices { copy.graphics[i].nodes = [] }
        return copy
    }

    /// Asked before the open project is replaced (*New*, *Open*): `true` to go ahead. The app sets this to a
    /// Save / Don't Save / Cancel dialog; the model itself never shows one, so on its own it always goes ahead.
    public var confirmDiscardingChanges: () -> Bool = { true }

    public var projectTitle: String {
        if let currentFileURL = currentFileURL {
            return currentFileURL.deletingPathExtension().lastPathComponent
        } else if let name = project?.name, !name.isEmpty {
            return name
        } else {
            return "Dirigo"
        }
    }

    /// Re-reads the serial adapters attached to this machine.
    ///
    /// **This was dead code.** It was defined and never called from anywhere, so `availablePorts` stayed
    /// empty for the life of the process and the Hardware Link section always said "No serial ports
    /// found." — the list is only ever populated here. `MainView.hardwareSection` now calls it on
    /// appear; it is idempotent, and it only picks a default when nothing is selected, so a port loaded
    /// from a project is never overwritten.
    public func refreshPorts() {
        availablePorts = SerialPort.availablePorts()
        if let first = availablePorts.first, selectedPortPath.isEmpty {
            selectedPortPath = first.path
        }
    }

    public func createNewProject() {
        guard confirmDiscardingChanges() else { return }
        pause()
        let newProj = PCCProject(
            name: "Untitled",
            pages: [ProjectPage(caption: "main")],
            modules: []
        )
        isRestoringUndo = true
        self.project = newProj
        isRestoringUndo = false
        history.clear()
        self.currentFileURL = nil
        self.selectedPage = "main"
        self.selectedModuleId = nil
        clearAnnotationSelection()
        clearedPinValues = [:]
        self.engine = installEngine(project: newProj)
        self.tickCount = 0
        self.simulationVersion = 0
        self.isDocumentEdited = false
        savedContent = Self.content(of: newProj)
        resetZoom()
    }

    @MainActor
    public func loadProject(url: URL) {
        pause()
        do {
            let parser = PCCParser()
            let proj = try parser.parse(fileAt: url)
            isRestoringUndo = true
            self.project = proj
            // A new document means new meanings for the same module ids, and `ModulePinCatalog`
            // memoises a pin schema by module id. Without this a block could be labelled from the
            // *previous* project's schema for that id — wrong names on the panel, silently.
            ModulePinCatalog.invalidateSchemaCache()
            isRestoringUndo = false
            history.clear()
            self.currentFileURL = url
            self.selectedPage = proj.pages.first?.caption ?? "main"
            self.selectedModuleId = nil
            clearAnnotationSelection()
            // Module ids mean other blocks in another document.
            clearedPinValues = [:]
            self.engine = installEngine(project: proj)
        refreshSnapshots()
            self.tickCount = 0
            self.simulationVersion = 0
            self.isDocumentEdited = false
            savedContent = Self.content(of: proj)
            // The canvas has not been laid out yet, so its viewport size is still the placeholder.
            // Fitting to that produces a wrong zoom and pan; defer until the view reports a real
            // size (see `performPendingZoomToFit`).
            self.needsZoomToFit = true
        } catch {
            presentMessage(title: "Failed to open PCC project",
                           message: error.localizedDescription,
                           kind: .warning)
        }
    }

    /// Asks the view for a file. The panel itself belongs to the view layer now.
    @MainActor
    public func openProjectFile() {
        guard confirmDiscardingChanges() else { return }
        pendingFilePanel = .open
    }

    /// Called once the open panel has a result.
    @MainActor
    public func openProject(at url: URL) {
        loadProject(url: url)
    }

    @MainActor
    public func saveProject() {
        if let url = currentFileURL {
            do {
                try saveProject(to: url)
            } catch {
                saveProjectAs()
            }
        } else {
            saveProjectAs()
        }
    }

    @MainActor
    // MARK: - Adding blocks

    /// Inserts a new block of `guid` on the current page.
    ///
    /// It lands in the middle of the visible canvas, which is where the eye already is. The engine
    /// is rebuilt so the new block takes part in simulation immediately.
    @discardableResult
    public func addBlock(guid: UUID, at point: CGPoint? = nil) -> Int? {
        guard var project else { return nil }

        let id = BlockFactory.nextId(in: project)
        let name = BlockFactory.suggestedName(for: guid, existing: project.modules)
        let order = BlockFactory.nextOrder(in: project, page: selectedPage)
        let centre = point ?? viewportCentreInCanvas()

        // Nudge down-right while the spot is taken, so repeated insertions do not stack.
        var spot = snapToGrid ? CGPoint(x: GridSnap.snap(centre.x), y: GridSnap.snap(centre.y)) : centre
        while project.modules.contains(where: {
            $0.page == selectedPage && abs($0.x - spot.x) < 24 && abs($0.y - spot.y) < 24
        }) {
            spot.x += snapToGrid ? GridSnap.step : 28
            spot.y += snapToGrid ? GridSnap.step : 22
        }

        var module = BlockFactory.makeModule(
            guid: guid, id: id, name: name,
            x: spot.x, y: spot.y,
            order: order, threadId: threadForNewBlocks, page: selectedPage
        )
        // A new `If` / `Switch` is a container; ones read from a file stay the marker blocks they were.
        if guid == ConstructContainers.ifGuid || guid == ConstructContainers.switchGuid {
            module.rawAttributes["CONTAINER"] = "1"
            if guid == ConstructContainers.switchGuid {
                ConstructContainers.setCases([.init(id: "c1", values: "1")], of: &module)
                module.rawAttributes["DEFAULT"] = "1"
            }
        }
        project.modules.append(module)
        self.project = project
        self.selectedModuleId = id
        self.isDocumentEdited = true
        self.engine = installEngine(project: project)
        // A new SystemCmd is the Tris command (0x0302), as Dirigo makes one: it has pins to name and a command to send.
        if guid == SystemCmdBlock.guid, let tris = systemCommandCatalogue.first(where: { $0.command == 0x0302 }) {
            setSystemCommand(moduleId: id, to: tris)
        }
        return id
    }

    /// The middle of the visible canvas, in content coordinates.
    public func viewportCentreInCanvas() -> CGPoint {
        let scale = max(zoomScale, 0.01)
        return CGPoint(
            x: (viewportSize.width / 2 - panOffset.width) / scale,
            y: (viewportSize.height / 2 - panOffset.height) / scale
        )
    }

    // MARK: - Containers

    /// Puts a block into a branch of an `If` / `Switch` container (`nil` takes it out). Refuses anything that would
    /// make a container hold itself.
    public func setContainer(of id: Int, to container: (id: Int, arm: String)?) {
        guard var project, let index = project.modules.firstIndex(where: { $0.id == id }) else { return }
        if let container {
            guard container.id != id,
                  let owner = project.modules.first(where: { $0.id == container.id }),
                  ConstructContainers.isContainer(owner),
                  ConstructContainers.arms(of: owner).contains(where: { $0.id == container.arm }),
                  !ConstructContainers.wouldCycle(moving: id, into: container.id, in: project.modules) else { return }
            project.modules[index].rawAttributes["IN_CONTAINER"] = "\(container.id)"
            project.modules[index].rawAttributes["ARM"] = container.arm
        } else {
            project.modules[index].rawAttributes.removeValue(forKey: "IN_CONTAINER")
            project.modules[index].rawAttributes.removeValue(forKey: "ARM")
        }
        self.project = project
        isDocumentEdited = true
        self.engine = installEngine(project: project)
    }

    /// Replaces a switch container's cases and whether it has a default branch, as one undoable edit.
    ///
    /// Cases are matched by id, so a case whose values changed or that moved keeps its blocks. Blocks of a case
    /// that is gone — or of the default branch, if that is turned off — move to the default branch if there is
    /// one, and otherwise out of the switch onto the sheet. Nothing is deleted.
    public func setSwitchCases(of id: Int, to cases: [ConstructContainers.Case], hasDefault: Bool) {
        guard var project, let index = project.modules.firstIndex(where: { $0.id == id }),
              ConstructContainers.isContainer(project.modules[index]),
              project.modules[index].guid == ConstructContainers.switchGuid else { return }
        ConstructContainers.setCases(cases, of: &project.modules[index])
        project.modules[index].rawAttributes["DEFAULT"] = hasDefault ? "1" : "0"
        let owner = project.modules[index]
        for i in project.modules.indices where project.modules[i].rawAttributes["IN_CONTAINER"] == "\(id)" {
            let arm = project.modules[i].rawAttributes["ARM"] ?? ""
            if let home = ConstructContainers.rehome(arm: arm, in: owner) {
                project.modules[i].rawAttributes["ARM"] = home
            } else {
                project.modules[i].rawAttributes.removeValue(forKey: "IN_CONTAINER")
                project.modules[i].rawAttributes.removeValue(forKey: "ARM")
            }
        }
        self.project = project
        isDocumentEdited = true
        self.engine = installEngine(project: project)
    }

    /// Container, or not: the "Move into" entries of a block's menu.
    public func containerChoices(for id: Int) -> [(container: PCCModule, arm: ConstructContainers.Arm)] {
        guard let project else { return [] }
        return project.modules
            .filter { $0.page == selectedPage && $0.id != id && ConstructContainers.isContainer($0)
                      && !ConstructContainers.wouldCycle(moving: id, into: $0.id, in: project.modules) }
            .flatMap { owner in ConstructContainers.arms(of: owner).map { (container: owner, arm: $0) } }
    }

    /// Deletes a block and its cables. Undoable, so there is no confirmation step — that is what
    /// ⌘Z is for, and a modal on every delete gets tiresome fast.
    /// Applies a structural change to the runtime: rebuild the engine and mark the document edited.
    ///
    /// Call this *after* assigning `project`, because that setter is the single undo choke point and
    /// has already recorded history by the time we get here.
    func runtimeDidChangeStructure() {
        if let project { engine = installEngine(project: project) }
        isDocumentEdited = true
        refreshSnapshots()
    }

    public func deleteModule(id: Int) -> Bool {
        guard var project else { return false }
        guard project.deleteModule(id: id) != nil else { return false }

        self.project = project
        if selectedModuleId == id { selectedModuleId = nil }
        if configuringModuleId == id { configuringModuleId = nil }
        self.engine = installEngine(project: project)
        self.isDocumentEdited = true
        return true
    }

    /// Deletes whatever is selected.
    ///
    /// Only blocks on the page being shown: a selection survives switching pages, and must not delete
    /// something invisible from another one.
    public func deleteSelectedModule() {
        guard let selectedModuleId, var project else { return }
        let ids = selectedModuleIds.union([selectedModuleId])
        let onPage = project.modules.filter { ids.contains($0.id) && $0.page == selectedPage }.map(\.id)
        guard !onPage.isEmpty else { return }
        for id in onPage { _ = project.deleteModule(id: id) }
        // One edit and one engine rebuild for the whole group, not one per block.
        self.project = project
        self.selectedModuleId = nil
        if let configuringModuleId, onPage.contains(configuringModuleId) { self.configuringModuleId = nil }
        self.engine = installEngine(project: project)
        self.isDocumentEdited = true
    }

    /// Lays the current page out so signals flow left to right (`AutoLayout`), as one undoable edit.
    ///
    /// Hand-drawn wire routes on the page are reset too: they are offsets from the source pin, so they would
    /// no longer fit blocks that have moved. Text objects stay where they are.
    @MainActor
    public func organizeBlocks() {
        guard var project else { return }
        let onPage = project.modules.filter { $0.page == selectedPage }
        guard !onPage.isEmpty else { return }
        let ids = Set(onPage.map(\.id))
        let byId = Dictionary(onPage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let nodes = onPage.map {
            AutoLayout.Node(id: $0.id,
                            size: CGSize(width: ModuleCardView.cardWidth(for: $0),
                                         height: ModuleCardView.cardHeight(for: $0)),
                            order: $0.order)
        }
        let edges = project.inConnections
            .filter { ids.contains($0.outModuleId) && ids.contains($0.inModuleId) }
            .map { AutoLayout.Edge(from: $0.outModuleId, to: $0.inModuleId,
                                   fromPinY: ModuleCardView.outPinPoint(for: byId[$0.outModuleId]!, pinIndex: $0.outPinId).y
                                       - byId[$0.outModuleId]!.y,
                                   toPinY: ModuleCardView.inPinPoint(for: byId[$0.inModuleId]!, pinIndex: $0.inPinId).y
                                       - byId[$0.inModuleId]!.y) }
            + project.paramConnections
            .filter { ids.contains($0.outModuleId) && ids.contains($0.inModuleId) }
            .map { AutoLayout.Edge(from: $0.outModuleId, to: $0.inModuleId) }
        let origin = CGPoint(x: onPage.map(\.x).min()!, y: onPage.map(\.y).min()!)

        let placed = AutoLayout.positions(nodes: nodes, edges: edges, origin: origin)
        for index in project.modules.indices {
            guard let point = placed[project.modules[index].id] else { continue }
            project.modules[index].x = snapToGrid ? GridSnap.snap(point.x) : point.x
            project.modules[index].y = snapToGrid ? GridSnap.snap(point.y) : point.y
        }
        _ = project.resetWireRouting(onPage: selectedPage)
        self.project = project
        self.isDocumentEdited = true
    }

    /// Tidy hand-drawn wire routes on the current page back to Dirigo's default, mirroring the
    /// IDE's *Default points* command.
    @MainActor
    public func resetWireRouting() {
        guard var project else { return }
        let count = project.resetWireRouting(onPage: selectedPage)
        guard count > 0 else {
            presentMessage(title: "No hand-drawn wire routes",
                           message: "Every cable on this page already uses Dirigo's default routing.",
                           kind: .info)
            return
        }
        self.project = project
        self.isDocumentEdited = true
    }

    /// Writes a copy that the original Dirigo can open.
    ///
    /// The workspace here is unbounded, so the layout may not fit Dirigo's single A3 sheet. This
    /// translates it (and, as a last resort, scales it) onto the sheet and reports what it did.
    @MainActor
    public func exportForDirigo() {
        guard let project else { return }

        preparedExport = PaperSize.prepareForDirigo(project)
        pendingFilePanel = .export
    }

    /// What the export panel should suggest as a name — without the extension, which the panel adds.
    ///
    /// `.pcc` and `.pbd` are not types macOS knows, so a panel cannot tell that a suggested `x.pcc` already
    /// ends in its type's extension, and appends it again: `x.pcc.pcc`. The same holds for the names below.
    public var exportDefaultName: String {
        let base = currentFileURL?.deletingPathExtension().lastPathComponent
            ?? (project?.name ?? "project")
        return base + "-dirigo"
    }

    /// Writes the prepared export, once the user has chosen where.
    @MainActor
    public func finishExport(to url: URL) {
        guard project != nil, let result = preparedExport else { return }
        preparedExport = nil

        // Extra properties become Dirigo counterparts — or are removed — on export only. A normal
        // save keeps them, which is what lets a block be improved here and still hand back a project
        // the original can open.
        let translation = ExtraPropertyTranslator.translate(result.project,
                                                            declarations: ExtraPropertyCatalog.byGuid)

        // `If` / `Switch` containers become Dirigo's marker blocks, which is all the original knows.
        var output = ConstructContainers.expanded(translation.project)
        output.projectPath = url.path
        do {
            let xml = PCCSerializer().serialize(project: output)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError("Could not write \(url.lastPathComponent)", detail: error.localizedDescription)
            return
        }

        var notes = result.adjustments
        if let warning = result.warning { notes.append(warning) }
        notes.append(contentsOf: translation.notes)
        if notes.isEmpty {
            notes = ["The layout already fits an A3 sheet; nothing was moved."]
        }
        presentMessage(title: "Exported \(url.lastPathComponent)",
                       message: notes.joined(separator: "\n\n"),
                       kind: result.warning == nil ? .info : .warning)
    }

    @MainActor
    private func presentError(_ message: String, detail: String) {
        presentMessage(title: message, message: detail, kind: .warning)
    }

    @MainActor
    public func saveProjectAs() {
        guard project != nil else { return }
        pendingFilePanel = .saveAs

    }

    /// What the save panel should suggest as a name, without the extension (see `exportDefaultName`).
    public var saveAsDefaultName: String {
        let base = currentFileURL?.lastPathComponent
            ?? ((project?.name.isEmpty == false) ? project!.name : "Untitled")
        return base.hasSuffix(".pcc") ? String(base.dropLast(4)) : base
    }

    /// Called once the save panel has a destination.
    public func didChooseSaveURL(_ url: URL) {
        do {
            try saveProject(to: url)
        } catch {
            presentMessage(title: "Failed to save project",
                           message: error.localizedDescription,
                           kind: .critical)
        }
    }

    public func saveProject(to url: URL) throws {
        guard var project = project else { return }
        project.projectPath = url.path
        let serializer = PCCSerializer()
        let xmlString = serializer.serialize(project: project)
        try xmlString.write(to: url, atomically: true, encoding: .utf8)
        self.project = project
        self.currentFileURL = url
        self.isDocumentEdited = false
        savedContent = Self.content(of: project)
    }

    public func zoomIn(anchor: CGPoint? = nil) {
        zoomBy(factor: 1.25, anchor: anchor)
    }

    public func zoomOut(anchor: CGPoint? = nil) {
        zoomBy(factor: 0.8, anchor: anchor)
    }

    public func resetZoom() {
        noteZoomActivity()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            zoomScale = 1.0
            panOffset = CGSize(width: 40, height: 40)
            dragStartPan = panOffset
        }
    }

    public func zoomTo(_ targetZoom: CGFloat, anchor: CGPoint? = nil) {
        guard zoomScale > 0 else { return }
        let factor = targetZoom / zoomScale
        zoomBy(factor: factor, anchor: anchor)
    }

    public func zoomBy(factor: CGFloat, anchor: CGPoint? = nil) {
        // Counted before the no-op guard: a pinch that momentarily changes nothing is still an
        // active gesture, and must not let the sharpening kick in mid-gesture.
        noteZoomActivity()
        let oldZoom = zoomScale
        let newZoom = max(0.2, min(3.5, oldZoom * factor))
        guard newZoom != oldZoom else { return }

        let focus = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)

        let contentX = (focus.x - panOffset.width) / oldZoom
        let contentY = (focus.y - panOffset.height) / oldZoom

        panOffset.width = focus.x - contentX * newZoom
        panOffset.height = focus.y - contentY * newZoom
        dragStartPan = panOffset
        zoomScale = newZoom
        noteZoomActivity()
    }

    /// True once the zoom has been still for a moment.
    ///
    /// Card rasterisation is sharpened only while this is true. Changing a card's render scale
    /// re-rasterises it, so doing that mid-gesture re-renders all 57 cards in a single frame —
    /// measured as a 95 ms hitch on essentially every zoom step. Holding the sharpening until the
    /// gesture stops removes every spike from the interaction while keeping text crisp at rest.
    public private(set) var isZoomSettled = true
    private var zoomSettleTask: Task<Void, Never>?

    private func noteZoomActivity() {
        zoomSettleTask?.cancel()
        if isZoomSettled { isZoomSettled = false }
        zoomSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isZoomSettled = true
        }
    }

    /// Set when a project is loaded before the canvas knows its size.
    public var needsZoomToFit: Bool = false

    /// Called by the canvas once it has a real viewport size.
    public func performPendingZoomToFit() {
        guard needsZoomToFit, viewportSize.width > 80, viewportSize.height > 80 else { return }
        needsZoomToFit = false
        zoomToFit()
    }

    public func zoomToFit() {
        guard let project = project else {
            resetZoom()
            return
        }
        let pageModules = project.modules.filter { $0.page == selectedPage }
        guard !pageModules.isEmpty else {
            resetZoom()
            return
        }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for mod in pageModules {
            let w = Double(ModuleCardView.cardWidth(for: mod))
            let h = Double(ModuleCardView.cardHeight(for: mod))
            minX = min(minX, mod.x)
            minY = min(minY, mod.y)
            maxX = max(maxX, mod.x + w)
            maxY = max(maxY, mod.y + h)
        }

        let bboxW = CGFloat(maxX - minX)
        let bboxH = CGFloat(maxY - minY)
        guard bboxW > 0, bboxH > 0 else { return }

        let padding: CGFloat = 60.0
        let availW = max(100, viewportSize.width - padding * 2)
        let availH = max(100, viewportSize.height - padding * 2)

        let scaleX = availW / bboxW
        let scaleY = availH / bboxH
        let targetScale = max(0.25, min(1.8, min(scaleX, scaleY)))

        let targetPanX = (viewportSize.width - bboxW * targetScale) / 2.0 - CGFloat(minX) * targetScale
        let targetPanY = (viewportSize.height - bboxH * targetScale) / 2.0 - CGFloat(minY) * targetScale

        noteZoomActivity()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            zoomScale = targetScale
            panOffset = CGSize(width: targetPanX, height: targetPanY)
            dragStartPan = panOffset
        }
    }

    public func step() {
        guard engine != nil else { return }
        // One step is one execution: simulated time advances to the next thread that runs. A fixed project
        // cycle would usually reach no thread at all once threads keep their profile periods (a second, say).
        let cycle = Double(max(1, project?.appOptions.cycleDelay ?? 1))
        stepBackend(deltaMs: max(cycle, engine?.msUntilNextRun() ?? 0))
        simulationDidChange()
    }

    public func reset() {
        simulationTimerTask?.cancel()
        simulationTimerTask = nil
        isPlaying = false
        // Rebuilt from the document, not wound back block by block: every pin returns to the value the
        // file gives it, and the PLC's array area is cleared.
        if let project { engine = installEngine(project: project) }
        heldButtons = []
        tickCount = 0
        simulationDidChange()
    }

    public func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }


    public func play() {
        guard engine != nil else { return }
        isPlaying = true
        simulationTimerTask?.cancel()

        simulationTimerTask = Task { @MainActor [weak self] in
            var lastUIUpdateTime = ContinuousClock.now
            var lastStepTime = ContinuousClock.now
            var updatePending = false
            while !Task.isCancelled {
                guard let self = self, self.isPlaying else { break }
                // Step the engine the *views* read, re-read every iteration. Capturing it once
                // orphaned the loop the moment anything rebuilt the runtime (wiring a connection,
                // deleting a block, an undo): the tick counter kept advancing from the discarded
                // engine while the canvas drew values from the new one, so the workspace froze and
                // only moved when an interaction forced a repaint.
                guard let engine = self.engine else { break }

                // Step only when a thread is due. A project whose fastest thread runs once a second is
                // then stepped once a second, instead of twenty times for nothing — and the cycle is
                // given the wall-clock time that actually elapsed, so the simulation still advances in
                // real time however seldom it is stepped.
                let now = ContinuousClock.now
                let elapsedMs = Double((now - lastStepTime).components.seconds) * 1000
                    + Double((now - lastStepTime).components.attoseconds) / 1e15
                // Simulated time since the last step, and whether it reaches a thread. Calling `step` anyway would
                // count a tick and wake the UI every few milliseconds whatever the speed, with no thread running.
                let simulatedMs = elapsedMs * self.effectiveSpeed
                let untilRun = engine.msUntilNextRun()
                let ran = untilRun <= simulatedMs + 1e-9
                    ? stepBackend(deltaMs: simulatedMs)
                    : false
                if ran { lastStepTime = now }
                if updatePending && self.isAppActive && !ran && now - lastUIUpdateTime >= .milliseconds(28) {
                    self.simulationDidChange()
                    lastUIUpdateTime = now
                    updatePending = false
                }
                if ran {
                    self.tickCount = engine.tickCount
                    // Throttle UI property invalidations to ~30-40 Hz maximum to keep UI at solid 60fps
                    // without choking — but never *drop* one. Dropping is what a rare step cannot afford:
                    // a thread that runs once a second would have its single update swallowed by the
                    // frame budget, and the canvas would show the old values until the next second.
                    // Only ask SwiftUI to redraw when something can see it. The step above still ran, so
                    // no simulated time is lost — and one catch-up refresh happens on reactivation.
                    if !self.isAppActive {
                        updatePending = false
                    } else if now - lastUIUpdateTime >= .milliseconds(28) {
                        self.simulationDidChange()
                        lastUIUpdateTime = now
                        updatePending = false
                    } else {
                        updatePending = true
                    }
                }

                // Sleep until the next thread is due — in wall-clock time, so a slowed simulation waits longer —
                // never less than 2 ms and never longer than a second. A pending update caps the wait
                // instead, so it is delivered within one frame rather than one thread period.
                let untilRunNow = engine.msUntilNextRun()
                let sinceStep = Double((ContinuousClock.now - lastStepTime).components.seconds) * 1000
                    + Double((ContinuousClock.now - lastStepTime).components.attoseconds) / 1e15
                let remainingSimMs = max(0, untilRunNow - sinceStep * self.effectiveSpeed)
                var dueSec = min(max(remainingSimMs / 1000.0 / max(0.001, self.effectiveSpeed), 0.002), 1.0)
                if updatePending { dueSec = min(dueSec, 0.028) }
                try? await Task.sleep(nanoseconds: UInt64(dueSec * 1_000_000_000))
            }
        }
    }

    public func pause() {
        isPlaying = false
        simulationTimerTask?.cancel()
        simulationTimerTask = nil
    }

    /// `Profiles.ini`, read once. A profile gives each thread its real period (`Timer 1s` every
    /// 1000 ms, `Tick` every 71 ms, `Idle` every 50 ms), which is what lets the play loop sleep instead
    /// of waking twenty times a second whether or not anything is due.
    private static let profileDatabase = ProfileRegistry.load()

    /// Builds the runtime with the project's profile, so scheduling follows the hardware rather than a
    /// fixed cadence. Falls back to the project's `CYCLE_DELAY` when no profile matches, which is the
    /// same period for every thread.
    private func installEngine(project: PCCProject) -> CxxSimulationCore {
        let profile = Self.profileDatabase.flatMap { ProfileRegistry.profile(for: project, in: $0) }
        return CxxSimulationCore(project: project, profile: profile, profileScheduling: true)
    }

    /// A module's live pins, read out of the core.
    public func getNode(id: Int) -> RuntimeNode? {
        guard let engine, engine.contains(moduleId: id),
              let module = engine.runtimeModules.first(where: { $0.id == id }) else { return nil }
        return RuntimeNode(module: module, block: RuntimePins(inPins: engine.inPins(moduleId: id),
                                                              paramPins: engine.paramPins(moduleId: id),
                                                              outPins: engine.outPins(moduleId: id)))
    }

    /// Rebuilds the core after a block changed shape (an input or output count), carrying every pin value
    /// the document gives across — the same as any other structural edit.
    private func rebuildAfterShapeChange() {
        if let project { engine = installEngine(project: project) }
        simulationDidChange()
    }

    /// Moves a module. The workspace is unbounded — Dirigo's fixed A3 sheet is only a *reference*
    /// here; `exportForDirigo()` is what reconciles an oversized layout with it.
    public func updateModulePosition(id: Int, deltaX: Double, deltaY: Double, snapped: Bool = true) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        let moved = (snapped ? snappedPosition(id: id, deltaX: deltaX, deltaY: deltaY) : nil) ?? CGPoint(
            x: project!.modules[idx].x + deltaX, y: project!.modules[idx].y + deltaY)
        project?.modules[idx].x = moved.x
        project?.modules[idx].y = moved.y
    }

    /// Light, dark or follow the system. Remembered between launches.
    var appearance: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    /// Moves `ids` together by a drag of `lead`: the lead block lands where `updateModulePosition` would put it
    /// (snapped, if on) and the others shift by the same amount.
    public func moveModules(_ ids: Set<Int>, lead: Int, deltaX: Double, deltaY: Double) {
        guard let leadModule = project?.modules.first(where: { $0.id == lead }) else { return }
        let before = CGPoint(x: leadModule.x, y: leadModule.y)
        updateModulePosition(id: lead, deltaX: deltaX, deltaY: deltaY)
        guard let after = project?.modules.first(where: { $0.id == lead }) else { return }
        for id in ids where id != lead {
            updateModulePosition(id: id, deltaX: after.x - before.x, deltaY: after.y - before.y, snapped: false)
        }
    }

    /// Whether the scroll wheel zooms (otherwise it pans). Remembered between launches.
    public var scrollZooms: Bool = UserDefaults.standard.object(forKey: "scrollZooms") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scrollZooms, forKey: "scrollZooms") }
    }

    /// Whether module moves and new blocks land on the canvas grid. Remembered between launches.
    public var snapToGrid: Bool = UserDefaults.standard.object(forKey: "snapToGrid") as? Bool ?? false {
        didSet { UserDefaults.standard.set(snapToGrid, forKey: "snapToGrid") }
    }

    /// Where a module ends up when moved by a delta with snapping on; `nil` when snapping is off.
    public func snappedPosition(id: Int, deltaX: Double, deltaY: Double) -> CGPoint? {
        guard snapToGrid, let module = project?.modules.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: GridSnap.snap(module.x + deltaX), y: GridSnap.snap(module.y + deltaY))
    }

    public var configuringModuleId: Int? = nil

    public func openConfigureModule(id: Int) {
        self.configuringModuleId = id
        self.selectedModuleId = id
    }

    public func closeConfigureModule() {
        self.configuringModuleId = nil
    }

    public func updateBoolVarMode(id: Int, mode: BoolVarBlock.Mode) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].simulMode = mode.rawValue
        project?.modules[idx].rawAttributes["SimulMode"] = "\(mode.rawValue)"
        // The mode is the module's, read from the document whenever the button is pressed; the core only
        // runs out pulses, so it has nothing to update.
        heldButtons.remove(id)
        self.isDocumentEdited = true
        simulationDidChange()
    }

    /// Writes one **input** pin: the runtime block, and the document, so the change is saved the way a
    /// parameter edit is. Then it makes the change visible straight away rather than at the next tick,
    /// on whichever backend is running — while paused that means one step, and while playing the value is
    /// simply pushed into the core for the next one.
    /// A pin of a module, for `clearedPinValues`.
    struct PinKey: Hashable {
        var module: Int
        var pin: Int
    }

    /// The value an input pin had when a click cleared it, so the next click restores it. Only for this
    /// session: a typed value replaces it, and a new document starts without any.
    private var clearedPinValues: [PinKey: PinValue] = [:]

    public func setModuleInput(moduleId: Int, pinIndex: Int, value: PinValue) {
        // A value written directly is the new one to come back to, not the one cleared before it.
        clearedPinValues[PinKey(module: moduleId, pin: pinIndex)] = nil
        // `pinIndex >= 0` is not decoration: every one of these guards used to check only the upper
        // bound, so a negative index passed it and subscripted the arrays out of bounds — a trap, not a
        // wrong value. See `rejectsOutOfRangePinIndices`.
        guard pinIndex >= 0 else { return }
        guard let idx = project?.modules.firstIndex(where: { $0.id == moduleId }) else { return }
        if pinIndex < (project?.modules[idx].inPins.count ?? 0) {
            project?.modules[idx].inPins[pinIndex].value = value
        }
        engine?.setIn(moduleId: moduleId, pin: pinIndex, value: value)
        isDocumentEdited = true
        refreshAfterPinEdit()
    }

    /// The same for an **output** pin a person drives directly: a `BoolVar`'s switch, an `8xDI` channel.
    /// Writing an output clears any pulse still running on it, as `BoolVarBlock.setOutput` does.
    public func setModuleOutput(moduleId: Int, pinIndex: Int, value: PinValue) {
        guard pinIndex >= 0, let node = getNode(id: moduleId), pinIndex < node.block.outPins.count else { return }
        engine?.setOut(moduleId: moduleId, pin: pinIndex, value: value)
        refreshAfterPinEdit()
    }

    /// Sets a variable block's value by hand (`IntVar`). The value is the block's state, so the core writes
    /// it into the variable itself, not only onto the output pin the variable would overwrite on its next pass.
    public func setVariableValue(moduleId: Int, value: Int) {
        guard let module = module(id: moduleId), BlockRole.isIntVariable(module) else { return }
        engine?.setOut(moduleId: moduleId, pin: 0, value: .int32(Int32(truncatingIfNeeded: value)))
        refreshAfterPinEdit()
    }

    /// The same for a `FloatVar`.
    public func setFloatVariableValue(moduleId: Int, value: Float) {
        guard let module = module(id: moduleId), BlockRole.isFloatVariable(module) else { return }
        engine?.setOut(moduleId: moduleId, pin: 0, value: .float(value))
        refreshAfterPinEdit()
    }

    /// Re-propagates and, when the simulation is not running, evaluates every thread once so an edit shows up
    /// now. A plain step would not: with the profile's periods, the edited block's thread may not be due for
    /// another second.
    private func refreshAfterPinEdit() {
        engine?.propagate()
        if !isPlaying, let engine {
            engine.evaluateNow(now: now())
            tickCount = engine.tickCount
        }
        simulationDidChange()
    }

    static func zero(like value: PinValue) -> PinValue {
        switch value {
        case .int16: return .int16(0)
        case .int32: return .int32(0)
        case .int64: return .int64(0)
        case .float: return .float(0)
        default: return .bool(false)
        }
    }

    static func one(like value: PinValue) -> PinValue {
        switch value {
        case .int16: return .int16(1)
        case .int32: return .int32(1)
        case .int64: return .int64(1)
        case .float: return .float(1)
        default: return .bool(true)
        }
    }

    public func updateModuleParam(id: Int, paramIndex: Int, value: PinValue) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        if paramIndex < (project?.modules[idx].paramPins.count ?? 0) {
            project?.modules[idx].paramPins[paramIndex].value = value
        }
        engine?.setParam(moduleId: id, pin: paramIndex, value: value)
        self.isDocumentEdited = true
        // Through the same path as every other edit: what reads the parameter is recomputed now, not at the next tick.
        refreshAfterPinEdit()
    }

    /// Passes a module's attribute-driven configuration (a timer's `MODE`) to the running core.
    public func reconfigureModule(id: Int) {
        if let module = module(id: id) { engine?.reconfigure(module: module) }
        simulationDidChange()
    }

    /// One block's own reset — its state and outputs, keeping its inputs — as the inspector's Reset asks.
    public func resetModuleState(id: Int) {
        engine?.resetModule(moduleId: id)
        heldButtons.remove(id)
        simulationDidChange()
    }

    public func updatePulseGenTiming(id: Int, tOn: Int, tOff: Int) {
        updateModuleParam(id: id, paramIndex: 0, value: .int32(Int32(tOn)))
        updateModuleParam(id: id, paramIndex: 1, value: .int32(Int32(tOff)))
    }

    public func updateCounterStep(id: Int, step: Int) {
        updateModuleParam(id: id, paramIndex: 0, value: .int32(Int32(step)))
    }

    // MARK: - Presenting

    /// A message waiting to be shown.
    ///
    /// The model never opens a window of its own: it records what should be said and a view presents
    /// it. That is what keeps this file free of AppKit.
    public struct PendingAlert: Identifiable, Equatable {
        public enum Kind: Equatable { case info, warning, critical }
        public let id = UUID()
        public var title: String
        public var message: String
        public var kind: Kind
    }

    public var pendingAlert: PendingAlert?

    /// The export prepared while the user picks a destination.
    private var preparedExport: DirigoExport?

    /// A file panel the user has asked for, for the same reason.
    public enum FilePanel: Equatable {
        case open, saveAs, export, uploadProgram
        /// The build's two exports, and the template it can read.
        case exportProgramBinary, exportSymbolTable, importBuildTemplate
    }
    public var pendingFilePanel: FilePanel?

    /// Shows a message.
    public func presentMessage(title: String, message: String, kind: PendingAlert.Kind = .warning) {
        pendingAlert = PendingAlert(title: title, message: message, kind: kind)
    }

    // MARK: - Search

    /// What the sidebar's search box contains.
    ///
    /// It searches *blocks*, not pages: typing a block type or an instance name highlights the
    /// matches on the sheet instead of hiding everything that does not match.
    public var blockSearchText: String = ""

    private var searchQuery: String {
        blockSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a block matches the current search — by instance name, block type, the original
    /// Delphi class, or its category.
    public func moduleMatchesSearch(_ module: PCCModule) -> Bool {
        let query = searchQuery
        guard !query.isEmpty else { return false }
        let info = BlockTypeCatalog.info(forGuid: module.guid)
        let fields = [module.name, info?.blockName ?? "", info?.delphiClass ?? "", info?.category ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Matches on the page being shown — the ones the canvas can actually highlight.
    public var highlightedModuleIds: Set<Int> {
        guard !searchQuery.isEmpty, let project else { return [] }
        return Set(project.modules
            .filter { $0.page == selectedPage && moduleMatchesSearch($0) }
            .map(\.id))
    }

    /// Matches anywhere in the project, so the sidebar can say when hits are on another page.
    public var blockSearchMatchCount: Int {
        guard !searchQuery.isEmpty, let project else { return 0 }
        return project.modules.filter { moduleMatchesSearch($0) }.count
    }

    // MARK: - Sheet text

    /// The text object being edited, and the one selected, as indices into `project.graphics`.
    ///
    /// A graphic has no id of its own, so an index is the only handle there is. It stays valid for as
    /// long as the array is not restructured, and every path that restructures it clears these.
    public var selectedAnnotationIndex: Int? {
        // As with blocks: selecting a text object outside the marquee group (or nothing) ends the group.
        didSet { if let i = selectedAnnotationIndex, selectedAnnotationIndices.contains(i) { return }; selectedAnnotationIndices = [] }
    }
    /// Text objects picked together with the selection rectangle. Empty for a plain selection.
    public var selectedAnnotationIndices: Set<Int> = []
    public var editingAnnotationIndex: Int?

    /// Drops every text selection — for when the graphics array is replaced and the indices mean nothing.
    private func clearAnnotationSelection() {
        selectedAnnotationIndex = nil
        selectedAnnotationIndices = []
        editingAnnotationIndex = nil
    }

    /// The text objects on a page, each with the index it has in the project's array — which is what
    /// the canvas needs in order to select or delete one.
    public func textAnnotations(onPage page: String) -> [(index: Int, graphic: ProjectGraphic)] {
        (project?.graphics ?? []).enumerated().compactMap { offset, graphic in
            guard graphic.page == page, graphic.text != nil else { return nil }
            return (index: offset, graphic: graphic)
        }
    }

    public func beginEditingAnnotation(at index: Int) {
        guard project?.graphics.indices.contains(index) == true else { return }
        selectedAnnotationIndex = index
        editingAnnotationIndex = index
    }

    /// Adds a text object at a point in canvas coordinates — the middle of the view when omitted —
    /// and opens it for editing, because an object you cannot type into is not much use.
    @discardableResult
    public func addTextAnnotation(_ text: String = "A", at point: CGPoint? = nil) -> Int? {
        guard var project else { return nil }
        let spot = point ?? viewportCentreInCanvas()
        project.graphics.append(
            PCCGraphicBuilder.text(text,
                                   at: RoutePoint(x: Double(spot.x), y: Double(spot.y)),
                                   page: selectedPage)
        )
        self.project = project
        isDocumentEdited = true

        let index = project.graphics.count - 1
        selectedAnnotationIndex = index
        editingAnnotationIndex = index
        return index
    }

    /// Sets a text object's character. An empty string is refused: the object would still be in the
    /// document but nothing would be drawn, leaving an invisible thing to find and delete.
    public func updateAnnotationText(at index: Int, text: String) {
        guard var project, project.graphics.indices.contains(index) else { return }
        guard !text.isEmpty else { return }
        guard project.graphics[index].text != text else { return }
        project.graphics[index].text = text
        self.project = project
        isDocumentEdited = true
    }

    public func deleteAnnotation(at index: Int) {
        guard var project, project.graphics.indices.contains(index) else { return }
        project.graphics.remove(at: index)
        self.project = project
        selectedAnnotationIndex = nil
        editingAnnotationIndex = nil
        isDocumentEdited = true
    }

    /// Deletes the selected text object, and only if it belongs to the page being shown — otherwise a
    /// selection made on one page could delete something invisible from another.
    public func deleteSelectedAnnotation() {
        guard let index = selectedAnnotationIndex,
              let project,
              project.graphics.indices.contains(index),
              project.graphics[index].page == selectedPage else { return }
        // Highest index first, so the removals do not shift the ones still to go.
        for i in selectedAnnotationIndices.union([index]).sorted(by: >) { deleteAnnotation(at: i) }
    }

    // MARK: - Pages

    /// Adds a page, selecting it.
    ///
    /// A page's caption is what every block on it references, so captions must be unique. A clashing
    /// name is given a numeric suffix rather than silently merging two pages into one.
    @discardableResult
    public func addPage(caption: String, isMacro: Bool = false) -> String? {
        guard var project else { return nil }
        var base = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = isMacro ? "Macro" : "Page" }
        if isMacro, !base.hasPrefix("*") { base = "*" + base }

        var candidate = base
        var suffix = 2
        while project.pages.contains(where: { $0.caption == candidate }) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }

        project.pages.append(ProjectPage(caption: candidate))
        self.project = project
        selectedPage = candidate
        isDocumentEdited = true
        return candidate
    }

    /// How many blocks sit on a page.
    public func moduleCount(onPage caption: String) -> Int {
        project?.modules.filter { $0.page == caption }.count ?? 0
    }

    /// Deletes a page together with everything on it.
    ///
    /// Blocks reference their page by caption, so leaving them behind would strand them: no sheet
    /// draws them, no export places them, but they stay in the file. They go too, with their cables.
    /// The last page is never removed — a project with no pages has nowhere to put a block.
    @discardableResult
    public func deletePage(caption: String) -> Bool {
        guard var project else { return false }
        guard project.pages.count > 1 else { return false }
        guard let index = project.pages.firstIndex(where: { $0.caption == caption }) else { return false }

        for module in project.modules where module.page == caption {
            _ = project.deleteModule(id: module.id)
        }
        project.graphics.removeAll { $0.page == caption }
        project.pages.remove(at: index)
        self.project = project

        if selectedPage == caption {
            selectedPage = project.pages.first?.caption ?? "main"
        }
        if let selectedModuleId, project.modules.first(where: { $0.id == selectedModuleId }) == nil {
            self.selectedModuleId = nil
        }
        isDocumentEdited = true
        runtimeDidChangeStructure()
        return true
    }

    /// Module ids on a thread, in the order the runtime will execute them.
    public func executionOrder(forThread threadId: Int) -> [Int] {
        engine?.executionOrder(forThread: threadId) ?? []
    }

    /// The module whose name is being edited on the canvas, if any.
    public var renamingModuleId: Int?

    /// Renames a module.
    ///
    /// Rebuilds the runtime: the registry falls back to name matching for a few types (`Inputs` and
    /// `Outputs` share a GUID, and some blocks are recognised by a word in the name), so a rename can
    /// change which block is built.
    public func renameModule(id: Int, name: String) {
        defer { renamingModuleId = nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = project?.modules.firstIndex(where: { $0.id == id }),
              project?.modules[index].name != trimmed else { return }
        project?.modules[index].name = trimmed
        runtimeDidChangeStructure()
    }

    /// The module with this id, if it is still in the document.
    public func module(id: Int) -> PCCModule? {
        project?.modules.first { $0.id == id }
    }

    /// Moves a module to another thread.
    ///
    /// The runtime files every module under its thread, so this has to
    /// rebuild it — a plain field write would leave the block running on its old thread until some
    /// other edit happened to rebuild.
    public func updateModuleThread(id: Int, threadId: Int) {
        guard let index = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(31, threadId))
        guard project?.modules[index].threadId != clamped else { return }
        project?.modules[index].threadId = clamped
        runtimeDidChangeStructure()
    }

    /// Changes where a module sits in its thread's execution order.
    ///
    /// Within a thread, blocks run in ascending `ORDER`, so this re-sorts the schedule and therefore
    /// rebuilds it too.
    public func updateModuleOrder(id: Int, order: Int) {
        guard let index = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(9999, order))
        guard project?.modules[index].order != clamped else { return }
        project?.modules[index].order = clamped
        runtimeDidChangeStructure()
    }

    public func setModuleRawAttribute(id: Int, key: String, value: String) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].rawAttributes[key] = value
        self.isDocumentEdited = true
        simulationDidChange()
    }

    public func updateDivModuloVisible(id: Int, isVisible: Bool) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].rawAttributes["MODULO_VISIBLE"] = isVisible ? "True" : "False"
        // Ensure outPins count in module aligns with visibility
        if isVisible {
            while (project?.modules[idx].outPins.count ?? 0) < 2 {
                project?.modules[idx].outPins.append(Pin(id: project?.modules[idx].outPins.count ?? 1, value: .int32(0)))
            }
        } else {
            // Keep at least 1 (quotient Y)
            if (project?.modules[idx].outPins.count ?? 0) > 1 {
                // If no connection uses pin 1, trim or keep pin count
                let hasWireOnMod = project?.inConnections.contains(where: { $0.outModuleId == id && $0.outPinId == 1 }) ?? false
                if !hasWireOnMod {
                    project?.modules[idx].outPins.removeSubrange(1...)
                }
            }
        }
        self.isDocumentEdited = true
        simulationDidChange()
    }

    public func updateRSPriority(id: Int, higherPriorityS: Bool) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        let priVal = higherPriorityS ? "S" : "R"
        project?.modules[idx].rawAttributes["PRIORITY"] = priVal
        project?.modules[idx].rawAttributes["RS_PRIORITY"] = priVal
        if let module = project?.modules[idx] { engine?.reconfigure(module: module) }
        self.isDocumentEdited = true
        simulationDidChange()
    }

    public func updateModuleInputCount(id: Int, count: Int) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].rawAttributes["INPUT_COUNT"] = "\(count)"
        // For ISwitch, inPins = En (0), Sw (1), X0...X(count-1) -> total count + 2
        // For And/Or/Xor, inPins = En (0), X0...X(count-1) -> total count + 1
        let isSwitch = project?.modules[idx].name.lowercased().contains("switch") ?? false
        let totalNeeded = isSwitch ? (count + 2) : (count + 1)
        
        while (project?.modules[idx].inPins.count ?? 0) < totalNeeded {
            let nextId = project?.modules[idx].inPins.count ?? 0
            let defVal: PinValue = isSwitch ? (nextId == 0 ? .bool(true) : .int32(0)) : (nextId == 0 ? .bool(true) : .bool(false))
            project?.modules[idx].inPins.append(Pin(id: nextId, value: defVal))
        }
        if (project?.modules[idx].inPins.count ?? 0) > totalNeeded {
            // Only trim if not connected
            let hasWire = project?.inConnections.contains(where: { $0.inModuleId == id && $0.inPinId >= totalNeeded }) ?? false
            if !hasWire {
                project?.modules[idx].inPins.removeSubrange(totalNeeded...)
            }
        }
        
        self.isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    public func updateModuleOutputCount(id: Int, count: Int) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].rawAttributes["OUTPUT_COUNT"] = "\(count)"
        
        while (project?.modules[idx].outPins.count ?? 0) < count {
            let nextId = project?.modules[idx].outPins.count ?? 0
            project?.modules[idx].outPins.append(Pin(id: nextId, value: .bool(false)))
        }
        if (project?.modules[idx].outPins.count ?? 0) > count {
            let hasWire = project?.inConnections.contains(where: { $0.outModuleId == id && $0.outPinId >= count }) ?? false
            if !hasWire {
                project?.modules[idx].outPins.removeSubrange(count...)
            }
        }
        
        self.isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    public func update8xDIMask(id: Int, maskHex: String, showWord: Bool) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
        project?.modules[idx].rawAttributes["PIN_MASK"] = maskHex
        if showWord {
            project?.modules[idx].rawAttributes["PIN_ALL_VISIBLE"] = "True"
        } else {
            project?.modules[idx].rawAttributes.removeValue(forKey: "PIN_ALL_VISIBLE")
        }
        self.isDocumentEdited = true
        simulationDidChange()
    }

    /// Applies a digital-output block's channel count and hidden mask, and keeps the module's pins in step with
    /// them: `En` plus one pin per visible channel, in channel order. A channel that stays visible keeps its
    /// pin, value and wires; a hidden one loses them; a newly visible one starts at 0.
    public func update8xDOConfig(id: Int, pinCount: Int, hiddenMaskHex: String) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }),
              let module = project?.modules[idx] else { return }
        func visible(_ count: Int, _ mask: Int) -> [Int] {
            (0..<max(0, count)).filter { $0 >= 16 || mask & (1 << $0) == 0 }
        }
        let oldVisible: [Int]
        if let rawCount = module.rawAttributes["PIN_COUNT"].flatMap({ Int($0) }) {
            oldVisible = visible(rawCount, module.rawAttributes["HIDDEN_PIN_MASK"].map(PinMask.parse) ?? 0)
        } else {
            oldVisible = Array(0..<max(0, module.inPins.count - 1))
        }
        let newVisible = visible(pinCount, PinMask.parse(hiddenMaskHex))

        var newPins: [Pin] = module.inPins.isEmpty ? [Pin(id: 0, value: .bool(true))] : [module.inPins[0]]
        var indexMap: [Int: Int] = [0: 0]
        for (position, channel) in newVisible.enumerated() {
            let newIndex = position + 1
            if let old = oldVisible.firstIndex(of: channel), old + 1 < module.inPins.count {
                var pin = module.inPins[old + 1]
                pin.id = newIndex
                newPins.append(pin)
                indexMap[old + 1] = newIndex
            } else {
                newPins.append(Pin(id: newIndex, value: .bool(false)))
            }
        }
        project?.inConnections = (project?.inConnections ?? []).compactMap { connection in
            guard connection.inModuleId == id, !connection.isParam else { return connection }
            guard let moved = indexMap[connection.inPinId] else { return nil }   // its channel is hidden now
            var kept = connection
            kept.inPinId = moved
            return kept
        }
        project?.modules[idx].inPins = newPins
        project?.modules[idx].rawAttributes["PIN_COUNT"] = "\(pinCount)"
        project?.modules[idx].rawAttributes["HIDDEN_PIN_MASK"] = hiddenMaskHex
        self.isDocumentEdited = true
        rebuildAfterShapeChange()
    }

    public func toggleModuleInput(moduleId: Int, pinIndex: Int) {
        // A negative index used to reach `inPins[pinIndex]` below and trap.
        guard pinIndex >= 0, let node = getNode(id: moduleId) else { return }
        if let mode = BlockRole.boolVarMode(of: node.module) {
            // `BoolVarBlock.trigger`: a push button gives a two-cycle pulse, a switch flips.
            if mode == .pushButton {
                engine?.pulseOut(moduleId: moduleId, pin: 0, cycles: 2)
            } else {
                engine?.setOut(moduleId: moduleId, pin: 0, value: .bool(!(node.block.outPins.first?.asBool ?? false)))
            }
        } else if BlockRole.hasClickableOutputs(node.module) {
            // The macro `Inputs` interface and `8xDI` are driven on their outputs.
            guard pinIndex < node.block.outPins.count else { return }
            engine?.setOut(moduleId: moduleId, pin: pinIndex, value: .bool(!node.block.outPins[pinIndex].asBool))
        } else if pinIndex < node.block.inPins.count {
            // A click clears a set pin and sets a clear one, keeping the value's *kind* so a switch's
            // `X3 = 8` becomes `0` — and the next click brings the `8` back, not a `1`.
            let current = node.block.inPins[pinIndex]
            let key = PinKey(module: moduleId, pin: pinIndex)
            let next = current.asBool ? Self.zero(like: current) : (clearedPinValues[key] ?? Self.one(like: current))
            setModuleInput(moduleId: moduleId, pinIndex: pinIndex, value: next)
            if current.asBool { clearedPinValues[key] = current }
            return
        } else if pinIndex < node.block.outPins.count {
            engine?.setOut(moduleId: moduleId, pin: pinIndex, value: .bool(!node.block.outPins[pinIndex].asBool))
        }
        refreshAfterPinEdit()
    }

    /// Reports a momentary control being held down or let go.
    ///
    /// Kept separate from `toggleModuleInput` because a push button's value is the *duration* of
    /// the press, which a single call cannot express.
    public func setModuleInputPressed(moduleId: Int, pinIndex: Int, isPressed: Bool) {
        guard let node = getNode(id: moduleId) else { return }
        if let mode = BlockRole.boolVarMode(of: node.module) {
            // `BoolVarBlock.press` / `release`: a held push button is high for as long as it is held; a
            // switch flips on the press and ignores the release.
            if mode == .pushButton {
                if isPressed {
                    heldButtons.insert(moduleId)
                    engine?.setOut(moduleId: moduleId, pin: 0, value: .bool(true))
                } else {
                    guard heldButtons.remove(moduleId) != nil else { return }
                    engine?.setOut(moduleId: moduleId, pin: 0, value: .bool(false))
                }
            } else if isPressed {
                engine?.setOut(moduleId: moduleId, pin: 0, value: .bool(!(node.block.outPins.first?.asBool ?? false)))
            } else {
                return
            }
        } else if isPressed {
            // Everything else is a latch, so a press is the whole interaction.
            toggleModuleInput(moduleId: moduleId, pinIndex: pinIndex)
            return
        } else {
            return
        }
        refreshAfterPinEdit()
    }

    public func connectHardware() {
        guard !selectedPortPath.isEmpty else { return }
        do {
            // 57600 and even parity are the *Unit config* settings; see docs/plc-protocol.md.
            try serialPort.open(path: selectedPortPath, baudRate: 57600, parity: .even)
            isHardwareConnected = true
        } catch {
            print("Hardware connection failed: \(error)")
            isHardwareConnected = false
        }
    }

    public func disconnectHardware() {
        serialPort.close()
        isHardwareConnected = false
    }

    // MARK: - Building the project

    /// What a build produced, and where its header came from.
    ///
    /// The compiling, the counts and the wording all come from `PLCProjectBuild` in DirigoHardware — the
    /// same type `dirigo-cli build` uses — so this only adds what is the app's: the template it remembered
    /// and the program binary ready to be written.
    public struct BuildReport {
        public var build: PLCProjectBuild
        public var templateNote: String
        public var programBinary: [UInt8]

        public var moduleCount: Int { build.report.moduleCount }
        public var compiledModules: Int { build.report.compiledModules }
        public var displayModules: Int { build.report.displayModules }
        public var recordBytes: Int { build.report.recordBytes }
        public var dataSlots: Int { build.report.dataSlots }
        public var terminals: Int { build.report.terminals }
        public var symbolRows: Int { build.report.symbolRows }
        public var unshaped: [String] { build.report.unshaped }
        public var unshapedModules: [String] { build.report.unshapedModules }
        public var macros: [String] { build.report.macros }
        public var table: [UInt8] { build.table }
        public var symbolCSV: String { build.symbolCSV }

        public var summary: String {
            ([templateNote] + build.report.lines).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// The last build, kept so the exporters and the report sheet can use it without recompiling.
    public var buildReport: BuildReport?
    /// Whether the report sheet is up.
    public var isShowingBuildReport = false

    /// Whether builds run the optimising pass (`PLCProgramOptimizer`): records in dataflow order, unread or switched-off logic and math dropped.
    /// On by default; remembered between launches.
    public var optimizeProgram: Bool = UserDefaults.standard.object(forKey: "optimizeProgram") as? Bool ?? true {
        didSet { UserDefaults.standard.set(optimizeProgram, forKey: "optimizeProgram") }
    }

    /// The program binary the user imported, if any: the build takes its table and header from it.
    private var buildTemplateImage: PLCProgramImage?

    /// The template the next build fills in — an imported `.pbd` when there is one, otherwise the blank
    /// table `PLCProgramTable.buildTemplate()` describes.
    private func buildTemplate() -> PLCProgramTable? {
        buildTemplateImage.flatMap(PLCProgramTable.from(image:)) ?? PLCProgramTable.buildTemplate()
    }

    /// Compiles the project as it stands. Returns the report, and stores it.
    @discardableResult
    @MainActor
    public func compileProject() -> BuildReport? {
        guard let project else {
            presentMessage(title: "Nothing to build", message: "Open a project first.")
            return nil
        }
        guard let template = buildTemplate() else {
            presentMessage(title: "Could not prepare a program table",
                           message: "The build template is not a 256-byte table.")
            return nil
        }
        let xml = PCCSerializer().serialize(project: ConstructContainers.expanded(project))
        do {
            let build = try PLCProjectBuild.compile(xml: xml,
                                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                    template: template, optimize: optimizeProgram)
            let name = currentFileURL?.lastPathComponent ?? (project.name + ".pcc")
            let binary = try PLCProgramImage.programBinary(table: build.table, projectName: name,
                                                           header: buildTemplateImage?.header)
            let report = BuildReport(
                build: build,
                templateNote: buildTemplateImage == nil ? "" : "Header from the imported .pbd.",
                programBinary: binary)
            buildReport = report
            return report
        } catch {
            presentMessage(title: "Build failed", message: String(describing: error))
            return nil
        }
    }

    /// Compiles, then shows the report.
    @MainActor
    public func buildAndShowReport() {
        if compileProject() != nil { isShowingBuildReport = true }
    }

    /// Writes the compiled program binary (`.pbd`).
    @MainActor
    public func exportCompiledProgram() {
        guard compileProject() != nil else { return }
        pendingFilePanel = .exportProgramBinary
    }

    /// Writes the compiled symbol table (`.csv`).
    @MainActor
    public func exportSymbolTable() {
        guard compileProject() != nil else { return }
        pendingFilePanel = .exportSymbolTable
    }

    /// Uploads what the compiler just produced, rather than a file.
    @MainActor
    public func uploadCompiledProgram() {
        guard let report = compileProject() else { return }
        guard let table = try? PLCProgramTable(bytes: report.table) else { return }
        isUploading = true
        Task { await upload(table: table) }
    }

    /// The name the program-binary panel suggests, without the extension (see `exportDefaultName`).
    public var programBinaryDefaultName: String {
        currentFileURL?.deletingPathExtension().lastPathComponent ?? (project?.name ?? "program")
    }

    /// The name the symbol-table panel suggests.
    public var symbolTableDefaultName: String {
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? (project?.name ?? "program")
        return base + ".csv"
    }

    /// Writes the built program binary once the user has chosen where.
    @MainActor
    public func finishProgramBinaryExport(to url: URL) {
        guard let report = buildReport else { return }
        do {
            try Data(report.programBinary).write(to: url, options: .atomic)
            presentMessage(title: "Exported \(url.lastPathComponent)",
                           message: "\(report.compiledModules) modules, "
                                    + "\(report.table.count) bytes of table.",
                           kind: .info)
        } catch {
            presentError("Could not write \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }

    /// Writes the built symbol table once the user has chosen where.
    @MainActor
    public func finishSymbolTableExport(to url: URL) {
        guard let report = buildReport else { return }
        do {
            try report.symbolCSV.write(to: url, atomically: true, encoding: .utf8)
            presentMessage(title: "Exported \(url.lastPathComponent)",
                           message: "\(report.symbolRows) symbol row(s).", kind: .info)
        } catch {
            presentError("Could not write \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }

    /// Reads a `.pbd` to use as the build template: its table is filled in, and its header is carried
    /// through to the next export.
    @MainActor
    public func loadBuildTemplate(from url: URL) {
        do {
            let image = try PLCProgramImage.load(contentsOf: url)
            guard image.blocks.contains(where: { $0.id == PLCProgramImage.programTableSection }) else {
                presentMessage(title: "No program table in \(url.lastPathComponent)",
                               message: "A program binary needs a 525 section.")
                return
            }
            buildTemplateImage = image
            buildReport = nil
            presentMessage(title: "Using \(url.lastPathComponent) as the build template",
                           message: "The table's header and profile come from it now.", kind: .info)
        } catch {
            presentError("Could not read \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }

    /// Asks for a `.pbd` to use as the build template.
    public func chooseBuildTemplate() { pendingFilePanel = .importBuildTemplate }
}
