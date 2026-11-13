import Foundation
import WirebenchCore
import WirebenchLibrary

/// Turns a project back into Structured Text: what the IDE shows when a `.pcc` is opened that has no source.
///
/// The subset cannot express every block, so this recovers what it can — programs, `AT %IXn`/`AT %QXn` pins, variables,
/// function-block calls, Boolean logic — and lists the rest as a comment at the end of each unit instead of inventing code.
/// Compiling the result back gives the same pages and the same pins for a project the subset can describe; for anything
/// else it is a readable skeleton, not a faithful round trip.
public struct PCCDecompiler {
    public init() {}

    public func source(for input: PCCProject, named name: String? = nil) -> String {
        let project = ConstructContainers.expanded(input)
        let profile = ProfileRegistry.profile(for: project, in: ProfileRegistry.builtIn)
        let interval = max(1, profile?.threads.filter { $0.intervalMs > 0 }
            .min { $0.intervalMs < $1.intervalMs }?.intervalMs ?? 10)

        let captions = project.pages.map(\.caption)
        let normal = captions.filter { !$0.hasPrefix("*") }
        let macroPages = captions.filter { $0.hasPrefix("*") }
        let ordered = normal + macroPages

        var fileNames = NameSet()
        var structNames: [String: String] = [:]
        for caption in macroPages {
            structNames[caption] = fileNames.unique(Identifier.of(MacroInterface.name(ofSheet: caption), fallback: "Macro"))
        }
        for caption in normal {
            structNames[caption] = fileNames.unique(Identifier.of(caption, fallback: "Page"))
        }

        // A macro's pin names are its call's labels, so they are fixed once and used from both sides.
        var interfaces: [String: Interface] = [:]
        for caption in macroPages {
            var names = NameSet()
            let inputs = (project.macroInterface(.inputs, onSheet: caption).map(MacroInterface.pinNames(of:)) ?? [])
                .map { names.unique(Identifier.of($0, fallback: "input")) }
            let outputs = (project.macroInterface(.outputs, onSheet: caption).map(MacroInterface.pinNames(of:)) ?? [])
                .map { names.unique(Identifier.of($0, fallback: "output")) }
            interfaces[caption] = Interface(inputs: inputs, outputs: outputs)
        }
        var macroPageByCallName: [String: String] = [:]
        var macroStructByCallName: [String: String] = [:]
        for caption in macroPages {
            let name = MacroInterface.name(ofSheet: caption)
            macroPageByCallName[name] = caption
            macroStructByCallName[name] = structNames[caption]
        }

        var out: [String] = [
            "(* Recovered from \(name ?? (project.name.isEmpty ? "the project" : project.name)) by Wirebench.",
            "   The subset cannot express every block; what was not recovered is listed at the end of each unit. *)",
            "",
        ]
        // A project can hold only macro sheets (a library of them, with no program of its own). The source needs a
        // PROGRAM to be a program, so one is added; compiling it back adds that page to the project.
        if normal.isEmpty {
            out.append("PROGRAM \(fileNames.unique("Main"))")
            out.append("END_PROGRAM")
            out.append("")
        }
        for (index, caption) in ordered.enumerated() {
            let reader = PageReader(project: project, page: caption, interval: interval,
                                    structName: structNames[caption] ?? "Page",
                                    interfaces: interfaces, macroPageByCallName: macroPageByCallName,
                                    macroStructByCallName: macroStructByCallName)
            out.append(reader.read(isMain: index == 0))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    struct Interface {
        var inputs: [String]
        var outputs: [String]
    }
}

// MARK: - One page

private final class PageReader {
    private let project: PCCProject
    private let page: String
    private let interval: Int
    private let structName: String
    private let interfaces: [String: PCCDecompiler.Interface]
    private let macroPageByCallName: [String: String]
    private let macroStructByCallName: [String: String]
    private let isMacro: Bool

    private let modules: [PCCModule]
    private let wires: [Int: [Int: (module: Int, pin: Int)]]
    /// The first 8xDI / 8xDO on the page: the one the source's `@DI`/`@DO` pins stand for. A page can hold more than
    /// one of either (16 inputs as two blocks), and the extra ones are recovered as library blocks instead.
    private let primaryDI: Int?
    private let primaryDO: Int?
    private var usedOutputs: [Int: Set<Int>] = [:]
    private var names = NameSet()
    private var unsupported: [String] = []
    private var skipped: Set<Int> = []
    private var hasConditionals = false
    /// Conditional groups that are recovered as `if` statements: their `Set` writes become branch assignments.
    private var conditionalGroups: [ConditionalGroup] = []
    private var branchOf: [Int: Branch] = [:]

    private enum Branch { case then, other }

    private struct ConditionalGroup {
        var id: Int
        var thenIds: Set<Int>
        var elseIds: Set<Int>
        var hasElse: Bool
        /// A conditional inside this one cannot be expressed by flattening, so the group is left unrecovered.
        var hadNested: Bool
    }

    /// Combinational blocks only: a conditional is recovered when gating them changes nothing, and its work is done by
    /// `Set` writes (which the language's `if` merges exactly).
    private static let pureGuids: Set<UUID> = {
        var guids: Set<UUID> = []
        for name in ["And", "Or", "Not", "Xor", "Yes"] {
            if let guid = BlockTypeCatalog.info(forBlockName: name)?.guid { guids.insert(guid) }
        }
        let stateful: Set<String> = ["RS", "Mean", "HystComparator"]
        for info in BlockTypeCatalog.all where (info.category.hasPrefix("Math")
            || info.category == "Main\\Comparators" || info.category == "Bool") && !stateful.contains(info.blockName) {
            guids.insert(info.guid)
        }
        return guids
    }()

    private var diNames: [Int: String] = [:]
    private var diChannels: [Int: Int] = [:]
    private var outputNames: [Int: String] = [:]
    private var outputChannels: [Int: Int] = [:]
    private var variableNames: [Int: String] = [:]
    private var callNames: [Int: String] = [:]
    /// The call blocks that made it into the source. A read of a call that was skipped must not become a name.
    private var boundCalls: Set<Int> = []
    private var blockNames: [Int: String] = [:]
    private var boundBlocks: Set<Int> = []

    init(project: PCCProject, page: String, interval: Int, structName: String,
         interfaces: [String: PCCDecompiler.Interface], macroPageByCallName: [String: String],
         macroStructByCallName: [String: String]) {
        self.project = project
        self.page = page
        self.interval = interval
        self.structName = structName
        self.interfaces = interfaces
        self.macroPageByCallName = macroPageByCallName
        self.macroStructByCallName = macroStructByCallName
        self.isMacro = page.hasPrefix("*")
        let pageModules = project.modules.filter { $0.page == page }
        self.modules = pageModules
        let ordered = pageModules.sorted { $0.order < $1.order }
        let macroPage = page.hasPrefix("*")
        self.primaryDI = macroPage ? nil : ordered.first { $0.guid == EightDIBlock.guid }?.id
        self.primaryDO = macroPage ? nil : ordered.first { $0.guid == EightDOBlock.guid }?.id
        var wires: [Int: [Int: (module: Int, pin: Int)]] = [:]
        for connection in project.inConnections {
            wires[connection.inModuleId, default: [:]][connection.inPinId] = (connection.outModuleId, connection.outPinId)
        }
        self.wires = wires
        for connection in project.inConnections {
            usedOutputs[connection.outModuleId, default: []].insert(connection.outPinId)
        }
    }

    private var interface: PCCDecompiler.Interface {
        interfaces[page] ?? PCCDecompiler.Interface(inputs: [], outputs: [])
    }

    func read(isMain: Bool) -> String {
        markConditionals()
        assignNames()

        var inputDeclarations: [String] = []
        var outputDeclarations: [String] = []
        var variableDeclarations: [String] = []

        if isMacro {
            for name in interface.inputs { inputDeclarations.append("    \(name) : BOOL;") }
            for name in interface.outputs { outputDeclarations.append("    \(name) : BOOL;") }
        } else {
            for (pin, name) in diNames.sorted(by: { $0.key < $1.key }) {
                variableDeclarations.append("    \(name) AT %IX\(diChannels[pin] ?? pin) : BOOL;")
            }
            for (pin, name) in outputNames.sorted(by: { $0.key < $1.key }) {
                variableDeclarations.append("    \(name) AT %QX\(outputChannels[pin] ?? pin) : BOOL;")
            }
        }
        for module in modules where module.guid == BoolVarBlock.guid {
            let initial = module.outPins.first?.value.asBool == true
            variableDeclarations.append("    \(variableNames[module.id] ?? "state") : BOOL"
                                        + (initial ? " := TRUE" : "") + ";")
        }

        // Declare every instance first: a block type from the catalogue, or a macro's function block.
        let callModules = orderedModules().filter { $0.guid == MacroInterface.callGUID }
        let blockModules = orderedModules().filter(isLibraryBlock)
        var instanceDeclarations: [String] = []
        for module in blockModules {
            guard let text = blockDeclaration(module) else {
                unsupported.append("\(module.name) (\(BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? "block"))")
                continue
            }
            instanceDeclarations.append(text)
            boundBlocks.insert(module.id)
        }
        for module in callModules {
            let macro = module.rawAttributes["MACRO_NAME"] ?? "Macro"
            guard let type = macroStructByCallName[macro] else {
                unsupported.append("\(module.name) call of \(macro)")
                continue
            }
            instanceDeclarations.append("    \(callNames[module.id] ?? "call") : \(type);")
            boundCalls.insert(module.id)
        }
        variableDeclarations.append(contentsOf: instanceDeclarations)

        // The calls that wire those instances' inputs, and their parameters.
        var calls: [String] = []
        for module in callModules where boundCalls.contains(module.id) {
            if let text = macroCall(module) { calls.append(text) }
        }
        for module in blockModules where boundBlocks.contains(module.id) {
            guard let name = blockNames[module.id] else { continue }
            calls.append(blockCall(module, name: name))
        }

        // A `Set` writes its input into the variable it is wired to; that is an assignment here, and inside a recovered
        // conditional it goes into the branch the `Set` sits in.
        var assignments: [String] = []
        var thenByGroup: [Int: [String]] = [:]
        var elseByGroup: [Int: [String]] = [:]
        for module in orderedModules() where module.guid == SetBlock.guid {
            // A `Set`'s X pin is typed Long in Dirigo, but the variable it writes here is Boolean, so an unwired
            // constant is `true`/`false` and not the number 0.
            guard let value = booleanValue(module: module.id, pin: 1) else {
                unsupported.append("\(module.name) (Set)")
                continue
            }
            for connection in project.inConnections where connection.inModuleId == module.id && connection.inPinId >= 2 {
                guard let variable = variableNames[connection.outModuleId] else { continue }
                let assignment = "        \(variable) := \(value);"
                if let branch = branchOf[module.id],
                   let group = conditionalGroups.first(where: { $0.thenIds.contains(module.id) || $0.elseIds.contains(module.id) }) {
                    if branch == .then {
                        thenByGroup[group.id, default: []].append(assignment)
                    } else {
                        elseByGroup[group.id, default: []].append(assignment)
                    }
                } else {
                    assignments.append(assignment)
                }
            }
        }

        var conditionals: [String] = []
        for group in conditionalGroups {
            guard let condition = expression(module: group.id, pin: 0, depth: 0) else {
                unsupported.append("If\(group.id) condition")
                continue
            }
            var lines = ["    IF \(condition) THEN"]
            for line in thenByGroup[group.id] ?? [] { lines.append(line) }
            if group.hasElse {
                lines.append("    ELSE")
                for line in elseByGroup[group.id] ?? [] { lines.append(line) }
            }
            lines.append("    END_IF;")
            conditionals.append(lines.joined(separator: "\n"))
        }

        if isMacro {
            if let outputsBlock = project.macroInterface(.outputs, onSheet: page) {
                for (index, name) in interface.outputs.enumerated() {
                    guard let value = expression(module: outputsBlock.id, pin: index, depth: 0) else {
                        unsupported.append("\(outputsBlock.name) pin \(name)")
                        continue
                    }
                    assignments.append("    \(name) := \(value);")
                }
            }
        } else {
            for module in modules where module.id == primaryDO {
                for pin in module.inPins.indices.dropFirst()
                where (isDriven(module: module.id, pin: pin) || module.inPins[pin].value.asBool) && pin - 1 <= 7 {
                    let index = pin - 1
                    guard let name = outputNames[index] else {
                        unsupported.append("\(module.name) output \(index)")
                        continue
                    }
                    guard let value = expression(module: module.id, pin: pin, depth: 0) else {
                        unsupported.append("\(module.name) input \(name)")
                        continue
                    }
                    assignments.append("    \(name) := \(value);")
                }
            }
        }

        var text: [String] = []
        text.append("\(isMacro ? "FUNCTION_BLOCK" : "PROGRAM") \(structName)")
        if !inputDeclarations.isEmpty {
            text.append("VAR_INPUT")
            text.append(contentsOf: inputDeclarations)
            text.append("END_VAR")
        }
        if !outputDeclarations.isEmpty {
            text.append("VAR_OUTPUT")
            text.append(contentsOf: outputDeclarations)
            text.append("END_VAR")
        }
        if !variableDeclarations.isEmpty {
            text.append("VAR")
            text.append(contentsOf: variableDeclarations)
            text.append("END_VAR")
        }
        text.append("")
        if !calls.isEmpty {
            text.append(contentsOf: calls)
            text.append("")
        }
        if !conditionals.isEmpty {
            text.append(contentsOf: conditionals)
            text.append("")
        }
        text.append(contentsOf: assignments)
        if hasConditionals {
            text.append("(* Conditional blocks (IF/ELSE/END_IF) are not recovered yet. *)")
        }
        if !unsupported.isEmpty {
            text.append("(* Not recovered: \(unsupported.joined(separator: ", ")) *)")
        }
        text.append("\(isMacro ? "END_FUNCTION_BLOCK" : "END_PROGRAM")")
        return text.joined(separator: "\n")
    }

    /// `name : Type;` — a catalogued block's instance declaration.
    private func blockDeclaration(_ module: PCCModule) -> String? {
        guard let name = blockNames[module.id],
              let rawType = BlockLabels.sourceName(for: module.guid) else { return nil }
        let type = Identifier.type(rawType)
        let params = BlockLabels.paramLabels(for: module.guid)
        let paramTypes = BlockLabels.paramTypes(for: module.guid)
        // A parameter the source cannot name would be lost; leave the block listed instead.
        guard module.paramPins.count <= params.count else { return nil }
        for (index, pin) in module.paramPins.enumerated() {
            let type = paramTypes.indices.contains(index) ? paramTypes[index] : ""
            if literal(pin.value, type: type) == nil { return nil }
        }
        let inputs = BlockLabels.inputTypes(for: module.guid, totalPins: module.inPins.count)
        for pin in module.inPins.indices where wires[module.id]?[pin] == nil {
            let type = inputs.indices.contains(pin) ? inputs[pin] : ""
            if literal(module.inPins[pin].value, type: type) == nil { return nil }
        }
        return "    \(name) : \(type);"
    }

    /// `name(input := value, Parameter := 2);` — the call that wires a catalogued block's pins.
    private func blockCall(_ module: PCCModule, name: String) -> String {
        var arguments: [String] = []
        let labels = BlockLabels.inputLabels(for: module.guid, totalPins: module.inPins.count)
        for pin in module.inPins.indices {
            guard let value = expression(module: module.id, pin: pin, depth: 0) else {
                unsupported.append("\(module.name) input \(pin)")
                continue
            }
            arguments.append("\(labels[pin]) := \(value)")
        }
        let params = BlockLabels.paramLabels(for: module.guid)
        let paramTypes = BlockLabels.paramTypes(for: module.guid)
        for (index, pin) in module.paramPins.enumerated() {
            guard index < params.count else {
                unsupported.append("\(module.name) parameter pin \(index)")
                continue
            }
            let type = paramTypes.indices.contains(index) ? paramTypes[index] : ""
            guard let text = literal(pin.value, type: type) else {
                unsupported.append("\(module.name) parameter \(params[index])")
                continue
            }
            arguments.append("\(params[index]) := \(text)")
        }
        return "    \(name)(\(arguments.joined(separator: ", ")));"
    }

    /// `name(input := value);` — the call that wires a function-block instance's inputs. Unwired inputs keep their
    /// defaults and stay out of the call.
    private func macroCall(_ module: PCCModule) -> String? {
        let macro = module.rawAttributes["MACRO_NAME"] ?? "Macro"
        guard let macroPage = macroPageByCallName[macro], let interface = interfaces[macroPage] else { return nil }
        var arguments: [String] = []
        for (index, pin) in interface.inputs.enumerated() where wires[module.id]?[index] != nil {
            guard let value = booleanValue(module: module.id, pin: index) else { return nil }
            arguments.append("\(pin) := \(value)")
        }
        let name = callNames[module.id] ?? "call"
        return "    \(name)(\(arguments.joined(separator: ", ")));"
    }

    /// A `let name = Macro(...)` statement, or nil when an argument cannot be expressed yet.
    private func callStatement(_ module: PCCModule) -> String? {
        let macro = module.rawAttributes["MACRO_NAME"] ?? "Macro"
        guard let macroPage = macroPageByCallName[macro], let interface = interfaces[macroPage] else { return nil }
        var arguments: [String] = []
        for (index, pin) in interface.inputs.enumerated() {
            // A macro's inputs are Boolean in this subset, whatever the call block's own pin types say.
            guard let value = booleanValue(module: module.id, pin: index) else { return nil }
            arguments.append("\(pin): \(value)")
        }
        let called = macroStructByCallName[macro] ?? Identifier.of(macro, fallback: "Macro")
        return "        let \(callNames[module.id] ?? "call") = \(called)(\(arguments.joined(separator: ", ")))"
    }
    private func isLibraryBlock(_ module: PCCModule) -> Bool {
        switch module.guid {
        case EightDIBlock.guid:
            return module.id != primaryDI
        case EightDOBlock.guid:
            return module.id != primaryDO
        case BoolVarBlock.guid, SetBlock.guid, MacroInterface.callGUID, MacroInterface.interfaceGUID:
            return false
        default:
            let kind = BlockTypeCatalog.info(forGuid: module.guid)?.delphiClass
            return kind != "TMIfModule" && kind != "TMElseModule" && kind != "TMEndIfModule"
        }
    }

    /// The block's creation, with its parameters: its inputs are wired later by `set`.
    private func blockStatement(_ module: PCCModule) -> String? {
        guard let name = blockNames[module.id],
              let rawType = BlockLabels.sourceName(for: module.guid) else { return nil }
        let type = Identifier.type(rawType)
        var arguments: [String] = []
        let params = BlockLabels.paramLabels(for: module.guid)
        let paramTypes = BlockLabels.paramTypes(for: module.guid)
        for (index, pin) in module.paramPins.enumerated() where index < params.count {
            // A fractional float parameter has no source spelling yet; leaving it out would silently change it.
            let type = paramTypes.indices.contains(index) ? paramTypes[index] : ""
            guard let text = literal(pin.value, type: type) else { return nil }
            arguments.append("\(params[index]): \(text)")
        }
        return "        let \(name) = Block.\(type)(\(arguments.joined(separator: ", ")))"
    }

    /// A pin's value as source, by the pin's type. `nil` when the value has no source spelling (a fractional float).
    private func literal(_ value: PinValue, type: String) -> String? {
        if BlockLabels.isBooleanType(type) { return value.asBool ? "true" : "false" }
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .int16(let number): return "\(number)"
        case .int32(let number): return "\(number)"
        case .int64(let number): return "\(number)"
        case .float(let number): return number == number.rounded() ? "\(Int(number))" : nil
        case .undefined: return "false"
        }
    }

    /// The hardware channels an 8xDI/8xDO exposes, in pin order. A masked or counted block selects channels by
    /// attribute (`PIN_MASK`, `PIN_COUNT`, `HIDDEN_PIN_MASK`), so its pin 0 is not necessarily channel 0.
    private func ioChannels(_ module: PCCModule) -> [Int] {
        switch module.guid {
        case EightDIBlock.guid:
            let mask = integerAttribute(module.rawAttributes["PIN_MASK"]) ?? 0xFF
            return (0..<16).filter { mask & (1 << $0) != 0 }
        case EightDOBlock.guid:
            let count = Int(module.rawAttributes["PIN_COUNT"] ?? "") ?? 8
            let hidden = integerAttribute(module.rawAttributes["HIDDEN_PIN_MASK"]) ?? 0
            return (0..<max(0, count)).filter { hidden & (1 << $0) == 0 }
        default:
            return []
        }
    }

    private func integerAttribute(_ raw: String?) -> Int? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("$") { return Int(text.dropFirst(), radix: 16) }
        if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        return Int(text)
    }

    private func assignNames() {
        if !isMacro {
            for module in modules where module.id == primaryDI {
                let channels = ioChannels(module)
                for pin in module.outPins.indices where usedOutputs[module.id]?.contains(pin) == true {
                    guard channels.indices.contains(pin), (0...7).contains(channels[pin]) else {
                        unsupported.append("\(module.name) out pin \(pin) (only channels 0–7 are expressible)")
                        continue
                    }
                    diNames[pin] = names.unique("di\(channels[pin])")
                    diChannels[pin] = channels[pin]
                }
            }
            for module in modules where module.id == primaryDO {
                let channels = ioChannels(module)
                for pin in module.inPins.indices.dropFirst()
                where (isDriven(module: module.id, pin: pin) || module.inPins[pin].value.asBool) && pin - 1 <= 15 {
                    let position = pin - 1
                    guard channels.indices.contains(position), (0...7).contains(channels[position]) else {
                        unsupported.append("\(module.name) input \(position) (only channels 0–7 are expressible)")
                        continue
                    }
                    outputNames[position] = names.unique("do\(channels[position])")
                    outputChannels[position] = channels[position]
                }
            }
        }
        for module in modules where module.guid == BoolVarBlock.guid {
            variableNames[module.id] = names.unique(Identifier.of(module.name, fallback: "state\(module.id)"))
        }
        for module in modules where module.guid == MacroInterface.callGUID {
            callNames[module.id] = names.unique(Identifier.of(module.name, fallback: "call\(module.id)"))
        }
        for module in modules where isLibraryBlock(module) {
            blockNames[module.id] = names.unique(Identifier.of(module.name, fallback: "block\(module.id)"))
        }
    }

    // MARK: Expressions

    /// The value of a consumer's input pin, with the pin's inversion applied.
    private func expression(module: Int, pin: Int, depth: Int) -> String? {
        guard let value = expressionValue(module: module, pin: pin, depth: depth) else { return nil }
        guard let consumer = modules.first(where: { $0.id == module }),
              consumer.inPins.indices.contains(pin), consumer.inPins[pin].inverted else { return value }
        return "NOT (\(value))"
    }

    private func expressionValue(module: Int, pin: Int, depth: Int) -> String? {
        guard depth < 24 else { return nil }
        guard let source = wires[module]?[pin] else {
            guard let producer = modules.first(where: { $0.id == module }),
                  producer.inPins.indices.contains(pin) else { return nil }
            // An unwired pin is a constant, and its type is the pin's: a numeric 0 on a Boolean pin is `false`,
            // not the number zero.
            let types = BlockLabels.inputTypes(for: producer.guid, totalPins: producer.inPins.count)
            let type = types.indices.contains(pin) ? types[pin] : ""
            return literal(producer.inPins[pin].value, type: type)
        }
        guard let producer = modules.first(where: { $0.id == source.module }) else { return nil }
        if skipped.contains(producer.id) { return nil }

        switch producer.guid {
        case EightDIBlock.guid:
            if producer.id == primaryDI { return diNames[source.pin] }
            return blockOutput(producer, source.pin)
        case BoolVarBlock.guid:
            return variableNames[producer.id]
        case MacroInterface.interfaceGUID:
            // A macro reads its own inputs from the `Inputs` block; its output pins are the @Input properties.
            guard MacroInterface.kind(of: producer) == .inputs else { return nil }
            return interface.inputs.indices.contains(source.pin) ? interface.inputs[source.pin] : nil
        case MacroInterface.callGUID:
            guard boundCalls.contains(producer.id), let call = callNames[producer.id] else { return nil }
            let macro = producer.rawAttributes["MACRO_NAME"] ?? ""
            let macroPage = macroPageByCallName[macro]
            let outputs = macroPage.flatMap { interfaces[$0]?.outputs } ?? []
            guard outputs.indices.contains(source.pin) else { return nil }
            return "\(call).\(outputs[source.pin])"
        case NotBlock.guid:
            guard let value = expression(module: producer.id, pin: 1, depth: depth + 1) else { return nil }
            return "NOT \(parenthesise(value))"
        case AndBlock.guid:
            return binary(producer, "AND", depth)
        case OrBlock.guid:
            return binary(producer, "OR", depth)
        case XorBlock.guid:
            return binary(producer, "XOR", depth)
        default:
            return blockOutput(producer, source.pin)
        }
    }

    /// A pin as a Boolean expression: an unwired constant becomes `true`/`false` even where Dirigo types the pin
    /// numerically, which is what a `Set` writing a BoolVar needs.
    private func booleanValue(module: Int, pin: Int) -> String? {
        if wires[module]?[pin] == nil,
           let producer = modules.first(where: { $0.id == module }),
           producer.inPins.indices.contains(pin) {
            return producer.inPins[pin].value.asBool ? "true" : "false"
        }
        return expression(module: module, pin: pin, depth: 0)
    }

    /// A library block's output pin as a source expression, once the block has been emitted.
    private func blockOutput(_ producer: PCCModule, _ pin: Int) -> String? {
        guard boundBlocks.contains(producer.id), let name = blockNames[producer.id] else { return nil }
        let labels = BlockLabels.outputLabels(for: producer.guid)
        guard labels.indices.contains(pin) else { return nil }
        return "\(name).\(labels[pin])"
    }

    private func binary(_ module: PCCModule, _ op: String, _ depth: Int) -> String? {
        guard let left = expression(module: module.id, pin: 1, depth: depth + 1),
              let right = expression(module: module.id, pin: 2, depth: depth + 1) else { return nil }
        return "\(parenthesise(left)) \(op) \(parenthesise(right))"
    }

    private func parenthesise(_ text: String) -> String {
        text.contains(" ") ? "(\(text))" : text
    }

    private func isDriven(module: Int, pin: Int) -> Bool {
        wires[module]?[pin] != nil
    }

    private func orderedModules() -> [PCCModule] {
        modules.filter { !skipped.contains($0.id) }.sorted { $0.order < $1.order }
    }

    // MARK: Conditionals

    /// Reads the `If`/`Else`/`EndIf` ranges.
    ///
    /// A range is recovered as a source `if` only when that cannot change the circuit: the blocks inside are
    /// combinational (gating them changes nothing) and the writes are `Set` writes to variables, which the language
    /// merges exactly as Dirigo's gate does. Anything else — a counter, a timer, an 8xDO, a macro call — keeps its
    /// range skipped and is listed as not recovered.
    private func markConditionals() {
        var open: (id: Int, then: Set<Int>, other: Set<Int>, inElse: Bool, nested: Int, hadNested: Bool)?
        var groups: [ConditionalGroup] = []
        var skippedIds: Set<Int> = []

        for module in modules.sorted(by: { $0.order < $1.order }) {
            let kind = BlockTypeCatalog.info(forGuid: module.guid)?.delphiClass
            switch kind {
            case "TMIfModule":
                if var current = open {
                    current.nested += 1
                    current.hadNested = true
                    current.then.insert(module.id)
                    open = current
                } else {
                    open = (module.id, [module.id], [], false, 0, false)
                }
            case "TMElseModule":
                guard var current = open else { continue }
                if current.nested > 0 { current.other.insert(module.id) } else { current.inElse = true }
                open = current
            case "TMEndIfModule":
                guard var current = open else { continue }
                if current.nested > 0 {
                    current.nested -= 1
                    current.other.insert(module.id)
                    open = current
                } else {
                    current.other.insert(module.id)
                    groups.append(ConditionalGroup(id: current.id, thenIds: current.then,
                                                   elseIds: current.other, hasElse: current.inElse,
                                                   hadNested: current.hadNested))
                    open = nil
                }
            default:
                guard var current = open else { continue }
                if current.inElse { current.other.insert(module.id) } else { current.then.insert(module.id) }
                open = current
            }
        }
        if let current = open {
            hasConditionals = true
            skippedIds.formUnion(current.then)
            skippedIds.formUnion(current.other)
        }

        for group in groups {
            let inside = group.thenIds.union(group.elseIds)
            let sets = modules.filter { inside.contains($0.id) && $0.guid == SetBlock.guid }
            let recoverable = !group.hadNested && !sets.isEmpty
                && modules.filter { inside.contains($0.id) }.allSatisfy {
                    Self.pureGuids.contains($0.guid) || $0.guid == SetBlock.guid
                        || BlockTypeCatalog.info(forGuid: $0.guid)?.delphiClass == "TMElseModule"
                        || BlockTypeCatalog.info(forGuid: $0.guid)?.delphiClass == "TMEndIfModule"
                        || BlockTypeCatalog.info(forGuid: $0.guid)?.delphiClass == "TMIfModule"
                }
            guard recoverable else {
                hasConditionals = true
                skippedIds.formUnion(inside)
                continue
            }
            conditionalGroups.append(group)
            for set in sets {
                branchOf[set.id] = group.elseIds.contains(set.id) ? .other : .then
            }
        }
        skipped = skippedIds
    }
}

// MARK: - Names

/// Makes valid, unique Swift identifiers out of block and pin names.
private struct NameSet {
    private var used: Set<String> = []

    /// ST is case-insensitive, so `On` and `on` are the same name.
    mutating func unique(_ name: String) -> String {
        var candidate = name
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(name)\(suffix)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}

private enum Identifier {
    /// A name that is a keyword cannot be a variable.
    static let keywords: Set<String> = [
        "PROGRAM", "END_PROGRAM", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK",
        "VAR", "END_VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_GLOBAL", "CONSTANT", "RETAIN",
        "IF", "THEN", "ELSIF", "ELSE", "END_IF",
        "AND", "OR", "XOR", "NOT", "MOD", "AT", "TRUE", "FALSE",
        "BOOL", "INT", "REAL", "LREAL", "WORD",
    ]

    /// Unit and variable names avoid keywords *and* the catalogued type names: a function block named `IAdd` would
    /// shadow the block type in its own calls.
    static var reserved: Set<String> {
        var words = keywords
        for name in BlockLabels.sourceNames.keys { words.insert(name.uppercased()) }
        return words
    }

    /// A unit or variable name.
    static func of(_ raw: String, fallback: String) -> String {
        escaped(sanitise(raw, fallback: fallback), against: reserved)
    }

    /// A catalogued type name: already a valid identifier, escaped only when it is a keyword (`Not` -> `Not_`).
    static func type(_ raw: String) -> String {
        escaped(sanitise(raw, fallback: "Block"), against: keywords)
    }

    private static func sanitise(_ raw: String, fallback: String) -> String {
        var name = raw.map { $0.isLetter || $0.isNumber || $0 == "_" ? String($0) : "_" }.joined()
        while let first = name.first, first.isNumber { name = "_" + name }
        if name.isEmpty || name == "_" { name = fallback }
        return name
    }

    private static func escaped(_ name: String, against words: Set<String>) -> String {
        words.contains(name.uppercased()) ? name + "_" : name
    }
}
