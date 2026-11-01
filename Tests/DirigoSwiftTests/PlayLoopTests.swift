import Testing
import Foundation
import DirigoCore
import DirigoEngine
import DirigoLibrary
@testable import DirigoApp

/// The canvas draws live values straight out of the engine, which is a plain class rather than
/// observable state, so `CanvasView.body` reads `model.simulationVersion` to force re-evaluation
/// each tick. Both halves of that contract are invisible to the compiler and to every other test,
/// and when either breaks the symptom is identical: **the workspace freezes while the toolbar's
/// tick counter keeps counting**, until an unrelated interaction forces one repaint.
///
/// The failure that motivated these tests was the second half: `play()` captured the engine in its
/// task closure, so any rebuild of the runtime orphaned the loop. It stepped a discarded engine
/// while the views read the new one, which is why the workspace appeared to update once and stop.
@MainActor
@Suite("Play loop")
struct PlayLoopTests {
    /// The fastest thread the hardware profile defines.
    ///
    /// The app follows the profile's thread periods now, which is where its idle CPU went: a thread
    /// declared `Timer 1s` is stepped once a second rather than twenty times. This fixture is synthetic
    /// and about the *loop*, so it takes the profile's fastest thread — otherwise every observation below
    /// would wait a second for the privilege of being made.
    static func fastestThreadId() -> Int {
        guard let database = ProfileRegistry.load(),
              let profile = database.defaultProfile,
              let fastest = profile.threads.min(by: { $0.intervalMs < $1.intervalMs }) else { return 1 }
        return fastest.id
    }

    /// Writes a two-block project and returns it, so the runtime is built the way the app builds it.
    static func temporaryProject() throws -> URL {
        var project = PCCProject(name: "playloop")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0, order: 10,
                      threadId: Self.fastestThreadId(), page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true))],
                      paramPins: [Pin(id: 0, value: .int32(2)), Pin(id: 1, value: .int32(2))],
                      outPins: [Pin(id: 0, value: .int32(0)), Pin(id: 1, value: .bool(false))]),
            PCCModule(id: 2, guid: NotBlock.guid, name: "Not1", x: 300, y: 0, order: 20,
                      threadId: Self.fastestThreadId(), page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playloop-\(UUID().uuidString).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Playing advances the runtime continuously, not once")
    func loopAdvances() async throws {
        let model = AppModel()
        try model.loadProject(url: Self.temporaryProject())

        let versionBefore = model.simulationVersion
        model.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        let versionAfter = model.simulationVersion
        let ticks = model.tickCount
        model.pause()

        #expect(ticks > 0, "the loop never stepped the engine")
        #expect(versionAfter > versionBefore, "the canvas would never be invalidated")
        // The cadence now follows the profile's threads (this fixture uses its fastest), so a handful of
        // invalidations over 500 ms is the design rather than a fixed 20 Hz.
        // No count is asserted here. An invalidation happens when the *values* change, and the loop now
        // runs at the project's thread periods, so any fixed number would be a statement about the
        // fixture's pulse rather than about the loop. That it keeps producing changes — not one — is what
        // the two tests below measure, by sampling the published values over time.
    }

    @Test("A runtime rebuilt while playing does not orphan the loop")
    func survivesRebuild() async throws {
        let model = AppModel()
        try model.loadProject(url: Self.temporaryProject())
        model.play()
        try await Task.sleep(nanoseconds: 150_000_000)

        // Rebuild the runtime exactly as wiring a connection does.
        let wired = model.connectPins(from: PinReference(moduleId: 1, side: .output, index: 1),
                                      to: PinReference(moduleId: 2, side: .input, index: 1))
        #expect(wired, "the test needs a successful rebuild to be meaningful")

        // `tickCount` is no good here: an orphaned loop keeps advancing its *own* engine, so the
        // counter still rises. What the canvas actually draws is the live node values, so those are
        // what must keep moving.
        var observed: Set<String> = []
        for _ in 0..<12 {
            let value = model.getNode(id: 1)?.block.outPins.first?.description ?? "-"
            observed.insert(value)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        model.pause()

        #expect(observed.count > 1,
                "the engine the views read never changed (\(observed)) — the loop was stepping an orphan")
    }

    @Test("The values the cards draw are published as observable snapshots")
    func snapshotsTrackTheEngine() async throws {
        let model = AppModel()
        try model.loadProject(url: Self.temporaryProject())
        model.refreshSnapshots()
        #expect(model.snapshots[1] != nil, "a loaded project must publish block values")

        model.play()
        var seen: Set<String> = []
        for _ in 0..<12 {
            if let values = model.snapshots[1]?.outValues {
                seen.insert(values.map(\.description).joined(separator: ","))
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        model.pause()

        // The whole point of the snapshot: as the engine advances, the data the cards draw changes.
        #expect(seen.count > 1,
                "the published values never changed (\(seen)) — the canvas would look frozen")
    }

    @Test("A structural change republishes values immediately")
    func structuralChangeRefreshesSnapshots() async throws {
        let model = AppModel()
        try model.loadProject(url: Self.temporaryProject())
        let wired = model.connectPins(from: PinReference(moduleId: 1, side: .output, index: 1),
                                      to: PinReference(moduleId: 2, side: .input, index: 1))
        #expect(wired)
        // Wiring rebuilds the runtime; the canvas must not be left drawing the discarded engine.
        #expect(model.snapshots[1] != nil)
        #expect(model.snapshots[2] != nil)
    }

    /// A settled project used to republish identical values ~17 times a second, invalidating every
    /// card for nothing. Publishing only on a real change is what makes an idle sheet actually idle.
    @Test("A settled simulation stops invalidating the canvas")
    func settledSimulationIsQuiet() async throws {
        var project = PCCProject(name: "settled")
        project.pages = [ProjectPage(caption: "main")]
        project.modules = [
            PCCModule(id: 1, guid: NotBlock.guid, name: "Not1", x: 0, y: 0, order: 10,
                      threadId: Self.fastestThreadId(), page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settled-\(UUID()).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)

        let model = AppModel()
        model.loadProject(url: url)
        model.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        let settled = model.simulationVersion
        try await Task.sleep(nanoseconds: 400_000_000)
        let later = model.simulationVersion
        model.pause()

        // The engine keeps stepping; the *published values* do not move, so nothing is invalidated.
        #expect(model.tickCount > 0, "the loop must still be running for this to be meaningful")
        #expect(later == settled,
                "a settled project invalidated \(later - settled) more times with identical values")

        // And the work is skipped, not merely discarded: once a refresh has published, the digest says the
        // values still agree, so the next refresh returns before building anything. Returning early *is*
        // the optimization — before it, every one of those ticks rebuilt the whole dictionary and compared
        // it only to throw it away (measured: 2 changes in 460 refreshes on `had+1block.pcc`).
        #expect(model.refreshSnapshots() == false,
                "a settled project must not republish")
        let rebuilds = model.snapshotRebuildCount
        for _ in 0..<5 { _ = model.refreshSnapshots() }
        let extra = model.snapshotRebuildCount - rebuilds
        let message = "5 more refreshes rebuilt the dictionary \(extra) times with identical values,"
            + " so the digest shortcut is not returning early"
        #expect(model.snapshotRebuildCount == rebuilds, "\(message)")
    }

    /// A project opened from Finder arrives through `AppDelegate.openFiles`, which reaches the model
    /// via `AppModel.shared`. If `init` stops publishing itself that path silently does nothing —
    /// the window simply never loads the document, with no error anywhere.
    @Test("AppModel publishes itself for document opens")
    func publishesSharedInstance() {
        let model = AppModel()
        #expect(AppModel.shared === model,
                "a Finder-opened project would have no model to load into")
    }

    /// `refreshSnapshots` asks the engine for a digest of every pin value and returns early when it
    /// matches the digest the published snapshots correspond to, so the dictionary build, the per-module
    /// snapshots and the whole-dictionary comparison are all skipped on a tick where nothing moved —
    /// **99.6% of ticks** on `had+1block.pcc` (2 changes in 460 refreshes).
    ///
    /// That shortcut is only safe while the digest is faithful, and faithfulness is the whole risk: a
    /// digest that missed a change would leave a stale value on the canvas, which is the worst thing this
    /// file can do. So this test pins the digest to *values*, in both directions — it moves when a value
    /// moves, comes back when the value does, and does not drift on its own.
    @Test("The pin digest tracks values exactly, and does not drift")
    func pinDigestIsFaithful() throws {
        let project = CxxSimulationTests.pulseIntoNot()
        let engine = TestEngine(project: project, scheduling: .everyTick)
        func digest() -> UInt64 { engine.pinsDigest() }

        // Stable when nothing happened, including across repeat calls.
        let settled = digest()
        #expect(digest() == settled, "the digest must not drift between two calls with no step between")

        // A step that moves a value moves it.
        engine.step()
        #expect(digest() != settled, "a step that changed an output must move the digest")

        // A second digest call with no step between must agree, or the shortcut would republish every
        // tick and the optimization would be worse than nothing.
        let afterStep = digest()
        #expect(digest() == afterStep, "the digest must be a function of the values, not of call count")

        // It tracks values exactly: writing one back restores the earlier digest.
        guard let node = engine.getNode(id: 1)?.block else {
            Issue.record("the fixture must expose PulseGen1"); return
        }
        let restore = node.outPins
        node.outPins[0] = .int32(1234)
        #expect(digest() != afterStep, "a changed pin value must change the digest")
        node.outPins = restore
        #expect(digest() == afterStep, "restoring the values must restore the digest")

        // And it is not blind to the *kind* of a value, which an `asInt`-based digest would be: `out[0]`
        // is an int32 here, so the same number as a bool must still read as a different value.
        node.outPins[0] = .bool(true)
        #expect(digest() != afterStep, "the same number as a different kind is a different value")
        node.outPins = restore
        #expect(digest() == afterStep)
    }
}
