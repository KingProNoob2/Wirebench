import Foundation
import WirebenchCore

public final class BlockRegistry: @unchecked Sendable {
    public static let shared = BlockRegistry()

    public typealias Factory = (PCCModule) -> FunctionBlock

    private var registry: [UUID: Factory] = [:]
    private var nameRegistry: [String: Factory] = [:]

    public init() {
        registerBuiltins()
    }

    public func register(guid: UUID, factory: @escaping Factory) {
        registry[guid] = factory
    }

    public func register(typeName: String, factory: @escaping Factory) {
        nameRegistry[typeName.lowercased()] = factory
    }

    /// Every GUID this registry can build. Used by `BlockIdentityTests` to prove that no block was
    /// registered under a GUID that does not exist in the recovered catalog — a mistake that
    /// compiles, passes every behavioural test, and silently unmaps real modules in a user's file.
    public var registeredGuids: Set<UUID> { Set(registry.keys) }

    public func create(for module: PCCModule) -> FunctionBlock {
        // The block-type GUID is the authoritative identity: it is what Dirigo stores in the
        // project and it does not change when a user renames an instance.
        if let factory = registry[module.guid] {
            return factory(module)
        }

        for key in Self.lookupKeys(for: module.name) {
            if let factory = nameRegistry[key] {
                return factory(module)
            }
        }

        // Unknown type. Name it from the recovered registry when possible, and return an inert
        // placeholder rather than guessing at behaviour — see `UnresolvedBlock`.
        let info = BlockTypeCatalog.info(forGuid: module.guid)
        return UnresolvedBlock(
            resolvedName: info?.blockName ?? module.name,
            delphiClass: info?.delphiClass,
            inCount: module.inPins.count,
            outCount: module.outPins.count
        )
    }

    /// Candidate registry keys for a module instance name, most specific first.
    ///
    /// Dirigo names instances `<Type><number>` (`And1`, `8xDO2`) or `<Type><suffix>`
    /// (`PulseGenKostka`, `OrPrepinac`). Only the first form can be recovered from the name
    /// alone, and only for blocks whose type name survives stripping the instance number.
    static func lookupKeys(for instanceName: String) -> [String] {
        let lowered = instanceName.lowercased()
        var keys = [lowered]

        let withoutTrailingDigits = String(lowered.reversed().drop { $0.isNumber }.reversed())
        if withoutTrailingDigits != lowered, !withoutTrailingDigits.isEmpty {
            keys.append(withoutTrailingDigits)
        }

        // Legacy behaviour, kept last because it is the lossiest: drop every digit, which turns
        // `8xDO1` into `xdo`.
        let withoutAnyDigits = lowered.filter { !$0.isNumber }
        if !keys.contains(withoutAnyDigits) {
            keys.append(withoutAnyDigits)
        }
        return keys
    }

    /// Resolved block type name for a module, or `nil` when this build cannot simulate it.
    public func resolvedTypeName(for module: PCCModule) -> String? {
        if let factory = registry[module.guid] { return type(of: factory(module)).typeName }
        for key in Self.lookupKeys(for: module.name) {
            if let factory = nameRegistry[key] { return type(of: factory(module)).typeName }
        }
        return nil
    }

    private func registerBuiltins() {
        // And
        register(guid: AndBlock.guid) { mod in
            let count = mod.inputCount ?? max(mod.inPins.count - 1, 2)
            return AndBlock(inputCount: count)
        }
        register(typeName: "and") { mod in
            let count = mod.inputCount ?? max(mod.inPins.count - 1, 2)
            return AndBlock(inputCount: count)
        }

        // Or
        register(guid: OrBlock.guid) { mod in
            let count = mod.inputCount ?? max(mod.inPins.count - 1, 2)
            return OrBlock(inputCount: count)
        }
        register(typeName: "or") { mod in
            let count = mod.inputCount ?? max(mod.inPins.count - 1, 2)
            return OrBlock(inputCount: count)
        }
        register(typeName: "orspin") { mod in
            let count = mod.inputCount ?? max(mod.inPins.count - 1, 2)
            return OrBlock(inputCount: count)
        }

        // Not
        register(guid: NotBlock.guid) { _ in NotBlock() }
        register(typeName: "not") { _ in NotBlock() }

        // Xor
        register(guid: XorBlock.guid) { _ in XorBlock() }
        register(typeName: "xor") { _ in XorBlock() }

        // RS
        register(guid: RSBlock.guid) { mod in
            let resetPri = (mod.rawAttributes["PRIORITY"]?.uppercased() != "S") && (mod.rawAttributes["RS_PRIORITY"]?.uppercased() != "S")
            return RSBlock(resetPriority: resetPri)
        }
        register(typeName: "rs") { mod in
            let resetPri = (mod.rawAttributes["PRIORITY"]?.uppercased() != "S") && (mod.rawAttributes["RS_PRIORITY"]?.uppercased() != "S")
            return RSBlock(resetPriority: resetPri)
        }

        // Trigger
        register(guid: TriggerBlock.guid) { _ in TriggerBlock() }
        register(typeName: "trigger") { _ in TriggerBlock() }

        // Comparator
        register(guid: ComparatorBlock.guid) { _ in ComparatorBlock() }
        register(typeName: "comparator") { _ in ComparatorBlock() }

        // Int2Bits
        register(guid: Int2BitsBlock.guid) { mod in
            let count = mod.rawAttributes["OUTPUT_COUNT"].flatMap { Int($0) } ?? max(1, mod.outPins.count)
            return Int2BitsBlock(bitCount: count)
        }
        register(typeName: "intbits") { mod in
            let count = mod.rawAttributes["OUTPUT_COUNT"].flatMap { Int($0) } ?? max(1, mod.outPins.count)
            return Int2BitsBlock(bitCount: count)
        }
        register(typeName: "int2bits") { mod in
            let count = mod.rawAttributes["OUTPUT_COUNT"].flatMap { Int($0) } ?? max(1, mod.outPins.count)
            return Int2BitsBlock(bitCount: count)
        }

        // Div
        register(guid: DivBlock.guid) { _ in DivBlock() }
        register(typeName: "div") { _ in DivBlock() }
        register(typeName: "idiv") { _ in DivBlock() }

        // 8xPWM
        register(guid: EightPWMBlock.guid) { mod in
            let steps = mod.paramPins.first?.value.asInt ?? (mod.rawAttributes["PWM_STEPS"].flatMap { Int($0) } ?? 256)
            return EightPWMBlock(steps: steps)
        }
        register(typeName: "8xpwm") { mod in
            let steps = mod.paramPins.first?.value.asInt ?? (mod.rawAttributes["PWM_STEPS"].flatMap { Int($0) } ?? 256)
            return EightPWMBlock(steps: steps)
        }

        // ISwitch
        register(guid: ISwitchBlock.guid) { mod in
            let count = mod.rawAttributes["INPUT_COUNT"].flatMap { Int($0) } ?? max(1, mod.inPins.count - 2)
            return ISwitchBlock(inputCount: count)
        }
        register(typeName: "iswitch") { mod in
            let count = mod.rawAttributes["INPUT_COUNT"].flatMap { Int($0) } ?? max(1, mod.inPins.count - 2)
            return ISwitchBlock(inputCount: count)
        }

        // Set
        register(guid: SetBlock.guid) { mod in
            SetBlock(inPins: mod.inPins.count, params: mod.paramPins.count)
        }
        register(typeName: "set") { mod in
            // Help pins: En, X, P1...Pn — all inputs, no outputs. The number of P pins is
            // user-configurable (1...126), so take the module's shape.
            SetBlock(inPins: mod.inPins.count, params: mod.paramPins.count)
        }

        // Add
        register(guid: AddBlock.guid) { _ in AddBlock() }
        register(typeName: "iadd") { _ in AddBlock() }

        // Mul
        register(guid: MulBlock.guid) { _ in MulBlock() }
        register(typeName: "imul") { _ in MulBlock() }

        // PulseGen
        register(guid: PulseGenBlock.guid) { _ in PulseGenBlock() }
        register(typeName: "pulsegen") { _ in PulseGenBlock() }

        // Counter
        register(guid: CounterBlock.guid) { _ in CounterBlock() }
        register(typeName: "counter") { _ in CounterBlock() }

        // Segment
        register(guid: SegmentBlock.guid) { _ in SegmentBlock() }
        register(typeName: "segment") { _ in SegmentBlock() }

        // 8xDO
        register(guid: EightDOBlock.guid) { mod in
            // `mod.inPins` already includes En, so the channel count is one less.
            EightDOBlock(pinCount: max(2, mod.inPins.count))
        }
        register(typeName: "xdo") { mod in
            // `mod.inPins` already includes En, so this is the *total* pin count.
            let total = mod.rawAttributes["PIN_COUNT"].flatMap { Int($0).map { $0 + 1 } }
                ?? (mod.inPins.count > 0 ? mod.inPins.count : 9)
            return EightDOBlock(pinCount: total)
        }
        register(typeName: "8xdo") { mod in
            // `mod.inPins` already includes En, so this is the *total* pin count.
            let total = mod.rawAttributes["PIN_COUNT"].flatMap { Int($0).map { $0 + 1 } }
                ?? (mod.inPins.count > 0 ? mod.inPins.count : 9)
            return EightDOBlock(pinCount: total)
        }

        // 8xDI
        register(guid: EightDIBlock.guid) { mod in
            return EightDIBlock(pinCount: max(1, mod.outPins.count))
        }
        register(typeName: "xdi") { mod in
            return EightDIBlock(pinCount: max(1, mod.outPins.count))
        }
        register(typeName: "8xdi") { mod in
            return EightDIBlock(pinCount: max(1, mod.outPins.count))
        }

        // Macro IO (Inputs / Outputs)
        register(guid: InputsBlock.guid) { mod in
            let kind = mod.rawAttributes["KIND"] ?? "0"
            if kind == "1" || mod.name.lowercased().hasPrefix("output") {
                return OutputsBlock(count: max(mod.inPins.count, 1))
            } else {
                return InputsBlock(count: max(mod.outPins.count, 1))
            }
        }
        register(typeName: "inputs") { mod in
            InputsBlock(count: max(mod.outPins.count, 1))
        }
        register(typeName: "outputs") { mod in
            OutputsBlock(count: max(mod.inPins.count, 1))
        }

        // Macro Invocation
        register(guid: MacroBlock.guid) { mod in
            let mName = mod.rawAttributes["MACRO_NAME"] ?? mod.name
            return MacroBlock(
                macroName: mName,
                inCount: mod.inPins.count,
                paramCount: mod.paramPins.count,
                outCount: mod.outPins.count
            )
        }
        register(typeName: "macro") { mod in
            let mName = mod.rawAttributes["MACRO_NAME"] ?? mod.name
            return MacroBlock(
                macroName: mName,
                inCount: mod.inPins.count,
                paramCount: mod.paramPins.count,
                outCount: mod.outPins.count
            )
        }

        // BoolVar (Interactive variable / button)
        register(guid: BoolVarBlock.guid) { mod in
            let modeRaw = mod.simulMode ?? (mod.rawAttributes["SimulMode"].flatMap { Int($0) } ?? 2)
            return BoolVarBlock(mode: BoolVarBlock.Mode(simulMode: modeRaw))
        }
        register(typeName: "boolvar") { mod in
            let modeRaw = mod.simulMode ?? (mod.rawAttributes["SimulMode"].flatMap { Int($0) } ?? 2)
            return BoolVarBlock(mode: BoolVarBlock.Mode(simulMode: modeRaw))
        }
        register(typeName: "roztoctruletu") { _ in
            BoolVarBlock(mode: .pushButton)
        }
        register(typeName: "prepinacrezim") { _ in
            BoolVarBlock(mode: .toggleSwitch)
        }

        // SystemCmd
        register(guid: SystemCmdBlock.guid) { mod in
            SystemCmdBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count,
                           definition: mod.rawAttributes["DEFINITION"].flatMap(ProfilesParser.systemCommand(fromDefinition:)))
        }
        register(typeName: "systemcmd") { mod in
            SystemCmdBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count,
                           definition: mod.rawAttributes["DEFINITION"].flatMap(ProfilesParser.systemCommand(fromDefinition:)))
        }

        // Yes
        register(guid: YesBlock.guid) { mod in
            YesBlock(pinCount: max(mod.inPins.count, 1))
        }
        register(typeName: "yes") { mod in
            YesBlock(pinCount: max(mod.inPins.count, 1))
        }

        // Bits2Int
        register(guid: Bits2IntBlock.guid) { mod in
            Bits2IntBlock(totalPins: max(2, mod.inPins.count))   // total pins: En + bits
        }
        register(typeName: "bitsint") { mod in
            Bits2IntBlock(totalPins: max(2, mod.inPins.count))   // total pins: En + bits
        }
        register(typeName: "bits2int") { mod in
            Bits2IntBlock(totalPins: max(2, mod.inPins.count))   // total pins: En + bits
        }

        // Shl
        register(guid: ShlBlock.guid) { _ in ShlBlock() }
        register(typeName: "shl") { _ in ShlBlock() }

        // Sar
        register(guid: SarBlock.guid) { _ in SarBlock() }
        register(typeName: "sar") { _ in SarBlock() }
        register(typeName: "shr") { _ in SarBlock() }

        // Ext
        register(guid: ExtBlock.guid) { _ in ExtBlock() }
        register(typeName: "ext") { _ in ExtBlock() }

        // Ins
        register(guid: InsBlock.guid) { _ in InsBlock() }
        register(typeName: "ins") { _ in InsBlock() }

        // SinglePulse
        register(guid: SinglePulseBlock.guid) { mod in SinglePulseBlock(pinCount: mod.inPins.count) }
        register(typeName: "singlepulse") { mod in SinglePulseBlock(pinCount: mod.inPins.count) }

        // PulseLength / PulseLen
        register(guid: PulseLengthBlock.guid) { mod in PulseLengthBlock(pinCount: mod.inPins.count) }
        register(typeName: "pulselen") { mod in PulseLengthBlock(pinCount: mod.inPins.count) }
        register(typeName: "pulselength") { mod in PulseLengthBlock(pinCount: mod.inPins.count) }

        // Sub
        register(guid: SubBlock.guid) { _ in SubBlock() }
        register(typeName: "sub") { _ in SubBlock() }
        register(typeName: "isub") { _ in SubBlock() }

        // Abs
        register(guid: AbsBlock.guid) { _ in AbsBlock() }
        register(typeName: "abs") { _ in AbsBlock() }
        register(typeName: "iabs") { _ in AbsBlock() }

        // Inc
        register(guid: IncBlock.guid) { _ in IncBlock() }

        // Long and Float arithmetic (21 types) — previously placeholders.
        register(guid: UUID(uuidString: "ADB50AD6-4603-4795-804E-19CA0C500F42")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FAbs")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fabs") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FAbs")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "CC842836-7B14-4BE9-B1BA-A8CD31825D02")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FACos")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "facos") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FACos")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "49BF4B3B-61E4-49ED-91B1-A69D335FE792")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FAdd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fadd") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FAdd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "D0D39B69-25EB-4EA6-BE12-AD5C3390CB87")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FASin")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fasin") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FASin")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "9EF78DFE-8F05-451B-91AA-EA57433CA85A")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FCos")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fcos") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FCos")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "79685024-9421-418E-B5DD-AC2B51122319")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FDiv")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fdiv") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FDiv")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "90F39003-8FF6-448E-A195-1337DB52CB8E")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FMod")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fmod") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FMod")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "4AE1D575-8C94-4BCC-B11C-8EDD862CE912")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FMul")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fmul") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FMul")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "4C8B2C7E-1B3E-4268-9469-218409A1E268")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FNeg")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fneg") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FNeg")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "7FD4DCE9-BC76-442A-8296-73BB26C3DB1F")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSin")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fsin") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSin")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "83C2F65F-BEE3-485C-87CD-4E0CF5EF7105")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSqrt")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fsqrt") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSqrt")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "E455B3D9-9693-44AA-8B41-434C627A009B")!) { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSub")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "fsub") { mod in FloatMathNumericBlock(operation: FloatMathOperation(blockName: "FSub")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "C5417B3B-AD3A-40B6-A585-C1BE54F33F26")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAbs")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "labs") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAbs")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "D58C7D8C-D1B9-4570-92E9-7EE16ED5F74C")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAdd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "ladd") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAdd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "0BC03AB1-FEB2-42CE-A63E-40F4C15E354A")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAnd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "land") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LAnd")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "113A29BF-A437-4D73-BB8F-5F111ADF9C54")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LInc")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "linc") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LInc")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "8A6CC082-F7E5-44B1-8CF9-587C01E4EFA9")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LNeg")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "lneg") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LNeg")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "B4A2E3DA-7EB8-4BAD-800A-C1FF940698AB")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LNot")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "lnot") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LNot")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "8EC61B54-764E-4F13-B9EC-7590EA40AC3E")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LOr")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "lor") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LOr")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "E4909076-CAF6-4A44-81F8-8A084D9C93AA")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LSub")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "lsub") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LSub")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "EE61B9F0-19B4-48E9-8A6D-3F74E9BC1FC3")!) { mod in LongMathBlock(operation: LongMathOperation(blockName: "LXor")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "lxor") { mod in LongMathBlock(operation: LongMathOperation(blockName: "LXor")!, inPins: mod.inPins.count,
                  params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "inc") { _ in IncBlock() }
        register(typeName: "iinc") { _ in IncBlock() }

        // Neg
        register(guid: NegBlock.guid) { _ in NegBlock() }
        register(typeName: "neg") { _ in NegBlock() }
        register(typeName: "ineg") { _ in NegBlock() }

        // Limiter
        register(guid: LimiterBlock.guid) { _ in LimiterBlock() }
        register(typeName: "limiter") { _ in LimiterBlock() }
        register(typeName: "ilimiter") { _ in LimiterBlock() }
        // LLimiter is the Long form of the same block; this codebase carries Long in the same
        // 32-bit pin type, so it shares the implementation.
        register(guid: UUID(uuidString: "14EBD5B1-9918-4506-B841-D850C0AD9FA9")!) { _ in LimiterBlock() }
        register(typeName: "llimiter") { _ in LimiterBlock() }

        // InRange
        register(guid: InRangeBlock.guid) { _ in InRangeBlock() }
        register(typeName: "inrange") { _ in InRangeBlock() }

        // Mean
        register(guid: MeanBlock.guid) { mod in
            // The window is configuration; accept a legacy param pin or a stored attribute.
            let window = mod.paramPins.first?.value.asInt
                ?? mod.rawAttributes["N"].flatMap { Int($0) }
                ?? mod.rawAttributes["WINDOW"].flatMap { Int($0) }
                ?? 12
            return MeanBlock(windowSize: window)
        }
        register(typeName: "mean") { mod in
            // The window is configuration; accept a legacy param pin or a stored attribute.
            let window = mod.paramPins.first?.value.asInt
                ?? mod.rawAttributes["N"].flatMap { Int($0) }
                ?? mod.rawAttributes["WINDOW"].flatMap { Int($0) }
                ?? 12
            return MeanBlock(windowSize: window)
        }

        // CalibTransf
        register(guid: CalibratedTransformBlock.guid) { _ in CalibratedTransformBlock() }
        register(typeName: "calibtransf") { _ in CalibratedTransformBlock() }

        // FloatMath
        register(guid: FloatMathBlock.guid) { mod in
            let opStr = mod.rawAttributes["OP"]?.lowercased() ?? "add"
            let op: FloatMathBlock.Operation
            switch opStr {
            case "sub": op = .sub
            case "mul": op = .mul
            case "div": op = .div
            case "sqrt": op = .sqrt
            case "sin": op = .sin
            case "cos": op = .cos
            default: op = .add
            }
            return FloatMathBlock(operation: op)
        }
        register(typeName: "floatmath") { _ in FloatMathBlock() }
        // The Dirigo float-math family (FAdd, FSub, FMul, FDiv, FSqrt, ...) are separate block
        // types whose pin layout includes an `En` pin this class does not model. Aliasing them
        // here would simulate them with the wrong operands, so they are deliberately left
        // unresolved until they get real implementations.

        // Timer
        register(guid: TimerBlock.guid) { mod in
            let modeRaw = mod.rawAttributes["MODE"] ?? "0"
            let mode = TimerBlock.Mode(rawValue: Int(modeRaw) ?? 0) ?? .onDelay
            return TimerBlock(mode: mode)
        }
        register(typeName: "timer") { mod in
            let modeRaw = mod.rawAttributes["MODE"] ?? "0"
            let mode = TimerBlock.Mode(rawValue: Int(modeRaw) ?? 0) ?? .onDelay
            return TimerBlock(mode: mode)
        }

        // Ramp
        register(guid: RampBlock.guid) { _ in RampBlock() }
        register(typeName: "ramp") { _ in RampBlock() }

        // Valve
        register(guid: ValveBlock.guid) { _ in ValveBlock() }
        register(typeName: "valve") { _ in ValveBlock() }

        // WaterRegulator
        register(guid: WaterRegulatorBlock.guid) { _ in WaterRegulatorBlock() }
        register(typeName: "waterregulator") { _ in WaterRegulatorBlock() }
        register(typeName: "waterreg") { _ in WaterRegulatorBlock() }

        // StepDrv
        register(guid: StepDriverBlock.guid) { _ in StepDriverBlock() }
        register(typeName: "stepdrv") { _ in StepDriverBlock() }
        register(typeName: "stepdriver") { _ in StepDriverBlock() }

        // HysteresisComparator
        register(guid: HysteresisComparatorBlock.guid) { _ in HysteresisComparatorBlock() }
        register(typeName: "hysteresiscomparator") { _ in HysteresisComparatorBlock() }
        register(typeName: "hysteresis") { _ in HysteresisComparatorBlock() }

        // MultiComparator
        register(guid: MultiComparatorBlock.guid) { _ in MultiComparatorBlock() }
        register(typeName: "multicomparator") { _ in MultiComparatorBlock() }

        // Structured Control Flow: If, Else, EndIf
        register(guid: IfBlock.guid) { _ in IfBlock() }
        register(typeName: "if") { _ in IfBlock() }

        register(guid: ElseBlock.guid) { _ in ElseBlock() }
        register(typeName: "else") { _ in ElseBlock() }

        register(guid: EndIfBlock.guid) { _ in EndIfBlock() }
        register(typeName: "endif") { _ in EndIfBlock() }

        // Switch, Case, Results
        register(guid: SwitchBlock.guid) { _ in SwitchBlock() }
        register(typeName: "switch") { _ in SwitchBlock() }

        // A Case's accepted values are configuration, written by the dialog as `VALUES`
        // (e.g. "1, 5..7, 9") — they are not pins.
        register(guid: CaseBlock.guid) { mod in
            CaseBlock(valuesSpec: mod.rawAttributes["VALUES"] ?? mod.rawAttributes["CASE_VALUES"] ?? "")
        }
        register(typeName: "case") { mod in
            CaseBlock(valuesSpec: mod.rawAttributes["VALUES"] ?? mod.rawAttributes["CASE_VALUES"] ?? "")
        }

        // Default / EndSwitch: the remaining arms of a Switch construct. Both are labels with no
        // pins — the engine marks Default when no Case matched, EndSwitch closes the range.
        register(guid: DefaultBlock.guid) { _ in DefaultBlock() }
        register(typeName: "default") { _ in DefaultBlock() }
        register(guid: EndSwitchBlock.guid) { _ in EndSwitchBlock() }
        register(typeName: "endswitch") { _ in EndSwitchBlock() }

        register(guid: ResultsBlock.guid) { mod in
            ResultsBlock(count: max(mod.inPins.count, 1))
        }
        register(typeName: "results") { mod in
            ResultsBlock(count: max(mod.inPins.count, 1))
        }

        // IntVar, FloatVar
register(guid: IntVarBlock.guid) { mod in
            // No parameter pin any more, so the initial value lives in an attribute.
            let raw = mod.paramPins.first?.value.asInt ?? mod.rawAttributes["INIT_VALUE"].flatMap { Int($0) } ?? 0
            return IntVarBlock(initialValue: Int32(clamping: raw))
        }
        register(typeName: "intvar") { mod in
            let initVal = mod.paramPins.first?.value.asInt32 ?? 0
            return IntVarBlock(initialValue: initVal)
        }

register(guid: FloatVarBlock.guid) { mod in
            let raw = mod.paramPins.first?.value.asFloat
                ?? mod.rawAttributes["INIT_VALUE"].flatMap { Float($0) } ?? 0
            return FloatVarBlock(initialValue: raw)
        }
        register(typeName: "floatvar") { mod in
            let initVal = mod.paramPins.first?.value.asFloat ?? 0.0
            return FloatVarBlock(initialValue: initVal)
        }

        // Array Management
        register(guid: CreateArrayBlock.guid) { _ in CreateArrayBlock() }
        register(typeName: "createarray") { _ in CreateArrayBlock() }
        register(typeName: "createintarray") { _ in CreateArrayBlock() }

        register(guid: ReadArrayBlock.guid) { _ in ReadArrayBlock() }
        register(typeName: "readarray") { _ in ReadArrayBlock() }
        register(typeName: "readintarray") { _ in ReadArrayBlock() }

        register(guid: WriteArrayBlock.guid) { _ in WriteArrayBlock() }
        register(typeName: "writearray") { _ in WriteArrayBlock() }
        register(typeName: "writeintarray") { _ in WriteArrayBlock() }

        // Long and Float arrays. One data area, read and written as a wider or floating element
        // type. `CreateLongArray` reuses the Int create block: the help gives it the same pins,
        // and the element type is decided by whichever block accesses the array.
        register(guid: UUID(uuidString: "B41BDDA5-0D9B-4D8B-8AF3-B378DCC134AB")!) { _ in CreateArrayBlock() }
        register(typeName: "createlongarray") { _ in CreateArrayBlock() }
        register(guid: UUID(uuidString: "0B4FB208-E024-495E-BB00-3F4325A38DDE")!) { _ in ReadArrayBlock(element: .integer) }
        register(typeName: "readlongarray") { _ in ReadArrayBlock(element: .integer) }
        register(guid: UUID(uuidString: "554E9CED-6359-4721-A2F0-A093AFFA2EE7")!) { _ in ReadArrayBlock(element: .floating) }
        register(typeName: "readfloatarray") { _ in ReadArrayBlock(element: .floating) }
        register(guid: UUID(uuidString: "56BB173E-2EAB-408B-98A2-77EBBD6691DF")!) { _ in WriteArrayBlock(element: .integer) }
        register(typeName: "writelongarray") { _ in WriteArrayBlock(element: .integer) }
        register(guid: UUID(uuidString: "B2ADBB97-AB12-456F-8D5F-E2FDF543079C")!) { _ in WriteArrayBlock(element: .floating) }
        register(typeName: "writefloatarray") { _ in WriteArrayBlock(element: .floating) }

        // Switch / Move / Vars remainder.
        register(guid: UUID(uuidString: "3BD2D87B-2EBA-4459-B5C6-385263D81995")!) { mod in ISwitchBlock(inputCount: max(1, mod.inPins.count - 2), isFloat: true) }
        register(typeName: "fswitch") { mod in ISwitchBlock(inputCount: max(1, mod.inPins.count - 2), isFloat: true) }
        register(guid: UUID(uuidString: "4C867BD2-4C26-431F-82CE-DE8ECC656E88")!) { mod in ISwitchBlock(inputCount: max(1, mod.inPins.count - 2), isFloat: false) }
        register(typeName: "lswitch") { mod in ISwitchBlock(inputCount: max(1, mod.inPins.count - 2), isFloat: false) }
        register(guid: UUID(uuidString: "57C24D25-B6DC-44D7-9DEA-85215732687C")!) { mod in IntVarBlock(initialValue: Int32(clamping: mod.rawAttributes["INIT_VALUE"].flatMap { Int($0) } ?? 0)) }
        register(typeName: "longvar") { mod in IntVarBlock(initialValue: Int32(clamping: mod.rawAttributes["INIT_VALUE"].flatMap { Int($0) } ?? 0)) }
        register(guid: UUID(uuidString: "4EBC4D35-5F55-416E-B939-6D2640FD3E96")!) { mod in ComparatorBlock() }
        register(typeName: "lcomparator") { mod in ComparatorBlock() }
        register(guid: UUID(uuidString: "BC2C94BA-D36C-4323-9650-4BEC5A5C32F3")!) { mod in MoveBlock() }
        register(typeName: "move") { mod in MoveBlock() }

        // Physical I/O: pin surface only — there is no PLC to write to.
        register(guid: UUID(uuidString: "BC74195A-656A-4001-9E08-62E2E68CEA2E")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "2xao") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "131E98D1-A769-430E-B046-D713D38F3B56")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_3xdo") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "17F1F0FF-CFC8-4ECE-8145-41D59E08AC48")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_8xao") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "C69C8129-EE2B-492A-BA1D-83DE7BF0AB63")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_8xdo") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "24007AAA-F865-4445-8E34-D931F415B30F")!) { _ in ReadDallasBlock() }
        register(typeName: "readdallas") { _ in ReadDallasBlock() }        // Value Display

        // SetIdx: like `Set`, but writes only the P pin named by Idx.
        register(guid: SetIdxBlock.guid) { mod in SetIdxBlock(inPins: mod.inPins.count) }
        register(typeName: "setidx") { mod in SetIdxBlock(inPins: mod.inPins.count) }

        // Analog, counter and encoder inputs (8 types). Hardware reads; with no unit attached
        // the honest reading is zero, and the shape follows the module.
        register(guid: UUID(uuidString: "E692388B-2308-4DAA-8871-4377F2FE50BF")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "8xai") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "9DF5B011-5506-419F-93D9-F4762BB5EB54")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "readai") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "83C63003-BEDC-47E2-8195-ECC544F8120D")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_8xai") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "24A88402-C7FC-4017-84BA-91E941F1D583")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_16xai") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "578863BC-2BF6-4CEB-9DBB-F437819468EC")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_9xdi") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "F7DD85EC-C7E6-4231-B8B3-098F30DC93AF")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iic_9xdicnt") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "5A9C9082-CC72-4F14-8F9D-BDE837F57336")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "irc") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "3A1667B3-2E18-4764-905E-DFBF85F52D2A")!) { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "cnt") { mod in HardwareInputBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "E8DEDEF1-F54B-4E54-9415-EF515AF1DA94")!) { mod in IntDemuxBlock(outputCount: max(1, mod.outPins.count)) }
        register(typeName: "ldemux") { mod in IntDemuxBlock(outputCount: max(1, mod.outPins.count)) }

        // D3-Net (17 types). One subsystem: readers fill an internal buffer, `Store*Data`
        // drains it, writers transmit. There is no network, so nothing is fabricated.
        register(guid: UUID(uuidString: "BA9833F6-4994-4192-BB35-250905593E5C")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(typeName: "d3nrfloat") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(guid: UUID(uuidString: "6277BDAC-D6B6-438C-8152-03AA80F7FC1F")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(typeName: "d3nrfloatmtx") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(guid: UUID(uuidString: "851CAC97-67A0-499A-9577-D4F31C19AC21")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "d3nrint") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(guid: UUID(uuidString: "FE82FA20-122B-475A-88EC-90627DA45992")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "d3nrintmtx") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(guid: UUID(uuidString: "C0BAA899-5710-4875-A928-12553D8E1EE2")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "d3nrlong") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(guid: UUID(uuidString: "41866D27-49C4-4B5A-82D9-1C713CBC2E57")!) { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "d3nrlongmtx") { mod in D3NetReadBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(guid: UUID(uuidString: "A031837E-AA3F-4F56-A124-4589E6DA6304")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwfloat") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "AB35B2E3-4B69-4A8E-9E02-3DA6A222522F")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwfloatmtx") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "2CE60ACE-1373-4EAE-A8B6-9DDC8DB27CD6")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwint") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "60767426-DBD2-4ED0-9FF6-64760F423C6D")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwintmtx") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "0DD1E8FD-B348-4075-94A6-2985DDC31989")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwlong") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "2365D2C4-C1A8-425A-AD3D-27C13026E4B3")!) { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "d3nwlongmtx") { mod in D3NetWriteBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "30B764B6-E8AB-40FE-93B9-C4FCDED4911A")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "iqrf") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "485A849C-E494-475E-8D18-1864B3B09826")!) { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(typeName: "storefloatdata") { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .floating) }
        register(guid: UUID(uuidString: "9427E092-3536-4D23-B39C-0C91E4FC12EB")!) { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "storeintdata") { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }

        // Main/Other remainder. `Switch2` has no documentation entry and no template, so it is
        // registered shape-preserving and inert rather than having its pin order guessed — a
        // wrong guess would silently mis-wire every real Switch2 module.
        register(guid: UUID(uuidString: "3CB29B37-0D87-4A38-B09C-0C67F2E1F801")!) { mod in LoggerBlock(inPins: mod.inPins.count, outPins: mod.outPins.count) }
        register(typeName: "logger") { mod in LoggerBlock(inPins: mod.inPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "8EA347F1-5B20-4914-9B1E-ADD7627534A7")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "savedata") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "439BFD1C-2D33-4B23-A419-33DA6B2EFBAE")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "p3menu") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "50B871F0-F43B-46C1-A16C-9AD0B33BD200")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "switch2") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: UUID(uuidString: "DFAF5136-D840-4A57-9C6B-EF248F4F1796")!) { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(typeName: "storelongdata") { mod in D3NetStoreBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count, element: .integer) }
        register(guid: UUID(uuidString: "ADB81936-BC88-4153-B009-6A71E2BCDEBA")!) { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(typeName: "usercomm") { mod in ShapePreservingBlock(inPins: mod.inPins.count, params: mod.paramPins.count, outPins: mod.outPins.count) }
        register(guid: ValueDisplayBlock.guid) { mod in
            let fmt = mod.rawAttributes["FORMAT"] ?? mod.inPins.first?.format ?? ""
            return ValueDisplayBlock(format: fmt)
        }
        register(typeName: "value") { mod in
            let fmt = mod.rawAttributes["FORMAT"] ?? mod.inPins.first?.format ?? ""
            return ValueDisplayBlock(format: fmt)
        }

        // DateTime
        register(guid: DateTimeBlock.guid) { mod in DateTimeBlock(outPins: mod.outPins.count,
                                     offsetSeconds: mod.rawAttributes["OFFS"].flatMap { Int($0) }
                                         ?? mod.rawAttributes["OFFSET"].flatMap { Int($0) } ?? 0) }
        register(typeName: "datetime") { mod in DateTimeBlock(outPins: mod.outPins.count,
                                     offsetSeconds: mod.rawAttributes["OFFS"].flatMap { Int($0) }
                                         ?? mod.rawAttributes["OFFSET"].flatMap { Int($0) } ?? 0) }

        // WeekProgram
        register(guid: WeekProgramBlock.guid) { _ in WeekProgramBlock() }
        register(typeName: "weekprogram") { _ in WeekProgramBlock() }

        // Equitherm
        register(guid: EquithermBlock.guid) { _ in EquithermBlock() }
        register(typeName: "equitherm") { _ in EquithermBlock() }

        // Copy
        register(guid: CopyBlock.guid) { mod in
            let count = max(mod.outPins.count, 1)
            let hasWr = mod.inPins.count > count
            return CopyBlock(count: count, hasWrPin: hasWr)
        }
        register(typeName: "copy") { mod in
            let count = max(mod.outPins.count, 1)
            let hasWr = mod.inPins.count > count
            return CopyBlock(count: count, hasWrPin: hasWr)
        }

        // EncodeDate & DecodeDate
        register(guid: EncodeDateBlock.guid) { _ in EncodeDateBlock() }
        register(typeName: "encodedate") { _ in EncodeDateBlock() }

        register(guid: DecodeDateBlock.guid) { _ in DecodeDateBlock() }
        register(typeName: "decodedate") { _ in DecodeDateBlock() }

        // Demux
        register(guid: IntDemuxBlock.guid) { mod in
            IntDemuxBlock(outputCount: max(1, mod.outPins.count))
        }
        register(typeName: "idemux") { mod in
            IntDemuxBlock(outputCount: max(1, mod.outPins.count))
        }
        register(typeName: "intdemux") { mod in
            IntDemuxBlock(outputCount: max(1, mod.outPins.count))
        }

        register(guid: FloatDemuxBlock.guid) { mod in
            FloatDemuxBlock(outputCount: max(1, mod.outPins.count))
        }
        register(typeName: "fdemux") { mod in
            FloatDemuxBlock(outputCount: max(1, mod.outPins.count))
        }
        register(typeName: "floatdemux") { mod in
            FloatDemuxBlock(outputCount: max(1, mod.outPins.count))
        }

        // AdvCounter
        register(guid: AdvCounterBlock.guid) { _ in AdvCounterBlock() }
        register(typeName: "advcounter") { _ in AdvCounterBlock() }
        // NOTE: `Cnt` (TMCnt, "reads the counter value on channel Ch") is a different block from
        // AdvCounter and is not implemented. It used to be aliased here, which simulated the
        // wrong block; it now falls through to UnresolvedBlock so the gap is visible.

        // Filter (1st-order IIR)
        register(guid: FilterBlock.guid) { _ in FilterBlock() }
        register(typeName: "filter") { _ in FilterBlock() }

        // DelayFilter (pulse-length filter) is a different block with a different GUID; it used
        // to be registered against FilterBlock, which simulated the wrong function entirely.
        register(guid: DelayFilterBlock.guid) { _ in DelayFilterBlock() }
        register(typeName: "delayfilter") { _ in DelayFilterBlock() }

        // Bitwise Integer Logic
        register(guid: IntAndBlock.guid) { _ in IntAndBlock() }
        register(typeName: "iand") { _ in IntAndBlock() }
        register(typeName: "intand") { _ in IntAndBlock() }

        register(guid: IntOrBlock.guid) { _ in IntOrBlock() }
        register(typeName: "ior") { _ in IntOrBlock() }
        register(typeName: "intor") { _ in IntOrBlock() }

        register(guid: IntXorBlock.guid) { _ in IntXorBlock() }
        register(typeName: "ixor") { _ in IntXorBlock() }
        register(typeName: "intxor") { _ in IntXorBlock() }

        register(guid: IntNotBlock.guid) { _ in IntNotBlock() }
        register(typeName: "inot") { _ in IntNotBlock() }
        register(typeName: "intnot") { _ in IntNotBlock() }
    }
}
