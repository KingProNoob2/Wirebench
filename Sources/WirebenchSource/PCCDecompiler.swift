import Foundation
import WirebenchCore
import WirebenchLibrary

/// Turns a project back into PLC Swift: what the IDE shows when a `.pcc` is opened that has no source.
///
/// The subset cannot express every block, so this recovers what it can — pages, `@DI`/`@DO` pins, variables, macro
/// calls, Boolean logic, `pulse` — and lists the rest as a comment at the end of each page instead of inventing code.
/// Compiling the result back gives the same pages and the same pins for a project the subset can describe; for anything
/// else it is a readable skeleton, not a faithful round trip.
public struct PCCDecompiler {
    public init() {}

    public func source(for project: PCCProject, named name: String? = nil) -> String {
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
            "// Recovered from \(name ?? (project.name.isEmpty ? "the project" : project.name)) by Wirebench.",
            "// The subset cannot express every block; what was not recovered is listed at the end of each page.",
            "",
            "import PLC",
            "",
        ]
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
    }

    /// Combinational blocks only: a conditional is recovered when gating them changes nothing, and its work is done by
    /// `Set` writes (which the language's `if` merges exactly).
    private static let pureGuids: Set<UUID> = {
        var guids: Set<UUID> = []
        for name in ["And", "Or", "Not", "Xor", "Yes"] {
            if let guid = BlockTypeCatalog.info(forBlockName: name)?.guid { guids.insert(guid) }
        }
        for info in BlockTypeCatalog.all where info.category.hasPrefix("Math")
            || info.category == "Main\\Comparators" || info.category == "Bool" {
            guids.insert(info.guid)
        }
        return guids
    }()

    private var diNames: [Int: String] = [:]
    private var outputNames: [Int: String] = [:]
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
        self.modules = project.modules.filter { $0.page == page }
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

        var declarations: [String] = []
        if isMacro {
            for (index, name) in interface.inputs.enumerated() {
                declarations.append("    @Input(\(index)) var \(name): Bool")
            }
            for (index, name) in interface.outputs.enumerated() {
                declarations.append("    @Output(\(index)) var \(name): Bool")
            }
        } else {
            for (pin, name) in diNames.sorted(by: { $0.key < $1.key }) {
                declarations.append("    @DI(\(pin)) var \(name): Bool")
            }
            for (pin, name) in outputNames.sorted(by: { $0.key < $1.key }) {
                declarations.append("    @DO(\(pin)) var \(name): Bool")
            }
        }
        for module in modules where module.guid == BoolVarBlock.guid {
            declarations.append("    var \(variableNames[module.id] ?? "state"): Bool = \(module.outPins.first?.value.asBool == true)")
        }

        // Blocks are created first, with their parameters only: their inputs are wired afterwards with `set`, which is
        // what lets a feedback loop — a counter whose output reaches its own input — be written down at all.
        var lets: [String] = []
        let callModules = orderedModules().filter { $0.guid == MacroInterface.callGUID }
        let blockModules = orderedModules().filter(isLibraryBlock)
        for module in blockModules {
            guard let text = blockStatement(module) else {
                unsupported.append("\(module.name) (\(BlockTypeCatalog.info(forGuid: module.guid)?.blockName ?? "block"))")
                continue
            }
            lets.append(text)
            boundBlocks.insert(module.id)
        }
        var pendingCalls = Set(callModules.map(\.id))
        var progress = true
        while progress {
            progress = false
            for module in callModules where pendingCalls.contains(module.id) {
                guard let text = callStatement(module) else { continue }
                lets.append(text)
                boundCalls.insert(module.id)
                pendingCalls.remove(module.id)
                progress = true
            }
        }
        for module in callModules where pendingCalls.contains(module.id) {
            unsupported.append("\(module.name) call of \(module.rawAttributes["MACRO_NAME"] ?? "macro")")
        }

        var sets: [String] = []
        for module in blockModules where boundBlocks.contains(module.id) {
            guard let name = blockNames[module.id] else { continue }
            for pin in module.inPins.indices where wires[module.id]?[pin] != nil {
                guard let value = expression(module: module.id, pin: pin, depth: 0) else {
                    unsupported.append("\(module.name) input \(pin)")
                    continue
                }
                sets.append("        \(name).set(\(pin), \(value))")
            }
        }

        var assignments: [String] = []
        var thenByGroup: [Int: [String]] = [:]
        var elseByGroup: [Int: [String]] = [:]

        // A `Set` writes its input into the variable it is wired to; that is an assignment here, and inside a recovered
        // conditional it goes into the branch the `Set` sits in.
        for module in orderedModules() where module.guid == SetBlock.guid {
            guard let value = expression(module: module.id, pin: 1, depth: 0) else {
                unsupported.append("\(module.name) (Set)")
                continue
            }
            for connection in project.inConnections where connection.inModuleId == module.id && connection.inPinId >= 2 {
                guard let variable = variableNames[connection.outModuleId] else { continue }
                let assignment = "        \(variable) = \(value)"
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
            var lines = ["        if \(condition) {"]
            for line in thenByGroup[group.id] ?? [] { lines.append("    " + line) }
            if group.hasElse {
                lines.append("        } else {")
                for line in elseByGroup[group.id] ?? [] { lines.append("    " + line) }
            }
            lines.append("        }")
            conditionals.append(lines.joined(separator: "\n"))
        }

        if isMacro {
            if let outputsBlock = project.macroInterface(.outputs, onSheet: page) {
                for (index, name) in interface.outputs.enumerated() {
                    guard let value = expression(module: outputsBlock.id, pin: index, depth: 0) else {
                        unsupported.append("\(outputsBlock.name) pin \(name)")
                        continue
                    }
                    assignments.append("        \(name) = \(value)")
                }
            }
        } else {
            for module in modules where module.guid == EightDOBlock.guid {
                for pin in module.inPins.indices.dropFirst()
                where (isDriven(module: module.id, pin: pin) || module.inPins[pin].value.asBool) && pin - 1 <= 7 {
                    let index = pin - 1
                    guard let name = outputNames[index] else { continue }
                    guard let value = expression(module: module.id, pin: pin, depth: 0) else {
                        unsupported.append("\(module.name) input \(name)")
                        continue
                    }
                    assignments.append("        \(name) = \(value)")
                }
            }
        }

        var text: [String] = []
        if isMacro { text.append("@macro") } else if isMain { text.append("@main") }
        text.append("struct \(structName) {")
        text.append(contentsOf: declarations)
        text.append("")
        text.append("    func scan() {")
        var body = lets
        if !sets.isEmpty {
            if !body.isEmpty { body.append("") }
            body.append(contentsOf: sets)
        }
        if !conditionals.isEmpty {
            if !body.isEmpty { body.append("") }
            body.append(contentsOf: conditionals)
        }
        text.append(contentsOf: body)
        if !body.isEmpty && !assignments.isEmpty { text.append("") }
        text.append(contentsOf: assignments)
        text.append("    }")
        if hasConditionals {
            text.append("    // Conditional blocks (If / Else / EndIf) are not recovered yet.")
        }
        if !unsupported.isEmpty {
            text.append("    // Not recovered: \(unsupported.joined(separator: ", "))")
        }
        text.append("}")
        return text.joined(separator: "\n")
    }

    /// A `let name = Macro(...)` statement, or nil when an argument cannot be expressed yet.
    private func callStatement(_ module: PCCModule) -> String? {
        let macro = module.rawAttributes["MACRO_NAME"] ?? "Macro"
        guard let macroPage = macroPageByCallName[macro], let interface = interfaces[macroPage] else { return nil }
        var arguments: [String] = []
        for (index, pin) in interface.inputs.enumerated() {
            guard let value = expression(module: module.id, pin: index, depth: 0) else { return nil }
            arguments.append("\(pin): \(value)")
        }
        let called = macroStructByCallName[macro] ?? Identifier.of(macro, fallback: "Macro")
        return "        let \(callNames[module.id] ?? "call") = \(called)(\(arguments.joined(separator: ", ")))"
    }
    private func isLibraryBlock(_ module: PCCModule) -> Bool {
        switch module.guid {
        case EightDIBlock.guid, EightDOBlock.guid, BoolVarBlock.guid, SetBlock.guid,
             MacroInterface.callGUID, MacroInterface.interfaceGUID:
            return false
        default:
            let kind = BlockTypeCatalog.info(forGuid: module.guid)?.delphiClass
            return kind != "TMIfModule" && kind != "TMElseModule" && kind != "TMEndIfModule"
        }
    }

    /// The block's creation, with its parameters: its inputs are wired later by `set`.
    private func blockStatement(_ module: PCCModule) -> String? {
        guard let name = blockNames[module.id],
              let type = BlockLabels.sourceName(for: module.guid) else { return nil }
        var arguments: [String] = []
        let params = BlockLabels.paramLabels(for: module.guid)
        for (index, pin) in module.paramPins.enumerated() where index < params.count {
            arguments.append("\(params[index]): \(literal(pin.value))")
        }
        return "        let \(name) = Block.\(type)(\(arguments.joined(separator: ", ")))"
    }

    private func literal(_ value: PinValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .int16(let number): return "\(number)"
        case .int32(let number): return "\(number)"
        case .int64(let number): return "\(number)"
        case .float(let number): return "\(Int(number))"
        case .undefined: return "false"
        }
    }

    private func assignNames() {
        if !isMacro {
            for module in modules where module.guid == EightDIBlock.guid {
                for pin in module.outPins.indices where usedOutputs[module.id]?.contains(pin) == true {
                    diNames[pin] = names.unique("di\(pin)")
                }
            }
            for module in modules where module.guid == EightDOBlock.guid {
                for pin in module.inPins.indices.dropFirst()
                where (isDriven(module: module.id, pin: pin) || module.inPins[pin].value.asBool) && pin - 1 <= 7 {
                    outputNames[pin - 1] = names.unique("do\(pin - 1)")
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

    private func expression(module: Int, pin: Int, depth: Int) -> String? {
        guard depth < 24 else { return nil }
        guard let source = wires[module]?[pin] else {
            guard let producer = modules.first(where: { $0.id == module }),
                  producer.inPins.indices.contains(pin) else { return nil }
            return producer.inPins[pin].value.asBool ? "true" : "false"
        }
        guard let producer = modules.first(where: { $0.id == source.module }) else { return nil }
        if skipped.contains(producer.id) { return nil }

        switch producer.guid {
        case EightDIBlock.guid:
            return diNames[source.pin] ?? "false"
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
        case PulseGenBlock.guid:
            // A macro page cannot start a timer in this subset.
            guard !isMacro, producer.paramPins.count >= 2 else { return nil }
            let cycles = producer.paramPins[0].value.asInt + producer.paramPins[1].value.asInt
            return "pulse(ms: \(max(interval, cycles * interval)))"
        case NotBlock.guid:
            guard let value = expression(module: producer.id, pin: 1, depth: depth + 1) else { return nil }
            return "!\(parenthesise(value))"
        case AndBlock.guid:
            return binary(producer, "&&", depth)
        case OrBlock.guid:
            return binary(producer, "||", depth)
        case XorBlock.guid:
            return binary(producer, "!=", depth)
        default:
            guard boundBlocks.contains(producer.id), let name = blockNames[producer.id] else { return nil }
            let labels = BlockLabels.outputLabels(for: producer.guid)
            guard labels.indices.contains(source.pin) else { return nil }
            return "\(name).\(labels[source.pin])"
        }
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
        var open: (id: Int, then: Set<Int>, other: Set<Int>, inElse: Bool, nested: Int)?
        var groups: [ConditionalGroup] = []
        var skippedIds: Set<Int> = []

        for module in modules.sorted(by: { $0.order < $1.order }) {
            let kind = BlockTypeCatalog.info(forGuid: module.guid)?.delphiClass
            switch kind {
            case "TMIfModule":
                if var current = open {
                    current.nested += 1
                    current.then.insert(module.id)
                    open = current
                } else {
                    open = (module.id, [module.id], [], false, 0)
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
                                                   elseIds: current.other, hasElse: current.inElse))
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
            let recoverable = !sets.isEmpty
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
    private static let reserved: Set<String> = ["true", "false", "var", "let", "func", "struct", "if", "else", "import",
                                               "return", "scan", "in", "for", "while"]

    mutating func unique(_ candidate: String) -> String {
        var name = candidate
        if NameSet.reserved.contains(name) { name += "_" }
        if name.isEmpty { name = "value" }
        var suffix = 2
        while used.contains(name) {
            name = "\(candidate)\(suffix)"
            suffix += 1
        }
        used.insert(name)
        return name
    }
}

private enum Identifier {
    static func of(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars: [Character] = []
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                scalars.append(Character(scalar))
            } else {
                scalars.append("_")
            }
        }
        var name = String(scalars)
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { return fallback }
        if let first = name.first, first.isNumber { name = "_" + name }
        return name
    }
}
