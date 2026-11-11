import Foundation
import WirebenchCore
import WirebenchLibrary

/// A macro the source declared, as the compiled project sees it.
public struct CompiledMacro: Equatable, Sendable {
    public var name: String
    public var caption: String
    public var inputs: [String]
    public var outputs: [String]
}

/// What one source file compiled to.
public struct CompiledSource {
    public var project: PCCProject
    public var entryPoint: String
    /// The main page's pins.
    public var usedInputs: [Int]
    public var writtenOutputs: [Int]
    public var variables: [String]
    /// Every page, the main one first.
    public var pages: [String]
    public var macros: [CompiledMacro]
    public var blockCount: Int
}

/// Compiles PLC Swift — a subset of Embedded Swift — into a Dirigo project.
///
/// The syntax is real Swift (`swift-syntax` builds the tree). Every `struct` is a page; `@macro` makes it a macro page:
/// its `@Input`/`@Output` properties become the `Inputs`/`Outputs` interface, its `scan` the blocks between them, and a
/// `let t = Name(...)` in another page becomes a `Macro` call whose pins mirror that interface. `t.output` reads a call's
/// output. Pages run on the profile's fastest thread; macro pages, as Dirigo stores them, on thread 0.
/// `docs/PLC-Swift.md` has the grammar, the mapping and the limits.
public struct SwiftSourceCompiler {
    public init() {}

    public func compile(_ source: String, projectName: String = "Program") throws -> CompiledSource {
        let program = try SourceParser.parse(source)
        guard let mainPage = program.main else {
            throw SwiftSourceError(line: 1, message: "the file has no page to compile")
        }
        let macros = Dictionary(program.macros.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        try checkRecursion(macros: macros)

        var project = PCCProject(name: mainPage.name.isEmpty ? projectName : mainPage.name, profile: "Sybas Duino-E")
        project.appOptions.cycleDelay = 10
        // Timers are written in milliseconds and the blocks count scans, so the conversion needs the thread's period.
        let thread = ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)?
            .threads.filter { $0.intervalMs > 0 }
            .min { $0.intervalMs < $1.intervalMs }
        let threadId = thread?.id ?? 1
        let interval = max(1, thread?.intervalMs ?? 10)
        let allocator = IDAllocator()

        var modules: [PCCModule] = []
        var connections: [Connection] = []
        var pages: [String] = []

        // The pages: the main one first, then the macros.
        let ordered = [mainPage] + program.units.filter { $0.kind == .page && $0.name != mainPage.name } + program.macros
        var compiledMacros: [CompiledMacro] = []
        for unit in ordered {
            let emitter = Emitter(page: unit.caption,
                                  thread: unit.kind == .macro ? 0 : threadId,
                                  allocator: allocator,
                                  intervalMs: interval,
                                  macros: macros)
            let summary = try emitter.emit(unit)
            modules.append(contentsOf: emitter.modules)
            connections.append(contentsOf: emitter.connections)
            pages.append(unit.caption)
            if unit.kind == .macro {
                compiledMacros.append(CompiledMacro(name: unit.name, caption: unit.caption,
                                                    inputs: summary.inputs, outputs: summary.outputs))
            }
        }

        project.pages = pages.map { ProjectPage(caption: $0) }
        project.modules = modules
        project.inConnections = connections

        return CompiledSource(project: project,
                              entryPoint: mainPage.scan?.name ?? "scan",
                              usedInputs: mainPage.inputs.map(\.index),
                              writtenOutputs: mainPage.outputs.map(\.index),
                              variables: mainPage.variables.map(\.name),
                              pages: pages,
                              macros: compiledMacros,
                              blockCount: modules.count)
    }

    /// A macro that calls itself, directly or through another, would compile to a call block that recurses forever.
    private func checkRecursion(macros: [String: SourceUnit]) throws {
        func called(_ unit: SourceUnit) -> [String] {
            guard let scan = unit.scan else { return [] }
            var names: [String] = []
            func walk(_ statements: [SourceStmt]) {
                for statement in statements {
                    switch statement.kind {
                    case .bind(_, let expr):
                        if case .call(let name, _) = expr.kind, macros[name] != nil { names.append(name) }
                    case .ifThen(_, let thenBody, let elseBody):
                        walk(thenBody)
                        if let elseBody { walk(elseBody) }
                    default:
                        break
                    }
                }
            }
            walk(scan.body)
            return names
        }
        for (name, unit) in macros {
            var seen: Set<String> = []
            var stack = called(unit)
            while let next = stack.popLast() {
                if next == name {
                    throw SwiftSourceError(line: unit.line, message: "macro '\(name)' calls itself")
                }
                if seen.insert(next).inserted, let callee = macros[next] {
                    stack.append(contentsOf: called(callee))
                }
            }
        }
    }

    /// Ids are unique across pages; the per-page emitter handles order and position.
    final class IDAllocator {
        private var next = 1
        func take() -> Int {
            defer { next += 1 }
            return next
        }
    }
}

// MARK: - The Boolean expression tree

/// A Boolean signal as a pure expression. `if` becomes `select`, so a whole scan is one expression per output.
indirect enum BoolExpr: Equatable {
    case constant(Bool)
    case input(Int)
    case variable(String)
    /// A `PulseGen` clock: the period in milliseconds. The emitter converts it to cycles.
    case pulse(Int)
    /// A macro page's own input, by pin position.
    case macroInput(Int)
    /// The output of a macro call site (index) by pin position.
    case macroCall(Int, Int)
    /// The output of a library block call site (index) by pin position.
    case blockOutput(Int, Int)
    case not(BoolExpr)
    case and(BoolExpr, BoolExpr)
    case or(BoolExpr, BoolExpr)
    case xor(BoolExpr, BoolExpr)

    var readsInput: Bool {
        var found = false
        walk { if case .input = $0 { found = true } }
        return found
    }

    func walk(_ visit: (BoolExpr) -> Void) {
        visit(self)
        switch self {
        case .constant, .input, .variable, .pulse, .macroInput, .macroCall, .blockOutput:
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
    case pin(module: Int, outPin: Int)
}

/// What one unit's emitter learned: a macro's pin names, or nothing for a page.
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
    private let allocator: SwiftSourceCompiler.IDAllocator
    private let intervalMs: Int
    private let macros: [String: SourceUnit]
    private var order = 10
    private var placed = 0
    private var digitalInput: Int?
    private var pulseBlocks: [Int: Int] = [:]
    private var variableBlocks: [String: Int] = [:]
    private var macroInputs: Int?
    private var macroOutputs: Int?
    private var callBlocks: [Int: Int] = [:]
    private var blockCalls: [BlockCall] = []
    private var blockCallBlocks: [Int: Int] = [:]
    private var isMacro: Bool { page.hasPrefix("*") }

    private static let columns = 4

    init(page: String, thread: Int, allocator: SwiftSourceCompiler.IDAllocator, intervalMs: Int,
         macros: [String: SourceUnit]) {
        self.page = page
        self.thread = thread
        self.allocator = allocator
        self.intervalMs = intervalMs
        self.macros = macros
    }

    @discardableResult
    func addBlock(_ guid: UUID, at point: (x: Double, y: Double)? = nil) -> Int {
        let id = allocator.take()
        let position = point ?? (x: Double(40 + (placed % Self.columns) * 200),
                                 y: Double(40 + (placed / Self.columns) * 150))
        placed += 1
        let module = BlockFactory.makeModule(guid: guid, id: id,
                                             name: BlockFactory.suggestedName(for: guid, existing: modules),
                                             x: position.x, y: position.y,
                                             order: order, threadId: thread, page: page)
        order += 10
        modules.append(module)
        return id
    }

    /// Adds a module built by hand (`Inputs`/`Outputs`/a macro call), which `BlockFactory` does not make.
    func addModule(_ module: PCCModule) {
        var module = module
        module.id = allocator.take()
        module.order = order
        module.threadId = thread
        module.page = page
        module.x = Double(40 + (placed % Self.columns) * 200)
        module.y = Double(40 + (placed / Self.columns) * 150)
        if module.name.isEmpty {
            module.name = BlockFactory.suggestedName(for: module.guid, existing: modules)
        }
        placed += 1
        order += 10
        modules.append(module)
    }

    func connect(_ consumer: Int, _ pin: Int, _ source: PinSource) {
        switch source {
        case .constant(let value):
            setIn(consumer, pin, .bool(value))
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
        guard let scan = unit.scan else { return UnitSummary() }
        var lowering = Lowering(unit: unit, macros: macros, intervalMs: intervalMs)
        let lowered = try lowering.lower(scan.body)
        blockCalls = lowered.blockCalls

        var summary = UnitSummary()
        if unit.kind == .macro {
            // The interface blocks are the macro's pin list: `Inputs` hands its values out, `Outputs` takes them in.
            summary.inputs = unit.inputs.map(\.name)
            summary.outputs = unit.outputs.map(\.name)
            if !summary.inputs.isEmpty {
                macroInputs = makeInterface(.inputs, names: summary.inputs)
            }
            if !summary.outputs.isEmpty {
                macroOutputs = makeInterface(.outputs, names: summary.outputs)
            }
        }

        // Variables exist before anything reads them: a read is the block's output, the value at the start of the scan.
        // The writes go in last, so everything that reads a variable reads it before the scan updates it.
        for variable in unit.variables {
            let block = addBlock(BoolVarBlock.guid)
            setOut(block, pin: 0, .bool(variable.initial))
            variableBlocks[variable.name] = block
        }

        var sources: [(pin: Int, source: PinSource)] = []
        for (pin, expression) in lowered.outputs.sorted(by: { $0.key < $1.key }) {
            sources.append((pin, try materialise(expression, calls: lowered.calls, unit: unit)))
        }

        if unit.kind == .page && !sources.isEmpty {
            let doBlock = addBlock(EightDOBlock.guid)
            for (pin, source) in sources { connect(doBlock, pin + 1, source) }
        }
        if unit.kind == .macro {
            if let macroOutputs {
                for (pin, source) in sources { connect(macroOutputs, pin, source) }
            } else if !sources.isEmpty {
                throw SwiftSourceError(line: unit.line, message: "macro '\(unit.name)' writes an output it does not declare")
            }
        }

        // Every call site runs, whether or not its outputs are read: the call is the statement.
        for (index, _) in lowered.calls.enumerated() {
            _ = try materialiseCall(index, calls: lowered.calls, unit: unit)
        }
        for index in lowered.blockCalls.indices {
            _ = try materialiseBlockCall(index, calls: lowered.calls, unit: unit)
        }

        for (name, expression) in lowered.variableWrites.sorted(by: { $0.key < $1.key }) {
            guard let variableBlock = variableBlocks[name] else { continue }
            let value = try materialise(expression, calls: lowered.calls, unit: unit)
            let set = addBlock(SetBlock.guid)
            connect(set, 1, value)
            connect(set, 2, .pin(module: variableBlock, outPin: 0))
        }
        return summary
    }

    private func outputName(_ key: Int, unit: SourceUnit) -> String {
        if unit.kind == .macro {
            return unit.outputs.indices.contains(key) ? unit.outputs[key].name : "output \(key)"
        }
        return unit.outputs.first { $0.index == key }?.name ?? "output \(key)"
    }

    // MARK: - Expressions

    func materialise(_ expression: BoolExpr, calls: [CallSite], unit: SourceUnit) throws -> PinSource {
        switch expression {
        case .constant(let value):
            return .constant(value)
        case .input(let pin):
            if digitalInput == nil { digitalInput = addBlock(EightDIBlock.guid) }
            return .pin(module: digitalInput!, outPin: pin)
        case .variable(let name):
            guard let block = variableBlocks[name] else { return .constant(false) }
            return .pin(module: block, outPin: 0)
        case .macroInput(let pin):
            guard let macroInputs else {
                throw SwiftSourceError(line: unit.line, message: "macro '\(unit.name)' reads an input it does not declare")
            }
            return .pin(module: macroInputs, outPin: pin)
        case .macroCall(let call, let pin):
            let block = try materialiseCall(call, calls: calls, unit: unit)
            return .pin(module: block, outPin: pin)
        case .blockOutput(let call, let pin):
            let block = try materialiseBlockCall(call, calls: calls, unit: unit)
            return .pin(module: block, outPin: pin)
        case .pulse(let milliseconds):
            if let existing = pulseBlocks[milliseconds] { return .pin(module: existing, outPin: 1) }
            let block = addBlock(PulseGenBlock.guid)
            let cycles = max(2, Int((Double(milliseconds) / Double(intervalMs)).rounded()))
            setIn(block, 1, .bool(true))
            setParam(block, 0, .int32(Int32(max(1, cycles / 2))))
            setParam(block, 1, .int32(Int32(max(1, cycles / 2))))
            pulseBlocks[milliseconds] = block
            return .pin(module: block, outPin: 1)
        case .not(let operand):
            let value = try materialise(operand, calls: calls, unit: unit)
            let block = addBlock(NotBlock.guid)
            connect(block, 1, value)
            return .pin(module: block, outPin: 0)
        case .and(let a, let b):
            let left = try materialise(a, calls: calls, unit: unit)
            let right = try materialise(b, calls: calls, unit: unit)
            let block = addBlock(AndBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .or(let a, let b):
            let left = try materialise(a, calls: calls, unit: unit)
            let right = try materialise(b, calls: calls, unit: unit)
            let block = addBlock(OrBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .xor(let a, let b):
            let left = try materialise(a, calls: calls, unit: unit)
            let right = try materialise(b, calls: calls, unit: unit)
            let block = addBlock(XorBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        }
    }

    /// Creates (once) the block a `Block.Type(...)` call names, with its input pins and parameters set.
    private func materialiseBlockCall(_ index: Int, calls: [CallSite], unit: SourceUnit) throws -> Int {
        if let existing = blockCallBlocks[index] { return existing }
        let call = blockCalls[index]
        var module = BlockFactory.makeModule(guid: call.guid, id: allocator.take(),
                                             name: BlockFactory.suggestedName(for: call.guid, existing: modules),
                                             x: 0, y: 0, order: 0, threadId: thread, page: page)
        if call.inputs.count > module.inPins.count {
            while module.inPins.count < call.inputs.count {
                module.inPins.append(Pin(id: module.inPins.count, value: .bool(false)))
            }
            if let count = BlockLabels.countedInputCount(for: call.guid, totalPins: call.inputs.count) {
                module.inputCount = count
            }
        }
        addModule(module)
        let block = modules[modules.count - 1].id
        // Registered before its inputs are wired: a feedback loop wires this block's own output back into it, and the
        // lookup has to find it rather than recurse.
        blockCallBlocks[index] = block
        let paramLabels = BlockLabels.paramLabels(for: call.guid)
        for (pin, argument) in call.inputs.enumerated() {
            switch argument {
            case .constant(let value):
                setIn(block, pin, value)
            case .signal(let expression):
                connect(block, pin, try materialise(expression, calls: calls, unit: unit))
            }
        }
        for (label, value) in call.params {
            if let parameter = paramLabels.firstIndex(of: label) { setParam(block, parameter, value) }
        }
        return block
    }

    /// Creates (once) the `Macro` call block of a call site, with its arguments wired to the interface's inputs.
    private func materialiseCall(_ index: Int, calls: [CallSite], unit caller: SourceUnit) throws -> Int {
        if let existing = callBlocks[index] { return existing }
        let call = calls[index]
        let outputs = call.macro.outputs

        // Arguments first, so the call runs after them.
        var wired: [(pin: Int, source: PinSource)] = []
        for (position, input) in call.macro.inputs.enumerated() {
            let argument: CallArgument?
            if let labelled = call.arguments.first(where: { $0.label == input.name }) {
                argument = labelled
            } else if call.arguments.count == call.macro.inputs.count {
                argument = call.arguments[position]
            } else {
                argument = nil
            }
            guard let argument else {
                throw SwiftSourceError(line: call.line,
                                       message: "'\(call.macro.name)' needs a value for '\\(input.name)'")
            }
            let source = try materialise(argument.value, calls: calls, unit: caller)
            wired.append((position, source))
        }
        if call.arguments.count > call.macro.inputs.count {
            throw SwiftSourceError(line: call.line,
                                   message: "'\(call.macro.name)' takes \\(call.macro.inputs.count) argument(s), not \\(call.arguments.count)")
        }

        var module = PCCModule(id: 0, guid: MacroInterface.callGUID,
                               name: BlockFactory.suggestedName(for: MacroInterface.callGUID, existing: modules),
                               x: 0, y: 0, order: 0, threadId: thread, page: page)
        module.rawAttributes["MACRO_NAME"] = call.macro.name
        module.inPins = call.macro.inputs.enumerated().map { index, pin in
            var value = Pin(id: index, value: .bool(false))
            value.name = pin.name
            value.rawAttributes["TYPE"] = "1"
            return value
        }
        module.outPins = outputs.enumerated().map { index, pin in
            var value = Pin(id: index, value: .bool(false), rights: 2)
            value.name = pin.name
            value.rawAttributes["TYPE"] = "1"
            return value
        }
        addModule(module)
        let block = modules[modules.count - 1].id
        for (pin, source) in wired { connect(block, pin, source) }
        callBlocks[index] = block
        return block
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
}

// MARK: - Lowering

/// One argument of a macro call, lowered to an expression in the caller.
struct CallArgument {
    var label: String?
    var value: BoolExpr
}

/// One argument of a library block call.
enum BlockArg {
    case constant(PinValue)
    case signal(BoolExpr)
}

/// One `let b = Block.Type(...)` written in a scan: a block from the catalogue, its inputs in pin order and its
/// parameters by name.
struct BlockCall {
    var guid: UUID
    var name: String
    var inputs: [BlockArg]
    var params: [(label: String, value: PinValue)]
    var line: Int
}

/// One `let t = Macro(...)` written in a scan.
struct CallSite {
    var macro: SourceUnit
    var arguments: [CallArgument]
    var line: Int
}

/// What a scan lowered to: the expression each output is driven with, the value each variable takes, and the calls it
/// makes.
struct LoweredScan {
    var outputs: [Int: BoolExpr] = [:]
    var variableWrites: [String: BoolExpr] = [:]
    var calls: [CallSite] = []
    var blockCalls: [BlockCall] = []
}

/// Lowers one struct's `scan`. A page's outputs are its `@DO` pins, a macro's its `@Output` pins; a macro's inputs are
/// reads of its `Inputs` block.
struct Lowering {
    let unit: SourceUnit
    let macros: [String: SourceUnit]
    let intervalMs: Int
    private var env: [String: BoolExpr] = [:]
    private var macroInstances: [String: Int] = [:]
    private var blockInstances: [String: Int] = [:]
    private var inBranch = false

    init(unit: SourceUnit, macros: [String: SourceUnit], intervalMs: Int) {
        self.unit = unit
        self.macros = macros
        self.intervalMs = intervalMs
    }

    mutating func lower(_ statements: [SourceStmt]) throws -> LoweredScan {
        var scan = LoweredScan()
        try lower(statements, into: &scan)
        return scan
    }

    private func outputIndex(_ name: String) -> Int? {
        if unit.kind == .macro { return unit.outputs.firstIndex { $0.name == name } }
        return unit.outputs.first { $0.name == name }?.index
    }

    private func inputIndex(_ name: String) -> Int? {
        unit.inputs.first { $0.name == name }?.index
    }

    /// The pin *position* of an output in the macro's interface (its index is only the declaration order).
    private func outputPosition(_ name: String) -> Int? {
        unit.outputs.firstIndex { $0.name == name }
    }

    private func inputPosition(_ name: String) -> Int? {
        unit.inputs.firstIndex { $0.name == name }
    }

    mutating func lower(_ statements: [SourceStmt], into scan: inout LoweredScan) throws {
        for statement in statements {
            switch statement.kind {
            case .bind(let name, let expression):
                if case .call(let callName, let arguments) = expression.kind, callName.hasPrefix("Block.") {
                    let index = try addBlockCall(callName, arguments, line: statement.line, scan: &scan)
                    blockInstances[name] = index
                    continue
                }
                if case .call(let macroName, let arguments) = expression.kind, let macro = macros[macroName] {
                    if inBranch {
                        throw SwiftSourceError(line: statement.line,
                                               message: "a macro call cannot be inside 'if' yet; it runs every scan where it is written")
                    }
                    var loweredArguments: [CallArgument] = []
                    for argument in arguments {
                        loweredArguments.append(CallArgument(label: argument.label,
                                                             value: try lower(argument.value, scan: &scan)))
                    }
                    scan.calls.append(CallSite(macro: macro, arguments: loweredArguments, line: statement.line))
                    macroInstances[name] = scan.calls.count - 1
                    continue
                }
                env[name] = try lower(expression, scan: &scan)
            case .assign(let name, let expression):
                let value = try lower(expression, scan: &scan)
                if let index = outputIndex(name) {
                    scan.outputs[index] = value
                } else if unit.variables.contains(where: { $0.name == name }) {
                    scan.variableWrites[name] = value
                } else if inputIndex(name) != nil {
                    throw SwiftSourceError(line: statement.line, message: "'\(name)' is an input; it is read, not written")
                } else if env[name] != nil {
                    throw SwiftSourceError(line: statement.line, message: "'\(name)' is a 'let'; it cannot be assigned")
                } else {
                    throw SwiftSourceError(line: statement.line, message: "unknown name '\(name)'")
                }
            case .blockSet(let instance, let pin, let value):
                guard let call = blockInstances[instance] else {
                    throw SwiftSourceError(line: statement.line,
                                           message: "'\(instance)' is not a block instance; 'set' needs a 'let name = Block...'")
                }
                let argument = try argumentValue(value, scan: &scan)
                while scan.blockCalls[call].inputs.count <= pin {
                    scan.blockCalls[call].inputs.append(.constant(.bool(false)))
                }
                scan.blockCalls[call].inputs[pin] = argument
            case .returnVoid:
                break
            case .ifThen(let condition, let thenBody, let elseBody):
                let test = try lower(condition, scan: &scan)
                let wasInBranch = inBranch
                let savedEnv = env
                inBranch = true
                var thenScan = scan
                try lower(thenBody, into: &thenScan)
                env = savedEnv
                var elseScan = scan
                if let elseBody { try lower(elseBody, into: &elseScan) }
                env = savedEnv
                inBranch = wasInBranch
                for pin in Set(thenScan.outputs.keys).union(elseScan.outputs.keys) {
                    let whenTrue = thenScan.outputs[pin] ?? scan.outputs[pin] ?? .constant(false)
                    let whenFalse = elseScan.outputs[pin] ?? scan.outputs[pin] ?? .constant(false)
                    scan.outputs[pin] = .select(test, whenTrue, whenFalse)
                }
                for name in Set(thenScan.variableWrites.keys).union(elseScan.variableWrites.keys) {
                    let whenTrue = thenScan.variableWrites[name] ?? .variable(name)
                    let whenFalse = elseScan.variableWrites[name] ?? .variable(name)
                    scan.variableWrites[name] = .select(test, whenTrue, whenFalse)
                }
            }
        }
    }

    /// Registers `Block.Type(...)` and returns its call index.
    private mutating func addBlockCall(_ callName: String, _ arguments: [SourceArgument],
                                       line: Int, scan: inout LoweredScan) throws -> Int {
        let typeName = String(callName.dropFirst("Block.".count))
        guard let guid = BlockLabels.guid(forSourceName: typeName) else {
            throw SwiftSourceError(line: line, message: "there is no block type called '\(typeName)'")
        }
        var inputs: [BlockArg] = []
        var params: [(label: String, value: PinValue)] = []
        let paramLabels = BlockLabels.paramLabels(for: guid)
        for argument in arguments {
            if let label = argument.label {
                guard let index = paramLabels.firstIndex(of: label) else {
                    throw SwiftSourceError(line: argument.value.line,
                                           message: "'\(typeName)' has no parameter '\(label)'; it has \(paramLabels.joined(separator: ", "))")
                }
                params.append((paramLabels[index], try constantValue(argument.value)))
            } else {
                switch argument.value.kind {
                case .boolean(let value): inputs.append(.constant(.bool(value)))
                case .integer(let value): inputs.append(.constant(.int32(Int32(value))))
                case .unary("-", let operand):
                    if case .integer(let value) = operand.kind {
                        inputs.append(.constant(.int32(Int32(-value))))
                    } else {
                        inputs.append(.signal(try lower(argument.value, scan: &scan)))
                    }
                default: inputs.append(.signal(try lower(argument.value, scan: &scan)))
                }
            }
        }
        scan.blockCalls.append(BlockCall(guid: guid, name: typeName, inputs: inputs, params: params, line: line))
        return scan.blockCalls.count - 1
    }

    /// One block-call argument: a literal stays a constant, anything else becomes a signal.
    private func argumentValue(_ expression: SourceExpr, scan: inout LoweredScan) throws -> BlockArg {
        switch expression.kind {
        case .boolean(let value): return .constant(.bool(value))
        case .integer(let value): return .constant(.int32(Int32(value)))
        case .unary("-", let operand):
            if case .integer(let value) = operand.kind { return .constant(.int32(Int32(-value))) }
            return .signal(try lower(expression, scan: &scan))
        default: return .signal(try lower(expression, scan: &scan))
        }
    }

    private func constantValue(_ expression: SourceExpr) throws -> PinValue {
        switch expression.kind {
        case .boolean(let value): return .bool(value)
        case .integer(let value): return .int32(Int32(value))
        case .unary("-", let operand):
            guard case .integer(let value) = operand.kind else {
                throw SwiftSourceError(line: expression.line, message: "expected a number")
            }
            return .int32(Int32(-value))
        default:
            throw SwiftSourceError(line: expression.line, message: "a parameter takes a literal value")
        }
    }

    private func lower(_ expression: SourceExpr, scan: inout LoweredScan) throws -> BoolExpr {
        switch expression.kind {
        case .boolean(let value):
            return .constant(value)
        case .integer(let value):
            throw SwiftSourceError(line: expression.line,
                                   message: "the number \(value) is not a signal; numbers are only used for pins and times")
        case .name(let name):
            if let value = env[name] { return value }
            if macroInstances[name] != nil {
                throw SwiftSourceError(line: expression.line, message: "'\(name)' is a macro call; read one of its outputs, as in '\\(name).result'")
            }
            if let index = inputIndex(name) {
                return unit.kind == .macro ? .macroInput(inputPosition(name) ?? 0) : .input(index)
            }
            if unit.variables.contains(where: { $0.name == name }) { return .variable(name) }
            if let index = outputIndex(name) {
                return scan.outputs[index] ?? .constant(false)
            }
            throw SwiftSourceError(line: expression.line, message: "unknown name '\(name)'")
        case .member(let base, let name):
            guard case .name(let instance) = base.kind else {
                throw SwiftSourceError(line: expression.line, message: "only a call's outputs can be read, as in 't.result'")
            }
            if let call = macroInstances[instance] {
                let macro = scan.calls[call].macro
                guard let position = macro.outputs.firstIndex(where: { $0.name == name }) else {
                    throw SwiftSourceError(line: expression.line,
                                           message: "macro '\(macro.name)' has no output '\(name)'; it has \(macro.outputs.map(\.name).joined(separator: ", "))")
                }
                return .macroCall(call, position)
            }
            if let call = blockInstances[instance] {
                let guid = scan.blockCalls[call].guid
                let labels = BlockLabels.outputLabels(for: guid)
                guard let position = labels.firstIndex(of: name) else {
                    throw SwiftSourceError(line: expression.line,
                                           message: "'\(scan.blockCalls[call].name)' has no output '\(name)'; it has \(labels.joined(separator: ", "))")
                }
                return .blockOutput(call, position)
            }
            throw SwiftSourceError(line: expression.line, message: "only a call's outputs can be read, as in 't.result'")
        case .call(let name, let arguments):
            guard name == "pulse", arguments.count == 1, case .integer(let milliseconds) = arguments[0].value.kind else {
                throw SwiftSourceError(line: expression.line,
                                       message: "unknown call '\(name)'; this subset has pulse(ms:)")
            }
            guard milliseconds > 0 else {
                throw SwiftSourceError(line: expression.line, message: "a pulse needs a time in milliseconds above zero")
            }
            guard milliseconds >= intervalMs else {
                throw SwiftSourceError(line: expression.line,
                                       message: "a pulse of \(milliseconds) ms is shorter than the \(intervalMs) ms scan of the profile's fastest thread")
            }
            if unit.kind == .macro {
                throw SwiftSourceError(line: expression.line, message: "a macro cannot start a timer yet")
            }
            return .pulse(milliseconds)
        case .unary(let op, let operand):
            switch op {
            case "!": return .negated(try lower(operand, scan: &scan))
            case "-": throw SwiftSourceError(line: expression.line, message: "negation needs numbers, which are not supported yet")
            default: throw SwiftSourceError(line: expression.line, message: "unknown operator '\(op)'")
            }
        case .binary(let op, let left, let right):
            let a = try lower(left, scan: &scan)
            let b = try lower(right, scan: &scan)
            switch op {
            case "&&": return .conjunction(a, b)
            case "||": return .disjunction(a, b)
            case "==": return .negated(.exclusiveOr(a, b))
            case "!=": return .exclusiveOr(a, b)
            case "<", ">", "<=", ">=", "+", "-", "*", "/", "%":
                throw SwiftSourceError(line: expression.line,
                                       message: "'\(op)' needs numbers, which are not supported yet; this subset is Boolean logic")
            default:
                throw SwiftSourceError(line: expression.line, message: "unknown operator '\(op)'")
            }
        }
    }
}
