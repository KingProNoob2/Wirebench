import Foundation
import WirebenchCore
import WirebenchLibrary
import WirebenchHardware

/// Compiles a Wirebench FBD project to an MFLW v1 image for the Maramat Duino-S (`PLC_HAL_MODEL_ID 0x0407`).
///
/// The image format and instruction encoding are ported from Maraflow's `MflwEmitter` and the
/// Duino-S `mara_vm.h`. Only FBD is compiled in this first pass: ST/LD pages and blocks with no
/// Duino-S opcode are reported as errors instead of producing an image that silently does nothing.
public enum DuinoCompiler {
    public static let headerSize = 72
    public static let modelId: UInt16 = 0x0407
    public static let maxImageBytes = 28_672
    public static let threadCount = 6
    public static let alwaysEnabledSlot: UInt16 = 0xFFFF

    public struct Result: Sendable {
        public var image: [UInt8]
        /// Operand name (`Block.Output`, `Page.Variable`) to the slot the VM watches.
        public var slots: [String: UInt16]
        public var slotNames: [UInt16: String]
        public var slotTypes: [UInt16: DuinoSlotType]
        public var notes: [String]
    }

    public enum CompileError: Error, LocalizedError, Equatable {
        case noProgram
        case unsupportedBlock(String, page: String)
        case unsupportedLanguage(String)
        case noPins(String)
        case missingDefinition(String)
        case imageTooLarge(Int)
        case slotLimit(String)
        case badWire(String)

        public var errorDescription: String? {
            switch self {
            case .noProgram:
                return "There is nothing to compile for the Duino-S: the project has no FBD modules."
            case .unsupportedBlock(let name, let page):
                return "Block '\(name)' on page '\(page)' has no Duino-S opcode mapping."
            case .unsupportedLanguage(let page):
                return "Page '\(page)' is not FBD. The Duino-S compiler supports FBD pages only."
            case .noPins(let name):
                return "Block '\(name)' has no pins to compile."
            case .missingDefinition(let name):
                return "Block '\(name)' has no Maraflow block definition."
            case .imageTooLarge(let size):
                return "The generated MFLW image is \(size) bytes; the Duino-S limit is \(maxImageBytes)."
            case .slotLimit(let detail):
                return "The program needs more VM slots than the Duino-S has: \(detail)."
            case .badWire(let detail):
                return "A wire could not be compiled: \(detail)."
            }
        }
    }

    // MARK: - Public entry point

    public static func compile(project: PCCProject) throws -> Result {
        let expanded = try DuinoMacroExpander.expand(project)
        var compiler = Compiler(project: expanded)
        return try compiler.compile()
    }
}

/// The four VM slot families. The top two bits of a slot ID select one.
public enum DuinoSlotType: Int, Sendable, CaseIterable {
    case bool = 0
    case int = 1
    case long = 2
    case float = 3

    public var slotBytes: Int {
        switch self {
        case .bool: return 1
        case .int, .float: return 4
        case .long: return 8
        }
    }

    /// A slot ID as the VM tags it: `(type << 14) | index`.
    public init?(slot: UInt16) {
        self.init(rawValue: Int(slot >> 14))
    }


    /// Decode a little-endian slot value for display/watch.
    public func value(from bytes: [UInt8]) -> Double {
        switch self {
        case .bool: return bytes.first == 1 ? 1 : 0
        case .int:
            guard bytes.count >= 4 else { return 0 }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Int32(bitPattern: bits))
        case .long:
            guard bytes.count >= 8 else { return 0 }
            var bits: UInt64 = 0
            for index in 0..<8 { bits |= UInt64(bytes[index]) << (index * 8) }
            return Double(Int64(bitPattern: bits))
        case .float:
            guard bytes.count >= 4 else { return 0 }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        }
    }

    public func bytes(from value: Double) -> [UInt8] {
        switch self {
        case .bool: return [value != 0 ? 1 : 0]
        case .int:
            let raw = UInt32(bitPattern: Int32(clamping: Int(value)))
            return [UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8),
                    UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 24)]
        case .long:
            let raw = UInt64(bitPattern: Int64(value))
            return (0..<8).map { UInt8(truncatingIfNeeded: raw >> ($0 * 8)) }
        case .float:
            let raw = Float(value).bitPattern
            return [UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8),
                    UInt8(truncatingIfNeeded: raw >> 16), UInt8(truncatingIfNeeded: raw >> 24)]
        }
    }
}

// MARK: - The emitter state

private struct Compiler {
    let project: PCCProject
    private var nextSlot = [Int](repeating: 0, count: 4)
    private var nextState = 0
    private var initEntries: [(slot: UInt16, bits: UInt64)] = []
    private var slots: [String: UInt16] = [:]
    private var slotNames: [UInt16: String] = [:]
    private var slotTypes: [UInt16: DuinoSlotType] = [:]
    private var notes: [String] = []
    private var blocksByID: [Int: CompileBlock] = [:]
    private var wiresByInput: [WireKey: WireSource] = [:]
    private var outputSlots: [Int: [UInt16]] = [:]
    private var threads = Array(repeating: [UInt8](), count: DuinoCompiler.threadCount)

    init(project: PCCProject) {
        self.project = project
    }

    mutating func compile() throws -> DuinoCompiler.Result {
        try collectBlocks()
        guard !blocksByID.isEmpty else { throw DuinoCompiler.CompileError.noProgram }
        collectWires()
        try emitProgram()
        let image = try assemble()
        return DuinoCompiler.Result(image: image, slots: slots, slotNames: slotNames, slotTypes: slotTypes, notes: notes)
    }

    // MARK: - Model

    private struct CompileBlock {
        var module: PCCModule
        var definition: MaraflowDefinition
        var definitionID: String
        var inputs: [PinSpec]
        var outputs: [PinSpec]
        var inputIndices: [Int]
        var outputIndices: [Int]
        var properties: [String: String]
        var inputConstants: [PinValue]
        var outputValues: [PinValue]
        var macro: MacroInfo?
    }

    private struct PinSpec {
        var short: String
        var type: DuinoSlotType
    }

    private struct MacroInfo {
        var name: String
        var page: String
    }

    private struct WireKey: Hashable {
        var module: Int
        var pin: Int
    }

    private struct WireSource {
        var module: Int
        var pin: Int
    }

    // MARK: - Collection

    private mutating func collectBlocks() throws {
        let macroPages = Set(project.modules.filter { $0.page.hasPrefix("*") }.map { $0.page.lowercased() })
        let fbdModules = project.modules.filter { !$0.page.hasPrefix("*") }
        guard !fbdModules.isEmpty else { throw DuinoCompiler.CompileError.noProgram }

        for module in fbdModules {
            if module.guid == MaraflowStPage.guid || module.guid == MaraflowLdPage.guid {
                throw DuinoCompiler.CompileError.unsupportedLanguage(module.page)
            }
            if module.guid == MacroBlock.guid { continue } // resolved below, after every block is known
            let (definition, bridge) = try definitionFor(module)
            var inputIndices: [Int] = []
            var outputIndices: [Int] = []
            for (index, spec) in definition.inputs.enumerated() {
                let source = bridge?.inputs[index] ?? index
                inputIndices.append(source)
                _ = spec
            }
            for (index, _) in definition.outputs.enumerated() {
                outputIndices.append(bridge?.outputs[index] ?? index)
            }
            let inputs = definition.inputs.map { PinSpec(short: $0.abbrev, type: slotType($0.dataType)) }
            let outputs = definition.outputs.map { PinSpec(short: $0.abbrev, type: slotType($0.dataType)) }
            guard !inputs.isEmpty || !outputs.isEmpty else {
                notes.append("Block '\(module.name)' has no pins; skipped.")
                continue
            }
            var inputConstants: [PinValue] = []
            for (index, _) in definition.inputs.enumerated() {
                let source = inputIndices[index]
                inputConstants.append(module.inPins.indices.contains(source) ? module.inPins[source].value : .undefined)
            }
            var outputValues: [PinValue] = []
            for (index, _) in definition.outputs.enumerated() {
                let source = outputIndices[index]
                outputValues.append(module.outPins.indices.contains(source) ? module.outPins[source].value : .undefined)
            }
            var props: [String: String] = [:]
            for (key, value) in module.rawAttributes where key.hasPrefix("MARAFLOW_PROP_") {
                props[String(key.dropFirst("MARAFLOW_PROP_".count))] = value
            }
            let block = CompileBlock(module: module, definition: definition, definitionID: definition.id,
                                     inputs: inputs, outputs: outputs,
                                     inputIndices: inputIndices, outputIndices: outputIndices,
                                     properties: props, inputConstants: inputConstants,
                                     outputValues: outputValues, macro: nil)
            blocksByID[module.id] = block
        }

        // Macro calls are a second pass: their pages must already be discoverable.
        for module in fbdModules where module.guid == MacroBlock.guid {
            let target = module.rawAttributes["MARAFLOW_DEF"].map { String($0.dropFirst("Macro.User.".count)) }
                ?? module.rawAttributes["MACRO_NAME"] ?? ""
            guard !target.isEmpty, macroPages.contains("*" + target.lowercased()) else {
                throw DuinoCompiler.CompileError.missingDefinition(module.name)
            }
            let def = MacroDefinition.make(name: target, module: module)
            let block = CompileBlock(module: module, definition: def, definitionID: "Macro.User.\(target)",
                                     inputs: def.inputs.map { PinSpec(short: $0.abbrev, type: slotType($0.dataType)) },
                                     outputs: def.outputs.map { PinSpec(short: $0.abbrev, type: slotType($0.dataType)) },
                                     inputIndices: Array(0..<def.inputs.count),
                                     outputIndices: Array(0..<def.outputs.count),
                                     properties: [:], inputConstants: module.inPins.map(\.value),
                                     outputValues: module.outPins.map(\.value),
                                     macro: MacroInfo(name: target, page: "*" + target.lowercased()))
            blocksByID[module.id] = block
        }
    }

    private mutating func collectWires() {
        // Connections carry Pin.id values, not array positions; map them to the block's pin order.
        for wire in project.inConnections + project.paramConnections {
            guard let target = blocksByID[wire.inModuleId],
                  let input = target.module.inPins.firstIndex(where: { $0.id == wire.inPinId }) else { continue }
            wiresByInput[WireKey(module: wire.inModuleId, pin: input)] =
                WireSource(module: wire.outModuleId, pin: wire.outPinId)
        }
    }

    private func definitionFor(_ module: PCCModule) throws -> (MaraflowDefinition, MaraflowExporter.Bridge?) {
        if let raw = module.rawAttributes["MARAFLOW_DEF"],
           let definition = MaraflowCatalog.byId[raw] {
            return (definition, nil)
        }
        if let definition = MaraflowCatalog.definition(forGuid: module.guid) {
            return (definition, nil)
        }
        if let info = BlockTypeCatalog.info(forGuid: module.guid),
           let bridge = MaraflowExporter.bridge(for: info),
           let definition = MaraflowCatalog.byId[bridge.definitionId] {
            return (definition, bridge)
        }
        throw DuinoCompiler.CompileError.unsupportedBlock(module.name, page: module.page)
    }

    private func slotType(_ text: String) -> DuinoSlotType {
        switch text.uppercased() {
        case "BOOL", "BOOLEAN", "BIT": return .bool
        case "LONG", "INT64": return .long
        case "FLOAT", "REAL": return .float
        default: return .int
        }
    }

    // MARK: - Program

    private mutating func emitProgram() throws {
        let sorted = blocksByID.values.sorted {
            ($0.module.threadId, $0.module.order, $0.module.id) < ($1.module.threadId, $1.module.order, $1.module.id)
        }
        // All output slots are allocated before any code: a feedback wire reads a block that may be emitted later.
        for block in sorted { allocateOutputSlots(for: block) }
        for block in sorted {
            let thread = min(max(block.module.threadId, 1), 5)
            if block.macro != nil {
                throw DuinoCompiler.CompileError.unsupportedBlock(block.module.name, page: block.module.page)
            }
            var stream = threads[thread]
            try emit(block, into: &stream)
            threads[thread] = stream
        }
        for thread in 1..<DuinoCompiler.threadCount {
            var stream = threads[thread]
            word(0x00, 0, UInt16(DuinoCompiler.alwaysEnabledSlot), 0, 0, into: &stream)
            threads[thread] = stream
        }
    }

    // MARK: - Slot allocation

    private mutating func alloc(_ type: DuinoSlotType) -> UInt16 {
        let index = nextSlot[type.rawValue]
        nextSlot[type.rawValue] += 1
        return UInt16(type.rawValue << 14) | UInt16(truncatingIfNeeded: index)
    }

    private mutating func allocInit(_ type: DuinoSlotType, value: PinValue, name: String) -> UInt16 {
        let slot = alloc(type)
        initEntries.append((slot, bits(for: value, type: type)))
        slots[name] = slot
        slotNames[slot] = name
        slotTypes[slot] = type
        return slot
    }

    private func bits(for value: PinValue, type: DuinoSlotType) -> UInt64 {
        switch type {
        case .bool:
            return value.asBool ? 1 : 0
        case .int:
            return UInt64(UInt32(bitPattern: value.asInt32))
        case .long:
            return UInt64(bitPattern: Int64(value.asInt))
        case .float:
            return UInt64(valueValue(value).bitPattern)
        }
    }

    private func valueValue(_ value: PinValue) -> Float {
        switch value {
        case .float(let f): return f
        default: return Float(value.asInt)
        }
    }

    private mutating func constant(_ value: PinValue, type: DuinoSlotType, name: String) -> UInt16 {
        allocInit(type, value: value, name: name)
    }

    // MARK: - Inputs

    private mutating func inputSlot(_ inputIndex: Int, of block: CompileBlock, into out: inout [UInt8]) throws -> UInt16 {
        let pin = block.inputs[inputIndex]
        let dirigo = block.inputIndices[inputIndex]
        if let wire = wiresByInput[WireKey(module: block.module.id, pin: dirigo)] {
            if let sourceBlock = blocksByID[wire.module],
               let sourcePin = sourceBlock.module.outPins.firstIndex(where: { $0.id == wire.pin }),
               let outputIndex = sourceBlock.outputIndices.firstIndex(of: sourcePin),
               let slot = outputSlots[wire.module]?[outputIndex] {
                if pin.type == .bool, block.module.inPins.indices.contains(dirigo),
                   block.module.inPins[dirigo].inverted {
                    let negated = alloc(.bool)
                    word(0x16, 0, UInt16(DuinoCompiler.alwaysEnabledSlot), negated, slot, into: &out)
                    return negated
                }
                return slot
            }
            // A display or an unsupported source produces no slot. Treat the input as constant 0 rather
            // than failing the whole image; the source is reported in the notes.
            notes.append("Input '\(block.module.name).\(pin.short)' is fed by \(wire.module).\(wire.pin), "
                         + "which has no Duino-S slot; using constant 0.")
        }
        let value = block.inputConstants.indices.contains(inputIndex) ? block.inputConstants[inputIndex] : .undefined
        var raw = value
        if pin.type == .bool, block.module.inPins.indices.contains(dirigo),
           block.module.inPins[dirigo].inverted {
            raw = .bool(!value.asBool)
        }
        let key = "\(block.module.name).\(pin.short)"
        return constant(raw, type: pin.type, name: key)
    }

    private mutating func allocateOutputSlots(for block: CompileBlock) {
        var allocated: [UInt16] = []
        for (index, pin) in block.outputs.enumerated() {
            let name = "\(block.module.name).\(pin.short)"
            let value = block.outputValues.indices.contains(index) ? block.outputValues[index] : .undefined
            allocated.append(allocInit(pin.type, value: value, name: name))
        }
        outputSlots[block.module.id] = allocated
    }

    // MARK: - Emit

    private mutating func emit(_ block: CompileBlock, into out: inout [UInt8]) throws {
        let def = block.definitionID
        let first = block.inputs.first?.short.lowercased() == "en" ? 1 : 0
        // Resolve every input once: the En slot is the first of them, not a second allocation.
        var ins: [UInt16] = []
        for index in block.inputs.indices { ins.append(try inputSlot(index, of: block, into: &out)) }
        let en = first == 1 && !ins.isEmpty ? ins[0] : UInt16(DuinoCompiler.alwaysEnabledSlot)
        let outs = outputSlots[block.module.id] ?? []
        defer { emitOutputInversions(block, outs: outs, en: en, into: &out) }

        switch def {
        case "Bool.And", "Bool.Nand", "Bool.Or", "Bool.Nor", "Bool.Xor", "Bool.Xnor":
            let op: UInt8 = switch def {
            case "Bool.And": 0x10
            case "Bool.Nand": 0x11
            case "Bool.Or": 0x12
            case "Bool.Nor": 0x13
            case "Bool.Xor": 0x14
            default: 0x15
            }
            let argc = max(2, block.inputs.count - first)
            let dst = outs.first ?? 0
            word(op, UInt8(truncatingIfNeeded: argc), en, dst, ins[min(first, ins.count - 1)], into: &out)
            let extra = argc - 1
            var written = 0
            while written < extra {
                let a = first + 1 + written < ins.count ? ins[first + 1 + written] : 0
                let b = first + 2 + written < ins.count ? ins[first + 2 + written] : 0
                u16(a, into: &out); u16(b, into: &out)
                written += 2
            }
        case "Bool.Not":
            word(0x16, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
        case "Bool.RS", "Bool.SR":
            let op: UInt8 = def == "Bool.RS" ? 0x17 : 0x18
            let q = outs.first ?? 0
            let nq = outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            let s = ins[min(first, ins.count - 1)]
            let r = ins[min(first + 1, ins.count - 1)]
            let qNeg = block.module.outPins.indices.contains(block.outputIndices[0]) && block.module.outPins[block.outputIndices[0]].inverted
            let latch = qNeg ? alloc(.bool) : q
            word(op, 0, en, latch, s, into: &out)
            u16(r, into: &out); u16(nq, into: &out)
            if qNeg { word(0x16, 0, en, q, latch, into: &out) }
        case "Math.Add", "Math.Sub", "Math.Mul", "Math.Min", "Math.Max":
            let op: UInt8 = switch def {
            case "Math.Add": 0x20
            case "Math.Sub": 0x21
            case "Math.Mul": 0x22
            case "Math.Min": 0x26
            default: 0x27
            }
            let a = ins[min(first, ins.count - 1)]
            let b = ins[min(first + 1, ins.count - 1)]
            word(op, 0, en, outs.first ?? 0, a, into: &out)
            u16(b, into: &out); u16(0, into: &out)
        case "Math.Div", "Math.Mod":
            let a = ins[min(first, ins.count - 1)]
            let b = ins[min(first + 1, ins.count - 1)]
            word(def == "Math.Div" ? 0x23 : 0x24, 0, en, outs.first ?? 0, a, into: &out)
            u16(b, into: &out)
            u16(outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot), into: &out)
        case "Math.Abs", "Math.Neg", "Math.Sqrt", "Math.Sin", "Math.Cos":
            let op: UInt8 = switch def {
            case "Math.Abs": 0x28
            case "Math.Neg": 0x29
            case "Math.Sqrt": 0x2A
            case "Math.Sin": 0x2B
            default: 0x2C
            }
            word(op, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
        case "Math.Clamp":
            word(0x2D, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
        case "Main.Comparators.EQ", "Main.Comparators.NE", "Main.Comparators.GT",
             "Main.Comparators.GE", "Main.Comparators.LT", "Main.Comparators.LE":
            let op: UInt8 = switch def {
            case "Main.Comparators.EQ": 0x40
            case "Main.Comparators.NE": 0x41
            case "Main.Comparators.GT": 0x42
            case "Main.Comparators.GE": 0x43
            case "Main.Comparators.LT": 0x44
            default: 0x45
            }
            word(op, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(0, into: &out)
        case "Main.Switches.Sel":
            word(0x48, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
        case "Main.Conversion.PackBits":
            let msb: UInt8 = (block.properties["BitOrder"] ?? "LSB").uppercased() == "MSB" ? 1 : 0
            word(0x0A, msb, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            for i in 1..<8 { u16(ins[min(first + i, ins.count - 1)], into: &out) }
            u16(0, into: &out)
        case "Main.Conversion.UnpackBits":
            let msb: UInt8 = (block.properties["BitOrder"] ?? "LSB").uppercased() == "MSB" ? 1 : 0
            word(0x0B, msb, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            for i in 1..<8 { u16(outs.indices.contains(i) ? outs[i] : 0, into: &out) }
            u16(0, into: &out)
        case "Main.Timers.Timer":
            let q = outs.first ?? 0
            let et = outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            word(0x50, 0, en, q, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(et, into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Timers.SinglePulse":
            word(0x53, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "IO.IREF":
            let ref = block.properties["Channel"] ?? block.module.name
            let analog = ref.uppercased().hasPrefix("AI")
            word(0x70, analog ? 2 : 0, UInt16(DuinoCompiler.alwaysEnabledSlot),
                 outs.first ?? 0, UInt16(ioChannel(ref)), into: &out)
        case "IO.OREF":
            let ref = block.properties["Channel"] ?? block.module.name
            let analog = ref.uppercased().hasPrefix("AO")
            word(0x71, analog ? 3 : 1, UInt16(DuinoCompiler.alwaysEnabledSlot),
                 UInt16(ioChannel(ref)), ins.first ?? 0, into: &out)
            if !ref.isEmpty { slots[ref] = ins.first ?? 0 }
        case "IO.PWM":
            let ref = block.properties["Channel"] ?? block.module.name
            word(0x72, 0, en, outs.first ?? 0, UInt16(ioChannel(ref)), into: &out)
            u16(ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
        case "Visual.Segment":
            break // a display reads pins; it has no VM instruction

        case "Visual.Vars.BoolVar", "Visual.Vars.IntVar", "Visual.Vars.LongVar", "Visual.Vars.FloatVar", "Visual.Value":
            // A variable's output slot was allocated with its initial value; Visual.Value just names an input.
            if def == "Visual.Value", let firstInput = ins.first { slots["\(block.module.name).In"] = firstInput }
        default:
            throw DuinoCompiler.CompileError.unsupportedBlock(block.module.name, page: block.module.page)
        }
    }

    private mutating func emitOutputInversions(_ block: CompileBlock, outs: [UInt16], en: UInt16, into out: inout [UInt8]) {
        // The VM writes the slot directly; an inverted source pin is the only case this compiler emits.
        for (index, pin) in block.outputs.enumerated() where pin.type == .bool {
            let dirigo = block.outputIndices.indices.contains(index) ? block.outputIndices[index] : index
            guard block.module.outPins.indices.contains(dirigo), block.module.outPins[dirigo].inverted,
                  outs.indices.contains(index) else { continue }
            let source = outs[index]
            word(0x16, 0, UInt16(DuinoCompiler.alwaysEnabledSlot), source, source, into: &out)
        }
    }

    // MARK: - Assembly

    private mutating func assemble() throws -> [UInt8] {
        let limits = [2048, 1024, 256, 1024]
        for (type, limit) in limits.enumerated() where nextSlot[type] > limit {
            throw DuinoCompiler.CompileError.slotLimit("\(nextSlot[type]) slots of type \(type), limit \(limit)")
        }
        guard nextState <= 512 else {
            throw DuinoCompiler.CompileError.slotLimit("\(nextState) state slots, limit 512")
        }
        let initOffset = DuinoCompiler.headerSize
        let initBytes = initEntries.count * 12
        var cursor = initOffset + initBytes
        var threadOffsets = [UInt32](repeating: 0, count: DuinoCompiler.threadCount)
        for thread in 1..<DuinoCompiler.threadCount {
            threadOffsets[thread] = UInt32(cursor)
            cursor += threads[thread].count
        }
        guard cursor <= DuinoCompiler.maxImageBytes else {
            throw DuinoCompiler.CompileError.imageTooLarge(cursor)
        }
        var image = [UInt8](repeating: 0, count: cursor)
        writeLE32(&image, 0, 0x574C464D)
        writeLE16(&image, 4, 0x0001)
        writeLE16(&image, 6, DuinoCompiler.modelId)
        writeLE32(&image, 8, UInt32(cursor))
        writeLE32(&image, 16, projectHash())
        writeLE16(&image, 20, UInt16(nextSlot[0]))
        writeLE16(&image, 22, UInt16(nextSlot[1]))
        writeLE16(&image, 24, UInt16(nextSlot[2]))
        writeLE16(&image, 26, UInt16(nextSlot[3]))
        writeLE16(&image, 28, UInt16(nextState))
        writeLE32(&image, 36, UInt32(initOffset))
        writeLE32(&image, 40, UInt32(initEntries.count))
        for thread in 0..<DuinoCompiler.threadCount {
            writeLE32(&image, 44 + thread * 4, threadOffsets[thread])
        }
        var position = initOffset
        for entry in initEntries {
            writeLE16(&image, position, entry.slot)
            writeLE16(&image, position + 2, 0)
            writeLE64(&image, position + 4, entry.bits)
            position += 12
        }
        for thread in 1..<DuinoCompiler.threadCount {
            let start = Int(threadOffsets[thread])
            image.replaceSubrange(start..<(start + threads[thread].count), with: threads[thread])
        }
        let crc = MaraProtFrame.crc32(image[DuinoCompiler.headerSize...])
        writeLE32(&image, 12, crc)
        return image
    }

    private func projectHash() -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in project.name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        for module in project.modules.sorted(by: { $0.id < $1.id }) {
            for byte in module.name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        return hash
    }

    private func ioChannel(_ text: String) -> Int {
        let digits = text.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // MARK: - Words

    private func word(_ op: UInt8, _ flags: UInt8, _ en: UInt16, _ dst: UInt16, _ src: UInt16,
                      into out: inout [UInt8]) {
        out.append(op); out.append(flags)
        u16(en, into: &out); u16(dst, into: &out); u16(src, into: &out)
    }

    private func u16(_ value: UInt16, into out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func writeLE16(_ image: inout [UInt8], _ offset: Int, _ value: UInt16) {
        image[offset] = UInt8(truncatingIfNeeded: value)
        image[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeLE32(_ image: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { image[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func writeLE64(_ image: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0..<8 { image[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}

// MARK: - Macro definitions built from the project's call pins

private enum MacroDefinition {
    static func make(name: String, module: PCCModule) -> MaraflowDefinition {
        let inputs = module.inPins.enumerated().map { index, pin in
            MaraflowPinSpec(abbrev: pin.name ?? "X\(index)", name: pin.name ?? "Input \(index)",
                            dataType: type(pin.value), defaultValue: "0")
        }
        let outputs = module.outPins.enumerated().map { index, pin in
            MaraflowPinSpec(abbrev: pin.name ?? "Y\(index)", name: pin.name ?? "Output \(index)",
                            dataType: type(pin.value), defaultValue: "0")
        }
        return MaraflowDefinition(id: "Macro.User.\(name)", guid: MacroBlock.guid, typeName: name,
                                  category: "Macro", delphiClass: "TMacro", summary: "",
                                  inputs: inputs, outputs: outputs, variableInputCount: false,
                                  configurableDataType: false, defaultInputCount: nil)
    }

    private static func type(_ value: PinValue) -> String {
        switch value {
        case .bool: return "BOOL"
        case .float: return "FLOAT"
        case .int64: return "LONG"
        default: return "INT"
        }
    }
}
