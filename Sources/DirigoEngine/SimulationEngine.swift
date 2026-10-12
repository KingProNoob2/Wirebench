import Foundation
import DirigoCore
import DirigoLibrary

public final class SimulationEngine: @unchecked Sendable {
    public struct RuntimeNode {
        public let module: PCCModule
        public var block: FunctionBlock
    }

    public func updateBlock(for moduleId: Int, newBlock: FunctionBlock) {
        if var node = nodes[moduleId] {
            node.block = newBlock
            nodes[moduleId] = node
            for (tid, list) in executionSchedule {
                if let idx = list.firstIndex(where: { $0.module.id == moduleId }) {
                    executionSchedule[tid]?[idx].block = newBlock
                }
            }
        }
    }

    /// How the engine decides which threads run on a given step.
    public enum ThreadScheduling: String, Sendable {
        /// Every block of every thread runs on every step. Matches the historical behaviour of
        /// this reimplementation and ignores the hardware profile's thread periods.
        case everyTick
        /// Each thread runs on the period its `Profiles.ini` profile declares (e.g. `Sybas P3`:
        /// `Timer 1s` every 1000 ms, `Tick` every 71 ms, `Idle` every 50 ms), with the engine
        /// clock advanced by the project's `CYCLE_DELAY` each step.
        case profileIntervals
    }

    public let project: PCCProject
    /// The hardware profile whose thread periods drive `.profileIntervals` scheduling.
    public let profile: PLCProfile?
    public let scheduling: ThreadScheduling
    public private(set) var nodes: [Int: RuntimeNode] = [:] // Module ID -> Node
    public private(set) var executionSchedule: [Int: [RuntimeNode]] = [:] // ThreadID -> Sorted Nodes
    /// The same schedule, flattened in thread order and built once per runtime.
    ///
    /// `step()` used to rebuild this with `sorted { $0.key < $1.key }.map { … }` on every tick — two
    /// array allocations per step, for a list that only changes when the project does.
    public private(set) var scheduledThreads: [(threadId: Int, nodes: [RuntimeNode])] = []
    public private(set) var tickCount: UInt64 = 0
    public var cycleDelayMs: Double

    /// The wall clock this engine stamps a cycle with.
    ///
    /// It is a property rather than a `Date()` call inside `step` for two reasons. It was previously
    /// called **once per scheduled thread**, so two blocks in the same cycle could be stamped with
    /// different times — small, but wrong, and it made any time-dependent block's output depend on how
    /// many threads a project happened to have. And a time-dependent block cannot be compared against
    /// another engine at all unless both can be shown the same instant, which is what tests inject here.
    public var now: () -> Date = { Date() }

    /// A digest of every pin value in the runtime, for answering "did anything change?".
    ///
    /// The app rebuilds every module's snapshot after each step and compares it with the previous one to
    /// decide whether to invalidate the canvas. Measured on `had+1block.pcc`, that data changes on **2
    /// ticks out of 460**, so 99.6% of those rebuilds — and of the whole-dictionary comparisons after
    /// them — were computed and thrown away. The digest lets that case return before allocating anything.
    ///
    /// It must be **faithful**: a digest that misses a change would freeze a value on the canvas, which
    /// is the worst failure this file can have. So every pin is mixed in full — the case *and* the exact
    /// bits, with no `asInt` widening — and the module id is mixed in by raw bits. It is an FNV-1a mix
    /// rather than `Hasher` so the value is stable across runs and reproducible in a bug report; the
    /// order is fixed by walking `nodes` sorted by id, since a dictionary's order is not stable.
    ///
    /// It is not the *only* check: `AppModel.refreshSnapshots` still compares, and it still publishes a
    /// new dictionary, so a missed digest could only ever cost a frame, never a wrong value. The digest
    /// decides whether to *look*, and the comparison decides what is true.
    public func pinsDigest() -> UInt64 {
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325     // FNV-1a offset basis
        for id in nodes.keys.sorted() {
            guard let node = nodes[id] else { continue }
            mix(&digest, UInt64(bitPattern: Int64(id)))
            for value in node.block.inPins { mixPinValue(&digest, value) }
            for value in node.block.paramPins { mixPinValue(&digest, value) }
            for value in node.block.outPins { mixPinValue(&digest, value) }
            // One piece a snapshot carries that the pins do **not** imply: a `BoolVar`'s mode, which
            // decides how the control draws and behaves. (A segment display's lit segments look like
            // the same kind of exception but are not — `SegmentBlock.segmentsState` is a computed view
            // of `inPins`, which are already mixed in above.)
            if let boolVar = node.block as? BoolVarBlock {
                mix(&digest, boolVar.isPulseMode ? 1 : 0)
            }
        }
        return digest
    }

    private func mix(_ digest: inout UInt64, _ value: UInt64) {
        digest = (digest ^ value) &* 0x0000_0100_0000_01b3  // FNV-1a prime
    }

    /// Mixes one pin value **losslessly**: case tag, then that case's exact bits.
    private func mixPinValue(_ digest: inout UInt64, _ value: PinValue) {
        switch value {
        case .bool(let v):
            mix(&digest, 0); mix(&digest, v ? 1 : 0)
        case .int16(let v):
            mix(&digest, 1); mix(&digest, UInt64(UInt16(bitPattern: v)))
        case .int32(let v):
            mix(&digest, 2); mix(&digest, UInt64(UInt32(bitPattern: v)))
        case .int64(let v):
            mix(&digest, 3); mix(&digest, UInt64(bitPattern: v))
        case .float(let v):
            mix(&digest, 4); mix(&digest, UInt64(v.bitPattern))
        case .undefined:
            mix(&digest, 5)
        }
    }

    /// Milliseconds of engine time accumulated since each thread last ran.
    private var threadElapsedMs: [Int: Double] = [:]
    /// How many times each thread has actually executed.
    public private(set) var threadRunCounts: [Int: UInt64] = [:]

    // MARK: - Construct state (docs/spec/execution-model.md §4)

    /// Condition bit-stack. A bit is set for every open construct whose condition is false, so
    /// `condStack == 0` means "inside no false branch". Reset at the start of every pass.
    private var condStack: Int = 0
    /// Module ids of the currently open `If`/`Switch` constructs, innermost last.
    private var constructStack: [Int] = []
    /// Selector captured by each open `Switch`; `nil` is the original's `0x80000000` sentinel.
    private var switchSelector: [Int: Int?] = [:]
    /// Whether any `Case` in each open `Switch` has matched its selector this activation.
    private var switchMatched: [Int: Bool] = [:]
    /// Inbound connections by destination module, so a block can pull its own inputs.
    private var inConnectionMap: [Int: [Connection]] = [:]
    private var inParamConnectionMap: [Int: [Connection]] = [:]


    public init(
        project: PCCProject,
        profile: PLCProfile? = nil,
        scheduling: ThreadScheduling = .everyTick
    ) {
        self.project = project
        self.profile = profile
        self.scheduling = scheduling
        self.cycleDelayMs = Double(max(1, project.appOptions.cycleDelay))
        setupRuntime()
    }

    /// The period of a thread, in milliseconds. Threads the profile does not define (macro
    /// sub-pages in the sample projects use `THREAD_ID` 0) run on every step.
    public func intervalMs(forThread threadId: Int) -> Double {
        if let thread = profile?.thread(id: threadId), thread.intervalMs > 0 {
            return Double(thread.intervalMs)
        }
        return max(1, cycleDelayMs)
    }

    /// Modules whose block type this build cannot simulate. They run as `UnresolvedBlock` and do
    /// nothing; surfacing them lets a caller warn instead of showing wrong values.
    public func unresolvedBlocks() -> [RuntimeNode] {
        nodes.values
            .filter { $0.block is UnresolvedBlock }
            .sorted { $0.module.id < $1.module.id }
    }

    private func setupRuntime() {
        nodes.removeAll()
        executionSchedule.removeAll()

        // 1. Instantiate blocks
        for mod in project.modules {
            let block = BlockRegistry.shared.create(for: mod)
            
            // Initialize pin values from project file
            for (idx, pin) in mod.inPins.enumerated() {
                if idx < block.inPins.count {
                    block.inPins[idx] = pin.value
                }
            }
            for (idx, pin) in mod.paramPins.enumerated() {
                if idx < block.paramPins.count {
                    block.paramPins[idx] = pin.value
                }
            }

            let node = RuntimeNode(module: mod, block: block)
            nodes[mod.id] = node

            let tid = mod.threadId
            executionSchedule[tid, default: []].append(node)
        }

        // 2. Sort execution schedule by module ORDER, and flatten it once
        for (tid, list) in executionSchedule {
            executionSchedule[tid] = list.sorted { $0.module.order < $1.module.order }
        }
        scheduledThreads = executionSchedule
            .sorted { $0.key < $1.key }
            .map { (threadId: $0.key, nodes: $0.value) }

        // 3. Index connection maps for fast immediate forward propagation
        outInConnectionMap.removeAll()
        for conn in project.inConnections {
            outInConnectionMap[conn.outModuleId, default: []].append(conn)
        }

        outParamConnectionMap.removeAll()
        for conn in project.paramConnections {
            outParamConnectionMap[conn.outModuleId, default: []].append(conn)
        }

        // Inbound maps: the original evaluates by pulling (see `pullInputs`).
        inConnectionMap.removeAll()
        inParamConnectionMap.removeAll()
        for conn in project.inConnections {
            inConnectionMap[conn.inModuleId, default: []].append(conn)
        }
        for conn in project.paramConnections {
            inParamConnectionMap[conn.inModuleId, default: []].append(conn)
        }

    }

    private var outInConnectionMap: [Int: [Connection]] = [:]
    private var outParamConnectionMap: [Int: [Connection]] = [:]

    /// Immediately propagates signals originating from a specific module.
    public func propagateWires(from moduleId: Int) {
        guard let srcNode = nodes[moduleId] else { return }

        if let conns = outInConnectionMap[moduleId] {
            for conn in conns {
                guard let dstNode = nodes[conn.inModuleId] else { continue }
                if conn.outPinId < srcNode.block.outPins.count &&
                   conn.inPinId < dstNode.block.inPins.count {
                    var val = srcNode.block.outPins[conn.outPinId]
                    if conn.inPinId < dstNode.module.inPins.count && dstNode.module.inPins[conn.inPinId].inverted {
                        val = .bool(!val.asBool)
                    }
                    dstNode.block.inPins[conn.inPinId] = val
                }
            }
        }

        if let conns = outParamConnectionMap[moduleId] {
            for conn in conns {
                guard let dstNode = nodes[conn.inModuleId] else { continue }
                if conn.outPinId < srcNode.block.outPins.count &&
                   conn.inPinId < dstNode.block.paramPins.count {
                    let val = srcNode.block.outPins[conn.outPinId]
                    dstNode.block.paramPins[conn.inPinId] = val
                }
            }
        }
    }

    /// Propagates signal values across all connections and macro interfaces.

    public func propagateWires() {
        // 1. Push current macro caller inputs to macro subpage inputs before wire propagation
        propagateMacroCalls()

        // 2. IN connections
        for conn in project.inConnections {
            guard let srcNode = nodes[conn.outModuleId],
                  let dstNode = nodes[conn.inModuleId] else {
                continue
            }

            if conn.outPinId < srcNode.block.outPins.count &&
               conn.inPinId < dstNode.block.inPins.count {
                var val = srcNode.block.outPins[conn.outPinId]
                // Handle pin inversion if configured
                if conn.inPinId < dstNode.module.inPins.count && dstNode.module.inPins[conn.inPinId].inverted {
                    val = .bool(!val.asBool)
                }
                dstNode.block.inPins[conn.inPinId] = val
            }
        }

        // 3. PARAM connections
        for conn in project.paramConnections {
            guard let srcNode = nodes[conn.outModuleId],
                  let dstNode = nodes[conn.inModuleId] else {
                continue
            }

            if conn.outPinId < srcNode.block.outPins.count &&
               conn.inPinId < dstNode.block.paramPins.count {
                let val = srcNode.block.outPins[conn.outPinId]
                dstNode.block.paramPins[conn.inPinId] = val
            }
        }

        // 4. Push updated macro caller inputs and pull macro outputs back to callers
        propagateMacroCalls()
    }

    private func propagateMacroCalls() {
        for macroNode in nodes.values {
            guard let macroName = macroNode.module.rawAttributes["MACRO_NAME"] ?? (macroNode.block as? MacroBlock)?.macroName,
                  macroName.lowercased() != "inputs",
                  macroName.lowercased() != "outputs",
                  macroName.lowercased() != "params",
                  !macroNode.module.page.hasPrefix("*") else {
                continue
            }

            let targetPage = "*\(macroName)"
            let candidateNodes = nodes.values.filter {
                $0.module.page == targetPage ||
                $0.module.page.lowercased() == targetPage.lowercased() ||
                $0.module.page.lowercased() == macroName.lowercased()
            }

            // 1. Caller InPins -> Target Page Inputs OutPins
            if let inputNode = candidateNodes.first(where: {
                $0.module.rawAttributes["KIND"] == "0" ||
                $0.module.name.lowercased().hasPrefix("input") ||
                $0.module.rawAttributes["MACRO_NAME"]?.lowercased() == "inputs"
            }) {
                for (idx, inVal) in macroNode.block.inPins.enumerated() {
                    if idx < inputNode.block.outPins.count {
                        inputNode.block.outPins[idx] = inVal
                    }
                }
            }

            // 2. Caller ParamPins -> Target Page Params OutPins
            if let paramNode = candidateNodes.first(where: {
                $0.module.rawAttributes["KIND"] == "2" ||
                $0.module.name.lowercased().hasPrefix("param") ||
                $0.module.rawAttributes["MACRO_NAME"]?.lowercased() == "params"
            }) {
                for (idx, pVal) in macroNode.block.paramPins.enumerated() {
                    if idx < paramNode.block.outPins.count {
                        paramNode.block.outPins[idx] = pVal
                    }
                }
            }

            // 3. Target Page Outputs InPins -> Caller OutPins
            if let outputNode = candidateNodes.first(where: {
                $0.module.rawAttributes["KIND"] == "1" ||
                $0.module.name.lowercased().hasPrefix("output") ||
                $0.module.rawAttributes["MACRO_NAME"]?.lowercased() == "outputs"
            }) {
                for (idx, inVal) in outputNode.block.inPins.enumerated() {
                    if idx < macroNode.block.outPins.count {
                        macroNode.block.outPins[idx] = inVal
                    }
                }
            }
        }
    }

    /// Executes one deterministic cycle of simulation for the given thread ID (or all threads).
    ///
    /// `deltaMs` is how much simulated time this cycle covers. It defaults to the project's
    /// `CYCLE_DELAY`, which is what a fixed-rate caller wants; the play loop passes the wall-clock time
    /// that actually elapsed instead, so a loop that sleeps until a slow thread is due still advances
    /// the simulation in real time.
    public func step(threadId: Int? = nil, deltaMs: Double? = nil) {
        tickCount += 1
        condStack = 0
        constructStack.removeAll()

        let scheduled: [(threadId: Int, nodes: [RuntimeNode])]
        if let tid = threadId {
            scheduled = executionSchedule[tid].map { [(tid, $0)] } ?? []
        } else {
            scheduled = scheduledThreads
        }

        // Propagate wires first
        propagateWires()
        var ranAny = false
        // One instant for the whole cycle, not one per thread.
        let stepTimestamp = now()

        let stepMs = max(1, deltaMs ?? cycleDelayMs)
        for (tid, list) in scheduled {
            let interval = intervalMs(forThread: tid)
            var isDue = true

            if scheduling == .profileIntervals {
                // A thread that has never run is due immediately: the original starts with a zero
                // epoch, so every thread executes on the first pass rather than waiting out its
                // first period. (docs/spec/execution-model.md §2)
                let elapsed = (threadElapsedMs[tid] ?? interval) + stepMs
                if elapsed + 1e-9 < interval {
                    threadElapsedMs[tid] = elapsed
                    isDue = false
                } else {
                    // Keep the remainder so slow threads do not drift.
                    threadElapsedMs[tid] = elapsed.truncatingRemainder(dividingBy: interval)
                }
            }

            guard isDue else { continue }
            ranAny = true

            let sample = SampleContext(
                tickCount: tickCount,
                // What the blocks see as elapsed time. A caller that supplies a delta — the play loop
                // passes the wall-clock time that actually elapsed — is describing exactly how much
                // simulated time this cycle covers, so that is what a block accumulates. Without one,
                // `.profileIntervals` gives each thread its own period and every-tick callers get the
                // project's cycle.
                deltaMs: deltaMs ?? (scheduling == .profileIntervals ? interval : stepMs),
                timestamp: stepTimestamp
            )
            for node in list {
                stepNode(node, sample: sample)
            }
            threadRunCounts[tid, default: 0] += 1
        }

        // Final wire and macro propagation — only when a thread actually ran. With per-thread periods
        // most steps have nothing due, and this pass is the second of two per step.
        if ranAny { propagateWires() }
    }

    /// Whether a thread would run if `step()` were called now, without advancing anything.
    public func hasDueThread() -> Bool {
        guard !executionSchedule.isEmpty else { return false }
        guard scheduling == .profileIntervals else { return true }
        return nextDueInMs() <= 0
    }

    /// Milliseconds until the earliest thread is due next, `0` when one already is.
    ///
    /// The play loop sleeps this long instead of waking on a fixed timer, so a project whose fastest
    /// thread is a second is stepped once a second rather than twenty times.
    public func nextDueInMs() -> Double {
        guard scheduling == .profileIntervals else { return 0 }
        // The reference step is the project's own cycle: the caller decides how much time a cycle
        // covers, but "within one cycle of its period" is what makes a thread due in `step`.
        let stepMs = max(1, cycleDelayMs)
        var soonest = Double.greatestFiniteMagnitude
        for (tid, _) in scheduledThreads {
            let interval = intervalMs(forThread: tid)
            // A thread that has never run is due immediately, matching `step`.
            let elapsed = threadElapsedMs[tid] ?? interval
            soonest = min(soonest, max(0, interval - elapsed))
        }
        // The clock advances by one step per call, so a thread within one step of its period is due.
        return soonest <= stepMs ? 0 : soonest - stepMs
    }

    /// One cycle, but only when a thread is due. Reports whether anything ran, so a caller can skip
    /// its own work — the UI refresh above all — on a step that did nothing.
    @discardableResult
    public func stepIfDue(deltaMs: Double? = nil) -> Bool {
        guard hasDueThread() else { return false }
        step(deltaMs: deltaMs)
        return true
    }

    /// Runs one module the way the original does.
    ///
    /// Two things differ from "call `process()` on every block each pass":
    ///
    /// * **Construct bookkeeping is never gated.** An `If` whose condition is false still pushes its
    ///   bit; an `EndIf` still pops. Only the *body* is gated, otherwise the stack would lose its
    ///   balance and every later block would be skipped for the rest of the pass.
    /// * **A block runs only when the whole condition stack is clear** — the original gates each
    ///   block individually (`TMP1Module.IsEnabled`) rather than skipping a range. A block inside a
    ///   false branch is still visited and does nothing, so it keeps every output value and all of
    ///   its internal state.
    ///
    /// `Switch`/`Case`/`Default`/`EndSwitch` are deliberately *not* wired into this yet: `EndSwitch`
    /// is unregistered, and pushing for `Switch` without a matching pop would corrupt the stack for
    /// every subsequent block. See docs/spec/execution-model.md §4.3.
    private func stepNode(_ node: RuntimeNode, sample: SampleContext) {
        let id = node.module.id
        let enabled = node.block.inPins.first?.asBool ?? true

        if node.block is IfBlock || node.block is SwitchBlock {
            // `b := (not InPinEnabled) xor Inverted`, pushed as the new innermost condition. A
            // `Switch` also resets its selector and matched flag, then reads the selector — but
            // only while its own bit is clear, exactly as the original does.
            let inverted = node.module.inPins.first?.inverted ?? false
            let holds = (!enabled) != inverted
            condStack = (condStack << 1) | (holds ? 1 : 0)
            constructStack.append(id)

            if let sw = node.block as? SwitchBlock {
                switchMatched[id] = false
                switchSelector[id] = (condStack & 1) == 0 ? sw.selector : Int?.none
            }
        } else if node.block is ElseBlock {
            if let top = constructStack.last, (nodes[top]?.block as? IfBlock) != nil {
                condStack ^= 1
            }
        } else if node.block is EndIfBlock || node.block is EndSwitchBlock {
            let wantsSwitch = node.block is EndSwitchBlock
            if let top = constructStack.last {
                let topIsMatch = wantsSwitch
                    ? (nodes[top]?.block as? SwitchBlock) != nil
                    : (nodes[top]?.block as? IfBlock) != nil
                if topIsMatch {
                    constructStack.removeLast()
                    condStack >>= 1
                }
            }
        } else if node.block is CaseBlock {
            // Bit 0 := "this case did not match". A case can only match when the switch captured a
            // selector, which it does not when the switch itself is inside a false branch.
            if let top = constructStack.last, (nodes[top]?.block as? SwitchBlock) != nil {
                var matched = false
                if let selector = switchSelector[top] ?? nil,
                   let caseBlock = node.block as? CaseBlock {
                    matched = caseBlock.accepts(selector)
                }
                if matched { switchMatched[top] = true }
                condStack |= 1
                if matched { condStack &= ~1 }
            } else {
                condStack |= 1
            }
        } else if node.block is DefaultBlock {
            // The default arm runs only when the switch captured a selector and no case matched it.
            if let top = constructStack.last, (nodes[top]?.block as? SwitchBlock) != nil {
                let selectorCaptured = (switchSelector[top] ?? nil) != nil
                let runs = selectorCaptured && !(switchMatched[top] ?? false)
                condStack |= 1
                if runs { condStack &= ~1 }
            } else {
                condStack |= 1
            }
        }

        // Gated body: a block in an inactive branch does nothing at all, so its outputs hold.
        guard condStack == 0, enabled else { return }

        pullInputs(into: node)
        node.block.process(sample: sample)

        // `Set` writes the value of X into "the variables (outputs of other modules) connected to
        // inputs P1-Pn". A block cannot reach another block, so the traversal has to happen here:
        // for each P pin, overwrite the producer's output pin.
        /// Writes `value` into whatever the connection's producer is.
        ///
        /// A variable stores state, so it must be written through `WritableVariable`: setting only
        /// its output pin would be undone the next time the variable ran. Anything else recomputes
        /// its outputs anyway, so the pin write is the only thing available.
        func writeThrough(_ connection: Connection, _ value: PinValue) {
            guard let source = nodes[connection.outModuleId] else { return }
            if let variable = source.block as? WritableVariable {
                variable.writeVariable(value)
                return
            }
            guard connection.outPinId < source.block.outPins.count else { return }
            source.block.outPins[connection.outPinId] = value
        }

        // `SetIdx` writes through exactly one P pin, chosen by its `Idx` input.
        if let indexed = node.block as? SetIdxBlock, let target = indexed.targetPinIndex {
            for conn in inConnectionMap[node.module.id] ?? [] where conn.inPinId == target {
                writeThrough(conn, indexed.writeValue)
            }
        }

        if let setBlock = node.block as? SetBlock {
            let value = setBlock.writeValue
            for conn in inConnectionMap[node.module.id] ?? [] where conn.inPinId >= 2 {
                writeThrough(conn, value)
            }
        }

        // Push this block's outputs to its consumers the moment it has run, which is what the original
        // does and what the C++ core does (`propagateFrom` after every module).
        //
        // Removing this call — and nothing else — puts the disagreement back: the differential test
        // reports `Int2Bits1` out[0] `cxx 1 vs swift 0` at step 0, plus the `Segment1` and `8xDO1` pins it
        // feeds, and the call removes all three. That is measured, twice, with the expectation set to a
        // name that cannot match, so the test's own report says which modules differ.
        //
        // The precise step-by-step reason is **not** established, and an earlier explanation here was
        // wrong: `pullInputs` does run for these blocks and does refresh them from the producer's current
        // output, so "the consumer never reaches `pullInputs`" is not it. What a trace does show is that
        // the push changes whether these blocks *execute at all*, not merely what they read — so the next
        // person should instrument `stepNode`'s gate (`condStack == 0, enabled`) rather than the pull.
        // See `docs/port-status.md` for the surrounding argument.
        //
        // The sweeps at the top and bottom of `step` stay, for macro plumbing whose values cross module
        // lists and cannot be reached by a single block pushing.
        propagateWires(from: id)
    }

    /// Refreshes a module's inputs from its producers' *current* output values.
    ///
    /// The original has no global wire-propagation pass: a consumer reads the producer's stored
    /// output cache when it runs (`vmLast`), so a forward wire is fresh and only a wire that feeds
    /// backwards is one pass stale. Pushing every wire up front instead would make *every* forward
    /// wire a pass late.
    private func pullInputs(into node: RuntimeNode) {
        for conn in inConnectionMap[node.module.id] ?? [] {
            guard let src = nodes[conn.outModuleId],
                  conn.outPinId < src.block.outPins.count,
                  conn.inPinId < node.block.inPins.count else { continue }
            var value = src.block.outPins[conn.outPinId]
            if node.module.inPins.indices.contains(conn.inPinId),
               node.module.inPins[conn.inPinId].inverted {
                value = .bool(!value.asBool)
            }
            node.block.inPins[conn.inPinId] = value
        }
        for conn in inParamConnectionMap[node.module.id] ?? [] {
            guard let src = nodes[conn.outModuleId],
                  conn.outPinId < src.block.outPins.count,
                  conn.inPinId < node.block.paramPins.count else { continue }
            node.block.paramPins[conn.inPinId] = src.block.outPins[conn.outPinId]
        }
    }

    public func run(ticks: Int) {
        for _ in 0..<ticks {
            step()
        }
    }

    public func reset() {
        // `setupRuntime()` throws away every instantiated block, so resetting them first would be
        // wasted work; reset the schedule state and rebuild instead.
        tickCount = 0
        threadElapsedMs.removeAll()
        threadRunCounts.removeAll()
        // The array data area is the PLC's, not a block's, so a reset clears it along with every
        // block instance (which `setupRuntime` discards).
        IntArrayStore.shared.reset()
        setupRuntime()
    }

    public func getNode(id: Int) -> RuntimeNode? {
        nodes[id]
    }
}
