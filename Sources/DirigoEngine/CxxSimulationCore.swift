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
        // Blocks whose pins *are* their behaviour: the I/O channels, and the displays that show them.
        case "TMDigitalInputs", "TMDigitalOutputs", "TDispValueModule", "TDispSegmentModule":
            return DIRIGO_BLOCK_PASSIVE
        default: return nil
        }
    }

    /// Whether every module in a project has a ported kind, which is what makes running it here sound.
    public static func isFullyPorted(_ project: PCCProject) -> Bool {
        project.modules.allSatisfy { kind(forGUID: $0.guid) != nil }
    }

    public init(project: PCCProject, profileScheduling: Bool = true) {
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
            let kind = Self.kind(forGUID: mod.guid) ?? DIRIGO_BLOCK_UNRESOLVED
            if kind != DIRIGO_BLOCK_UNRESOLVED { ported += 1 }
            index[mod.id] = Int32(position)
            totalIn += block.inPins.count
            totalOut += block.outPins.count
            pinValues.append((block.inPins, block.outPins))
            descs.append(DirigoModuleDesc(
                id: Int32(mod.id),
                order: Int32(mod.order),
                threadId: Int32(mod.threadId),
                kind: Int32(kind.rawValue),
                inCount: Int32(block.inPins.count),
                paramCount: Int32(block.paramPins.count),
                outCount: Int32(block.outPins.count),
                initialOut: nil, initialIn: nil))
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

        var connections: [DirigoConnection] = []
        for (list, isParam) in [(project.inConnections, false), (project.paramConnections, true)] {
            for conn in list {
                connections.append(DirigoConnection(
                    inModule: Int32(conn.inModuleId), inPin: Int32(conn.inPinId),
                    outModule: Int32(conn.outModuleId), outPin: Int32(conn.outPinId),
                    inverted: 0, toParamPins: isParam ? 1 : 0))
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
        }
        // Macro interfaces. The Swift engine finds these by matching `MACRO_NAME` and `KIND`
        // attributes and page names; doing that here rather than in C++ keeps the string matching in
        // one place, and the core only has to copy pins between the two modules it is handed.
        let bridges = Self.macroBridges(in: project)
        if !bridges.isEmpty {
            bridges.withUnsafeBufferPointer { buffer in
                dirigo_sim_set_macro_bridges(created, buffer.baseAddress, Int32(buffer.count))
            }
        }

        self.sim = created
        self.indexByModuleId = index
        self.portedModuleCount = ported
        self.unresolvedModuleCount = descs.count - ported
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
        let reserved: Set<String> = ["inputs", "outputs", "params"]

        for macro in project.modules {
            guard let name = macro.rawAttributes["MACRO_NAME"], !name.isEmpty,
                  !macro.page.hasPrefix("*"),
                  !reserved.contains(name.lowercased()) else { continue }
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
    @discardableResult
    public func step(deltaMs: Double) -> Bool { dirigo_sim_step(sim, deltaMs) != 0 }

    /// Milliseconds until the earliest thread is due.
    public func nextDueInMs() -> Double { dirigo_sim_next_due_ms(sim) }

    public func outValue(moduleId: Int, pin: Int) -> PinValue? {
        guard let index = indexByModuleId[moduleId] else { return nil }
        return Self.pinValue(dirigo_sim_get_out(sim, index, Int32(pin)))
    }

    public func inValue(moduleId: Int, pin: Int) -> PinValue? {
        guard let index = indexByModuleId[moduleId] else { return nil }
        return Self.pinValue(dirigo_sim_get_in(sim, index, Int32(pin)))
    }

    public func setIn(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_in(sim, index, Int32(pin), Self.cValue(value))
    }

    public func setOut(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_out(sim, index, Int32(pin), Self.cValue(value))
    }

    public func setParam(moduleId: Int, pin: Int, value: PinValue) {
        guard let index = indexByModuleId[moduleId] else { return }
        dirigo_sim_set_param(sim, index, Int32(pin), Self.cValue(value))
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
