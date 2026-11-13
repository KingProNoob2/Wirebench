import Foundation
@testable import WirebenchCore
@testable import WirebenchLibrary
@testable import WirebenchEngine

/// The C++ core behind the small engine surface the behaviour tests were written against.
///
/// The tests used to drive the Swift `SimulationEngine`. That engine is gone and the core is the only
/// simulation, so this keeps the tests' shape — `step()`, `run(ticks:)`, `getNode(id:)?.block.inPins[0] = …` —
/// and sends every call to the core. A pin written through `block` is written into the core.
final class TestEngine {
    enum ThreadScheduling { case everyTick, profileIntervals }

    let project: PCCProject
    let core: CxxSimulationCore
    let scheduling: ThreadScheduling
    /// The wall clock a step is stamped with; a test pins it to make `DateTime` deterministic.
    var now: () -> Date = { Date() }

    init(project: PCCProject, profile: PLCProfile? = nil, scheduling: ThreadScheduling = .everyTick) {
        self.project = project
        self.scheduling = scheduling
        self.core = CxxSimulationCore(project: project, profile: profile,
                                      profileScheduling: scheduling == .profileIntervals)
    }

    var cycleDelayMs: Double { Double(max(1, project.appOptions.cycleDelay)) }
    var tickCount: UInt64 { core.tickCount }
    var threadRunCounts: [Int: UInt64] { core.threadRunCounts }

    func step(deltaMs: Double? = nil) {
        core.step(deltaMs: deltaMs ?? cycleDelayMs, now: now())
    }

    func run(ticks: Int) {
        for _ in 0..<ticks { step() }
    }

    func propagateWires() { core.propagate() }
    func msUntilNextRun() -> Double { core.msUntilNextRun() }
    func intervalMs(forThread threadId: Int) -> Double { core.intervalMs(forThread: threadId) }
    func pinsDigest() -> UInt64 { core.pinsDigest() }

    /// Live pins of one module, read from and written into the core.
    final class Pins {
        let core: CxxSimulationCore
        let moduleId: Int
        init(core: CxxSimulationCore, moduleId: Int) { self.core = core; self.moduleId = moduleId }

        var inPins: [PinValue] {
            get { core.inPins(moduleId: moduleId) }
            set { for (pin, value) in newValue.enumerated() { core.setIn(moduleId: moduleId, pin: pin, value: value) } }
        }
        var paramPins: [PinValue] {
            get { core.paramPins(moduleId: moduleId) }
            set { for (pin, value) in newValue.enumerated() { core.setParam(moduleId: moduleId, pin: pin, value: value) } }
        }
        var outPins: [PinValue] {
            get { core.outPins(moduleId: moduleId) }
            set { for (pin, value) in newValue.enumerated() { core.setOut(moduleId: moduleId, pin: pin, value: value) } }
        }
    }

    struct Node {
        let module: PCCModule
        let block: Pins
    }

    func getNode(id: Int) -> Node? {
        guard core.contains(moduleId: id),
              let module = core.runtimeModules.first(where: { $0.id == id }) else { return nil }
        return Node(module: module, block: Pins(core: core, moduleId: id))
    }

    /// Every module the core runs, by id — macro copies and construct markers included.
    var nodes: [Int: Node] {
        Dictionary(core.runtimeModules.compactMap { module in getNode(id: module.id).map { (module.id, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// A click on a `BoolVar`, as the app makes it (`BoolVarBlock.trigger`): a push button gives a two-cycle pulse, a
    /// latch flips.
    func trigger(moduleId: Int) {
        guard let node = getNode(id: moduleId) else { return }
        let raw = node.module.simulMode ?? node.module.rawAttributes["SimulMode"].flatMap { Int($0) } ?? 2
        if BoolVarBlock.Mode(simulMode: raw) == .pushButton {
            core.pulseOut(moduleId: moduleId, pin: 0, cycles: 2)
        } else {
            core.setOut(moduleId: moduleId, pin: 0, value: .bool(!(node.block.outPins.first?.asBool ?? false)))
        }
    }

    /// Modules of a type no registry knows: they run inert.
    func unresolvedBlocks() -> [Node] {
        core.runtimeModules
            .filter { CxxSimulationCore.kind(forGUID: $0.guid) == nil }
            .sorted { $0.id < $1.id }
            .compactMap { getNode(id: $0.id) }
    }
}

/// One unwired module, run through its Swift block class the way the deleted Swift engine ran it: a module whose
/// first input is its `En` and reads 0 does not run at all; otherwise the block's `process`. That is everything the
/// engine did for a module with no wires, so it is a reference for comparing the core block by block. Blocks whose
/// first pin is data (`Yes`, `Int2Bits`, `Limiter`) always run — the help gives them no `En`.
final class BlockOracle {
    let block: FunctionBlock
    private let hasEnable: Bool
    private var tick: UInt64 = 0
    private let cycle: Double
    private let now: Date

    init(module: PCCModule, cycleDelayMs: Double, now: Date) {
        block = BlockRegistry.shared.create(for: module)
        for (index, pin) in module.inPins.enumerated() where index < block.inPins.count { block.inPins[index] = pin.value }
        for (index, pin) in module.paramPins.enumerated() where index < block.paramPins.count { block.paramPins[index] = pin.value }
        (block as? SystemCmdBlock)?.applyDefinition()
        hasEnable = BlockLabels.hasEnablePin(for: module.guid)
        cycle = cycleDelayMs
        self.now = now
    }

    func step() {
        tick += 1
        guard !hasEnable || (block.inPins.first?.asBool ?? true) else { return }
        block.process(sample: SampleContext(tickCount: tick, deltaMs: cycle, timestamp: now))
    }
}

extension CxxSimulationCore {
    /// This core's run recorded as a `PinChain`, comparable with `CorpusRecordings`.
    static func recordedChain(of project: PCCProject, now: Date) -> [UInt64] {
        let core = CxxSimulationCore(project: project, profileScheduling: false)
        let cycle = Double(max(1, project.appOptions.cycleDelay))
        var chain = PinChain()
        for step in 0..<PinChain.steps {
            core.step(deltaMs: cycle, now: now)
            chain.add(step: step, modules: project.modules,
                      inPins: { core.inPins(moduleId: $0) }, outPins: { core.outPins(moduleId: $0) })
        }
        return chain.recorded
    }
}
