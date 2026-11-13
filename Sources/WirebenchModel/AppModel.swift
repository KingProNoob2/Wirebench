import Foundation
import Observation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
import WirebenchHardware


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
    /// The hidden module that executes a Maraflow page's Structured Text or ladder. It is a runtime detail, not a block
    /// on the sheet, so the canvas and the page's block count leave it out.
    public static func isMaraflowPageRuntime(_ module: PCCModule) -> Bool {
        module.guid == MaraflowStPage.guid || module.guid == MaraflowLdPage.guid
    }

    /// A `BoolVar`'s mode, as the registry builds it: `SimulMode`, or a push button by default.
    public static func boolVarMode(of module: PCCModule) -> BoolVarBlock.Mode? {
        guard module.guid == BoolVarBlock.guid else { return nil }
        let raw = module.simulMode ?? (module.rawAttributes["SimulMode"].flatMap { Int($0) } ?? 2)
        return BoolVarBlock.Mode(simulMode: raw)
    }

    /// The largest value an `IntVar`'s slider reaches. Dirigo itself writes a slider as `SimulMode="3" HighValue="…"`, which is read
    /// here; this app's own `X_SliderMax` (see `ExtraPropertyCatalog`) wins when both are there, and is only written when the block
    /// has no `HighValue` and the value is not the default.
    public static func sliderMax(of module: PCCModule) -> Int {
        let stored = module.extraProperty("SliderMax")?.intValue.map(Int.init)
            ?? module.rawAttributes["HighValue"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return max(1, stored ?? BlockInteraction.defaultSliderMax)
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

    /// A seven-segment display's lit segments, from its pins.
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
        isDocumentEdited = hasSignificantChanges
    }
    public var selectedPage: String = "main"
    public var selectedModuleId: Int? {
        // Selecting a block outside the marquee group (or nothing) ends the group.
        didSet {
            if let id = selectedModuleId {
                selectedWire = nil          // picking a block ends a wire's selection
                if selectedModuleIds.contains(id) { return }
            }
            selectedModuleIds = []
        }
    }
    /// Blocks picked together with the selection rectangle; they move and delete as one. Empty for a plain selection.
    public var selectedModuleIds: Set<Int> = []
    /// The wire the user picked, if any: drawn picked, and the first thing Delete removes.
    ///
    /// A selection of its own, like a block's: picking a wire clears the block and graphic selections (`selectWire`) and
    /// picking either of those clears this, which is what makes Delete act on the one thing that was picked last.
    public var selectedWire: RoutedWire.Key?
    public var isPlaying: Bool = false
    /// What Copy last took: the blocks and the wires between them. See `AppModel+Clipboard`.
    package var clipboard: BlockClipboard?
#if WIREBENCH_AI
    /// The agent panel's state, shared by both frontends (`Agent/`). Only present in a build made with
    /// `WIREBENCH_AI`, which is off by default.
    public let agent = AgentModel()
#endif
    /// The block reference window's state, shared by both frontends (`Help/`).
    public let help = HelpModel()
    /// Whether a host timer (the Qt app's) drives the simulation, so `hostPlay()` starts it; the SwiftUI app plays on its own task.
    @ObservationIgnored public var playsOnHostTimer = false
    /// Where a block dragged out of the picker was dropped on the sheet, in sheet coordinates, until the drag has ended and it is added.
    @ObservationIgnored public var paletteDropPoint: CGPoint?
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
    package var effectiveSpeed: Double { simulationSpeed * Self.baseSpeed }
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

    /// Whether the serial link to the PLC is open: only while an upload is running, which opens the port itself and closes it again.
    public private(set) var isHardwareConnected: Bool = false

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
    nonisolated static package func phaseText(for stage: String) -> String {
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
    nonisolated package func uploadProgressTick(_ fraction: Double) {
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
    nonisolated package func setUploadPhase(_ phase: String, progress: Double?) {
        DispatchQueue.main.async { [weak self] in
            self?.uploadPhase = phase
            if let progress { self?.uploadProgress = progress }
        }
    }

    /// Counts replies so the percentage is steps done over steps in all. A lock, because the transport callback
    /// runs on the upload's thread.
    final package class UploadTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var replies = 0
        package let total: Int
        package init(total: Int) { self.total = total }
        package func reply() -> Double {
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
    nonisolated static package func hexSummary(_ bytes: [UInt8]) -> String {
        let head = bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > 24 ? "\(head) … (\(bytes.count) bytes)" : "\(head) (\(bytes.count) bytes)"
    }

    /// Sends one prepared table to the PLC — what *Build → Upload Compiled Program* produces.
    public func upload(table: PLCProgramTable) async {
        // The link is opened for the upload and closed after it, so there is nothing to connect beforehand and no port held in between.
        connectHardware()
        guard isHardwareConnected else {
            // `connectHardware` said why when the port was refused; with none chosen there is nothing to refuse.
            if selectedPortPath.isEmpty { uploadStatus = "No serial port. Plug in the adapter, rescan, and choose it." }
            uploadPhase = ""
            uploadProgress = nil
            isUploading = false
            return
        }
        defer { disconnectHardware() }
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

    /// - Parameter defaults: where what the block picker learns is kept (`blockUsage`). A test gives it its own.
    public init(defaults: UserDefaults = .standard) {
        usageDefaults = defaults
        blockUsage = BlockUsageModel.load(from: defaults)
        AppModel.shared = self
#if WIREBENCH_AI
        agent.toolbox = AgentToolbox(model: self)
#endif
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

    /// The frontend calls these when the application gains or loses the user's attention.
    public func appBecameActive() {
        isAppActive = true
        // Catch up once, so the canvas shows the current state rather than the last one drawn.
        simulationDidChange()
    }

    public func appResignedActive() {
        isAppActive = false
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
    /// A project opened from Dirigo's `.pcc`: readable, but every save writes the current `.wbp` format, so Save
    /// goes through Save As instead of overwriting the legacy file.
    public private(set) var isLegacyDocument = false

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
    static package func content(of project: PCCProject) -> PCCProject {
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

    /// What the app is about to do that would replace the open project, while it asks whether to save first.
    public enum UnsavedIntent: Equatable, Sendable {
        case newProject
        case open
        case openURL(URL)
        /// Replace the document with a compiled project (the editor's Open in Wirebench).
        case adopt
        case quit
    }

    /// The project a pending Open in Wirebench will install once the save question is answered.
    private var pendingAdoptProject: PCCProject?

    /// The answer to the save question.
    public enum UnsavedChoice: Equatable, Sendable {
        case save, discard, cancel
    }

    /// Non-nil while the view (`MainView`) is showing the save question. The model never presents a
    /// dialog itself: the question is state, the buttons are SwiftUI's, and no AppKit is involved.
    public private(set) var pendingUnsavedIntent: UnsavedIntent?

    /// Set when *Save* was chosen for a project that has no file yet, so the save panel's result can
    /// carry the intent out. Every other path finishes immediately.
    private var intentAwaitingSave: UnsavedIntent?

    /// The quit path's one way back to AppKit. AppKit asks *synchronously* whether it may terminate;
    /// instead of holding the request open, the delegate cancels that one and the answer asks again.
    /// Nothing can be left waiting if the alert never appears.
    public var quitHandler: (() -> Void)?

    /// Set once the answer was “go ahead”, so the second quit request does not ask again.
    public private(set) var isTerminationApproved = false

    public var projectTitle: String {
        if let currentFileURL = currentFileURL {
            return currentFileURL.deletingPathExtension().lastPathComponent
        } else if let name = project?.name, !name.isEmpty {
            return name
        } else {
            return "Wirebench"
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

    /// *New Project*. Asks about unsaved work first, then builds the empty project.
    @MainActor
    public func createNewProject() {
        requestProjectReplacement(.newProject)
    }

    /// The hardware a new project is for: the Duino-E this editor is used with. The PLC Configuration menu changes it.
    private static let newProjectProfile = "Sybas Duino-E"

    private func performNewProject() {
        pause()
        swiftSource = ""

        let newProj = PCCProject(
            name: "Untitled",
            profile: Self.newProjectProfile,
            pages: [ProjectPage(caption: "main")],
            modules: []
        )
        isRestoringUndo = true
        self.project = newProj
        isRestoringUndo = false
        history.clear()
        self.currentFileURL = nil
        self.isLegacyDocument = false
        self.selectedPage = "main"
        self.selectedModuleId = nil
        selectedWire = nil
        configuringModuleId = nil
        clearAnnotationSelection()
        clearedPinValues = [:]
        self.engine = installEngine(project: newProj)
        self.tickCount = 0
        self.simulationVersion = 0
        self.isDocumentEdited = false
        savedContent = Self.content(of: newProj)
        resetZoom()
    }

    /// Adopts a project built by the source editor as the open document, with no file yet: Save asks where it goes.
    ///
    /// The same setup as a project loaded from disk, except that there is no URL and nothing to compare against for the
    /// edited flag — the project is new.
    @MainActor
    public func adoptCompiledProject(_ compiled: PCCProject) {
        pause()
        isRestoringUndo = true
        self.project = compiled
        ModulePinCatalog.invalidateSchemaCache()
        isRestoringUndo = false
        history.clear()
        self.currentFileURL = nil
        self.isLegacyDocument = false
        self.selectedPage = compiled.pages.first?.caption ?? "main"
        self.selectedModuleId = nil
        selectedWire = nil
        configuringModuleId = nil
        clearAnnotationSelection()
        clearedPinValues = [:]
        self.engine = installEngine(project: compiled)
        refreshSnapshots()
        self.tickCount = 0
        self.simulationVersion = 0
        self.isDocumentEdited = false
        savedContent = Self.content(of: compiled)
        self.needsZoomToFit = true
    }

    @MainActor
    public func loadProject(url: URL) {
        pause()
        do {
            // Content decides the format: a `.wbp` and a `.pcc` are told apart even when the name is wrong.
            let loaded = try ProjectFile.read(at: url)
            // A `SystemCmd` block that is only configuration becomes an entry of the PLC configuration; one in the circuit stays a block.
            let proj = PLCConfiguration.extracting(loaded.project)
            var notes: [String] = []
            if !proj.profile.isEmpty, ProfileRegistry.builtIn.profile(named: proj.profile) == nil {
                notes.append("This project asks for the profile '\(proj.profile)', which this build does not know. "
                    + "Its threads and periods fall back to the default profile.")
            }
            notes.append(contentsOf: loaded.notes)
            if loaded.format != .wirebench {
                notes.append("This project is imported, so saving writes the current .wbp format and asks for a new file.")
            }
            if !notes.isEmpty {
                let title: String
                switch loaded.format {
                case .wirebench: title = "Unknown profile"
                case .dirigo: title = "Legacy project opened"
                case .maraflow: title = "Maraflow project imported"
                }
                presentMessage(title: title, message: notes.joined(separator: "\n\n"),
                               kind: loaded.format == .wirebench && notes.count == 1 ? .warning : .info)
            }
            isLegacyDocument = loaded.format != .wirebench
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
            selectedWire = nil
            configuringModuleId = nil
            swiftSource = ""
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
            presentMessage(title: "Failed to open project",
                           message: error.localizedDescription,
                           kind: .warning)
        }
    }

    /// Asks the view for a file. The panel itself belongs to the view layer now.
    @MainActor
    public func openProjectFile() {
        requestProjectReplacement(.open)
    }

    /// A project opened from Finder or `open`: same question, then the file replaces this one.
    @MainActor
    public func openProjectFromFinder(_ url: URL) {
        requestProjectReplacement(.openURL(url))
    }

    /// AppKit's `applicationShouldTerminate`: `true` means terminate, `false` means "ask first". The
    /// delegate cancels that request and `quitHandler` asks again once the answer is in, so no request
    /// is ever left open waiting on a window that might not be there.
    @MainActor
    public func shouldTerminateNow() -> Bool {
        if isTerminationApproved { return true }
        guard hasSignificantChanges else { return true }
        pendingUnsavedIntent = .quit
        return false
    }

    /// Answers the save question the view is showing. *Save* writes the file first — asking where when
    /// the project has none — and only then carries the intent out, so a failed or cancelled save
    /// cancels the New / Open / Quit rather than losing the work.
    @MainActor
    public func answerUnsavedChanges(_ choice: UnsavedChoice) {
        guard let intent = pendingUnsavedIntent else { return }
        pendingUnsavedIntent = nil
        switch choice {
        case .discard:
            continueAfter(intent)
        case .cancel:
            pendingAdoptProject = nil
            finishQuit(intent, terminate: false)
        case .save:
            // A legacy `.pcc` is never written back: saving asks for a `.wbp` destination.
            if isLegacyDocument || currentFileURL == nil {
                intentAwaitingSave = intent
                pendingFilePanel = .saveAs
            } else if let url = currentFileURL {
                do {
                    try saveProject(to: url)
                    continueAfter(intent)
                } catch {
                    presentMessage(title: "The project could not be saved.",
                                   message: error.localizedDescription,
                                   kind: .critical)
                    finishQuit(intent, terminate: false)
                }
            }
        }
    }

    /// The save panel was dismissed without a destination: the intent it was carrying is abandoned.
    @MainActor
    public func savePanelWasCancelled() {
        pendingAdoptProject = nil
        guard let intent = intentAwaitingSave else { return }
        intentAwaitingSave = nil
        finishQuit(intent, terminate: false)
    }

    /// Replaces the document with a compiled project, asking first when there is unsaved work — the same question New
    /// and Open ask, and the same undo history reset once the answer is discard or save.
    @MainActor
    public func requestAdopt(_ project: PCCProject) {
        pendingAdoptProject = project
        requestProjectReplacement(.adopt)
    }

    /// Asks first when there is something to lose.
    @MainActor
    private func requestProjectReplacement(_ intent: UnsavedIntent) {
        if hasSignificantChanges {
            pendingUnsavedIntent = intent
        } else {
            continueAfter(intent)
        }
    }

    /// Carries out what the save question was gating.
    @MainActor
    private func continueAfter(_ intent: UnsavedIntent) {
        switch intent {
        case .newProject: performNewProject()
        case .open: pendingFilePanel = .open
        case .openURL(let url): loadProject(url: url)
        case .adopt:
            if let project = pendingAdoptProject {
                pendingAdoptProject = nil
                adoptCompiledProject(project)
            }
        case .quit: finishQuit(intent, terminate: true)
        }
    }

    /// Carries out a quit the answer allowed. A New or Open that was refused has nothing to do here,
    /// and neither has a quit the user cancelled.
    private func finishQuit(_ intent: UnsavedIntent, terminate: Bool) {
        guard case .quit = intent, terminate else { return }
        isTerminationApproved = true
        quitHandler?()
    }

    /// Called by the delegate once AppKit accepted the second request, so a quit AppKit still refused
    /// asks again next time instead of quitting silently.
    public func clearTerminationApproval() {
        isTerminationApproved = false
    }

    /// Called once the open panel has a result.
    @MainActor
    public func openProject(at url: URL) {
        loadProject(url: url)
    }

    @MainActor
    public func saveProject() {
        // Never write a legacy file back over itself: the new format is saved under a new name.
        if isLegacyDocument {
            saveProjectAs()
            return
        }
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
        // What this block was added after and alongside, taken before it joins the page and takes the selection.
        let context = blockSuggestionContext

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
        blockUsage.recordAddition(of: guid, in: context)
        blockUsage.save(to: usageDefaults)
        lastAddedBlock = guid
        // A new SystemCmd is the Tris command (0x0302), as Dirigo makes one: it has pins to name and a command to send.
        if guid == SystemCmdBlock.guid, let tris = systemCommandCatalogue.first(where: { $0.command == 0x0302 }) {
            setSystemCommand(moduleId: id, to: tris)
        }
        return id
    }

    // MARK: - Block suggestions

    /// What the block picker has learned about which block to offer first: updated by every block added, and kept
    /// between launches.
    public private(set) var blockUsage: BlockUsageModel
    private let usageDefaults: UserDefaults
    /// The type of the block added last, for when nothing is selected to say what the next one follows.
    private var lastAddedBlock: UUID?

    /// What the next block is predicted in: the type of the selected block — or of the last one added — and the
    /// types already on the page.
    public var blockSuggestionContext: BlockUsageModel.Context {
        let onPage = project?.modules.filter { $0.page == selectedPage } ?? []
        let selected = selectedModuleId.flatMap { id in onPage.first { $0.id == id } }
        return BlockUsageModel.Context(anchor: selected?.guid ?? lastAddedBlock, page: Set(onPage.map(\.guid)))
    }

    /// Forgets what the picker has learned, so it offers the default order again.
    public func resetBlockSuggestions() {
        blockUsage = BlockUsageModel()
        lastAddedBlock = nil
        BlockUsageModel.forget(in: usageDefaults)
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
    package func runtimeDidChangeStructure() {
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
        if let key = selectedWire, onPage.contains(key.outModule) || onPage.contains(key.inModule) {
            selectedWire = nil
        }
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
                            size: CGSize(width: CardGeometry.cardWidth(for: $0),
                                         height: CardGeometry.cardHeight(for: $0)),
                            order: $0.order)
        }
        let edges = project.inConnections
            .filter { ids.contains($0.outModuleId) && ids.contains($0.inModuleId) }
            .map { AutoLayout.Edge(from: $0.outModuleId, to: $0.inModuleId,
                                   fromPinY: CardGeometry.outPinPoint(for: byId[$0.outModuleId]!, pinIndex: $0.outPinId).y
                                       - byId[$0.outModuleId]!.y,
                                   toPinY: CardGeometry.inPinPoint(for: byId[$0.inModuleId]!, pinIndex: $0.inPinId).y
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

        // The original knows no configuration list: its entries go back as blocks, before the layout is fitted to the sheet so that they are on it.
        let blocks = PLCConfiguration.injecting(project, defaultThread: configurationThread)
        preparedExport = PaperSize.prepareForDirigo(blocks, extent: CardGeometry.dirigoExtent(for:))
        pendingFilePanel = .export
    }

    /// Writes the imported project back as a Maraflow `.mfl`. The preserved property table is the base, so fields the
    /// native model does not interpret survive; current pages, native blocks and wires are laid over it.
    @MainActor
    public func exportMaraflow() {
        guard let project else { return }
        do {
            let result = try MaraflowExporter.export(project)
            preparedMaraflowExport = result.data
            preparedMaraflowNotes = result.notes
            pendingFilePanel = .exportMaraflow
        } catch {
            presentError("Could not prepare the Maraflow export", detail: error.localizedDescription)
        }
    }

    public var maraflowExportDefaultName: String {
        currentFileURL?.deletingPathExtension().lastPathComponent ?? (project?.name ?? "project")
    }

    @MainActor
    public func finishMaraflowExport(to url: URL) {
        guard let data = preparedMaraflowExport else { return }
        preparedMaraflowExport = nil
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentError("Could not write \(url.lastPathComponent)", detail: error.localizedDescription)
            return
        }
        let notes = preparedMaraflowNotes
        preparedMaraflowNotes = []
        presentMessage(title: "Exported \(url.lastPathComponent)",
                       message: notes.isEmpty ? "The Maraflow project was written." : notes.joined(separator: "\n\n"),
                       kind: notes.isEmpty ? .info : .warning)
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
        if let url = currentFileURL { return url.deletingPathExtension().lastPathComponent }
        return (project?.name.isEmpty == false) ? project!.name : "Untitled"
    }

    /// Called once the save panel has a destination.
    @MainActor
    public func didChooseSaveURL(_ url: URL) {
        let intent = intentAwaitingSave
        intentAwaitingSave = nil
        do {
            try saveProject(to: url)
            if let intent { continueAfter(intent) }
        } catch {
            presentMessage(title: "Failed to save project",
                           message: error.localizedDescription,
                           kind: .critical)
            if let intent { finishQuit(intent, terminate: false) }
        }
    }

    public func saveProject(to url: URL) throws {
        guard var project = project else { return }
        // The document records its own path, as the legacy format did; the legacy export rewrites it for Dirigo.
        project.projectPath = url.path
        try ProjectFile.write(project, to: url)
        // The path changed, and the project setter would record that as an edit; a save is not an undo step.
        isRestoringUndo = true
        self.project = project
        isRestoringUndo = false
        self.currentFileURL = url
        self.isLegacyDocument = false
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
        // Deliberately not animated: the grid and the pin values are drawn from `zoomScale`/`panOffset` in a `Canvas`, so an
        // animated transform would glide the cards while those two layers snapped straight to the end — the grid jumping and
        // the pin text leaving its block for the length of the animation. Immediate pan/zoom keeps every layer in one pass.
        zoomScale = 1.0
        panOffset = CGSize(width: 40, height: 40)
        dragStartPan = panOffset
        updateCardRenderScale()
    }

    public func zoomTo(_ targetZoom: CGFloat, anchor: CGPoint? = nil) {
        guard zoomScale > 0 else { return }
        let factor = targetZoom / zoomScale
        zoomBy(factor: factor, anchor: anchor)
    }

    public func zoomBy(factor: CGFloat, anchor: CGPoint? = nil) {
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
        updateCardRenderScale()
    }

    /// How sharply the cards are rasterised: `CardGeometry.renderScale(for:)` of the zoom, in coarse steps.
    ///
    /// Stored, and written only when the step changes, so that the canvas can depend on it. Worked out from `zoomScale` where
    /// the canvas reads it, it would make the canvas depend on the zoom itself, and rebuild every card at every step of a pinch.
    public private(set) var cardRenderScale: CGFloat = 1.0

    private func updateCardRenderScale() {
        let scale = CardGeometry.renderScale(for: zoomScale)
        if scale != cardRenderScale { cardRenderScale = scale }
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
            let w = Double(CardGeometry.cardWidth(for: mod))
            let h = Double(CardGeometry.cardHeight(for: mod))
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

        zoomScale = targetScale
        panOffset = CGSize(width: targetPanX, height: targetPanY)
        dragStartPan = panOffset
        updateCardRenderScale()
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
        // Force a republish: the digest shortcut must not leave the last run's values on the sheet.
        snapshots = [:]
        refreshSnapshots()
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

    /// For a frontend with its own event loop, which cannot drive `play()`'s Swift task: start playing, then call
    /// `hostTick` from a timer. `pause()` stops it as usual.
    public func hostPlay() {
        guard engine != nil else { return }
        pause()
        isPlaying = true
        hostSimulatedMs = 0
    }

    /// One turn of the play loop for a host timer: `elapsedMs` of wall-clock time since the last call. Steps the
    /// engine when a thread is due, and reports a change to whoever watches.
    public func hostTick(elapsedMs: Double) {
        guard isPlaying, let engine else { return }
        hostSimulatedMs += elapsedMs * effectiveSpeed
        // Step at each moment a thread comes due, as `play()` does by sleeping until then. One step per host tick would
        // run a thread at most once per tick, so a thread whose period is shorter than the timer's (a fast project, or a
        // high speed) fell behind real time, and the tick count followed the timer's rate instead of the threads'.
        var stepped = false
        var guardCount = 0
        while guardCount < 256 {
            let due = engine.msUntilNextRun()
            guard due <= hostSimulatedMs + 1e-9 else { break }
            let delta = max(due, 0.001)
            stepBackend(deltaMs: delta)
            hostSimulatedMs = max(0, hostSimulatedMs - delta)
            stepped = true
            guardCount += 1
        }
        // A host that fell far behind drops the backlog rather than spending its next tick catching up on it.
        if guardCount == 256 { hostSimulatedMs = 0 }
        if stepped {
            tickCount = engine.tickCount
            simulationDidChange()
        }
    }

    @ObservationIgnored private var hostSimulatedMs = 0.0

    public func pause() {
        isPlaying = false
        simulationTimerTask?.cancel()
        simulationTimerTask = nil
    }

    /// The hardware profiles (`ProfileRegistry.builtIn`). A profile gives each thread its real period (`Timer 1s` every
    /// 1000 ms, `Tick` every 71 ms, `Idle` every 50 ms), which is what lets the play loop sleep instead
    /// of waking twenty times a second whether or not anything is due.
    private static let profileDatabase = ProfileRegistry.builtIn

    /// Whether threads run at the hardware profile's periods. Off, every thread runs on the project's own cycle, which is the
    /// pace both frontends have always had; `WIREBENCH_HARDWARE_PROFILE=1` turns it on for a run.
    @ObservationIgnored public var usesHardwareProfile = ProcessInfo.processInfo.environment["WIREBENCH_HARDWARE_PROFILE"] == "1"

    /// Builds the runtime with the project's profile, so scheduling follows the hardware rather than a
    /// fixed cadence. Falls back to the project's `CYCLE_DELAY` when no profile matches, which is the
    /// same period for every thread.
    private func installEngine(project: PCCProject) -> CxxSimulationCore {
        let profile = usesHardwareProfile ? ProfileRegistry.profile(for: project, in: Self.profileDatabase) : nil
        return CxxSimulationCore(project: project, profile: profile, profileScheduling: true)
    }

    /// A Maraflow graphic binding target (`BlockName.PinName`), resolved to a module pin.
    public struct MaraflowPinBinding: Sendable, Equatable {
        public let moduleId: Int
        public let pinIndex: Int
        public let isOutput: Bool
    }

    /// Resolves a Maraflow `Block.Pin` reference against this page's modules. Inputs are tried first for buttons;
    /// `output` selects the output table for indicators.
    public func maraflowBinding(_ target: String, output: Bool) -> MaraflowPinBinding? {
        guard let dot = target.lastIndex(of: ".") else { return nil }
        let blockName = String(target[..<dot])
        let pinName = String(target[target.index(after: dot)...])
        guard let module = project?.modules.first(where: { $0.name == blockName }) else { return nil }
        let count = output ? module.outPins.count : module.inPins.count
        for index in 0..<count {
            let candidates = output
                ? [ModulePinCatalog.outputPinLabel(for: module, index: index),
                   ModulePinCatalog.outputPinFullName(for: module, index: index),
                   module.outPins[index].name ?? ""]
                : [ModulePinCatalog.inputPinLabel(for: module, index: index),
                   ModulePinCatalog.inputPinFullName(for: module, index: index),
                   module.inPins[index].name ?? ""]
            if candidates.contains(where: { $0.caseInsensitiveCompare(pinName) == .orderedSame }) {
                return MaraflowPinBinding(moduleId: module.id, pinIndex: index, isOutput: output)
            }
        }
        return nil
    }

    /// The live boolean of a Maraflow indicator/output binding. Published snapshots are read first: they are what the
    /// canvas observes, so a redraw is guaranteed when the value moves.
    public func maraflowBooleanValue(_ target: String) -> Bool {
        guard let binding = maraflowBinding(target, output: true) else { return false }
        if let snapshot = snapshots[binding.moduleId], binding.pinIndex < snapshot.outValues.count {
            return snapshot.outValues[binding.pinIndex].asBool
        }
        guard let node = getNode(id: binding.moduleId),
              binding.pinIndex < node.block.outPins.count else { return false }
        return node.block.outPins[binding.pinIndex].asBool
    }

    /// A Maraflow visual button writes its bound input pin. A toggle button flips it; a momentary one presses and
    /// releases over two scans through the existing input path.
    public func pressMaraflowBinding(_ target: String) {
        guard let binding = maraflowBinding(target, output: false),
              let node = getNode(id: binding.moduleId),
              binding.pinIndex < node.block.inPins.count else { return }
        let current = node.block.inPins[binding.pinIndex]
        setModuleInput(moduleId: binding.moduleId, pinIndex: binding.pinIndex,
                       value: .bool(!current.asBool))
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
    /// The Structured Text editor's buffer. It lives here, not in the window's state, so closing the window and opening it
    /// again brings back what was written instead of the template; it is kept across launches like the editor's settings.
    public var swiftSource: String = UserDefaults.standard.string(forKey: "structuredTextSource") ?? "" {
        didSet {
            guard swiftSource != oldValue else { return }
            UserDefaults.standard.set(swiftSource, forKey: "structuredTextSource")
        }
    }

    package var appearance: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
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
    package struct PinKey: Hashable {
        package var module: Int
        package var pin: Int
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

    /// Sets how far an `IntVar`'s slider goes. The default is not written down, so a block left alone carries
    /// nothing extra into the file.
    public func setSliderMax(id: Int, max newMax: Int) {
        guard let idx = project?.modules.firstIndex(where: { $0.id == id }),
              BlockRole.isIntVariable(project!.modules[idx]) else { return }
        let value = min(Swift.max(1, newMax), Int(Int32.max))
        if project!.modules[idx].rawAttributes["HighValue"] != nil {
            // A block from Dirigo keeps its range where Dirigo put it, so the original sees the change too.
            project?.modules[idx].rawAttributes["HighValue"] = "\(value)"
            project?.modules[idx].setExtraProperty("SliderMax", nil)
        } else {
            project?.modules[idx].setExtraProperty(
                "SliderMax", value == BlockInteraction.defaultSliderMax ? nil : .int(Int32(value)))
        }
        isDocumentEdited = true
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

    static package func zero(like value: PinValue) -> PinValue {
        switch value {
        case .int16: return .int16(0)
        case .int32: return .int32(0)
        case .int64: return .int64(0)
        case .float: return .float(0)
        default: return .bool(false)
        }
    }

    static package func one(like value: PinValue) -> PinValue {
        switch value {
        case .int16: return .int16(1)
        case .int32: return .int32(1)
        case .int64: return .int64(1)
        case .float: return .float(1)
        default: return .bool(true)
        }
    }

    public func updateModuleParam(id: Int, paramIndex: Int, value: PinValue) {
        // Not decoration: the bound below only checked the top, so a negative index trapped. See `setModuleInput`.
        guard paramIndex >= 0, let idx = project?.modules.firstIndex(where: { $0.id == id }) else { return }
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
    /// Bytes prepared by `exportMaraflow()` for the save panel.
    private var preparedMaraflowExport: Data?
    private var preparedMaraflowNotes: [String] = []

    /// A file panel the user has asked for, for the same reason.
    public enum FilePanel: Equatable {
        case open, saveAs, export, exportMaraflow
        /// The build's exports, and the template it can read.
        case exportProgramBinary, exportSymbolTable, exportProgramVariables, importBuildTemplate
    }
    public var pendingFilePanel: FilePanel?

    /// Whether the copy of a panel that sits in the build report (`inReport`) or in the main view is the one to
    /// show it. While the report is up it is the report's: a panel opened from behind a sheet would wait for it.
    public func isPresenting(_ panel: FilePanel, inReport: Bool) -> Bool {
        pendingFilePanel == panel && isBuildReportVisible == inReport
    }

    /// Shows a message — on the build report while that is up, since an alert would have no window to show in.
    public func presentMessage(title: String, message: String, kind: PendingAlert.Kind = .warning) {
        let alert = PendingAlert(title: title, message: message, kind: kind)
        if isBuildReportVisible { buildReportNotice = alert } else { pendingAlert = alert }
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
        // As with blocks: selecting a text object outside the marquee group (or nothing) ends the group, and
        // picking either kind ends a wire's pick, so Delete acts on whatever was picked last.
        didSet {
            if let i = selectedAnnotationIndex {
                selectedWire = nil
                if selectedAnnotationIndices.contains(i) { return }
            }
            selectedAnnotationIndices = []
        }
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

    /// Edits one graphic object's stored fields — pen, brush, font — in place.
    ///
    /// The inspector is the only caller, and one door keeps the edited-document bookkeeping in one
    /// place. Geometry is not here: `updateShape(at:to:)` clamps and snaps it, and must stay the way
    /// the canvas moves and resizes shapes.
    public func updateGraphic(at index: Int, _ mutate: (inout ProjectGraphic) -> Void) {
        guard var project, project.graphics.indices.contains(index) else { return }
        var graphic = project.graphics[index]
        mutate(&graphic)
        guard graphic != project.graphics[index] else { return }
        project.graphics[index] = graphic
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

    /// Deletes the selected graphic object, and only if it belongs to the page being shown — otherwise a
    /// selection made on one page could delete something invisible from another. Text objects and shapes
    /// share one selection because they share one array of indices.
    public func deleteSelectedAnnotation() {
        guard let index = selectedAnnotationIndex,
              let project,
              project.graphics.indices.contains(index),
              project.graphics[index].page == selectedPage else { return }
        // Highest index first, so the removals do not shift the ones still to go.
        for i in selectedAnnotationIndices.union([index]).sorted(by: >) { deleteAnnotation(at: i) }
    }

    // MARK: - Graphic shapes

    /// The rectangle and circle objects on a page, each with the index it has in the project's array.
    ///
    /// A shape with no readable box is left out rather than drawn at a guessed position: it stays in
    /// the document, and a real Dirigo file still shows what it holds.
    public func shapes(onPage page: String) -> [(index: Int, graphic: ProjectGraphic)] {
        (project?.graphics ?? []).enumerated().compactMap { offset, graphic in
            guard graphic.page == page, graphic.isShape, graphic.boundingBox != nil else { return nil }
            return (index: offset, graphic: graphic)
        }
    }

    /// The smallest shape the canvas can be dragged down to. Below this the object is a dot that
    /// cannot be picked again, which is how a document ends up holding things nobody can delete.
    public static let minimumShapeSize: Double = 16

    /// A new shape's size, by kind. Both are multiples of the drafting grid, so a shape dropped
    /// anywhere lands on it when snapping is on.
    public static func defaultShapeSize(_ kind: PCCGraphicBuilder.Kind) -> (width: Double, height: Double) {
        switch kind {
        case .ellipse: return (width: 128, height: 128)   // a circle
        default:       return (width: 192, height: 128)
        }
    }

    /// Adds a rectangle or circle at a point in canvas coordinates — the middle of the view when
    /// omitted — centred on it, and selects it.
    @discardableResult
    public func addShape(_ kind: PCCGraphicBuilder.Kind, at point: CGPoint? = nil) -> Int? {
        guard var project else { return nil }
        let size = Self.defaultShapeSize(kind)
        let spot = point ?? viewportCentreInCanvas()
        var box = GraphicBox(x: Double(spot.x) - size.width / 2,
                             y: Double(spot.y) - size.height / 2,
                             width: size.width, height: size.height)
        if snapToGrid { box = snappedBox(box) }

        // Nudge down-right while the spot is taken, so repeated insertions do not stack exactly.
        while project.graphics.contains(where: {
            $0.page == selectedPage && $0.boundingBox.map {
                abs($0.x - box.x) < 16 && abs($0.y - box.y) < 16
            } == true
        }) {
            let step = snapToGrid ? GridSnap.step : 24.0
            box = box.offsetBy(dx: step, dy: step)
        }

        project.graphics.append(PCCGraphicBuilder.shape(kind, in: box, page: selectedPage))
        self.project = project
        isDocumentEdited = true

        let index = project.graphics.count - 1
        selectedAnnotationIndex = index
        editingAnnotationIndex = nil
        return index
    }

    /// Moves or resizes one shape. Anything that is not a shape is refused, so a stale index cannot
    /// rewrite a text object's position.
    ///
    /// Returns false when nothing changed, which the canvas uses to skip a document write — and with
    /// it an undo step — for a drag that ended where it started.
    @discardableResult
    public func updateShape(at index: Int, to box: GraphicBox) -> Bool {
        guard var project, project.graphics.indices.contains(index),
              project.graphics[index].isShape,
              project.graphics[index].page == selectedPage,
              let current = project.graphics[index].boundingBox else { return false }
        var next = clamped(box)
        if snapToGrid { next = snappedBox(next) }
        guard next != current else { return false }

        project.graphics[index].setBoundingBox(next)
        self.project = project
        isDocumentEdited = true
        return true
    }

    /// Moves every shape named, together — the marquee can pick several, and dragging one of a group
    /// has to drag all of them or the selection falls apart.
    public func moveShapes(_ indices: Set<Int>, lead: Int, deltaX: Double, deltaY: Double) {
        guard var project else { return }
        let group = indices.union([lead]).filter {
            project.graphics.indices.contains($0)
                && project.graphics[$0].isShape
                && project.graphics[$0].page == selectedPage
        }
        guard !group.isEmpty else { return }

        var dx = deltaX
        var dy = deltaY
        if snapToGrid,
           project.graphics.indices.contains(lead),
           let anchor = project.graphics[lead].boundingBox {
            // Snap the lead shape onto the grid and move the rest by the same delta, so a group keeps
            // its spacing instead of each member sliding to its own nearest grid line.
            dx = GridSnap.snap(anchor.x + deltaX) - anchor.x
            dy = GridSnap.snap(anchor.y + deltaY) - anchor.y
        }

        var moved = false
        for index in group {
            guard let box = project.graphics[index].boundingBox else { continue }
            let next = box.offsetBy(dx: dx, dy: dy)
            if next != box {
                project.graphics[index].setBoundingBox(next)
                moved = true
            }
        }
        guard moved else { return }
        self.project = project
        isDocumentEdited = true
    }

    /// Keeps a shape big enough to see and pick.
    private func clamped(_ box: GraphicBox) -> GraphicBox {
        GraphicBox(x: box.x, y: box.y,
                   width: max(box.width, Self.minimumShapeSize),
                   height: max(box.height, Self.minimumShapeSize))
    }

    /// A box with its corners on the drafting grid. Width and height are snapped through their far
    /// corner rather than directly, so dragging resizes the shape instead of rounding its size away.
    private func snappedBox(_ box: GraphicBox) -> GraphicBox {
        let x = GridSnap.snap(box.x)
        let y = GridSnap.snap(box.y)
        return GraphicBox(x: x, y: y,
                          width: max(GridSnap.snap(box.maxX) - x, Self.minimumShapeSize),
                          height: max(GridSnap.snap(box.maxY) - y, Self.minimumShapeSize))
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
        if let key = selectedWire, project.modules.first(where: { $0.id == key.outModule }) == nil
            || project.modules.first(where: { $0.id == key.inModule }) == nil {
            selectedWire = nil
        }

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
        // And/Or/Xor are built from `inputCount`, and the serializer writes it over the attribute: left
        // stale, the new pins had no runtime pin behind them and the file kept the old count.
        project?.modules[idx].inputCount = count
        // For ISwitch, inPins = En (0), Sw (1), X0...X(count-1) -> total count + 2
        // For And/Or/Xor, inPins = En (0), X0...X(count-1) -> total count + 1
        let isSwitch = project?.modules[idx].typeKey.contains("switch") ?? false
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

    private func connectHardware() {
        guard !selectedPortPath.isEmpty else { return }
        do {
            // 57600 and even parity are the *Unit config* settings; see docs/plc-protocol.md.
            try serialPort.open(path: selectedPortPath, baudRate: 57600, parity: .even)
            isHardwareConnected = true
        } catch {
            print("Hardware connection failed: \(error)")
            // Said where the user looks, not only on the console: a refused port is the commonest thing to go wrong on Linux.
            uploadStatus = SerialPort.openFailureMessage(path: selectedPortPath, error: error)
            isHardwareConnected = false
        }
    }

    private func disconnectHardware() {
        serialPort.close()
        isHardwareConnected = false
    }

    // MARK: - Building the project

    /// What a build produced, and where its header came from.
    ///
    /// The compiling, the counts and the wording all come from `PLCProjectBuild` in WirebenchHardware — the
    /// same type `wirebench-cli build` uses — so this only adds what is the app's: the template it remembered
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
        /// The rows both variable exports are written from — the `.csv` and the `.dbf`.
        public var symbols: [PLCProjectCompiler.Symbol] { build.symbols }

        public var summary: String {
            ([templateNote] + build.report.lines).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// The last build, kept so the exporters and the report sheet can use it without recompiling.
    public var buildReport: BuildReport?
    /// Whether the PLC Configuration sheet is up (`PLCConfiguration`).
    public var isShowingPLCConfiguration = false
    /// Whether the report sheet is up.
    public var isShowingBuildReport = false {
        // A notice belongs to one showing of the report.
        didSet { buildReportNotice = nil }
    }
    /// Whether the report is actually on screen: it is asked for, and there is a build to show.
    public var isBuildReportVisible: Bool { isShowingBuildReport && buildReport != nil }
    /// What the last message said, while the report is up: an alert cannot attach to a window that already
    /// has a sheet, so `presentMessage` hands its message to the report instead.
    public var buildReportNotice: PendingAlert?

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
        // The PLC configuration goes into the program as the blocks it stands for, and containers as Dirigo's markers.
        let xml = BuildInput.xml(for: project, defaultThread: configurationThread)
        do {
            let build = try PLCProjectBuild.compile(xml: xml,
                                                    classForGUID: BlockTypeCatalog.classNamesByGUID,
                                                    template: template, optimize: optimizeProgram)
            let name = currentFileURL?.lastPathComponent ?? (project.name + ".wbp")
            // The trailer carries the project's profile's EEPROM offset and write block (`Sybas Duino-E`: 128, the P3: 8).
            let profile = ProfileRegistry.profile(for: project, in: Self.profileDatabase)
            let binary = try PLCProgramImage.programBinary(
                table: build.table, projectName: name, header: buildTemplateImage?.header,
                trailer: profile.map { PLCProgramImage.trailerPayload(eepromOffset: $0.eepromOffset, eepromWriteBlock: $0.eepromWriteBlock) })
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

    /// Writes the compiled variables as Dirigo's `.dbf`.
    ///
    /// The same rows as the `.csv`, in the dBase file the original writes beside a project — its own
    /// action is captioned "Export variables to CSV", but what lands next to the `.pcc` is this.
    @MainActor
    public func exportProgramVariables() {
        guard compileProject() != nil else { return }
        pendingFilePanel = .exportProgramVariables
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

    /// The name the variables panel suggests, without the extension (see `exportDefaultName`). Dirigo writes
    /// this file beside the project it came from, so the project's own name is the one to offer.
    public var programVariablesDefaultName: String {
        let base = currentFileURL?.deletingPathExtension().lastPathComponent ?? (project?.name ?? "program")
        return base
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

    /// Writes the built variables as a `.dbf` once the user has chosen where.
    @MainActor
    public func finishProgramVariablesExport(to url: URL) {
        guard let report = buildReport else { return }
        do {
            // Stamped with today, because the header's date is the day of the export — which is why two
            // exports of one project are not byte-identical to each other.
            let bytes = PLCVariableDBF.bytes(fromSymbols: report.symbols, exportedOn: .init())
            try Data(bytes).write(to: url, options: .atomic)
            presentMessage(title: "Exported \(url.lastPathComponent)",
                           message: "\(report.symbolRows) variables exported.", kind: .info)
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
