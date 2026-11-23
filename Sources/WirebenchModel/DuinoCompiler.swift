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
    private var nextMovAvg = 0
    private var arrayIndices: [String: Int] = [:]
    private var registerSlots: [String: UInt16] = [:]
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

    private struct TimeZoneRule {
        var stdOffset = 0
        var dstOffset = 0
        var startMonth = 0
        var startWeek = 0
        var startDow = 0
        var startHour = 0
        var endMonth = 0
        var endWeek = 0
        var endDow = 0
        var endHour = 0

        static func from(_ properties: [String: String]) -> TimeZoneRule {
            let presets: [String: TimeZoneRule] = [
                "UTC": TimeZoneRule(),
                "Europe/Prague": TimeZoneRule(stdOffset: 60, dstOffset: 60, startMonth: 3, startWeek: -1, startDow: 0, startHour: 2, endMonth: 10, endWeek: -1, endDow: 0, endHour: 3),
                "Europe/London": TimeZoneRule(stdOffset: 0, dstOffset: 60, startMonth: 3, startWeek: -1, startDow: 0, startHour: 1, endMonth: 10, endWeek: -1, endDow: 0, endHour: 2),
                "Europe/Athens": TimeZoneRule(stdOffset: 120, dstOffset: 60, startMonth: 3, startWeek: -1, startDow: 0, startHour: 3, endMonth: 10, endWeek: -1, endDow: 0, endHour: 4),
                "Europe/Moscow": TimeZoneRule(stdOffset: 180),
                "America/New_York": TimeZoneRule(stdOffset: -300, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "America/Chicago": TimeZoneRule(stdOffset: -360, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "America/Denver": TimeZoneRule(stdOffset: -420, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "America/Phoenix": TimeZoneRule(stdOffset: -420),
                "America/Los_Angeles": TimeZoneRule(stdOffset: -480, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "America/Anchorage": TimeZoneRule(stdOffset: -540, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "Pacific/Honolulu": TimeZoneRule(stdOffset: -600),
                "America/St_Johns": TimeZoneRule(stdOffset: -210, dstOffset: 60, startMonth: 3, startWeek: 2, startDow: 0, startHour: 2, endMonth: 11, endWeek: 1, endDow: 0, endHour: 2),
                "America/Sao_Paulo": TimeZoneRule(stdOffset: -180),
                "America/Santiago": TimeZoneRule(stdOffset: -240, dstOffset: 60, startMonth: 9, startWeek: 1, startDow: 6, startHour: 24, endMonth: 4, endWeek: 1, endDow: 6, endHour: 24),
                "Asia/Dubai": TimeZoneRule(stdOffset: 240),
                "Asia/Kolkata": TimeZoneRule(stdOffset: 330),
                "Asia/Kathmandu": TimeZoneRule(stdOffset: 345),
                "Asia/Shanghai": TimeZoneRule(stdOffset: 480),
                "Asia/Tokyo": TimeZoneRule(stdOffset: 540),
                "Australia/Adelaide": TimeZoneRule(stdOffset: 570, dstOffset: 60, startMonth: 10, startWeek: 1, startDow: 0, startHour: 2, endMonth: 4, endWeek: 1, endDow: 0, endHour: 3),
                "Australia/Sydney": TimeZoneRule(stdOffset: 600, dstOffset: 60, startMonth: 10, startWeek: 1, startDow: 0, startHour: 2, endMonth: 4, endWeek: 1, endDow: 0, endHour: 3),
                "Australia/Lord_Howe": TimeZoneRule(stdOffset: 630, dstOffset: 30, startMonth: 10, startWeek: 1, startDow: 0, startHour: 2, endMonth: 4, endWeek: 1, endDow: 0, endHour: 2),
                "Pacific/Auckland": TimeZoneRule(stdOffset: 720, dstOffset: 60, startMonth: 9, startWeek: -1, startDow: 0, startHour: 2, endMonth: 4, endWeek: 1, endDow: 0, endHour: 3),
                "Pacific/Chatham": TimeZoneRule(stdOffset: 765, dstOffset: 60, startMonth: 9, startWeek: -1, startDow: 0, startHour: 2, endMonth: 4, endWeek: 1, endDow: 0, endHour: 3),
                "Pacific/Kiritimati": TimeZoneRule(stdOffset: 840),
            ]
            let name = properties["TimeZone"] ?? "UTC"
            if name != "Custom", let preset = presets[name] { return preset }
            func number(_ key: String, _ fallback: Int = 0) -> Int {
                properties[key].flatMap(Int.init) ?? fallback
            }
            return TimeZoneRule(stdOffset: number("TzStdOffsetMin"), dstOffset: number("TzDstOffsetMin"),
                                startMonth: number("TzDstStartMonth"), startWeek: number("TzDstStartWeek"),
                                startDow: number("TzDstStartDow"), startHour: number("TzDstStartHour", 2),
                                endMonth: number("TzDstEndMonth"), endWeek: number("TzDstEndWeek"),
                                endDow: number("TzDstEndDow"), endHour: number("TzDstEndHour", 3))
        }
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
            let inputCount = bridge == nil && definition.variableInputCount
                ? module.inPins.count : definition.inputs.count
            var inputIndices: [Int] = []
            var outputIndices: [Int] = []
            for index in 0..<inputCount {
                let source = bridge?.inputs[index] ?? index
                inputIndices.append(source)
            }
            let outputCount = definition.id == "Math.Div" ? module.outPins.count : definition.outputs.count
            for index in 0..<outputCount {
                outputIndices.append(bridge?.outputs[index] ?? index)
            }
            func shortName(_ specs: [MaraflowPinSpec], _ index: Int, _ pins: [Pin], _ source: Int) -> String {
                if pins.indices.contains(source), let name = pins[source].name, !name.isEmpty { return name }
                if specs.indices.contains(index) { return specs[index].abbrev }
                if let last = specs.last?.abbrev, let number = Int(last.dropFirst()) {
                    return "\(last.prefix(1))\(number + index - specs.count + 1)"
                }
                return "X\(index)"
            }
            var inputs = inputIndices.enumerated().map { index, source -> PinSpec in
                let spec = definition.inputs.indices.contains(index) ? definition.inputs[index] : definition.inputs.last!
                let value = module.inPins.indices.contains(source) ? module.inPins[source].value : .undefined
                let type = definition.configurableDataType ? slotType(value, fallback: spec.dataType) : slotType(spec.dataType)
                return PinSpec(short: shortName(definition.inputs, index, module.inPins, source), type: type)
            }
            var outputs = outputIndices.enumerated().map { index, source -> PinSpec in
                let value = module.outPins.indices.contains(source) ? module.outPins[source].value : .undefined
                if !definition.outputs.indices.contains(index) {
                    return PinSpec(short: "Mod", type: slotType(value, fallback: "Int"))
                }
                let spec = definition.outputs[index]
                let type = definition.configurableDataType ? slotType(value, fallback: spec.dataType) : slotType(spec.dataType)
                return PinSpec(short: shortName(definition.outputs, index, module.outPins, source), type: type)
            }
            let channel = module.rawAttributes["MARAFLOW_PROP_Channel"]?.uppercased() ?? ""
            if definition.id == "IO.IREF", channel.hasPrefix("AI"), !outputs.isEmpty {
                outputs[0].type = .int
            }
            if definition.id == "IO.OREF", channel.hasPrefix("AO"), !inputs.isEmpty {
                inputs[0].type = .int
            }
            guard !inputs.isEmpty || !outputs.isEmpty else {
                notes.append("Block '\(module.name)' has no pins; skipped.")
                continue
            }
            let inputConstants = inputIndices.map { source in
                module.inPins.indices.contains(source) ? module.inPins[source].value : .undefined
            }
            let outputValues = outputIndices.map { source in
                module.outPins.indices.contains(source) ? module.outPins[source].value : .undefined
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

    private func slotType(_ value: PinValue, fallback: String) -> DuinoSlotType {
        switch value {
        case .bool: return .bool
        case .int16, .int32: return .int
        case .int64: return .long
        case .float: return .float
        case .undefined: return slotType(fallback)
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

    /// One shared slot per named register, so a `ReadReg` sees what a `WriteReg` stored (Maraflow `getOrAllocRegSlot`).
    private mutating func registerSlot(_ name: String, type: DuinoSlotType) -> UInt16 {
        let key = name.uppercased()
        if let slot = registerSlots[key] { return slot }
        let slot = allocInit(type, value: .undefined, name: "REG.\(key)")
        registerSlots[key] = slot
        return slot
    }

    /// One array index per distinct array name, capped at the VM's eight arrays (Maraflow `arrayNameToIdx`).
    private mutating func arrayIndex(named name: String) -> Int {
        let key = name.uppercased()
        if let index = arrayIndices[key] { return index }
        let index = min(arrayIndices.count, 7)
        arrayIndices[key] = index
        return index
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
            var value = block.outputValues.indices.contains(index) ? block.outputValues[index] : .undefined
            let dirigo = block.outputIndices.indices.contains(index) ? block.outputIndices[index] : index
            if block.definitionID.hasPrefix("Visual.Vars."), let configured = block.properties["CurrentValue"] {
                value = PinValue.parse(configured)
            }
            if block.definitionID.hasPrefix("Visual.Vars."), pin.type == .bool,
               block.module.outPins.indices.contains(dirigo), block.module.outPins[dirigo].inverted {
                value = .bool(!value.asBool)
            }
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
            let argc = max(2, ins.count - first)
            var accumulator = ins[min(first, ins.count - 1)]
            for index in 1..<argc {
                let target = index == argc - 1 ? (outs.first ?? 0) : alloc(block.outputs.first?.type ?? .int)
                word(op, 0, en, target, accumulator, into: &out)
                u16(ins[first + index], into: &out); u16(0, into: &out)
                accumulator = target
            }
        case "Math.Div", "Math.Mod":
            let a = ins[min(first, ins.count - 1)]
            let b = ins[min(first + 1, ins.count - 1)]
            word(def == "Math.Div" ? 0x23 : 0x24, 0, en, outs.first ?? 0, a, into: &out)
            u16(b, into: &out)
            u16(outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot), into: &out)
            if def == "Math.Div", outs.count > 2 {
                word(0x24, 0, en, outs[2], a, into: &out)
                u16(b, into: &out)
                u16(UInt16(DuinoCompiler.alwaysEnabledSlot), into: &out)
            }
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
        case "Math.Scale":
            word(0x2E, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
            u16(ins[min(first + 3, ins.count - 1)], into: &out)
            u16(ins[min(first + 4, ins.count - 1)], into: &out)
        case "Math.Random":
            word(0x2F, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Math.PID":
            word(0x30, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
            u16(ins[min(first + 3, ins.count - 1)], into: &out)
            u16(ins[min(first + 4, ins.count - 1)], into: &out)
            u16(ins[min(first + 5, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out)
            nextState += 1
        case "Main.Comparators.InRange":
            word(0x46, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
        case "Main.Comparators.Hysteresis":
            word(0x47, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Filters.LowPass":
            word(0x31, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out)
            nextState += 1
        case "Main.Filters.MovingAvg":
            let window = min(max(Int(block.properties["WindowSize"] ?? "8") ?? 8, 1), 64)
            let maIndex = nextMovAvg
            nextMovAvg += 1
            word(0x32, UInt8(window), en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(UInt16(maIndex), into: &out)
        case "Main.Filters.Debounce":
            word(0x33, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out)
            nextState += 1
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
        case "Main.Switches.Mux":
            let dataCount = max(0, ins.count - (first + 1))
            if dataCount > 0 {
                let low = constant(.int32(0), type: .int, name: "\(block.module.name).Lo")
                let high = constant(.int32(Int32(dataCount - 1)), type: .int, name: "\(block.module.name).Hi")
                let clamped = alloc(.int)
                word(0x2D, 0, en, clamped, ins[min(first, ins.count - 1)], into: &out)
                u16(low, into: &out); u16(high, into: &out)
                for index in 0..<dataCount {
                    let indexConstant = constant(.int32(Int32(index)), type: .int,
                                                 name: "\(block.module.name).Sel\(index)")
                    let condition = alloc(.bool)
                    word(0x40, 0, en, condition, clamped, into: &out)
                    u16(indexConstant, into: &out); u16(0, into: &out)
                    let enabledCondition = alloc(.bool)
                    word(0x10, 2, UInt16(DuinoCompiler.alwaysEnabledSlot), enabledCondition, condition, into: &out)
                    u16(en, into: &out); u16(0, into: &out)
                    word(0x08, 0, enabledCondition, outs.first ?? 0, ins[first + 1 + index], into: &out)
                }
            }
        case "Main.Switches.Demux":
            let address = ins[min(first, ins.count - 1)]
            let input = ins[min(first + 1, ins.count - 1)]
            let zero = constant(.int32(0), type: .int, name: "\(block.module.name).Zero")
            for (index, outSlot) in outs.enumerated() {
                let indexConstant = constant(.int32(Int32(index)), type: .int,
                                             name: "\(block.module.name).Sel\(index)")
                let condition = alloc(.bool)
                word(0x40, 0, en, condition, address, into: &out)
                u16(indexConstant, into: &out); u16(0, into: &out)
                let enabledCondition = alloc(.bool)
                word(0x10, 2, UInt16(DuinoCompiler.alwaysEnabledSlot), enabledCondition, condition, into: &out)
                u16(en, into: &out); u16(0, into: &out)
                word(0x08, 0, en, outSlot, zero, into: &out)
                word(0x08, 0, enabledCondition, outSlot, input, into: &out)
            }
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
            let mode = (block.properties["TimerMode"] ?? "TON").uppercased()
            let modeFlag: UInt8 = mode.hasPrefix("TOF") ? 1 : (mode.hasPrefix("TP") ? 2 : 0)
            word(0x50, modeFlag, en, q, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(et, into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Timers.PulseGen":
            word(0x51, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out)
            nextState += 1
        case "Main.Timers.PulseLen":
            word(0x52, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out)
            nextState += 1
        case "Main.Timers.SinglePulse":
            word(0x53, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Timers.Counter":
            let q = outs.first ?? 0
            let cv = outs.count > 1 ? outs[1] : 0
            word(0x54, 0, en, q, ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out)
            u16(ins[min(first + 2, ins.count - 1)], into: &out)
            u16(ins[min(first + 3, ins.count - 1)], into: &out)
            u16(cv, into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Timers.DateTime":
            word(0x60, 0, en, outs.first ?? 0, 0, into: &out)
        case "Main.Timers.DecodeDate", "Main.Timers.EncodeDate":
            let decoding = def == "Main.Timers.DecodeDate"
            word(decoding ? 0x61 : 0x62, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            for index in 1...5 {
                u16(decoding ? (outs.indices.contains(index) ? outs[index] : 0)
                             : ins[min(first + index, ins.count - 1)], into: &out)
            }
            emitTimeZone(.from(block.properties), into: &out)
        case "Main.Arrays.ArrayRead":
            let value = outs.first ?? 0
            let oob = outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            word(0x38, UInt8(arrayIndex(named: block.properties["ArrayName"] ?? "ARR_0")), en, value,
                 ins[min(first, ins.count - 1)], into: &out)
            u16(oob, into: &out); u16(0, into: &out)
        case "Main.Arrays.ArrayWrite":
            let oob = outs.first ?? UInt16(DuinoCompiler.alwaysEnabledSlot)
            word(0x39, UInt8(arrayIndex(named: block.properties["ArrayName"] ?? "ARR_0")), en, oob,
                 ins[min(first, ins.count - 1)], into: &out)
            u16(ins[min(first + 1, ins.count - 1)], into: &out); u16(0, into: &out)
        case "Comm.I2C.TMP75":
            let address = block.properties["DeviceAddressHex"].flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0x48
            word(0x75, 1, en, outs.first ?? 0, UInt16(clamping: address), into: &out)
            u16(outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot), into: &out)
            u16(0, into: &out)
        case "Comm.DS18B20.DS18B20Read":
            let dioPin = min(max(ioChannel(block.properties["OneWirePin"] ?? "DIO13"), 0), 255)
            let resolution = min(max(Int(block.properties["ResolutionBits"] ?? "12") ?? 12, 9), 12)
            var busIndex = 0
            var rom: UInt64 = 0
            if let romText = block.properties["RomAddress"] {
                if romText.uppercased().hasPrefix("AUTO:") {
                    busIndex = min(max(Int(romText.dropFirst(5)) ?? 0, 0), 7)
                } else {
                    rom = UInt64(romText.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
                }
            }
            word(0x75, 2, en, outs.first ?? 0,
                 UInt16((dioPin & 0xFF) | ((busIndex & 0xFF) << 8)), into: &out)
            u16(outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot), into: &out)
            u16(UInt16(resolution), into: &out)
            for shift in stride(from: 0, to: 64, by: 8) {
                out.append(UInt8(truncatingIfNeeded: rom >> shift))
            }
        case "IO.CH455G":
            // COMM_EXEC CH455G: the VM decodes value/decimals/brightness (or raw segments) and the
            // simulator renders the shield's display from it.
            let sclPin = min(max(ioChannel(block.properties["SclPin"] ?? "DIO2"), 0), 255)
            let sdaPin = min(max(ioChannel(block.properties["SdaPin"] ?? "DIO3"), 0), 255)
            let raw = (block.properties["DisplayMode"] ?? "").hasPrefix("Raw")
            func digitMaskBits() -> Int {
                guard let text = block.properties["DigitMask"] else { return 0x0F }
                let cleaned = text.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
                if cleaned.hasPrefix("0x"), let value = Int(cleaned.dropFirst(2), radix: 16) { return value & 0x0F }
                if let value = Int(cleaned, radix: 2) { return value & 0x0F }
                return 0x0F
            }
            func slot(named: String) -> UInt16 {
                guard let index = block.inputs.firstIndex(where: { $0.short == named }),
                      ins.indices.contains(index) else { return UInt16(DuinoCompiler.alwaysEnabledSlot) }
                return ins[index]
            }
            let s0 = slot(named: raw ? "D0" : "Val"), s1 = slot(named: raw ? "D1" : "Dec")
            let s2 = slot(named: raw ? "D2" : "Brt"), s3 = slot(named: raw ? "D3" : "")
            let s4 = slot(named: raw ? "DpMask" : ""), s5 = slot(named: raw ? "Brt" : "")
            let modeAndMask = UInt16((raw ? 1 : 0) | ((digitMaskBits() & 0x0F) << 4))
            word(0x75, 3, en, outs.first ?? 0,
                 UInt16((sclPin & 0xFF) | ((sdaPin & 0xFF) << 8)), into: &out)
            u16(modeAndMask, into: &out)
            u16(s0, into: &out); u16(s1, into: &out); u16(s2, into: &out)
            u16(s3, into: &out); u16(s4, into: &out); u16(s5, into: &out)
            u16(0, into: &out)
        case "Main.Safety.EStop":
            let trip = outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            let source = outs.count > 2 ? outs[2] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            word(0x02, 0, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(trip, into: &out)
            u16(source, into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Execution.Interrupt":
            let captureMode = (block.properties["CaptureMode"] ?? "PULSE_WIDTH_US").uppercased()
            let edgeMode = (block.properties["TriggerEdge"] ?? "RISING").uppercased()
            let latchPolicy = (block.properties["LatchPolicy"] ?? "HOLD_FIRST_UNTIL_RST").uppercased()
            let interruptSource = (block.properties["InterruptSource"] ?? "TIM_IC1").uppercased()
            let captureBits = captureMode == "EDGE_COUNT" ? 1 : (captureMode.hasPrefix("GPIO_STATE") ? 2 : 0)
            let edgeBits = edgeMode == "FALLING" ? 1 : (edgeMode == "BOTH" ? 2 : 0)
            let latchBit = latchPolicy == "OVERWRITE_LATEST" ? 1 : 0
            let flags = UInt8((captureBits & 0x03) | ((edgeBits & 0x03) << 2) | ((latchBit & 0x01) << 4))
            let diChannel = interruptSource.hasPrefix("EXTI_DI") ? UInt16(clamping: ioChannel(interruptSource)) : 0xFFFF
            let flag = outs.count > 1 ? outs[1] : UInt16(DuinoCompiler.alwaysEnabledSlot)
            word(0x3A, flags, en, outs.first ?? 0, ins[min(first, ins.count - 1)], into: &out)
            u16(flag, into: &out)
            u16(diChannel, into: &out)
            u16(UInt16(nextState), into: &out); u16(0, into: &out)
            nextState += 1
        case "Main.Execution.ReadReg", "Main.Execution.WriteReg":
            let registerName = (block.properties["RegisterName"] ?? "REG_0").uppercased()
            let dataType = def == "Main.Execution.ReadReg" ? (block.outputs.first?.type ?? .int)
                                                           : (block.inputs.count > 1 ? block.inputs[1].type : .int)
            let register = registerSlot(registerName, type: dataType)
            let risingTrigger = (block.properties["TriggerMode"] ?? "Continuous (While En=1)").hasPrefix("Rising")
            var effectiveEn = en
            if risingTrigger && en != UInt16(DuinoCompiler.alwaysEnabledSlot) {
                let pulse = alloc(.bool)
                word(0x53, 0, UInt16(DuinoCompiler.alwaysEnabledSlot), pulse, en, into: &out)
                u16(UInt16(nextState), into: &out); u16(0, into: &out)
                nextState += 1
                effectiveEn = pulse
            }
            let retentive = (block.properties["RetentiveEeprom"] ?? "").lowercased() == "true"
            let parameterID = UInt16(min(max(ioChannel(registerName), 0), 255))
            if def == "Main.Execution.ReadReg" {
                if retentive { word(0x36, 0, effectiveEn, register, parameterID, into: &out) }
                word(0x08, 0, effectiveEn, outs.first ?? 0, register, into: &out)
            } else {
                word(0x08, 0, effectiveEn, register, ins[min(first, ins.count - 1)], into: &out)
                if retentive { word(0x37, 0, effectiveEn, register, parameterID, into: &out) }
                if let outSlot = outs.first, outSlot != 0 {
                    word(0x08, 0, UInt16(DuinoCompiler.alwaysEnabledSlot), outSlot, register, into: &out)
                }
            }
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
        case "Ladder.Coil.NORMAL", "Ladder.Coil.NEGATED", "Ladder.Coil.SET", "Ladder.Coil.RESET",
             "Ladder.Coil.POS", "Ladder.Coil.NEG":
            let flags: UInt8 = switch def {
            case "Ladder.Coil.NEGATED": 1
            case "Ladder.Coil.SET": 2
            case "Ladder.Coil.RESET": 3
            case "Ladder.Coil.POS": 4
            case "Ladder.Coil.NEG": 5
            default: 0
            }
            let operand = block.properties["Operand"] ?? "DO0"
            let destination = registerSlot(operand, type: .bool)
            let edge = def == "Ladder.Coil.POS" || def == "Ladder.Coil.NEG"
            word(0x1B, flags, en, destination, 0, into: &out)
            u16(UInt16(edge ? nextState : 0), into: &out); u16(0, into: &out)
            if edge { nextState += 1 }
            if operand.uppercased().hasPrefix("DO") {
                word(0x71, 1, UInt16(DuinoCompiler.alwaysEnabledSlot), UInt16(ioChannel(operand)), destination, into: &out)
            }
            slots[operand] = destination
        case "Ladder.Coil.ANALOG", "Ladder.Coil.WRITE_REG":
            let operand = block.properties["Operand"] ?? (def == "Ladder.Coil.ANALOG" ? "AO0" : "REG_0")
            let source = ins[min(first, ins.count - 1)]
            if operand.uppercased().hasPrefix("AO") {
                word(0x71, 3, en, UInt16(ioChannel(operand)), source, into: &out)
            } else {
                let type = block.inputs.count > 1 ? block.inputs[1].type : .int
                let register = registerSlot(operand, type: type)
                word(0x08, 0, en, register, source, into: &out)
            }
            if !operand.isEmpty { slots[operand] = source }
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
        guard !block.definitionID.hasPrefix("Visual.Vars.") else { return }
        let alwaysEnabled = ["Main.Timers.Timer", "Main.Timers.PulseGen", "Main.Timers.PulseLen",
                             "Main.Timers.SinglePulse", "IO.PWM"].contains(block.definitionID)
            || block.definitionID.hasPrefix("Macro.User.")
        let inversionEnable = alwaysEnabled ? UInt16(DuinoCompiler.alwaysEnabledSlot) : en
        for (index, pin) in block.outputs.enumerated() where pin.type == .bool {
            if ["Bool.RS", "Bool.SR"].contains(block.definitionID), index == 0 { continue }
            let dirigo = block.outputIndices.indices.contains(index) ? block.outputIndices[index] : index
            guard block.module.outPins.indices.contains(dirigo), block.module.outPins[dirigo].inverted,
                  outs.indices.contains(index) else { continue }
            let source = outs[index]
            word(0x16, 0, inversionEnable, source, source, into: &out)
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
        guard nextMovAvg <= 8 else {
            throw DuinoCompiler.CompileError.slotLimit("\(nextMovAvg) moving-average instances, limit 8")
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

    private func emitTimeZone(_ rule: TimeZoneRule, into out: inout [UInt8]) {
        u16(UInt16(truncatingIfNeeded: rule.stdOffset), into: &out)
        u16(UInt16(truncatingIfNeeded: rule.dstOffset), into: &out)
        for value in [rule.startMonth, rule.startWeek, rule.startDow, rule.startHour,
                      rule.endMonth, rule.endWeek, rule.endDow, rule.endHour] {
            out.append(UInt8(truncatingIfNeeded: value))
        }
        u16(0, into: &out)
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
