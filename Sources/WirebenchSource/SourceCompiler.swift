import Foundation
import WirebenchCore
import WirebenchLibrary

/// A function block the source declared, as the compiled project sees it.
public struct CompiledMacro: Equatable, Sendable {
    public var name: String
    public var caption: String
    public var inputs: [String]
    public var outputs: [String]
}

/// What one Structured Text file compiled to.
public struct CompiledSource {
    public var project: PCCProject
    /// The `PROGRAM` the document opens on.
    public var program: String
    /// The main program's pins.
    public var usedInputs: [Int]
    public var writtenOutputs: [Int]
    public var variables: [String]
    /// Every page, the main one first.
    public var pages: [String]
    public var macros: [CompiledMacro]
    public var blockCount: Int
}

/// Compiles IEC 61131-3 Structured Text into a Dirigo project.
///
/// Each `PROGRAM` is a page and each `FUNCTION_BLOCK` a macro page: its `VAR_INPUT`/`VAR_OUTPUT` becomes the
/// `Inputs`/`Outputs` interface, its body the blocks between them. A `VAR` declaration of a function block or a
/// catalogued block type makes an instance, `instance(name := value)` wires its inputs, and `instance.output` reads its
/// output. `AT %IXn`/`AT %QXn` pins are one `8xDI`/`8xDO`, a stored `BOOL` a `BoolVar` plus the `Set` that writes it,
/// and `IF` a selection of wires rather than `If` markers. `docs/Structured-Text.md` has the subset and the limits.
public struct SourceCompiler {
    public init() {}

    public func compile(_ source: String, projectName: String = "Program") throws -> CompiledSource {
        let program = try SourceParser.parse(source)
        guard let mainPage = program.main else {
            throw SourceError(line: 1, message: "the file has no PROGRAM to compile")
        }
        var macrosByName: [String: SourceUnit] = [:]
        for block in program.macros { macrosByName[block.name.lowercased()] = block }
        var functionsByName: [String: SourceFunction] = [:]
        for function in program.functions { functionsByName[function.name.lowercased()] = function }
        try checkRecursion(units: program.units, macros: macrosByName)

        var project = PCCProject(name: mainPage.name.isEmpty ? projectName : mainPage.name, profile: "Sybas Duino-E")
        project.appOptions.cycleDelay = 10
        // Time-based blocks count scans, so a millisecond timing needs the thread's period.
        let thread = ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)?
            .threads.filter { $0.intervalMs > 0 }
            .min { $0.intervalMs < $1.intervalMs }
        let threadId = thread?.id ?? 1
        let interval = max(1, thread?.intervalMs ?? 10)
        let allocator = IDAllocator()

        var modules: [PCCModule] = []
        var connections: [Connection] = []
        var pages: [String] = []
        var compiledMacros: [CompiledMacro] = []

        // The program first, then the other programs, then the function blocks.
        let ordered = [mainPage]
            + program.units.filter { $0.kind == .program && $0.name != mainPage.name }
            + program.units.filter { $0.kind == .functionBlock }
        for unit in ordered {
            let emitter = Emitter(page: unit.caption,
                                  thread: unit.kind == .functionBlock ? 0 : threadId,
                                  allocator: allocator,
                                  intervalMs: interval,
                                  macros: macrosByName,
                                  functions: functionsByName)
            let summary = try emitter.emit(unit)
            modules.append(contentsOf: emitter.modules)
            connections.append(contentsOf: emitter.connections)
            pages.append(unit.caption)
            if unit.kind == .functionBlock {
                compiledMacros.append(CompiledMacro(name: unit.name, caption: unit.caption,
                                                    inputs: summary.inputs, outputs: summary.outputs))
            }
        }

        project.pages = pages.map { ProjectPage(caption: $0) }
        project.modules = modules
        project.inConnections = connections

        return CompiledSource(project: project,
                              program: mainPage.name,
                              usedInputs: mainPage.inputs.map(\.index),
                              writtenOutputs: mainPage.outputs.map(\.index),
                              variables: mainPage.variables.map(\.name),
                              pages: pages,
                              macros: compiledMacros,
                              blockCount: modules.count)
    }

    /// A function block that calls itself, directly or through another, would compile to a call that recurses forever.
    private func checkRecursion(units: [SourceUnit], macros: [String: SourceUnit]) throws {
        var callsByBlock: [String: [String]] = [:]
        for unit in units where unit.kind == .functionBlock {
            var targets: [String] = []
            let types = Dictionary(unit.instances.map { ($0.name.lowercased(), $0.typeName.lowercased()) },
                                   uniquingKeysWith: { first, _ in first })
            for statement in unit.body {
                guard case .call(let instance, _) = statement.kind,
                      let type = types[instance.lowercased()], macros[type] != nil else { continue }
                targets.append(type)
            }
            callsByBlock[unit.name.lowercased()] = targets
        }
        for (name, _) in macros {
            var stack = callsByBlock[name] ?? []
            var seen: Set<String> = []
            while let next = stack.popLast() {
                if next == name {
                    throw SourceError(line: macros[name]?.line ?? 1,
                                      message: "function block '\(macros[name]?.name ?? name)' calls itself")
                }
                if seen.insert(next).inserted { stack.append(contentsOf: callsByBlock[next] ?? []) }
            }
        }
    }

    /// Ids are unique across pages; each page restarts order and position.
    final class IDAllocator {
        private var next = 1
        func take() -> Int {
            defer { next += 1 }
            return next
        }
    }
}

/// The catalogue block that computes `op` on `type`, if one exists. `Div` is the integer division; the catalogue has
/// no Long multiply/divide or Int modulo, so those are refused rather than approximated.
private func numericBlock(_ op: String, _ type: NumType) -> UUID? {
    let name: String?
    switch (type, op) {
    case (.int, "+"): name = "IAdd"
    case (.int, "-"): name = "ISub"
    case (.int, "*"): name = "IMul"
    case (.int, "/"): name = "Div"
    case (.long, "+"): name = "LAdd"
    case (.long, "-"): name = "LSub"
    case (.real, "+"): name = "FAdd"
    case (.real, "-"): name = "FSub"
    case (.real, "*"): name = "FMul"
    case (.real, "/"): name = "FDiv"
    case (.real, "%"): name = "FMod"
    default: name = nil
    }
    guard let name else { return nil }
    return BlockTypeCatalog.info(forBlockName: name)?.guid
}

private func comparisonBlock(_ type: NumType) -> UUID? {
    switch type {
    case .int: return BlockTypeCatalog.info(forBlockName: "Comparator")?.guid
    case .long: return BlockTypeCatalog.info(forBlockName: "LComparator")?.guid
    case .real: return nil
    }
}

private func switchBlock(_ type: NumType) -> UUID? {
    let name = type == .int ? "ISwitch" : type == .long ? "LSwitch" : "FSwitch"
    return BlockTypeCatalog.info(forBlockName: name)?.guid
}

// MARK: - Values

enum NumType: Equatable {
    case int, long, real

    var name: String {
        switch self {
        case .int: return "INT"
        case .long: return "LONG"
        case .real: return "REAL"
        }
    }
}

/// A numeric expression, with the type each node produces.
indirect enum NumExpr: Equatable {
    case constant(PinValue)
    case variable(String)
    case negate(NumExpr, NumType)
    case binary(String, NumExpr, NumExpr, NumType)
    /// `condition ? a : b`, lowered to `ISwitch`/`LSwitch`/`FSwitch`.
    case select(BoolExpr, NumExpr, NumExpr, NumType)
    /// `a[i]`, lowered to `ReadIntArray`/`ReadLongArray`.
    case arrayRead(String, NumExpr, NumType)
}

/// A lowered value: a Boolean signal, or a number with its type.
indirect enum Value: Equatable {
    case bool(BoolExpr)
    case number(NumExpr, NumType)
}

// MARK: - The Boolean expression tree

/// A Boolean signal as a pure expression. `IF` becomes `select`, so a whole scan is one expression per output.
indirect enum BoolExpr: Equatable {
    case constant(Bool)
    case input(Int)
    case variable(String)
    /// A function block's own input, by pin position.
    case macroInput(Int)
    /// The output of a macro call site (index) by pin position.
    case macroCall(Int, Int)
    /// The output of a library block call site (index) by pin position.
    case blockOutput(Int, Int)
    /// A numeric comparison, materialised as a comparator block's output when the Boolean is used.
    case comparison(String, NumExpr, NumExpr, NumType)
    case not(BoolExpr)
    case and(BoolExpr, BoolExpr)
    case or(BoolExpr, BoolExpr)
    case xor(BoolExpr, BoolExpr)

    func walk(_ visit: (BoolExpr) -> Void) {
        visit(self)
        switch self {
        case .constant, .input, .variable, .macroInput, .macroCall, .blockOutput, .comparison:
            break
        case .not(let a):
            a.walk(visit)
        case .and(let a, let b), .or(let a, let b), .xor(let a, let b):
            a.walk(visit); b.walk(visit)
        }
    }

    static func negated(_ a: BoolExpr) -> BoolExpr {
        switch a {
        case .constant(let v): return .constant(!v)
        case .not(let inner): return inner
        default: return .not(a)
        }
    }

    static func conjunction(_ a: BoolExpr, _ b: BoolExpr) -> BoolExpr {
        if case .constant(let v) = a { return v ? b : .constant(false) }
        if case .constant(let v) = b { return v ? a : .constant(false) }
        return .and(a, b)
    }

    static func disjunction(_ a: BoolExpr, _ b: BoolExpr) -> BoolExpr {
        if case .constant(let v) = a { return v ? .constant(true) : b }
        if case .constant(let v) = b { return v ? .constant(true) : a }
        return .or(a, b)
    }

    static func exclusiveOr(_ a: BoolExpr, _ b: BoolExpr) -> BoolExpr {
        if case .constant(let v) = a { return v ? negated(b) : b }
        if case .constant(let v) = b { return v ? negated(a) : a }
        return .xor(a, b)
    }

    /// `condition ? whenTrue : whenFalse`, folded where the answer is already known.
    static func select(_ condition: BoolExpr, _ whenTrue: BoolExpr, _ whenFalse: BoolExpr) -> BoolExpr {
        if whenTrue == whenFalse { return whenTrue }
        if case .constant(let v) = condition { return v ? whenTrue : whenFalse }
        if case .constant(true) = whenTrue, case .constant(false) = whenFalse { return condition }
        if case .constant(false) = whenTrue, case .constant(true) = whenFalse { return negated(condition) }
        if case .constant(false) = whenFalse { return conjunction(condition, whenTrue) }
        if case .constant(false) = whenTrue { return conjunction(negated(condition), whenFalse) }
        if case .constant(true) = whenTrue { return disjunction(condition, whenFalse) }
        if case .constant(true) = whenFalse { return disjunction(negated(condition), whenTrue) }
        return disjunction(conjunction(condition, whenTrue), conjunction(negated(condition), whenFalse))
    }
}

// MARK: - Blocks and wires

/// Where a consumer's input pin gets its value: a constant written into the pin, or a wire from a producer's output.
enum PinSource {
    case constant(Bool)
    case number(PinValue)
    case pin(module: Int, outPin: Int)
}

/// What one unit's emitter learned: a function block's pin names, or nothing for a program.
struct UnitSummary {
    var inputs: [String] = []
    var outputs: [String] = []
}

/// Builds the blocks and wires of one page. Ids come from the compiler's allocator; order and position restart at each
/// page, which is how Dirigo stores a sheet.
final class Emitter {
    private(set) var modules: [PCCModule] = []
    private(set) var connections: [Connection] = []
    private let page: String
    private let thread: Int
    private let allocator: SourceCompiler.IDAllocator
    private let intervalMs: Int
    private let macros: [String: SourceUnit]
    private let functions: [String: SourceFunction]
    private var order = 10
    private var placed = 0
    private var digitalInput: Int?
    private var variableBlocks: [String: Int] = [:]
    /// Each declared array's `Create…Array` block and its PLC Id.
    private var arrayBlocks: [String: (create: Int, id: Int, type: NumType)] = [:]
    private var macroInputs: Int?
    private var macroOutputs: Int?
    private var calls: [CallSite] = []
    private var blockCalls: [BlockCall] = []
    private var callBlocks: [Int: Int] = [:]
    private var blockCallBlocks: [Int: Int] = [:]
    private var isMacro: Bool { page.hasPrefix("*") }

    private static let columns = 4

    init(page: String, thread: Int, allocator: SourceCompiler.IDAllocator, intervalMs: Int,
         macros: [String: SourceUnit], functions: [String: SourceFunction]) {
        self.page = page
        self.thread = thread
        self.allocator = allocator
        self.intervalMs = intervalMs
        self.macros = macros
        self.functions = functions
    }

    @discardableResult
    func addBlock(_ guid: UUID) -> Int {
        let id = allocator.take()
        let module = BlockFactory.makeModule(guid: guid, id: id,
                                             name: BlockFactory.suggestedName(for: guid, existing: modules),
                                             x: Double(40 + (placed % Self.columns) * 200),
                                             y: Double(40 + (placed / Self.columns) * 150),
                                             order: order, threadId: thread, page: page)
        placed += 1
        order += 10
        modules.append(module)
        return id
    }

    /// Adds a module built by hand (`Inputs`/`Outputs`/a call), which `BlockFactory` does not make.
    ///
    /// `ordered: false` leaves ORDER for `assignOrder()` once the call's arguments are materialised: a call has to run
    /// after the blocks that feed it, and a self-wire is why it must exist before they are wired.
    func addModule(_ module: PCCModule, ordered: Bool = true) {
        var module = module
        module.id = allocator.take()
        module.order = ordered ? order : 0
        module.threadId = thread
        module.page = page
        module.x = Double(40 + (placed % Self.columns) * 200)
        module.y = Double(40 + (placed / Self.columns) * 150)
        if module.name.isEmpty {
            module.name = BlockFactory.suggestedName(for: module.guid, existing: modules)
        }
        placed += 1
        if ordered { order += 10 }
        modules.append(module)
    }

    /// Gives a module the next ORDER, now that everything it consumes has one.
    func assignOrder(_ id: Int) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[index].order = order
        order += 10
    }

    func connect(_ consumer: Int, _ pin: Int, _ source: PinSource) {
        switch source {
        case .constant(let value):
            setIn(consumer, pin, .bool(value))
        case .number(let value):
            setIn(consumer, pin, value)
        case .pin(let module, let outPin):
            connections.append(Connection(inModuleId: consumer, inPinId: pin, outModuleId: module, outPinId: outPin))
        }
    }

    func setIn(_ module: Int, _ pin: Int, _ value: PinValue) {
        guard let index = modules.firstIndex(where: { $0.id == module }),
              modules[index].inPins.indices.contains(pin) else { return }
        modules[index].inPins[pin].value = value
    }

    func setOut(_ module: Int, pin: Int, _ value: PinValue) {
        guard let index = modules.firstIndex(where: { $0.id == module }),
              modules[index].outPins.indices.contains(pin) else { return }
        modules[index].outPins[pin].value = value
    }

    private func setParam(_ module: Int, _ index: Int, _ value: PinValue) {
        guard let moduleIndex = modules.firstIndex(where: { $0.id == module }),
              modules[moduleIndex].paramPins.indices.contains(index) else { return }
        modules[moduleIndex].paramPins[index].value = value
    }

    // MARK: - Compiling one unit

    func emit(_ unit: SourceUnit) throws -> UnitSummary {
        var lowering = Lowering(unit: unit, macros: macros, intervalMs: intervalMs, functions: functions)
        let lowered = try lowering.lower(unit.body)
        calls = lowered.calls
        blockCalls = lowered.blockCalls

        var summary = UnitSummary()
        if unit.kind == .functionBlock {
            summary.inputs = unit.inputs.map(\.name)
            summary.outputs = unit.outputs.map(\.name)
            if !summary.inputs.isEmpty { macroInputs = makeInterface(.inputs, names: summary.inputs) }
            if !summary.outputs.isEmpty { macroOutputs = makeInterface(.outputs, names: summary.outputs) }
        }

        // Arrays are allocated once per scan before anything reads them; the block keeps its contents for the same
        // length, so the store survives between scans.
        for (offset, array) in unit.arrays.enumerated() {
            let block = addBlock(try guid(array.type == .int ? "CreateIntArray" : "CreateLongArray"))
            setIn(block, 0, .bool(true))
            setIn(block, 1, .int32(Int32(offset)))
            setIn(block, 2, .int32(Int32(array.length)))
            arrayBlocks[array.name.lowercased()] = (block, offset, array.type == .int ? .int : .long)
        }

        // Variables exist before anything reads them: a read is the block's output, the value at the start of the scan.
        // The writes go in last, so everything that reads a variable reads it before the scan updates it.
        for variable in unit.variables {
            let blockGuid: UUID
            switch variable.type {
            case .bool: blockGuid = BoolVarBlock.guid
            case .int: blockGuid = try guid("IntVar")
            case .long: blockGuid = try guid("LongVar")
            case .real: blockGuid = try guid("FloatVar")
            }
            let initial: PinValue
            switch (variable.type, variable.initial) {
            case (.bool, .boolean(let value)?): initial = .bool(value)
            case (.int, .integer(let value)?): initial = .int32(Int32(clamping: value))
            case (.long, .integer(let value)?): initial = .int32(Int32(clamping: value))
            case (.real, .real(let value)?): initial = .float(Float(value))
            case (.real, .integer(let value)?): initial = .float(Float(value))
            default:
                switch variable.type {
                case .bool: initial = .bool(false)
                case .int: initial = .int32(0)
                case .long: initial = .int32(0)
                case .real: initial = .float(0)
                }
            }
            let block = addBlock(blockGuid)
            setOut(block, pin: 0, initial)
            if variable.type != .bool {
                // A variable's configured value is `INIT_VALUE`; the simulator/registry reads it from there.
                if let index = modules.firstIndex(where: { $0.id == block }) {
                    modules[index].rawAttributes["INIT_VALUE"] = "\(initial)"
                }
            }
            variableBlocks[variable.name.lowercased()] = block
        }

        var sources: [(pin: Int, source: PinSource)] = []
        for (pin, value) in lowered.outputs.sorted(by: { $0.key < $1.key }) {
            guard case .bool(let expression) = value else {
                throw SourceError(line: unit.line, message: "a numeric value cannot drive a BOOL output pin")
            }
            sources.append((pin, try materialiseBool(expression)))
        }
        if unit.kind == .program && !sources.isEmpty {
            let doBlock = addBlock(EightDOBlock.guid)
            for (pin, source) in sources { connect(doBlock, pin + 1, source) }
        }
        if unit.kind == .functionBlock {
            if let macroOutputs {
                for (pin, source) in sources { connect(macroOutputs, pin, source) }
            } else if !sources.isEmpty {
                throw SourceError(line: unit.line, message: "function block '\(unit.name)' writes an output it does not declare")
            }
        }

        // Only instances the body calls are emitted: an uncalled function block must not run every scan.
        for index in lowered.calledCalls.sorted() { _ = try materialiseCall(index) }
        for index in lowered.calledBlocks.sorted() { _ = try materialiseBlockCall(index) }

        for (name, expression) in lowered.variableWrites.sorted(by: { $0.key < $1.key }) {
            guard let variableBlock = variableBlocks[name.lowercased()] else { continue }
            let value = try materialise(expression)
            let set = addBlock(SetBlock.guid)
            connect(set, 1, value)
            connect(set, 2, .pin(module: variableBlock, outPin: 0))
        }
        // Array writes happen last in source order: reads earlier in the scan see the value the scan began with.
        for write in lowered.arrayWrites {
            guard let array = arrayBlocks[write.array.lowercased()] else { continue }
            let block = addBlock(try guid(array.type == .int ? "WriteIntArray" : "WriteLongArray"))
            connect(block, 0, .constant(true))
            connect(block, 1, .number(.int32(Int32(array.id))))
            connect(block, 2, try materialiseNumber(write.index))
            connect(block, 3, try materialiseNumber(write.value))
        }
        return summary
    }

    private func makeInterface(_ kind: MacroInterface.Kind, names: [String]) -> Int {
        var module = PCCModule(id: 0, guid: MacroInterface.interfaceGUID,
                               name: kind.attributeName, x: 0, y: 0, order: 0, threadId: thread, page: page)
        module.rawAttributes["MACRO_NAME"] = kind.attributeName
        module.rawAttributes["KIND"] = String(kind.rawValue)
        switch kind {
        case .inputs:
            module.outPins = names.enumerated().map { index, name in
                var pin = Pin(id: index, value: .bool(false), rights: 2)
                pin.name = name
                pin.rawAttributes["TYPE"] = "1"
                return pin
            }
        case .outputs:
            module.inPins = names.enumerated().map { index, name in
                var pin = Pin(id: index, value: .bool(false))
                pin.name = name
                pin.rawAttributes["TYPE"] = "1"
                return pin
            }
        }
        addModule(module)
        return modules[modules.count - 1].id
    }

    // MARK: - Expressions

    /// The catalogue block with this name, or a clear error.
    private func guid(_ name: String) throws -> UUID {
        guard let guid = BlockTypeCatalog.info(forBlockName: name)?.guid else {
            throw SourceError(line: 0, message: "the catalogue has no block named '\(name)'")
        }
        return guid
    }

    func materialise(_ value: Value) throws -> PinSource {
        switch value {
        case .bool(let expression): return try materialiseBool(expression)
        case .number(let expression, _): return try materialiseNumber(expression)
        }
    }

    func materialiseBool(_ expression: BoolExpr) throws -> PinSource {
        switch expression {
        case .constant(let value):
            return .constant(value)
        case .comparison(let op, let a, let b, let type):
            guard let blockGuid = comparisonBlock(type) else {
                throw SourceError(line: 0, message: "no comparator for \(type.name)")
            }
            let left = try materialiseNumber(a), right = try materialiseNumber(b)
            let block = addBlock(blockGuid)
            connect(block, 0, .constant(true))
            connect(block, 1, left)
            connect(block, 2, right)
            let output = op == ">" ? 0 : op == "==" ? 1 : 2
            return .pin(module: block, outPin: output)
        case .input(let pin):
            if digitalInput == nil { digitalInput = addBlock(EightDIBlock.guid) }
            return .pin(module: digitalInput!, outPin: pin)
        case .variable(let name):
            guard let block = variableBlocks[name.lowercased()] else { return .constant(false) }
            return .pin(module: block, outPin: 0)
        case .macroInput(let pin):
            guard let macroInputs else { return .constant(false) }
            return .pin(module: macroInputs, outPin: pin)
        case .macroCall(let call, let pin):
            return .pin(module: try materialiseCall(call), outPin: pin)
        case .blockOutput(let call, let pin):
            let block = try materialiseBlockCall(call)
            let count = modules.first { $0.id == block }?.outPins.count ?? 0
            guard pin < count else {
                throw SourceError(line: blockCalls[call].line,
                                  message: "'\(blockCalls[call].name)' has no output pin \(pin); it has \(count)")
            }
            return .pin(module: block, outPin: pin)
        case .not(let operand):
            let value = try materialiseBool(operand)
            let block = addBlock(NotBlock.guid)
            connect(block, 1, value)
            return .pin(module: block, outPin: 0)
        case .and(let a, let b):
            let left = try materialiseBool(a), right = try materialiseBool(b)
            let block = addBlock(AndBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .or(let a, let b):
            let left = try materialiseBool(a), right = try materialiseBool(b)
            let block = addBlock(OrBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .xor(let a, let b):
            let left = try materialiseBool(a), right = try materialiseBool(b)
            let block = addBlock(XorBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        }
    }

    /// Lower a numeric expression to a pin: constants into the consumer's pin, or a wire from a block's output.
    private func materialiseNumber(_ expression: NumExpr) throws -> PinSource {
        switch expression {
        case .constant(let value):
            return .number(value)
        case .variable(let name):
            guard let block = variableBlocks[name.lowercased()] else {
                throw SourceError(line: 0, message: "unknown variable '\(name)'")
            }
            return .pin(module: block, outPin: 0)
        case .negate(let inner, let type):
            guard let blockGuid = numericBlock("-", type) else {
                throw SourceError(line: 0, message: "no block computes '-' on \(type.name)")
            }
            let operand = try materialiseNumber(inner)
            let block = addBlock(blockGuid)
            connect(block, 0, .constant(true))
            connect(block, 1, .number(type == .real ? .float(0) : .int32(0)))
            connect(block, 2, operand)
            return .pin(module: block, outPin: 0)
        case .binary(let op, let a, let b, let type):
            guard let blockGuid = numericBlock(op, type) else {
                throw SourceError(line: 0, message: "no block computes '\(op)' on \(type.name)")
            }
            let left = try materialiseNumber(a), right = try materialiseNumber(b)
            let block = addBlock(blockGuid)
            connect(block, 0, .constant(true))
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .arrayRead(let name, let index, let type):
            guard let array = arrayBlocks[name.lowercased()] else {
                throw SourceError(line: 0, message: "unknown array '\(name)'")
            }
            let block = addBlock(try guid(type == .int ? "ReadIntArray" : "ReadLongArray"))
            connect(block, 0, .constant(true))
            connect(block, 1, .number(.int32(Int32(array.id))))
            connect(block, 2, try materialiseNumber(index))
            return .pin(module: block, outPin: 0)
        case .select(let condition, let whenTrue, let whenFalse, let type):
            guard let blockGuid = switchBlock(type) else {
                throw SourceError(line: 0, message: "no selector for \(type.name)")
            }
            let test = try materialiseBool(condition)
            let yes = try materialiseNumber(whenTrue), no = try materialiseNumber(whenFalse)
            let block = addBlock(blockGuid)
            connect(block, 0, .constant(true))
            connect(block, 1, test)
            connect(block, 2, no)       // X0, the value when Sw = 0
            connect(block, 3, yes)      // X1, the value when Sw = 1
            return .pin(module: block, outPin: 0)
        }
    }

    /// Creates (once) the block a declared instance stands for, wires the inputs its call gave, and sets its parameters.
    private func materialiseBlockCall(_ index: Int) throws -> Int {
        if let existing = blockCallBlocks[index] { return existing }
        let call = blockCalls[index]
        var module = BlockFactory.makeModule(guid: call.guid, id: allocator.take(),
                                             name: BlockFactory.suggestedName(for: call.guid, existing: modules),
                                             x: 0, y: 0, order: 0, threadId: thread, page: page)
        if let highest = call.inputs.keys.max(), highest >= module.inPins.count {
            while module.inPins.count <= highest {
                module.inPins.append(Pin(id: module.inPins.count, value: .bool(false)))
            }
            if let count = BlockLabels.countedInputCount(for: call.guid, totalPins: module.inPins.count) {
                module.inputCount = count
            }
        }
        addModule(module, ordered: false)
        let block = modules[modules.count - 1].id
        // Registered before wiring: feedback wires this block's own output back into it.
        blockCallBlocks[index] = block
        for (pin, argument) in call.inputs {
            switch argument {
            case .constant(let value): setIn(block, pin, value)
            case .signal(let expression): connect(block, pin, try materialiseBool(expression))
            }
        }
        for (parameter, value) in call.params { setParam(block, parameter, value) }
        assignOrder(block)
        return block
    }

    /// Creates (once) the `Macro` block a function-block instance stands for, with its arguments wired.
    private func materialiseCall(_ index: Int) throws -> Int {
        if let existing = callBlocks[index] { return existing }
        let call = calls[index]
        let outputs = call.macro.outputs
        let names = call.macro.inputs.map(\.name)
        var module = PCCModule(id: 0, guid: MacroInterface.callGUID,
                               name: BlockFactory.suggestedName(for: MacroInterface.callGUID, existing: modules),
                               x: 0, y: 0, order: 0, threadId: thread, page: page)
        module.rawAttributes["MACRO_NAME"] = call.macro.name
        module.inPins = names.enumerated().map { index, name in
            var pin = Pin(id: index, value: .bool(false))
            pin.name = name
            pin.rawAttributes["TYPE"] = "1"
            return pin
        }
        let outputNames = outputs.map(\.name)
        module.outPins = outputNames.enumerated().map { index, name in
            var pin = Pin(id: index, value: .bool(false), rights: 2)
            pin.name = name
            pin.rawAttributes["TYPE"] = "1"
            return pin
        }
        addModule(module, ordered: false)
        let block = modules[modules.count - 1].id
        callBlocks[index] = block
        for (position, name) in names.enumerated() {
            guard let argument = call.arguments[name.lowercased()] else { continue }
            connect(block, position, try materialiseBool(argument))
        }
        assignOrder(block)
        return block
    }
}

// MARK: - Lowering

/// One argument of a block call.
enum BlockArg {
    case constant(PinValue)
    case signal(BoolExpr)
}

/// A declared instance of a catalogued block.
struct BlockCall {
    var guid: UUID
    var name: String
    var inputs: [Int: BlockArg] = [:]
    var params: [Int: PinValue] = [:]
    var line: Int
}

/// A declared instance of a function block, with the arguments its call gave.
struct CallSite {
    var macro: SourceUnit
    var arguments: [String: BoolExpr] = [:]
    var line: Int
}

/// What a unit's body lowered to.
/// A write into an array, in source order; the emitter turns each into a `Write…Array` block.
struct ArrayWrite {
    var array: String
    var index: NumExpr
    var value: NumExpr
    var line: Int
}

struct LoweredScan {
    var outputs: [Int: Value] = [:]
    var variableWrites: [String: Value] = [:]
    var arrayWrites: [ArrayWrite] = []
    var calls: [CallSite] = []
    var blockCalls: [BlockCall] = []
    /// Which instances the body actually calls; an uncalled one is not emitted at all.
    var calledCalls: Set<Int> = []
    var calledBlocks: Set<Int> = []
}

/// Lowers one unit's body.
struct Lowering {
    let unit: SourceUnit
    let macros: [String: SourceUnit]
    let intervalMs: Int
    let functions: [String: SourceFunction]
    private var instances: [String: Instance] = [:]
    private var inBranch = false

    private enum Instance {
        case macro(index: Int, block: SourceUnit)
        case block(index: Int)
    }

    init(unit: SourceUnit, macros: [String: SourceUnit], intervalMs: Int,
         functions: [String: SourceFunction]) {
        self.unit = unit
        self.macros = macros
        self.intervalMs = intervalMs
        self.functions = functions
    }

    mutating func lower(_ statements: [SourceStmt]) throws -> LoweredScan {
        var scan = LoweredScan()
        // Declare every instance first: they are the blocks the body then calls.
        for declaration in unit.instances {
            let key = declaration.name.lowercased()
            if let block = macros[declaration.typeName.lowercased()] {
                scan.calls.append(CallSite(macro: block, line: declaration.line))
                instances[key] = .macro(index: scan.calls.count - 1, block: block)
            } else if let guid = BlockLabels.guid(forSourceName: declaration.typeName) {
                scan.blockCalls.append(BlockCall(guid: guid, name: declaration.typeName, line: declaration.line))
                instances[key] = .block(index: scan.blockCalls.count - 1)
            } else {
                throw SourceError(line: declaration.line,
                                  message: "unknown type '\(declaration.typeName)'; declare a FUNCTION_BLOCK or a block type")
            }
        }
        try lower(statements, into: &scan)
        return scan
    }

    private func outputIndex(_ name: String) -> Int? {
        unit.outputs.first { $0.name.lowercased() == name.lowercased() }?.index
    }
    private func inputPin(_ name: String) -> SourcePin? {
        unit.inputs.first { $0.name.lowercased() == name.lowercased() }
    }
    private func outputPosition(_ name: String) -> Int? {
        unit.outputs.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
    private func inputPosition(_ name: String) -> Int? {
        unit.inputs.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
    private func variableName(_ name: String) -> String? {
        unit.variables.first { $0.name.lowercased() == name.lowercased() }?.name
    }

    private func variableType(_ name: String) -> SourceType? {
        unit.variables.first { $0.name.lowercased() == name.lowercased() }?.type
    }

    private func arrayInfo(_ name: String) -> SourceArray? {
        unit.arrays.first { $0.name.lowercased() == name.lowercased() }
    }

    private func numType(_ type: SourceType) -> NumType? {
        switch type {
        case .bool: return nil
        case .int: return .int
        case .long: return .long
        case .real: return .real
        }
    }

    private func widened(_ a: NumType, _ b: NumType) -> NumType {
        if a == b { return a }
        if a == .real || b == .real { return .real }
        return .long
    }

    private func boolValue(_ value: Value, line: Int, what: String = "this expression") throws -> BoolExpr {
        guard case .bool(let expr) = value else {
            throw SourceError(line: line, message: "\(what) is BOOL; a number cannot be used there")
        }
        return expr
    }

    private func numberValue(_ value: Value, line: Int) throws -> (NumExpr, NumType) {
        guard case .number(let expr, let type) = value else {
            throw SourceError(line: line, message: "a number is expected here, not a BOOL")
        }
        return (expr, type)
    }

    /// A value stored in a variable of `type`: BOOL only in BOOL, a number only where it widens.
    private func stored(_ value: Value, in type: SourceType, line: Int, name: String) throws -> Value {
        switch (type, value) {
        case (.bool, .bool):
            return value
        case (.bool, .number):
            throw SourceError(line: line, message: "'\(name)' is BOOL; a number cannot be stored in it")
        case (.int, .number(let expr, let from)):
            guard from == .int else {
                throw SourceError(line: line, message: "'\(name)' is INT; a \(from.name) cannot be narrowed into it")
            }
            return .number(expr, .int)
        case (.long, .number(let expr, let from)):
            guard from != .real else {
                throw SourceError(line: line, message: "'\(name)' is LONG; a REAL cannot be narrowed into it")
            }
            return .number(expr, .long)
        case (.real, .number(let expr, _)):
            return .number(expr, .real)
        case (_, .bool):
            throw SourceError(line: line, message: "'\(name)' is \(type.name); a BOOL cannot be stored in it")
        }
    }

    /// Inline a FUNCTION: parameters become the caller's argument expressions, nested calls are expanded first.
    private func expand(_ expression: SourceExpr, parameters: [SourceParameter], arguments: [SourceExpr],
                        depth: Int, line: Int) throws -> SourceExpr {
        guard depth < 32 else {
            throw SourceError(line: line, message: "a function call is recursive or nested too deeply")
        }
        switch expression.kind {
        case .name(let name):
            if let index = parameters.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                return arguments[index]
            }
            return expression
        case .functionCall(let name, let callArguments):
            guard let function = functions[name.lowercased()] else {
                throw SourceError(line: line, message: "unknown function '\(name)'")
            }
            guard callArguments.count == function.parameters.count else {
                throw SourceError(line: line,
                                  message: "'\(name)' takes \(function.parameters.count) argument(s), not \(callArguments.count)")
            }
            var expandedArguments: [SourceExpr] = []
            for argument in callArguments {
                expandedArguments.append(try expand(argument, parameters: parameters, arguments: arguments,
                                                    depth: depth + 1, line: line))
            }
            return try expand(function.body, parameters: function.parameters, arguments: expandedArguments,
                              depth: depth + 1, line: line)
        case .unary(let op, let operand):
            return SourceExpr(.unary(op, try expand(operand, parameters: parameters, arguments: arguments,
                                                    depth: depth + 1, line: line)), line: expression.line)
        case .binary(let op, let left, let right):
            return SourceExpr(.binary(op,
                                      try expand(left, parameters: parameters, arguments: arguments, depth: depth + 1, line: line),
                                      try expand(right, parameters: parameters, arguments: arguments, depth: depth + 1, line: line)),
                              line: expression.line)
        case .member, .element:
            throw SourceError(line: line, message: "a FUNCTION body cannot read instances or arrays")
        case .boolean, .integer, .real:
            return expression
        }
    }

    private func expandNodeCount(_ expression: SourceExpr) -> Int {
        switch expression.kind {
        case .boolean, .integer, .real, .name: return 1
        case .member(let base, _): return 1 + expandNodeCount(base)
        case .element(let base, let indexExpression): return 1 + expandNodeCount(base) + expandNodeCount(indexExpression)
        case .functionCall(_, let arguments): return 1 + arguments.reduce(0) { $0 + expandNodeCount($1) }
        case .unary(_, let operand): return 1 + expandNodeCount(operand)
        case .binary(_, let left, let right): return 1 + expandNodeCount(left) + expandNodeCount(right)
        }
    }

    /// A literal index is checked against the declaration; a computed one is left to the block's runtime range check.
    private func checkArrayBounds(_ index: NumExpr, array: SourceArray, line: Int) throws {
        let value: Int?
        switch index {
        case .constant(.int32(let constant)): value = Int(constant)
        case .constant(.int64(let constant)): value = Int(constant)
        default: value = nil
        }
        if let value, value < array.lower || value > array.upper {
            throw SourceError(line: line,
                              message: "index \(value) is outside \(array.name)[\(array.lower)..\(array.upper)]")
        }
    }

    /// The array blocks are 0-based; an `ARRAY[5..7]` element at `5` is slot 0.
    private func offsetArrayIndex(_ index: NumExpr, by array: SourceArray, type: NumType) -> NumExpr {
        guard array.lower != 0 else { return index }
        return .binary("-", index, .constant(type == .long ? .int64(Int64(array.lower)) : .int32(Int32(array.lower))), type)
    }

    private func defaultValue(for name: String) -> Value {
        guard let type = variableType(name) else { return .bool(.variable(name)) }
        switch type {
        case .bool: return .bool(.variable(name))
        case .int: return .number(.variable(name), .int)
        case .long: return .number(.variable(name), .long)
        case .real: return .number(.variable(name), .real)
        }
    }

    private func merge(_ test: BoolExpr, _ whenTrue: Value, _ whenFalse: Value, line: Int) throws -> Value {
        switch (whenTrue, whenFalse) {
        case (.bool(let a), .bool(let b)):
            return .bool(.select(test, a, b))
        case (.number(let a, let ta), .number(let b, let tb)):
            let type = widened(ta, tb)
            guard switchBlock(type) != nil else {
                throw SourceError(line: line, message: "a \(type.name) selection has no block")
            }
            return .number(.select(test, a, b, type), type)
        default:
            throw SourceError(line: line, message: "both branches of an IF must have the same type")
        }
    }
    private func instance(_ name: String) -> Instance? { instances[name.lowercased()] }

    private mutating func lower(_ statements: [SourceStmt], into scan: inout LoweredScan) throws {
        for statement in statements {
            switch statement.kind {
            case .assign(let name, let expression):
                let value = try lower(expression, scan: &scan)
                if let index = outputIndex(name) {
                    guard case .bool = value else {
                        throw SourceError(line: statement.line, message: "'\(name)' is a BOOL output pin; a number cannot drive it")
                    }
                    scan.outputs[index] = value
                } else if arrayInfo(name) != nil {
                    throw SourceError(line: statement.line,
                                      message: "'\(name)' is an array; assign an element as in '\(name)[0] := …'")
                } else if let variable = variableName(name), let type = variableType(variable) {
                    scan.variableWrites[variable.lowercased()] = try stored(value, in: type, line: statement.line, name: name)
                } else if inputPin(name) != nil {
                    throw SourceError(line: statement.line, message: "'\(name)' is an input; it is read, not written")
                } else if instance(name) != nil {
                    throw SourceError(line: statement.line, message: "'\(name)' is an instance; write one of its outputs? No — read it instead")
                } else {
                    throw SourceError(line: statement.line, message: "unknown name '\(name)'")
                }
            case .call(let name, let arguments):
                if inBranch {
                    throw SourceError(line: statement.line,
                                      message: "a block call cannot be inside IF; wire it before the branch")
                }
                guard let target = instance(name) else {
                    throw SourceError(line: statement.line, message: "unknown instance '\(name)'")
                }
                switch target {
                case .macro(let index, let block):
                    guard scan.calledCalls.insert(index).inserted else {
                        throw SourceError(line: statement.line,
                                          message: "'\(name)' is called twice; one block is wired once per scan")
                    }
                    for argument in arguments {
                        guard block.inputs.contains(where: { $0.name.lowercased() == argument.label.lowercased() }) else {
                            throw SourceError(line: argument.value.line,
                                              message: "'\(block.name)' has no input '\(argument.label)'; it has "
                                                  + block.inputs.map(\.name).joined(separator: ", "))
                        }
                        scan.calls[index].arguments[argument.label.lowercased()] =
                            try boolValue(lower(argument.value, scan: &scan), line: argument.value.line,
                                          what: "an input of '\(block.name)'")
                    }
                case .block(let index):
                    guard scan.calledBlocks.insert(index).inserted else {
                        throw SourceError(line: statement.line,
                                          message: "'\(name)' is called twice; one block is wired once per scan")
                    }
                    let call = scan.blockCalls[index]
                    let inputs = BlockLabels.inputLabels(for: call.guid, totalPins: BlockLabels.maxInputPins(for: call.guid))
                    let params = BlockLabels.paramLabels(for: call.guid)
                    for argument in arguments {
                        if let pin = inputs.firstIndex(where: { $0.lowercased() == argument.label.lowercased() }) {
                            scan.blockCalls[index].inputs[pin] = try blockArgument(argument.value, scan: &scan)
                        } else if let parameter = params.firstIndex(where: { $0.lowercased() == argument.label.lowercased() }) {
                            scan.blockCalls[index].params[parameter] = try constantValue(argument.value)
                        } else {
                            throw SourceError(line: argument.value.line,
                                              message: "'\(call.name)' has no input or parameter '\(argument.label)'")
                        }
                    }
                }
            case .arrayAssign(let name, let indexExpression, let valueExpression):
                if inBranch {
                    throw SourceError(line: statement.line,
                                      message: "an array write cannot be inside IF or CASE")
                }
                guard let array = arrayInfo(name) else {
                    throw SourceError(line: statement.line, message: "unknown array '\(name)'")
                }
                let (index, indexType) = try numberValue(try lower(indexExpression, scan: &scan), line: statement.line)
                guard indexType != .real else {
                    throw SourceError(line: statement.line, message: "an array index is an integer, not REAL")
                }
                let (value, valueType) = try numberValue(try lower(valueExpression, scan: &scan), line: statement.line)
                if array.type == .int, valueType != .int {
                    throw SourceError(line: statement.line, message: "'\(name)' is an INT array; a \(valueType.name) cannot be stored in it")
                }
                if array.type == .long, valueType == .real {
                    throw SourceError(line: statement.line, message: "'\(name)' is a LONG array; a REAL cannot be stored in it")
                }
                try checkArrayBounds(index, array: array, line: statement.line)
                scan.arrayWrites.append(ArrayWrite(array: name, index: offsetArrayIndex(index, by: array, type: indexType),
                                                   value: value, line: statement.line))
            case .block(let body):
                try lower(body, into: &scan)
            case .ifThen(let condition, let thenBody, let elseBody):
                let test = try boolValue(lower(condition, scan: &scan), line: statement.line, what: "an IF condition")
                let wasInBranch = inBranch
                inBranch = true
                var thenScan = scan
                try lower(thenBody, into: &thenScan)
                var elseScan = scan
                if let elseBody { try lower(elseBody, into: &elseScan) }
                inBranch = wasInBranch
                for pin in Set(thenScan.outputs.keys).union(elseScan.outputs.keys) {
                    let writtenBefore = scan.outputs[pin] != nil
                    let inThen = thenScan.outputs[pin] != nil
                    let inElse = elseScan.outputs[pin] != nil
                    if !writtenBefore && !(inThen && inElse) {
                        throw SourceError(line: statement.line,
                                          message: "an output written only inside IF is cleared when the condition is false; "
                                              + "assign it before the IF or add an ELSE")
                    }
                    func bool(_ value: Value?) -> BoolExpr? {
                        if case .bool(let expr)? = value { return expr }
                        return nil
                    }
                    let whenTrue = bool(thenScan.outputs[pin]) ?? bool(scan.outputs[pin]) ?? .constant(false)
                    let whenFalse = bool(elseScan.outputs[pin]) ?? bool(scan.outputs[pin]) ?? .constant(false)
                    scan.outputs[pin] = .bool(.select(test, whenTrue, whenFalse))
                }
                for name in Set(thenScan.variableWrites.keys).union(elseScan.variableWrites.keys) {
                    let fallback = defaultValue(for: name)
                    let whenTrue = thenScan.variableWrites[name] ?? fallback
                    let whenFalse = elseScan.variableWrites[name] ?? fallback
                    scan.variableWrites[name] = try merge(test, whenTrue, whenFalse, line: statement.line)
                }
            }
        }
    }

    private func integerValue(_ value: Int) -> PinValue {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(Int64(value))
    }

    private func blockArgument(_ expression: SourceExpr, scan: inout LoweredScan) throws -> BlockArg {
        switch expression.kind {
        case .boolean(let value): return .constant(.bool(value))
        case .integer(let value): return .constant(integerValue(value))
        case .real(let value): return .constant(.float(Float(value)))
        case .unary("-", let operand):
            if case .integer(let value) = operand.kind { return .constant(integerValue(-value)) }
            if case .real(let value) = operand.kind { return .constant(.float(Float(-value))) }
            return .signal(try boolValue(try lower(expression, scan: &scan), line: expression.line))
        default: return .signal(try boolValue(try lower(expression, scan: &scan), line: expression.line))
        }
    }

    private func constantValue(_ expression: SourceExpr) throws -> PinValue {
        switch expression.kind {
        case .boolean(let value): return .bool(value)
        case .integer(let value): return integerValue(value)
        case .real(let value): return .float(Float(value))
        case .unary("-", let operand):
            if case .real(let value) = operand.kind { return .float(Float(-value)) }
            guard case .integer(let value) = operand.kind else {
                throw SourceError(line: expression.line, message: "expected a number")
            }
            return integerValue(-value)
        default:
            throw SourceError(line: expression.line, message: "a parameter takes a literal value")
        }
    }

    private func lower(_ expression: SourceExpr, scan: inout LoweredScan) throws -> Value {
        switch expression.kind {
        case .boolean(let value):
            return .bool(.constant(value))
        case .integer(let value):
            return .number(.constant(integerValue(value)), Int32(exactly: value) != nil ? .int : .long)
        case .real(let value):
            return .number(.constant(.float(Float(value))), .real)
        case .name(let name):
            if let pin = inputPin(name) {
                return .bool(unit.kind == .functionBlock ? .macroInput(inputPosition(name) ?? 0) : .input(pin.index))
            }
            if let variable = variableName(name), let type = variableType(variable) {
                switch type {
                case .bool: return .bool(.variable(variable))
                case .int: return .number(.variable(variable), .int)
                case .long: return .number(.variable(variable), .long)
                case .real: return .number(.variable(variable), .real)
                }
            }
            if arrayInfo(name) != nil {
                throw SourceError(line: expression.line,
                                  message: "'\(name)' is an array; read an element as in '\(name)[0]'")
            }
            if instance(name) != nil {
                throw SourceError(line: expression.line,
                                  message: "'\(name)' is an instance; read one of its outputs, as in '\(name).Y'")
            }
            if let index = outputIndex(name) {
                guard let value = scan.outputs[index] else {
                    throw SourceError(line: expression.line,
                                      message: "'\(name)' is an output read before it is assigned; use a VAR to keep its value")
                }
                return value
            }
            throw SourceError(line: expression.line, message: "unknown name '\(name)'")
        case .member(let base, let name):
            guard case .name(let instanceName) = base.kind else {
                throw SourceError(line: expression.line, message: "only an instance's outputs can be read")
            }
            switch instance(instanceName) {
            case .macro(let index, let block):
                guard scan.calledCalls.contains(index) else {
                    throw SourceError(line: expression.line, message: "'\(instanceName)' is read before it is called")
                }
                guard let position = block.outputs.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
                    throw SourceError(line: expression.line,
                                      message: "'\(block.name)' has no output '\(name)'; it has "
                                          + block.outputs.map(\.name).joined(separator: ", "))
                }
                return .bool(.macroCall(index, position))
            case .block(let index):
                guard scan.calledBlocks.contains(index) else {
                    throw SourceError(line: expression.line, message: "'\(instanceName)' is read before it is called")
                }
                let call = scan.blockCalls[index]
                let labels = BlockLabels.outputLabels(for: call.guid)
                guard let position = labels.firstIndex(where: { $0.lowercased() == name.lowercased() }) else {
                    throw SourceError(line: expression.line,
                                      message: "'\(call.name)' has no output '\(name)'; it has "
                                          + labels.joined(separator: ", "))
                }
                return .bool(.blockOutput(index, position))
            case nil:
                throw SourceError(line: expression.line, message: "unknown instance '\(instanceName)'")
            }
        case .functionCall(let name, let arguments):
            guard let function = functions[name.lowercased()] else {
                throw SourceError(line: expression.line, message: "unknown function '\(name)'")
            }
            guard arguments.count == function.parameters.count else {
                throw SourceError(line: expression.line,
                                  message: "'\(name)' takes \(function.parameters.count) argument(s), not \(arguments.count)")
            }
            let expanded = try expand(function.body, parameters: function.parameters, arguments: arguments,
                                      depth: 0, line: expression.line)
            guard expandNodeCount(expanded) <= 50_000 else {
                throw SourceError(line: expression.line, message: "this function call expands to too large an expression")
            }
            let value = try lower(expanded, scan: &scan)
            switch (function.returnType, value) {
            case (.bool, .bool):
                return value
            case (.bool, _):
                throw SourceError(line: expression.line, message: "'\(name)' returns BOOL; its expression is a number")
            case (.int, .number(_, .int)):
                return value
            case (.int, .number(_, let from)):
                throw SourceError(line: expression.line, message: "'\(name)' returns INT; its expression is \(from.name)")
            case (.long, .number(_, .int)), (.long, .number(_, .long)):
                return value
            case (.long, .number(_, .real)):
                throw SourceError(line: expression.line, message: "'\(name)' returns LONG; its expression is REAL")
            case (.real, .number):
                return value
            case (.int, .bool), (.long, .bool), (.real, .bool):
                throw SourceError(line: expression.line,
                                  message: "'\(name)' returns \(function.returnType.name); its expression is BOOL")
            }
        case .element(let base, let indexExpression):
            guard case .name(let arrayName) = base.kind, let array = arrayInfo(arrayName) else {
                throw SourceError(line: expression.line, message: "only a declared array can be indexed")
            }
            let (index, indexType) = try numberValue(try lower(indexExpression, scan: &scan), line: expression.line)
            guard indexType != .real else {
                throw SourceError(line: expression.line, message: "an array index is an integer, not REAL")
            }
            try checkArrayBounds(index, array: array, line: expression.line)
            let type: NumType = array.type == .int ? .int : .long
            return .number(.arrayRead(arrayName, offsetArrayIndex(index, by: array, type: indexType), type), type)
        case .unary(let op, let operand):
            switch op {
            case "!":
                let value = try boolValue(try lower(operand, scan: &scan), line: expression.line)
                return .bool(.negated(value))
            case "-":
                let (value, type) = try numberValue(try lower(operand, scan: &scan), line: expression.line)
                return .number(.negate(value, type), type)
            default:
                throw SourceError(line: expression.line, message: "unknown operator '\(op)'")
            }
        case .binary(let op, let left, let right):
            let leftValue = try lower(left, scan: &scan)
            let rightValue = try lower(right, scan: &scan)
            switch op {
            case "&&", "||", "xor":
                let a = try boolValue(leftValue, line: left.line)
                let b = try boolValue(rightValue, line: right.line)
                switch op {
                case "&&": return .bool(.conjunction(a, b))
                case "||": return .bool(.disjunction(a, b))
                default: return .bool(.exclusiveOr(a, b))
                }
            case "==", "!=":
                if case .bool(let a) = leftValue, case .bool(let b) = rightValue {
                    let unequal = BoolExpr.exclusiveOr(a, b)
                    return .bool(op == "==" ? .negated(unequal) : unequal)
                }
                let (a, ta) = try numberValue(leftValue, line: left.line)
                let (b, tb) = try numberValue(rightValue, line: right.line)
                let type = widened(ta, tb)
                guard type != .real else {
                    throw SourceError(line: expression.line,
                                      message: "REAL comparison is not supported yet (no float comparator block)")
                }
                let equal = BoolExpr.comparison("==", a, b, type)
                return .bool(op == "==" ? equal : .negated(equal))
            case "<", ">", "<=", ">=":
                let (a, ta) = try numberValue(leftValue, line: left.line)
                let (b, tb) = try numberValue(rightValue, line: right.line)
                let type = widened(ta, tb)
                guard type != .real else {
                    throw SourceError(line: expression.line,
                                      message: "REAL comparison is not supported yet (no float comparator block)")
                }
                switch op {
                case "<": return .bool(.comparison("<", a, b, type))
                case ">": return .bool(.comparison(">", a, b, type))
                case "<=": return .bool(.disjunction(.comparison("<", a, b, type), .comparison("==", a, b, type)))
                default: return .bool(.disjunction(.comparison(">", a, b, type), .comparison("==", a, b, type)))
                }
            case "+", "-", "*", "/", "%":
                let (a, ta) = try numberValue(leftValue, line: left.line)
                let (b, tb) = try numberValue(rightValue, line: right.line)
                let type = widened(ta, tb)
                guard numericBlock(op, type) != nil else {
                    throw SourceError(line: expression.line,
                                      message: "no block computes '\(op)' on \(type.name)")
                }
                return .number(.binary(op, a, b, type), type)
            default:
                throw SourceError(line: expression.line, message: "unknown operator '\(op)'")
            }
        }
    }
}
