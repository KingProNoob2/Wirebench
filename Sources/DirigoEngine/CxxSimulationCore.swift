import Foundation
import DirigoCore
import DirigoLibrary
import DirigoSimCxx

/// The simulation core, in C++.
///
/// A thin wrapper: it builds the C structures from a `PCCProject`, steps them, and reads pins back. The
/// point of it is that the Swift `SimulationEngine` still exists beside it, so the two can be run on the
/// same project and compared pin for pin — a port that only compiles proves nothing, and this one is
/// deliberately partial.
///
/// The boundary is a plain C ABI (see `DirigoSimCxx.h`), so nothing here needs a C++ interoperability
/// mode, and the same sources build through SwiftPM and through the generated Xcode project.
public final class CxxSimulationCore {
    private let sim: OpaquePointer
    private let indexByModuleId: [Int: Int32]

    /// Modules the core actually simulates, and modules it holds inert because their block kind has not
    /// been ported. Reported rather than assumed: a caller can see how far the port reaches.
    public let portedModuleCount: Int
    public let unresolvedModuleCount: Int

    /// Each module's pin counts, as the core holds them. The core's module list is the *runtime* one — macro
    /// copies and construct markers included — so these are looked up by module id rather than assumed from
    /// the document.
    private let pinCounts: [Int: (inputs: Int, params: Int, outputs: Int)]
    /// The modules the core runs, in the order it was given them.
    public let runtimeModules: [PCCModule]

    /// The block kinds the core implements, by the class the GUID maps to in the block table.
    /// Anything absent is inert — and a project with an inert module does not run here at all, because
    /// one unported block stops wires it carries from moving and would make the *ported* blocks look
    /// wrong too. `isFullyPorted` is the check for that.
    public static func kind(forGUID guid: UUID) -> DirigoBlockKind? {
        switch BlockTypeCatalog.info(forGuid: guid)?.delphiClass {
        case "TMNot": return DIRIGO_BLOCK_NOT
        case "TMAnd": return DIRIGO_BLOCK_AND
        case "TMOr": return DIRIGO_BLOCK_OR
        case "TMXor": return DIRIGO_BLOCK_XOR
        case "TMBoolVar": return DIRIGO_BLOCK_BOOLVAR
        case "TMPulseGenerator": return DIRIGO_BLOCK_PULSEGEN
        case "TMCounter": return DIRIGO_BLOCK_COUNTER
        case "TMComparator": return DIRIGO_BLOCK_COMPARATOR
        case "TMInt2Bits": return DIRIGO_BLOCK_INT2BITS
        case "TSystemCommand": return DIRIGO_BLOCK_SYSTEMCMD
        case "TMIntSwitch": return DIRIGO_BLOCK_SWITCH
        // Writes through to the producers of its P pins rather than computing an output; the core does
        // that in its step loop, since it needs the connection graph.
        case "TMSetPins": return DIRIGO_BLOCK_SET
        case "TMInRange": return DIRIGO_BLOCK_INRANGE
        case "TMEquitherm": return DIRIGO_BLOCK_EQUITHERM
        // The macro call site and the subpage interfaces. Neither computes anything: the call site's
        // values are carried by the bridges (`macroBridges(in:)`), which is why the core needs no
        // `MACRO_NAME` of its own.
        case "TMacroModule": return DIRIGO_BLOCK_MACRO_IO
        case "TMacroInterface": return DIRIGO_BLOCK_MACRO_IO
        // Read a clock it is *given* rather than reading one: two engines that each call `Date()`
        // cannot agree, so a time-dependent pin could never be compared between them.
        case "TMDateTime": return DIRIGO_BLOCK_DATETIME
        case "TMBits2Int": return DIRIGO_BLOCK_BITS2INT
        case "TMRS": return DIRIGO_BLOCK_RS
        case "TMIntVar": return DIRIGO_BLOCK_INTVAR
        case "TMDiv": return DIRIGO_BLOCK_DIV
        case "TMIntSub": return DIRIGO_BLOCK_INTSUB
        // Blocks whose pins *are* their behaviour: the I/O channels, and the displays that show them.
        case "TMDigitalInputs", "TMDigitalOutputs", "TDispValueModule", "TDispSegmentModule":
            return DIRIGO_BLOCK_PASSIVE
        case "TMLComparator": return DIRIGO_BLOCK_COMPARATOR
        case "TMLongSwitch", "TMFloatSwitch": return DIRIGO_BLOCK_SWITCH
        case "TMYes": return DIRIGO_BLOCK_YES
        case "TMShl": return DIRIGO_BLOCK_SHL
        case "TMSar": return DIRIGO_BLOCK_SAR
        case "TMExt": return DIRIGO_BLOCK_EXT
        case "TMIns": return DIRIGO_BLOCK_INS
        case "TMSinglePulse": return DIRIGO_BLOCK_SINGLEPULSE
        case "TMPulseLength": return DIRIGO_BLOCK_PULSELEN
        case "TMIntAbs": return DIRIGO_BLOCK_IABS
        case "TMIntInc": return DIRIGO_BLOCK_IINC
        case "TMIntNeg": return DIRIGO_BLOCK_INEG
        case "TMIntAdd": return DIRIGO_BLOCK_IADD
        case "TMIntMul": return DIRIGO_BLOCK_IMUL
        case "TMLimiter", "TMLLimiter": return DIRIGO_BLOCK_LIMITER
        case "TMCalibratedTransform": return DIRIGO_BLOCK_CALIBTRANSF
        case "TMMean": return DIRIGO_BLOCK_MEAN
        case "TMMove": return DIRIGO_BLOCK_MOVE
        case "TMCopy": return DIRIGO_BLOCK_COPY
        case "TMEncodeDate": return DIRIGO_BLOCK_ENCODEDATE
        case "TMDecodeDate": return DIRIGO_BLOCK_DECODEDATE
        case "TMIntDemultiplexer", "TMLongDemultiplexer": return DIRIGO_BLOCK_IDEMUX
        case "TMFloatDemultiplexer": return DIRIGO_BLOCK_FDEMUX
        case "TMAdvCounter": return DIRIGO_BLOCK_ADVCOUNTER
        case "TMFilter": return DIRIGO_BLOCK_FILTER
        case "TMIntAnd": return DIRIGO_BLOCK_IAND
        case "TMIntOr": return DIRIGO_BLOCK_IOR
        case "TMIntXor": return DIRIGO_BLOCK_IXOR
        case "TMIntNot": return DIRIGO_BLOCK_INOT
        case "TMTrigger": return DIRIGO_BLOCK_TRIGGER
        // No unit attached: when they run they report "nothing read" (`configuration` picks the value).
        case "TMAnalogInputs", "TMCnt", "TMIIC_16xAI", "TMIIC_8xAI", "TMIIC_9xDICounter", "TMIIC_9xDI",
             "TMIRC", "TReadAnaChannel", "TMLogger", "TMReadDallas",
             "TMDbnReadFloat", "TMDbnReadFloatMtx", "TMDbnReadInt", "TMDbnReadIntMtx", "TMDbnReadLong",
             "TMDbnReadLongMtx", "TMDbnWriteFloat", "TMDbnWriteFloatMtx", "TMDbnWriteInt", "TMDbnWriteIntMtx",
             "TMDbnWriteLong", "TMDbnWriteLongMtx", "TMStoreFloatData", "TMStoreIntData", "TMStoreLongData":
            return DIRIGO_BLOCK_CONSTOUT
        // Pin surface only (`ShapePreservingBlock`), or behaviour no pin can observe (`8xPWM`'s duty, a
        // week program this build cannot decode).
        case "TMAnalogOutputs", "TMIIC_3xDO", "TMIIC_8xAO", "TMIIC_8xDO", "TMIQRF", "TMP3Menu", "TMSaveData",
             "TMSwitch2", "TMUserComm", "TMPWMOutputs", "TMWeekProgram":
            return DIRIGO_BLOCK_PASSIVE
        case "TMResults": return DIRIGO_BLOCK_YES                 // `ResultsBlock` copies like `YesBlock`
        case "TMP1DelayFilter": return DIRIGO_BLOCK_DELAYFILTER
        case "TMTimer": return DIRIGO_BLOCK_TIMER
        case "TMRamp": return DIRIGO_BLOCK_RAMP
        case "TMValve": return DIRIGO_BLOCK_VALVE
        case "TMWaterRegulator": return DIRIGO_BLOCK_WATERREG
        case "TMStepDriver": return DIRIGO_BLOCK_STEPDRV
        case "TMHysteresisComparator": return DIRIGO_BLOCK_HYSTCOMP
        case "TMMultiComparator": return DIRIGO_BLOCK_MCOMPARE
        case "TMIfModule": return DIRIGO_BLOCK_IF
        case "TMElseModule": return DIRIGO_BLOCK_ELSE
        case "TMEndIfModule": return DIRIGO_BLOCK_ENDIF
        case "TMSwitchModule": return DIRIGO_BLOCK_SWITCHCASE
        case "TMCaseModule": return DIRIGO_BLOCK_CASE
        case "TMDefaultModule": return DIRIGO_BLOCK_DEFAULT
        case "TMEndSwitchModule": return DIRIGO_BLOCK_ENDSWITCH
        case "TMFloatVar": return DIRIGO_BLOCK_FLOATVAR
        case "TMLongVar": return DIRIGO_BLOCK_INTVAR
        case "TMCreateIntArray", "TMCreateLongArray": return DIRIGO_BLOCK_CREATEARRAY
        case "TMReadIntArray", "TMReadLongArray", "TMReadFloatArray": return DIRIGO_BLOCK_READARRAY
        case "TMWriteIntArray", "TMWriteLongArray", "TMWriteFloatArray": return DIRIGO_BLOCK_WRITEARRAY
        case "TMSetIndexed": return DIRIGO_BLOCK_SETIDX
        default:
            // One Swift class backs each of these families; the operation is the `variant`.
            if LongMathOperation(blockName: BlockTypeCatalog.info(forGuid: guid)?.blockName ?? "") != nil {
                return DIRIGO_BLOCK_LONGMATH
            }
            if FloatMathOperation(blockName: BlockTypeCatalog.info(forGuid: guid)?.blockName ?? "") != nil {
                return DIRIGO_BLOCK_FLOATNUM
            }
            // The legacy `FloatMath` has no Delphi class of its own, so it is matched by GUID.
            if guid == FloatMathBlock.guid { return DIRIGO_BLOCK_FLOATMATH }
            return nil
        }
    }

    /// The per-instance configuration the Swift registry reads from module attributes when it builds the block.
    ///
    /// Each rule mirrors the matching `register` closure in `BlockRegistry`, so the core and the Swift block
    /// are configured from the same attributes the same way.
    static func configuration(for mod: PCCModule, kind: DirigoBlockKind,
                              inCount: Int, outCount: Int) -> (variant: Int32, config: [Int64]) {
        let blockName = BlockTypeCatalog.info(forGuid: mod.guid)?.blockName ?? ""
        switch kind {
        case DIRIGO_BLOCK_RS:
            let setPriority = mod.rawAttributes["PRIORITY"]?.uppercased() == "S"
                || mod.rawAttributes["RS_PRIORITY"]?.uppercased() == "S"
            return (setPriority ? 1 : 0, [])
        case DIRIGO_BLOCK_SWITCH:
            return (BlockTypeCatalog.info(forGuid: mod.guid)?.delphiClass == "TMFloatSwitch" ? 1 : 0, [])
        case DIRIGO_BLOCK_MEAN:
            let window = mod.paramPins.first?.value.asInt
                ?? mod.rawAttributes["N"].flatMap { Int($0) }
                ?? mod.rawAttributes["WINDOW"].flatMap { Int($0) }
                ?? 12
            return (0, [Int64(max(1, window))])
        case DIRIGO_BLOCK_COPY:
            // `CopyBlock(count:hasWrPin:)`: a Wr pin is present when there is an input beyond the outputs.
            return (inCount > max(outCount, 1) ? 1 : 0, [])
        case DIRIGO_BLOCK_LONGMATH:
            let ops: [LongMathOperation] = [.add, .subtract, .absolute, .negate, .logicalNot, .increment,
                                            .bitAnd, .bitOr, .bitXor]
            let op = LongMathOperation(blockName: blockName)
            return (Int32(ops.firstIndex { $0 == op } ?? 0), [])
        case DIRIGO_BLOCK_FLOATNUM:
            let ops: [FloatMathOperation] = [.add, .subtract, .multiply, .divide, .absolute, .negate,
                                             .squareRoot, .modulo, .sine, .cosine, .arcSine, .arcCosine]
            let op = FloatMathOperation(blockName: blockName)
            return (Int32(ops.firstIndex { $0 == op } ?? 0), [])
        case DIRIGO_BLOCK_FLOATMATH:
            let ops = ["add", "sub", "mul", "div", "sqrt", "sin", "cos"]
            return (Int32(ops.firstIndex(of: mod.rawAttributes["OP"]?.lowercased() ?? "add") ?? 0), [])
        case DIRIGO_BLOCK_TIMER:
            // `TimerBlock.Mode(rawValue:) ?? .onDelay`.
            let mode = Int(mod.rawAttributes["MODE"] ?? "0") ?? 0
            return ((0...3).contains(mode) ? Int32(mode) : 0, [])
        case DIRIGO_BLOCK_IF, DIRIGO_BLOCK_SWITCHCASE:
            return (mod.inPins.first?.inverted == true ? 1 : 0, [])
        case DIRIGO_BLOCK_DATETIME:
            let offset = mod.rawAttributes["OFFS"].flatMap { Int($0) } ?? mod.rawAttributes["OFFSET"].flatMap { Int($0) } ?? 0
            return (0, [Int64(offset)])
        case DIRIGO_BLOCK_CONSTOUT:
            switch BlockTypeCatalog.info(forGuid: mod.guid)?.delphiClass ?? "" {
            case let c where c.hasPrefix("TMDbnRead") || c.hasPrefix("TMDbnWrite"): return (1, [])
            case "TMStoreFloatData": return (2, [])
            case "TMReadDallas": return (3, [])
            default: return (0, [])
            }
        case DIRIGO_BLOCK_READARRAY, DIRIGO_BLOCK_WRITEARRAY:
            let delphiClass = BlockTypeCatalog.info(forGuid: mod.guid)?.delphiClass ?? ""
            return (delphiClass.hasSuffix("FloatArray") ? 1 : 0, [])
        default:
            return (0, [])
        }
    }

    /// Whether every module in a project has a ported kind, which is what makes running it here sound.
    public static func isFullyPorted(_ project: PCCProject) -> Bool {
        project.modules.allSatisfy { kind(forGUID: $0.guid) != nil }
    }

    public init(project original: PCCProject, profile: PLCProfile? = nil, profileScheduling: Bool = true) {
        // The same runtime `SimulationEngine` builds: every call of a macro on its own copy of the sheet
        // (`MacroInstancing`), then every container written out as legacy If/Case/EndIf markers
        // (`ConstructContainers`). The modules are addressable here by the ids those passes gave them.
        let project = ConstructContainers.expanded(MacroInstancing.instanced(original))
        // The same starting state `SimulationEngine.setupRuntime` builds: a block per module, the
        // project's in-pin and param-pin values applied over the block's own defaults. The values are
        // handed over as flat C arrays the core copies from, so nothing here outlives the call.
        var descs: [DirigoModuleDesc] = []
        var index: [Int: Int32] = [:]
        var ported = 0
        var totalIn = 0, totalOut = 0
        var pinValues: [(inPins: [PinValue], outPins: [PinValue])] = []

        for (position, mod) in project.modules.enumerated() {
            let block = BlockRegistry.shared.create(for: mod)
            for (idx, pin) in mod.inPins.enumerated() where idx < block.inPins.count {
                block.inPins[idx] = pin.value
            }
            for (idx, pin) in mod.paramPins.enumerated() where idx < block.paramPins.count {
                block.paramPins[idx] = pin.value
            }
            (block as? SystemCmdBlock)?.applyDefinition()
            let kind = Self.kind(forGUID: mod.guid) ?? DIRIGO_BLOCK_UNRESOLVED
            if kind != DIRIGO_BLOCK_UNRESOLVED { ported += 1 }
            index[mod.id] = Int32(position)
            totalIn += block.inPins.count
            totalOut += block.outPins.count
            pinValues.append((block.inPins, block.outPins))
            let setup = Self.configuration(for: mod, kind: kind,
                                           inCount: block.inPins.count, outCount: block.outPins.count)
            let config = setup.config + Array(repeating: 0, count: max(0, 4 - setup.config.count))
            descs.append(DirigoModuleDesc(
                id: Int32(mod.id),
                order: Int32(mod.order),
                threadId: Int32(mod.threadId),
                kind: Int32(kind.rawValue),
                inCount: Int32(block.inPins.count),
                paramCount: Int32(block.paramPins.count),
                outCount: Int32(block.outPins.count),
                initialOut: nil, initialIn: nil,
                variant: setup.variant,
                config: (config[0], config[1], config[2], config[3])))
        }

        let inFlat = UnsafeMutablePointer<DirigoValue>.allocate(capacity: max(1, totalIn))
        let outFlat = UnsafeMutablePointer<DirigoValue>.allocate(capacity: max(1, totalOut))
        defer { inFlat.deallocate(); outFlat.deallocate() }
        var offsetIn = 0, offsetOut = 0
        for i in 0..<descs.count {
            let values = pinValues[i]
            for (pin, value) in values.inPins.enumerated() { (inFlat + offsetIn + pin).pointee = Self.cValue(value) }
            for (pin, value) in values.outPins.enumerated() { (outFlat + offsetOut + pin).pointee = Self.cValue(value) }
            // `initialIn`/`initialOut` are `UnsafePointer` on the Swift side; the storage is ours to write.
            descs[i].initialIn = UnsafePointer(inFlat + offsetIn)
            descs[i].initialOut = UnsafePointer(outFlat + offsetOut)
            offsetIn += values.inPins.count
            offsetOut += values.outPins.count
        }

        // An in-pin wire carries its destination pin's `inverted` flag, which is where the Swift reads it
        // (`dstNode.module.inPins[inPinId].inverted`); a param wire is never inverted.
        let modulesById = Dictionary(project.modules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var connections: [DirigoConnection] = []
        for (list, isParam) in [(project.inConnections, false), (project.paramConnections, true)] {
            for conn in list {
                let pins = modulesById[conn.inModuleId]?.inPins ?? []
                let inverted = !isParam && pins.indices.contains(conn.inPinId) && pins[conn.inPinId].inverted
                connections.append(DirigoConnection(
                    inModule: Int32(conn.inModuleId), inPin: Int32(conn.inPinId),
                    outModule: Int32(conn.outModuleId), outPin: Int32(conn.outPinId),
                    inverted: inverted ? 1 : 0, toParamPins: isParam ? 1 : 0))
            }
        }

        let cycle = Double(max(1, project.appOptions.cycleDelay))
        let created: OpaquePointer? = descs.withUnsafeBufferPointer { descBuffer in
            connections.withUnsafeBufferPointer { connBuffer in
                dirigo_sim_create(descBuffer.baseAddress, Int32(descBuffer.count),
                                  connBuffer.baseAddress, Int32(connBuffer.count),
                                  cycle, profileScheduling ? 1 : 0)
            }
        }
        guard let created else {
            fatalError("dirigo_sim_create returned null")
        }
        // Parameter pins are not part of `DirigoModuleDesc`: they are per-instance configuration, so
        // they are pushed in afterwards. Without this a `PulseGen` ran with `TOn = TOff = 0` and its
        // period was two cycles instead of four.
        for (position, mod) in project.modules.enumerated() {
            let block = BlockRegistry.shared.create(for: mod)
            for (idx, pin) in mod.paramPins.enumerated() where idx < block.paramPins.count {
                dirigo_sim_set_param(created, Int32(position), Int32(idx), Self.cValue(pin.value))
            }
            // A `Case`'s accepted values are configuration (`VALUES`, e.g. "1, 5..7"), parsed as the Swift
            // `CaseBlock` parses them.
            if Self.kind(forGUID: mod.guid) == DIRIGO_BLOCK_CASE {
                let ranges = CaseBlock.parse(mod.rawAttributes["VALUES"] ?? mod.rawAttributes["CASE_VALUES"] ?? "")
                let flat = ranges.flatMap { [Int64($0.lowerBound), Int64($0.upperBound)] }
                flat.withUnsafeBufferPointer { buffer in
                    dirigo_sim_set_case_ranges(created, Int32(position), buffer.baseAddress, Int32(ranges.count))
                }
            }
        }
        // Thread periods from the hardware profile, as `SimulationEngine.intervalMs(forThread:)` takes them.
        for threadId in Set(project.modules.map(\.threadId)) {
            if let thread = profile?.thread(id: threadId), thread.intervalMs > 0 {
                dirigo_sim_set_thread_interval(created, Int32(threadId), Double(thread.intervalMs))
            }
        }
        // Macro interfaces. The Swift engine finds these by matching `MACRO_NAME` and `KIND`
        // attributes and page names; doing that here rather than in C++ keeps the string matching in
        // one place, and the core only has to copy pins between the two modules it is handed.
        let bridges = Self.macroBridges(in: project)
        if !bridges.isEmpty {
            bridges.withUnsafeBufferPointer { buffer in
                dirigo_sim_set_macro_bridges(created, buffer.baseAddress, Int32(buffer.count))
            }
            dirigo_sim_set_macro_sweeps(created, Int32(MacroCalls.sweeps(forDepth: MacroCalls.nestingDepth(in: project.modules))))
        }

        self.sim = created
        self.indexByModuleId = index
        self.portedModuleCount = ported
        self.unresolvedModuleCount = descs.count - ported
        self.runtimeModules = project.modules
        var counts: [Int: (inputs: Int, params: Int, outputs: Int)] = [:]
        for (position, mod) in project.modules.enumerated() {
            counts[mod.id] = (Int(descs[position].inCount), Int(descs[position].paramCount), Int(descs[position].outCount))
        }
        self.pinCounts = counts
    }

    // MARK: - Driving the core from the app

    /// Whether the core has a module with this id.
    public func contains(moduleId: Int) -> Bool { indexByModuleId[moduleId] != nil }

    /// A module's pins, as arrays — what the views draw.
    public func inPins(moduleId: Int) -> [PinValue] {
        (0..<(pinCounts[moduleId]?.inputs ?? 0)).map { inValue(moduleId: moduleId, pin: $0) ?? .undefined }
    }

    public func paramPins(moduleId: Int) -> [PinValue] {
        (0..<(pinCounts[moduleId]?.params ?? 0)).map { paramValue(moduleId: moduleId, pin: $0) ?? .undefined }
    }

    public func outPins(moduleId: Int) -> [PinValue] {
        (0..<(pinCounts[moduleId]?.outputs ?? 0)).map { outValue(moduleId: moduleId, pin: $0) ?? .undefined }
    }

    public func paramValue(moduleId: Int, pin: Int) -> PinValue? {
        guard let index = indexByModuleId[moduleId] else { return nil }
        return Self.pinValue(dirigo_sim_get_param(sim, index, Int32(clamping: pin)))
    }

    /// A push button's single click: the output goes high for `cycles` passes, then low.
    public func pulseOut(moduleId: Int, pin: Int, cycles: Int) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_pulse_out(sim, index, Int32(clamping: pin), Int32(clamping: cycles))
    }

    /// One block's own reset: its state and outputs, keeping its inputs and parameters.
    public func resetModule(moduleId: Int) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_reset_module(sim, index)
    }

    /// Re-reads a module's attribute-driven configuration (an RS priority, a timer mode) into the core, live.
    public func reconfigure(module: PCCModule) {
        guard let index = indexByModuleId[module.id], let kind = Self.kind(forGUID: module.guid),
              let counts = pinCounts[module.id] else { return }
        let setup = Self.configuration(for: module, kind: kind, inCount: counts.inputs, outCount: counts.outputs)
        dirigo_sim_set_variant(sim, index, setup.variant)
    }

    /// The whole-project wire and macro sweep, so a hand edit reaches its consumers without a step.
    public func propagate() { dirigo_sim_propagate(sim) }

    /// One pass of every thread *now*, leaving the threads' timers alone: an edit made while paused shows its
    /// effect even on a thread whose period is a second. Counts as a tick.
    public func evaluateNow(now: Date) {
        dirigo_sim_set_wall_clock(sim, Self.wallClock(from: now))
        dirigo_sim_evaluate_now(sim)
    }

    /// A faithful digest of every pin, for "did anything change since the last redraw?".
    public func pinsDigest() -> UInt64 { dirigo_sim_pins_digest(sim) }

    /// How many times each thread has run, for the threads the project uses.
    public var threadRunCounts: [Int: UInt64] {
        var counts: [Int: UInt64] = [:]
        for threadId in Set(runtimeModules.map(\.threadId)) {
            let count = dirigo_sim_thread_run_count(sim, Int32(clamping: threadId))
            if count > 0 { counts[threadId] = count }
        }
        return counts
    }

    /// A thread's period: the profile's, or the project's cycle.
    public func intervalMs(forThread threadId: Int) -> Double {
        dirigo_sim_thread_interval_ms(sim, Int32(clamping: threadId))
    }

    /// Module ids on a thread, in the order the core runs them: ascending `ORDER`, ties in runtime order.
    public func executionOrder(forThread threadId: Int) -> [Int] {
        runtimeModules.enumerated()
            .filter { $0.element.threadId == threadId }
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.id)
    }

    /// The caller/subpage interfaces of every macro in a project, in the shape the core expects.
    ///
    /// Mirrors `SimulationEngine.propagateMacroCalls`: a macro is any module carrying a `MACRO_NAME`
    /// that is not itself on a `*` subpage and is not one of the three reserved interface names. Its
    /// subpage is `*<MACRO_NAME>`, and the interfaces are found by `KIND` or by name, as the Swift does —
    /// `kind` here rather than a class check, because that is the mapping the rest of the engine uses
    /// and a file with an unusual interface name still resolves.
    public static func macroBridges(in project: PCCProject) -> [DirigoMacroBridge] {
        var result: [DirigoMacroBridge] = []

        for macro in project.modules {
            // A call on a `*` sheet is a nested macro and is bridged like any other. Like the Swift, a macro
            // block without a `MACRO_NAME` falls back to its instance name (`MacroBlock.macroName`).
            let fallback = macro.guid == MacroBlock.guid ? (macro.rawAttributes["MACRO_NAME"] ?? macro.name) : nil
            guard let name = MacroCalls.target(of: macro) ?? fallback,
                  !["inputs", "outputs", "params"].contains(name.lowercased()) else { continue }
            let targetPage = "*\(name)"
            let candidates = project.modules.filter {
                $0.page == targetPage
                    || $0.page.lowercased() == targetPage.lowercased()
                    || $0.page.lowercased() == name.lowercased()
            }
            guard !candidates.isEmpty else { continue }

            if let inputs = candidates.first(where: {
                $0.rawAttributes["KIND"] == "0"
                    || $0.name.lowercased().hasPrefix("input")
                    || $0.rawAttributes["MACRO_NAME"]?.lowercased() == "inputs"
            }) {
                result.append(DirigoMacroBridge(callerModule: Int32(macro.id),
                                                interfaceModule: Int32(inputs.id),
                                                kind: Int32(DIRIGO_MACRO_INPUTS.rawValue)))
            }
            if let params = candidates.first(where: {
                $0.rawAttributes["KIND"] == "2"
                    || $0.name.lowercased().hasPrefix("param")
                    || $0.rawAttributes["MACRO_NAME"]?.lowercased() == "params"
            }) {
                result.append(DirigoMacroBridge(callerModule: Int32(macro.id),
                                                interfaceModule: Int32(params.id),
                                                kind: Int32(DIRIGO_MACRO_PARAMS.rawValue)))
            }
            if let outputs = candidates.first(where: {
                $0.rawAttributes["KIND"] == "1"
                    || $0.name.lowercased().hasPrefix("output")
                    || $0.rawAttributes["MACRO_NAME"]?.lowercased() == "outputs"
            }) {
                result.append(DirigoMacroBridge(callerModule: Int32(macro.id),
                                                interfaceModule: Int32(outputs.id),
                                                kind: Int32(DIRIGO_MACRO_OUTPUTS.rawValue)))
            }
        }
        return result
    }

    deinit { dirigo_sim_destroy(sim) }

    /// Winds every block back to its own reset state, as `SimulationEngine.reset()` does.
    public func reset() { dirigo_sim_reset(sim) }

    public var tickCount: UInt64 { dirigo_sim_tick_count(sim) }

    /// One cycle. Reports whether a thread ran, like `SimulationEngine.stepIfDue`.
    ///
    /// `now` is the step's wall clock and is **required**, not defaulted: the caller that owns the clock
    /// has to hand the same instant to both engines, or a `TMDateTime` pin would differ between them for
    /// a reason that has nothing to do with the port. See `DirigoWallClock` and `SimulationEngine.now`.
    @discardableResult
    public func step(deltaMs: Double, now: Date) -> Bool {
        dirigo_sim_set_wall_clock(sim, Self.wallClock(from: now))
        return dirigo_sim_step(sim, deltaMs) != 0
    }

    /// Decomposes an instant the way `DateTimeBlock` does, so the two engines cannot disagree about the
    /// calendar: `DirigoEpoch` owns the epoch (days since 1 Jan 1980) and the weekday convention
    /// (0 = Monday), and this only moves its answers across the C boundary.
    static func wallClock(from date: Date) -> DirigoWallClock {
        let parts = DirigoEpoch.calendar.dateComponents([.hour, .minute, .second], from: date)
        return DirigoWallClock(days: Int32(DirigoEpoch.days(from: date)),
                               hour: Int32(parts.hour ?? 0),
                               minute: Int32(parts.minute ?? 0),
                               second: Int32(parts.second ?? 0),
                               dayOfWeek: Int32(DirigoEpoch.dayOfWeek(from: date)),
                               unixSeconds: date.timeIntervalSince1970)
    }

    /// Milliseconds until the earliest thread is due.
    public func nextDueInMs() -> Double { dirigo_sim_next_due_ms(sim) }

    /// Milliseconds of simulated time until a thread next runs, exactly.
    public func msUntilNextRun() -> Double { dirigo_sim_ms_until_run(sim) }

    public func outValue(moduleId: Int, pin: Int) -> PinValue? {
        guard let index = indexByModuleId[moduleId] else { return nil }
        return Self.pinValue(dirigo_sim_get_out(sim, index, Int32(clamping: pin)))
    }

    public func inValue(moduleId: Int, pin: Int) -> PinValue? {
        guard let index = indexByModuleId[moduleId] else { return nil }
        return Self.pinValue(dirigo_sim_get_in(sim, index, Int32(clamping: pin)))
    }

    public func setIn(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_in(sim, index, Int32(clamping: pin), Self.cValue(value))
    }

    public func setOut(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_out(sim, index, Int32(clamping: pin), Self.cValue(value))
    }

    public func setParam(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_param(sim, index, Int32(clamping: pin), Self.cValue(value))
    }

    // MARK: - Value translation

    static func cValue(_ value: PinValue) -> DirigoValue {
        var out = DirigoValue()
        switch value {
        case .bool(let v):
            out.kind = Int32(DIRIGO_VALUE_BOOL.rawValue); out.i = v ? 1 : 0
        case .int16(let v):
            out.kind = Int32(DIRIGO_VALUE_INT16.rawValue); out.i = Int32(v)
        case .int32(let v):
            out.kind = Int32(DIRIGO_VALUE_INT32.rawValue); out.i = v
        case .int64(let v):
            out.kind = Int32(DIRIGO_VALUE_INT64.rawValue); out.i64 = v
        case .float(let v):
            out.kind = Int32(DIRIGO_VALUE_FLOAT.rawValue); out.f = Double(v)
        case .undefined:
            out.kind = Int32(DIRIGO_VALUE_UNDEFINED.rawValue)
        }
        return out
    }

    static func pinValue(_ value: DirigoValue) -> PinValue {
        // Switched on the raw value rather than on `DirigoValueKind(rawValue:)`: a C enum's Swift
        // initialiser is not failable — it traps on an unknown value — so an unexpected `kind` from the
        // core would be a crash rather than `.undefined`.
        switch Int32(value.kind) {
        case Int32(DIRIGO_VALUE_BOOL.rawValue): return .bool(value.i != 0)
        case Int32(DIRIGO_VALUE_INT16.rawValue): return .int16(Int16(truncatingIfNeeded: value.i))
        case Int32(DIRIGO_VALUE_INT32.rawValue): return .int32(value.i)
        case Int32(DIRIGO_VALUE_INT64.rawValue): return .int64(value.i64)
        case Int32(DIRIGO_VALUE_FLOAT.rawValue): return .float(Float(value.f))
        default: return .undefined
        }
    }
}
