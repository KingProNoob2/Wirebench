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
                                  macros: macrosByName)
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
    case not(BoolExpr)
    case and(BoolExpr, BoolExpr)
    case or(BoolExpr, BoolExpr)
    case xor(BoolExpr, BoolExpr)

    func walk(_ visit: (BoolExpr) -> Void) {
        visit(self)
        switch self {
        case .constant, .input, .variable, .macroInput, .macroCall, .blockOutput:
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
    private var order = 10
    private var placed = 0
    private var digitalInput: Int?
    private var variableBlocks: [String: Int] = [:]
    private var macroInputs: Int?
    private var macroOutputs: Int?
    private var calls: [CallSite] = []
    private var blockCalls: [BlockCall] = []
    private var callBlocks: [Int: Int] = [:]
    private var blockCallBlocks: [Int: Int] = [:]
    private var isMacro: Bool { page.hasPrefix("*") }

    private static let columns = 4

    init(page: String, thread: Int, allocator: SourceCompiler.IDAllocator, intervalMs: Int,
         macros: [String: SourceUnit]) {
        self.page = page
        self.thread = thread
        self.allocator = allocator
        self.intervalMs = intervalMs
        self.macros = macros
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
        var lowering = Lowering(unit: unit, macros: macros, intervalMs: intervalMs)
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

        // Variables exist before anything reads them: a read is the block's output, the value at the start of the scan.
        // The writes go in last, so everything that reads a variable reads it before the scan updates it.
        for variable in unit.variables {
            let block = addBlock(BoolVarBlock.guid)
            setOut(block, pin: 0, .bool(variable.initial))
            variableBlocks[variable.name.lowercased()] = block
        }

        var sources: [(pin: Int, source: PinSource)] = []
        for (pin, expression) in lowered.outputs.sorted(by: { $0.key < $1.key }) {
            sources.append((pin, try materialise(expression)))
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

    func materialise(_ expression: BoolExpr) throws -> PinSource {
        switch expression {
        case .constant(let value):
            return .constant(value)
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
            let value = try materialise(operand)
            let block = addBlock(NotBlock.guid)
            connect(block, 1, value)
            return .pin(module: block, outPin: 0)
        case .and(let a, let b):
            let left = try materialise(a), right = try materialise(b)
            let block = addBlock(AndBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .or(let a, let b):
            let left = try materialise(a), right = try materialise(b)
            let block = addBlock(OrBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
            return .pin(module: block, outPin: 0)
        case .xor(let a, let b):
            let left = try materialise(a), right = try materialise(b)
            let block = addBlock(XorBlock.guid)
            connect(block, 1, left)
            connect(block, 2, right)
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
            case .signal(let expression): connect(block, pin, try materialise(expression))
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
            connect(block, position, try materialise(argument))
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
struct LoweredScan {
    var outputs: [Int: BoolExpr] = [:]
    var variableWrites: [String: BoolExpr] = [:]
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
    private var instances: [String: Instance] = [:]
    private var inBranch = false

    private enum Instance {
        case macro(index: Int, block: SourceUnit)
        case block(index: Int)
    }

    init(unit: SourceUnit, macros: [String: SourceUnit], intervalMs: Int) {
        self.unit = unit
        self.macros = macros
        self.intervalMs = intervalMs
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
    private func instance(_ name: String) -> Instance? { instances[name.lowercased()] }

    private mutating func lower(_ statements: [SourceStmt], into scan: inout LoweredScan) throws {
        for statement in statements {
            switch statement.kind {
            case .assign(let name, let expression):
                let value = try lower(expression, scan: &scan)
                if let index = outputIndex(name) {
                    scan.outputs[index] = value
                } else if let variable = variableName(name) {
                    scan.variableWrites[variable.lowercased()] = value
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
                        guard let position = block.inputs.firstIndex(where: {
                            $0.name.lowercased() == argument.label.lowercased()
                        }) else {
                            throw SourceError(line: argument.value.line,
                                              message: "'\(block.name)' has no input '\(argument.label)'; it has "
                                                  + block.inputs.map(\.name).joined(separator: ", "))
                        }
                        _ = position
                        scan.calls[index].arguments[argument.label.lowercased()] = try lower(argument.value, scan: &scan)
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
            case .ifThen(let condition, let thenBody, let elseBody):
                let test = try lower(condition, scan: &scan)
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

    private func integerValue(_ value: Int) -> PinValue {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(Int64(value))
    }

    private func blockArgument(_ expression: SourceExpr, scan: inout LoweredScan) throws -> BlockArg {
        switch expression.kind {
        case .boolean(let value): return .constant(.bool(value))
        case .integer(let value): return .constant(integerValue(value))
        case .unary("-", let operand):
            if case .integer(let value) = operand.kind { return .constant(integerValue(-value)) }
            return .signal(try lower(expression, scan: &scan))
        default: return .signal(try lower(expression, scan: &scan))
        }
    }

    private func constantValue(_ expression: SourceExpr) throws -> PinValue {
        switch expression.kind {
        case .boolean(let value): return .bool(value)
        case .integer(let value): return integerValue(value)
        case .unary("-", let operand):
            guard case .integer(let value) = operand.kind else {
                throw SourceError(line: expression.line, message: "expected a number")
            }
            return integerValue(-value)
        default:
            throw SourceError(line: expression.line, message: "a parameter takes a literal value")
        }
    }

    private func lower(_ expression: SourceExpr, scan: inout LoweredScan) throws -> BoolExpr {
        switch expression.kind {
        case .boolean(let value):
            return .constant(value)
        case .integer(let value):
            throw SourceError(line: expression.line,
                              message: "the number \(value) is not a signal; an expression here is Boolean")
        case .name(let name):
            if let pin = inputPin(name) {
                return unit.kind == .functionBlock ? .macroInput(inputPosition(name) ?? 0) : .input(pin.index)
            }
            if let variable = variableName(name) { return .variable(variable) }
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
                return .macroCall(index, position)
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
                return .blockOutput(index, position)
            case nil:
                throw SourceError(line: expression.line, message: "unknown instance '\(instanceName)'")
            }
        case .unary(let op, let operand):
            switch op {
            case "!": return .negated(try lower(operand, scan: &scan))
            case "-": throw SourceError(line: expression.line, message: "negation needs numbers, which are not supported yet")
            default: throw SourceError(line: expression.line, message: "unknown operator '\(op)'")
            }
        case .binary(let op, let left, let right):
            let a = try lower(left, scan: &scan)
            let b = try lower(right, scan: &scan)
            switch op {
            case "&&": return .conjunction(a, b)
            case "||": return .disjunction(a, b)
            case "xor": return .exclusiveOr(a, b)
            case "==": return .negated(.exclusiveOr(a, b))
            case "!=": return .exclusiveOr(a, b)
            default:
                throw SourceError(line: expression.line,
                                  message: "'\(op)' needs numbers, which are not supported yet; this subset is Boolean")
            }
        }
    }
}
