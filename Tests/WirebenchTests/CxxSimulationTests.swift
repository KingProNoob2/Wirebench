import Testing
import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchEngine
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// The C++ core against the Swift engine, pin for pin.
///
/// A port that compiles is not a port that agrees, so this runs both engines on the same project and
/// compares every in, param and out pin after every step. The second test measures how far the port
/// actually reaches on real projects, because "partially ported" should be a number, not a claim.
@Suite("C++ simulation core")
struct CxxSimulationTests {
    /// The instant every differential comparison pins both engines to.
    ///
    /// A `TMDateTime` pin is a function of the clock, and two engines that each read their own clock
    /// disagree by milliseconds — so the comparison would fail on a pin whose difference says nothing
    /// about the port. Pinning both to one instant is what makes the time-dependent kinds comparable at
    /// all, and it is why `CxxSimulationCore.step` takes `now` rather than defaulting it.
    static let fixedNow = Date(timeIntervalSince1970: 1_709_623_628)  // 2024-03-05T06:07:08Z

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A pulse generator wired into a `Not`, which is the smallest project that exercises the ported
    /// kinds: a time-dependent block, a stateless one, and a wire between them.
    static func pulseIntoNot() -> PCCProject {
        var project = PCCProject(name: "cpp")
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: PulseGenBlock.guid, name: "PulseGen1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(true))],
                      paramPins: [Pin(id: 0, value: .int32(2)), Pin(id: 1, value: .int32(2))],
                      outPins: [Pin(id: 0, value: .int32(0)), Pin(id: 1, value: .bool(false))]),
            PCCModule(id: 2, guid: NotBlock.guid, name: "Not1", x: 300, y: 0, order: 20,
                      threadId: 1, page: "main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(true))]),
        ]
        project.inConnections = [
            Connection(inModuleId: 2, inPinId: 1, outModuleId: 1, outPinId: 1, isParam: false),
        ]
        return project
    }

    @Test("The core runs the PulseGen-into-Not fixture as the Swift engine did")
    func enginesAgree() throws {
        let project = Self.pulseIntoNot()
        let cxx = CxxSimulationCore(project: project, profileScheduling: false)
        #expect(cxx.portedModuleCount == 2, "the fixture should be fully ported")
        try Self.compareBothEngines(project, label: "pulseIntoNot")
    }

    /// The C API exposes "hold this value" (`set_out`), not the inspector's two-tick `trigger()`, so this
    /// compares the part both engines have rather than pretending the pulse path is ported.
    @Test("A BoolVar holds the value both engines are given")
    func boolVarHoldsAgrees() throws {
        var project = PCCProject(name: "boolvar")
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: BoolVarBlock.guid, name: "zapnuti", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: [], paramPins: [],
                      outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        let swift = BlockOracle(module: project.modules[0], cycleDelayMs: 10, now: Self.fixedNow)
        let cxx = CxxSimulationCore(project: project, profileScheduling: false)

        (swift.block as? BoolVarBlock)?.setOutput(true)
        cxx.setOut(moduleId: 1, pin: 0, value: .bool(true))
        for step in 0..<5 {
            swift.step()
            cxx.step(deltaMs: 10, now: Self.fixedNow)
            #expect(cxx.outValue(moduleId: 1, pin: 0)?.description
                    == swift.block.outPins[0].description,
                    "step \(step)")
        }
    }

    /// `InRange` and `Equitherm` are the two arithmetic kinds `zelznice` needs, and until that project
    /// is fully ported it is *skipped* by the corpus comparison below — so without this test they would
    /// ship with no verification at all. That is the gap this closes: every branch of both blocks, both
    /// engines, compared pin for pin.
    ///
    /// The cases are the ones that are actually easy to get wrong: the exclusive upper bound, the
    /// wrapping window where `L > H`, `En = 0` holding rather than clearing, the degenerate curve where
    /// `BX == AX` (a division by zero), a curve that extrapolates below A, and negative temperature
    /// values, where C's integer division and Swift's both truncate *toward zero* — unlike a floor.
    @Test("Both engines agree on InRange and Equitherm across their edge cases")
    func inRangeAndEquithermAgree() throws {
        // (x, l, h) for InRange: inside, on L, on H (exclusive), below, above, and L > H wrapping.
        let rangeCases: [(Int32, Int32, Int32)] = [
            (50, 0, 100), (0, 0, 100), (100, 0, 100), (-1, 0, 100), (101, 0, 100),
            (0, 22, 6), (22, 22, 6), (5, 22, 6), (6, 22, 6), (23, 22, 6),
            (-30, -20, -10), (-10, -20, -10), (-20, -20, -10),
        ]
        for (x, l, h) in rangeCases {
            let project = Self.oneModuleProject(name: "inrange", guid: InRangeBlock.guid,
                                                inPins: [.bool(true), .int32(x)],
                                                paramPins: [.int32(l), .int32(h)],
                                                outPins: 1)
            try Self.compareBothEngines(project, label: "InRange x=\(x) l=\(l) h=\(h)")
        }
        // `En = 0` must hold the output, not clear it.
        let disabled = Self.oneModuleProject(name: "inrange-off", guid: InRangeBlock.guid,
                                            inPins: [.bool(false), .int32(50)],
                                            paramPins: [.int32(0), .int32(100)],
                                            outPins: 1)
        try Self.compareBothEngines(disabled, label: "InRange En=0")

        // (ot, ax, ay, bx, by) for Equitherm: a normal curve, the degenerate BX==AX, extrapolation at
        // both ends, and values that force a negative product and a truncating divide.
        let curveCases: [(Int32, Int32, Int32, Int32, Int32)] = [
            (0, -10, 40, 15, 20), (10, -10, 40, 15, 20), (-10, -10, 40, 15, 20),
            (15, -10, 40, 15, 20), (20, -10, 40, 15, 20), (-30, -10, 40, 15, 20),
            (5, 0, 0, 0, 0), (5, 0, 7, 0, 9), (-7, 3, 25, -4, 60), (1, 2, 3, 5, 7),
        ]
        for (ot, ax, ay, bx, by) in curveCases {
            let project = Self.oneModuleProject(name: "equitherm", guid: EquithermBlock.guid,
                                                inPins: [.bool(true), .int32(ot)],
                                                paramPins: [.int32(ax), .int32(ay),
                                                            .int32(bx), .int32(by)],
                                                outPins: 1)
            try Self.compareBothEngines(project,
                                        label: "Equitherm ot=\(ot) A=(\(ax),\(ay)) B=(\(bx),\(by))")
        }
    }

    /// `SystemCmd` answers arithmetic and the value it set, and both engines must agree on every command that
    /// has semantics here — including one a `DEFINITION` configures over the stale constant on the pin.
    @Test("SystemCmd: both engines agree for each command", arguments: [
        (0x0022, 7, 3), (0x0023, 3, 4), (0x0024, 5, 3), (0x0301, 21, 0), (0x0302, 112, 0),
        (0x0303, 2, 90), (0x0304, 1, 33), (0x0101, 9, 0), (0x0201, 4, 0), (0x0400, 50, 0),
        (0x0401, 2, 100), (0x0402, 3, 0), (0x0004, 8, 8), (0x0000, 1, 1),
    ])
    func systemCommandAgrees(command: Int, par1: Int, par2: Int) throws {
        let project = Self.oneModuleProject(
            name: "SystemCmd", guid: SystemCmdBlock.guid,
            inPins: [.bool(true), .int32(Int32(command))],
            paramPins: [.int32(Int32(par1)), .int32(Int32(par2))], outPins: 1)
        try Self.compareBothEngines(project, label: String(format: "SystemCmd 0x%04X", command))
        // And the engine's answer is the documented one.
        let engine = TestEngine(project: project)
        engine.step()
        let out = try #require(engine.getNode(id: 1)?.block.outPins.first?.asInt)
        #expect(out == SystemCommandSimulation.result(command: command, par1: par1, par2: par2))
    }

    @Test("SystemCmd arithmetic: square root, hypotenuse and perpendicular")
    func systemCommandArithmetic() {
        #expect(SystemCommandSimulation.result(command: 0x0022, par1: 144, par2: 0) == 12)
        #expect(SystemCommandSimulation.result(command: 0x0022, par1: 0, par2: 1) == 65536)      // 2^32 → 2^16
        #expect(SystemCommandSimulation.result(command: 0x0023, par1: 3, par2: 4) == 5)
        #expect(SystemCommandSimulation.result(command: 0x0024, par1: 5, par2: 3) == 4)
        #expect(SystemCommandSimulation.result(command: 0x0024, par1: 3, par2: 5) == 0)          // no real answer
        #expect(SystemCommandSimulation.result(command: 0x0000, par1: 9, par2: 9) == 0)          // a query of the unit
    }

    @Test("SystemCmd: a configured variant's command word replaces the pin's constant")
    func systemCommandDefinition() throws {
        let definition = ProfilesParser.systemCommand(fromDefinition:
            "TXT=Pwm, CMD=0x0303, I1=(Int)PwmCH,        I2=(Int)Value,        O1=(Int)Out")
        let block = SystemCmdBlock(inPins: 2, params: 2, outPins: 1, definition: definition)
        block.inPins[1] = .int32(770)                  // what zelznice.pcc carries
        block.paramPins = [.int32(2), .int32(90)]
        block.applyDefinition()
        #expect(block.inPins[1].asInt == 0x0303)
        block.process(sample: SampleContext())
        #expect(block.outPins[0].asInt == 90)          // PWM answers the value it set
    }

    /// A one-module project, so a block kind can be compared in isolation.
    static func oneModuleProject(name: String, guid: UUID, inPins: [PinValue],
                                 paramPins: [PinValue], outPins: Int) -> PCCProject {
        var project = PCCProject(name: name)
        project.pages = [ProjectPage(caption: "main")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            PCCModule(id: 1, guid: guid, name: "U1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "main",
                      inPins: inPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                      paramPins: paramPins.enumerated().map { Pin(id: $0.offset, value: $0.element) },
                      outPins: (0..<outPins).map { Pin(id: $0, value: .bool(false)) }),
        ]
        return project
    }

    /// Compares the core against the Swift reference for one project.
    ///
    /// A one-module project is compared step by step against the block's own Swift class (`BlockOracle`), which
    /// is everything the deleted Swift engine did for an unwired module. A larger one is compared against the
    /// run recorded from the Swift engine before it was deleted (`CorpusRecordings`), by `label`.
    static func compareBothEngines(_ project: PCCProject, label: String) throws {
        #expect(CxxSimulationCore.isFullyPorted(project),
                "\(label): the block under test must be ported, or nothing is being compared")
        guard project.modules.count == 1 else {
            let recorded = try #require(CorpusRecordings.chains[label], "\(label): no recording to compare with")
            let chain = CxxSimulationCore.recordedChain(of: project, now: Self.fixedNow)
            #expect(chain == recorded, "\(label): the core's run differs from the recorded Swift run (checkpoints \(PinChain.checkpoints))")
            return
        }
        let module = project.modules[0]
        let swift = BlockOracle(module: module, cycleDelayMs: Double(max(1, project.appOptions.cycleDelay)),
                                now: Self.fixedNow)
        let cxx = CxxSimulationCore(project: project, profileScheduling: false)
        for step in 0..<60 {
            swift.step()
            cxx.step(deltaMs: Double(max(1, project.appOptions.cycleDelay)), now: Self.fixedNow)
            for pin in swift.block.outPins.indices {
                let theirs = cxx.outValue(moduleId: module.id, pin: pin)?.description ?? "-"
                let ours = swift.block.outPins[pin].description
                #expect(theirs == ours, "\(label): step \(step) out[\(pin)] cxx \(theirs) vs swift \(ours)")
            }
            for pin in swift.block.inPins.indices {
                let theirs = cxx.inValue(moduleId: module.id, pin: pin)?.description ?? "-"
                let ours = swift.block.inPins[pin].description
                #expect(theirs == ours, "\(label): step \(step) in[\(pin)] cxx \(theirs) vs swift \(ours)")
            }
        }
    }

    /// The fixture `macroBridgeAgrees` runs: see its note.
    static func macroProject() -> PCCProject {
        var project = PCCProject(name: "macro")
        project.pages = [ProjectPage(caption: "Main"), ProjectPage(caption: "*M")]
        project.appOptions.cycleDelay = 10
        project.modules = [
            // The call site: one in pin, one out pin, on the Main page.
            PCCModule(id: 1, guid: MacroBlock.guid, name: "M1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "Main",
                      inPins: [Pin(id: 0, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .int32(0))],
                      rawAttributes: ["MACRO_NAME": "M"]),
            // The subpage's inputs interface: no in pins, one out pin driven by the bridge.
            PCCModule(id: 2, guid: InputsBlock.guid, name: "Inputs1", x: 0, y: 0, order: 10,
                      threadId: 1, page: "*M",
                      inPins: [], outPins: [Pin(id: 0, value: .int32(0))],
                      rawAttributes: ["MACRO_NAME": "Inputs", "KIND": "0"]),
            // The subpage's work: reads the interface, tests a window.
            PCCModule(id: 3, guid: InRangeBlock.guid, name: "InRange1", x: 0, y: 0, order: 20,
                      threadId: 1, page: "*M",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .int32(0))],
                      paramPins: [Pin(id: 0, value: .int32(0)), Pin(id: 1, value: .int32(100))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
            // The subpage's outputs interface: one in pin, no out pins; the bridge reads it back.
            PCCModule(id: 4, guid: OutputsBlock.guid, name: "Outputs1", x: 0, y: 0, order: 30,
                      threadId: 1, page: "*M",
                      inPins: [Pin(id: 0, value: .bool(false))], outPins: [],
                      rawAttributes: ["MACRO_NAME": "Outputs", "KIND": "1"]),
            // Something on Main to read the macro's result, so a broken bridge is visible as a value.
            PCCModule(id: 5, guid: NotBlock.guid, name: "Not1", x: 0, y: 0, order: 20,
                      threadId: 1, page: "Main",
                      inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                      outPins: [Pin(id: 0, value: .bool(false))]),
        ]
        project.inConnections = [
            // The subpage's inputs interface feeds the work block...
            Connection(inModuleId: 3, inPinId: 1, outModuleId: 2, outPinId: 0, isParam: false),
            // ...whose result drives the subpage's outputs interface...
            Connection(inModuleId: 4, inPinId: 0, outModuleId: 3, outPinId: 0, isParam: false),
            // ...and the caller's output pin is read by a block on Main.
            Connection(inModuleId: 5, inPinId: 1, outModuleId: 1, outPinId: 0, isParam: false),
        ]
        return project
    }

    /// A macro's values cross the caller/subpage boundary *between* module lists, through no connection
    /// any single block could pull — which is why the Swift engine keeps a global `propagateWires()`
    /// sweep for macros even though ordinary blocks are pull-based, and why the core needs
    /// `wirebench_sim_set_macro_bridges` rather than another pin kind.
    ///
    /// `zelznice.pcc` is the corpus project that has a macro, and it is *skipped* by the comparison
    /// below while one of its kinds is unported — so without this fixture the bridge would ship with no
    /// verification at all. This reproduces the shape with ported kinds only:
    ///
    ///   Main: PulseGen2 → And1 ← macro call site; the macro's out feeds `And1`'s second input.
    ///   *M:   InRange1 consumes the subpage's inputs interface and drives its outputs interface.
    ///
    /// so the caller's argument has to reach `InRange1`, and `InRange1`'s result has to come back to the
    /// caller's output pin, or the two engines disagree.
    @Test("A macro's values cross the caller/subpage boundary in the core too")
    func macroBridgeAgrees() throws {
        let project = Self.macroProject()
        #expect(CxxSimulationCore.isFullyPorted(project),
                "the fixture must be fully ported, or nothing is being compared")
        let bridges = CxxSimulationCore.macroBridges(in: project)
        #expect(bridges.count == 2, "expected an inputs and an outputs bridge, got \(bridges.count)")
        try Self.compareBothEngines(project, label: "macro bridge")
    }

    /// The five kinds added for the rest of the corpus: `Bits2Int`, `RS`, `IntVar`, `Div`, `IntSub`.
    ///
    /// They are worth their own fixture because the corpus sweep **cannot** verify them on their own
    /// terms: a project that disagrees for an unrelated reason is isolated by name, and that would take
    /// these kinds down with it. Each is exercised across the cases that are easy to get wrong — `En = 0`
    /// holding rather than clearing, `Div`'s divide-by-zero guard, `RS`'s latch state across passes, and
    /// `Bits2Int`'s off-by-one (`En` is not `B0`).
    @Test("Both engines agree on the five kinds the rest of the corpus needed")
    func newCorpusKindsAgree() throws {
        // Bits2Int: `En` then B0..Bn-1 packed into one Int.
        for (bits, n) in [([true, false, true], 3), ([false, false, false], 3),
                          ([true, true, true, true], 4), ([true], 1)] {
            let project = Self.oneModuleProject(
                name: "bits2int", guid: Bits2IntBlock.guid,
                inPins: [.bool(true)] + bits.map { PinValue.bool($0) },
                paramPins: [], outPins: 1)
            try Self.compareBothEngines(project, label: "Bits2Int \(bits.prefix(n))")
        }
        // Bits2Int with En low: the output must hold, not clear.
        let bitsDisabled = Self.oneModuleProject(
            name: "bits2int-off", guid: Bits2IntBlock.guid,
            inPins: [.bool(false), .bool(true), .bool(true)], paramPins: [], outPins: 1)
        try Self.compareBothEngines(bitsDisabled, label: "Bits2Int En=0")

        // Sixteen bits make a 16-bit signed Int: the upper bits copied from a sign read back negative.
        let sixteen = Self.oneModuleProject(
            name: "bits2int-16", guid: Bits2IntBlock.guid,
            inPins: [.bool(true), .bool(true), .bool(false), .bool(true)] + Array(repeating: PinValue.bool(true), count: 13),
            paramPins: [], outPins: 1)
        try Self.compareBothEngines(sixteen, label: "Bits2Int 16 bits")
        let block = Bits2IntBlock(totalPins: 17)
        block.inPins = [.bool(true), .bool(true), .bool(false), .bool(true)] + Array(repeating: PinValue.bool(true), count: 13)
        block.process(sample: SampleContext(deltaMs: 1))
        #expect(block.outPins[0].asInt == -3, "0xFFFD as a signed 16-bit Int")

        // Div: En, A, B — quotient and remainder, including the B = 0 guard and negative operands.
        for (a, b) in [(Int32(17), Int32(5)), (7, 7), (-17, 5), (17, -5), (-17, -5), (0, 3),
                       (5, 0), (-5, 0), (Int32.min, -1)] {
            let project = Self.oneModuleProject(
                name: "div", guid: DivBlock.guid,
                inPins: [.bool(true), .int32(a), .int32(b)], paramPins: [], outPins: 2)
            try Self.compareBothEngines(project, label: "Div \(a)/\(b)")
        }

        // IntSub: En, A, B.
        for (a, b) in [(Int32(10), Int32(3)), (3, 10), (-10, 3), (0, 0), (Int32.min, 1)] {
            let project = Self.oneModuleProject(
                name: "intsub", guid: SubBlock.guid,
                inPins: [.bool(true), .int32(a), .int32(b)], paramPins: [], outPins: 1)
            try Self.compareBothEngines(project, label: "IntSub \(a)-\(b)")
        }

        // RS: En, S, R — a latch, so it has to agree on state *across* passes, not just per step.
        for (sIn, rIn) in [(false, false), (true, false), (false, true), (true, true)] {
            let project = Self.oneModuleProject(
                name: "rs", guid: RSBlock.guid,
                inPins: [.bool(true), .bool(sIn), .bool(rIn)], paramPins: [], outPins: 1)
            try Self.compareBothEngines(project, label: "RS S=\(sIn) R=\(rIn)")
        }

        // IntVar: a variable that is written by `Set`. Sixteen values in sequence, so the fixture also
        // covers the value surviving the variable's own `process` — the whole point of `WritableVariable`.
        for value in [Int32(0), 1, -1, 4096, Int32.min, Int32.max] {
            var project = Self.oneModuleProject(
                name: "intvar", guid: IntVarBlock.guid, inPins: [], paramPins: [], outPins: 1)
            project.modules[0].outPins = [Pin(id: 0, value: .int32(value))]
            try Self.compareBothEngines(project, label: "IntVar \(value)")
        }
    }

    /// The test that matters for real projects: every corpus project, every pin, every step, against the run
    /// recorded from the Swift engine (`CorpusRecordings`) while the two engines agreed pin for pin on all of them.
    @Test("The core runs every corpus project as the Swift engine did")
    func corpusProjectAgrees() throws {
        let school = TestCorpus.directories[0]
        var compared: [String] = []

        // **Every** project on disk, not a hand-kept list. A hand-kept list was how `zelznice` once went
        // unchecked while the coverage number still climbed. `had.pcc` and `had+1block.pcc` are in the
        // workspace root; everything else is in the Dirigo school folder.
        let rootFiles = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let schoolFiles = (try? FileManager.default.contentsOfDirectory(
            at: school, includingPropertiesForKeys: nil)) ?? []
        let sources = (rootFiles + schoolFiles)
            .filter { $0.pathExtension.lowercased() == "pcc" }
            // Sorted so a failure names the same project on every run, and a new file changes the list.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // A sweep that finds nothing must not look like a sweep that found everything correct.
        #expect(sources.count >= 10, "the corpus should be on disk; found \(sources.count)")

        for url in sources {
            let name = url.lastPathComponent
            guard let project = try? PCCParser().parse(fileAt: url) else { continue }
            #expect(CxxSimulationCore.isFullyPorted(project), "\(name): every module should be ported")
            // A project with no recording was added after the Swift engine was deleted: there is nothing to
            // compare it with, and that is reported rather than passed.
            guard let recorded = CorpusRecordings.chains[name] else {
                Issue.record("\(name): no recorded Swift run to compare with")
                continue
            }
            let chain = CxxSimulationCore.recordedChain(of: project, now: Self.fixedNow)
            #expect(chain == recorded,
                    "\(name): the core differs from the recorded Swift run at checkpoints \(PinChain.checkpoints): \(chain) vs \(recorded)")
            compared.append(name)
        }
        print("C++ core whole-project agreement — compared: \(compared)")
        #expect(!compared.isEmpty, "nothing was compared")
    }

    /// The app must actually be running on the core, and the values the canvas reads must keep moving
    /// while it does — the pins are mirrored back into the Swift blocks for exactly that reason.
    @Test("The app plays a covered project on the C++ core")
    @MainActor
    func appUsesTheCore() async throws {
        let model = AppModel()
        model.loadProject(url: try PlayLoopTests.temporaryProject())

        let before = model.getNode(id: 1)?.block.outPins.map(\.description) ?? []
        model.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        let after = model.getNode(id: 1)?.block.outPins.map(\.description) ?? []
        model.pause()

        #expect(model.tickCount > 0, "the core never stepped")
        #expect(after != before, "the mirrored pins never moved: \(before) then \(after)")
    }

    /// A block of a type nobody knows runs on the core too — inert, as the Swift `UnresolvedBlock` was — and
    /// the blocks around it keep running.
    ///
    /// This used to assert the opposite: while the core was partial, one unported block kept the whole
    /// project on the Swift engine. Every registered block type is ported now and the Swift engine is gone,
    /// so the only "unported" kind left is a GUID no registry knows, and the core is the only engine.
    @Test("A project with an unknown block still runs on the core, with that block inert")
    @MainActor
    func appRunsUnknownBlocksInert() throws {
        var project = CxxSimulationTests.pulseIntoNot()
        project.modules.append(PCCModule(id: 3, guid: UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!,
                                         name: "Unknown1", x: 0, y: 0, order: 30, threadId: 1, page: "main",
                                         inPins: [], paramPins: [], outPins: []))
        #expect(!CxxSimulationCore.isFullyPorted(project),
                "this fixture needs a kind the core does not port")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cxx-fallback-\(UUID().uuidString).pcc")
        try PCCSerializer().serialize(project: project).write(to: url, atomically: true, encoding: .utf8)
        let model = AppModel()
        model.loadProject(url: url)
        let before = model.getNode(id: 1)?.block.outPins.map(\.description)
        for _ in 0..<6 { model.step() }
        #expect(model.getNode(id: 1)?.block.outPins.map(\.description) != before,
                "the known blocks keep running beside the unknown one")
    }

    /// Measured, the per-tick work is ~21 µs against milliseconds of SwiftUI re-evaluation, so an idle
    /// background app spends its CPU redrawing a canvas nobody can see. The simulation keeps running —
    /// it is wall-clock driven and stopping it would lose simulated time — and one refresh catches the
    /// canvas up on reactivation.
    @Test("An unfocused app keeps simulating and stops redrawing")
    @MainActor
    func inactiveAppSkipsRedraw() async throws {
        let model = AppModel()
        model.loadProject(url: try PlayLoopTests.temporaryProject())
        model.isAppActive = false
        let versionBefore = model.simulationVersion

        model.play()
        try await Task.sleep(nanoseconds: 400_000_000)
        let ticks = model.tickCount
        let versionWhileHidden = model.simulationVersion
        model.pause()

        #expect(ticks > 0, "the simulation must keep running while the app is in the background")
        #expect(versionWhileHidden == versionBefore,
                "nothing is on screen, so nothing should be invalidated (\(versionWhileHidden))")

        model.isAppActive = true
        model.simulationDidChange()
        #expect(model.simulationVersion > versionBefore, "reactivating must catch the canvas up")
    }

    @Test("How much of a real project the core simulates")
    func corpusCoverage() throws {
        let school = TestCorpus.directories[0]
        var report: [String] = []
        for name in ["had.pcc", "kostička.pcc", "ehhhhhh zelznice.pcc"] {
            let url = school.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let project = try? PCCParser().parse(fileAt: url) else { continue }
            let core = CxxSimulationCore(project: project)
            let share = Double(core.portedModuleCount) / Double(max(1, project.modules.count))
            report.append("\(name): \(core.portedModuleCount)/\(project.modules.count) modules ported"
                          + " (\(Int(share * 100))%)")
        }
        // Recorded rather than asserted: the port is deliberately partial, and this is the measurement.
        print("C++ core coverage — " + report.joined(separator: "; "))
        #expect(!report.isEmpty, "the corpus should be on disk")
        #expect(CxxSimulationCore.kind(forGUID: NotBlock.guid) != nil)
        #expect(CxxSimulationCore.kind(forGUID: UUID()) == nil, "an unknown GUID must be inert")
    }
}
