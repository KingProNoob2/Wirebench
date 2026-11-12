import Foundation

/// The bridge between block types and their source spelling.
///
/// Every catalogued block gets a constructor in PLC Swift: `Block.IAdd(X0, X1)`-style calls name the type, take its input
/// pins positionally, and take parameters by label. That is what lets the editor recover a sheet of any blocks, not only
/// the ones with a Boolean operator behind them.
public enum BlockLabels {
    /// A catalogue name a source identifier can carry: `IAdd` stays, `8xDI` becomes `_8xDI`, spaces become `_`.
    public static func sanitise(_ raw: String) -> String {
        var scalars: [Character] = []
        for scalar in raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                scalars.append(Character(scalar))
            } else {
                scalars.append("_")
            }
        }
        var name = String(scalars)
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { name = "Block" }
        if let first = name.first, first.isNumber { name = "_" + name }
        return name
    }

    /// The constructor each block type is called by, unique across the catalogue.
    public static let sourceNames: [String: UUID] = {
        var table: [String: UUID] = [:]
        var used: [String: Int] = [:]
        for info in BlockTypeCatalog.all {
            var name = sanitise(info.blockName)
            if let count = used[name] {
                used[name] = count + 1
                name += "\(count + 1)"
            } else {
                used[name] = 1
            }
            table[name] = info.guid
        }
        return table
    }()

    public static func guid(forSourceName name: String) -> UUID? {
        sourceNames[name]
    }

    public static func sourceName(for guid: UUID) -> String? {
        sourceNames.first { $0.value == guid }?.key
    }

    public static func isBooleanType(_ type: String) -> Bool {
        switch type.lowercased() {
        case "boolean", "bit", "bool": return true
        default: return false
        }
    }

    /// The input pins' data types, in pin order, for a block configured with `totalPins` inputs.
    public static func inputTypes(for guid: UUID, totalPins: Int) -> [String] {
        guard let template = template(for: guid) else { return [] }
        guard let placeholder = runPlaceholder(template) else {
            return template.inputs.map(\.dataType)
        }
        let prefix = prefix(of: placeholder)
        let fixed = template.inputs.filter { $0.abbrev != placeholder.abbrev && !isRunMember($0, prefix: prefix) }
        let run = max(0, totalPins - fixed.count)
        return fixed.map(\.dataType) + Array(repeating: placeholder.dataType, count: run)
    }

    public static func paramTypes(for guid: UUID) -> [String] {
        template(for: guid)?.params.map(\.dataType) ?? []
    }

    /// The output pins' source names, in pin order.
    public static func outputLabels(for guid: UUID) -> [String] {
        let names = template(for: guid)?.outputs.map(\.name) ?? []
        return unique(names.isEmpty ? ["Y"] : names)
    }

    /// The parameter pins' source names, in pin order.
    public static func paramLabels(for guid: UUID) -> [String] {
        unique(template(for: guid)?.params.map(\.name) ?? [])
    }

    /// How many operands a block with `totalPins` input pins was configured for, when it has a configurable run; `nil`
    /// when its pins are fixed.
    /// The template's configurable run. Some blocks mark it with `isCountedInput`; others only name it
    /// `X0 - Xn`, and Dirigo lets those grow too.
    private static func runPlaceholder(_ template: BlockPinTemplate) -> PinTemplate? {
        template.inputs.first { $0.isCountedInput || $0.abbrev.contains(" - ") }
    }

    public static func countedInputCount(for guid: UUID, totalPins: Int) -> Int? {
        guard let template = template(for: guid), runPlaceholder(template) != nil else { return nil }
        return max(1, totalPins - fixedInputCount(for: guid))
    }

    /// How many input pins the block has before its configurable run starts.
    public static func fixedInputCount(for guid: UUID) -> Int {
        guard let template = template(for: guid) else { return 0 }
        guard let placeholder = runPlaceholder(template) else { return template.inputs.count }
        let prefix = prefix(of: placeholder)
        return template.inputs.filter { $0.abbrev != placeholder.abbrev && !isRunMember($0, prefix: prefix) }.count
    }

    /// The most input pins a block call may have: the template's own, or the fixed run plus a generous window for a
    /// configurable block. A `set` beyond this is a mistake, not a bigger block.
    public static func maxInputPins(for guid: UUID) -> Int {
        guard let template = template(for: guid) else {
            // No recovered pin layout: `BlockFactory` gives the block one generic pin, and a file can carry more.
            return 256
        }
        return hasConfigurableInputs(guid) ? fixedInputCount(for: guid) + 256 : template.inputs.count
    }

    public static func hasConfigurableInputs(_ guid: UUID) -> Bool {
        guard let template = template(for: guid) else { return false }
        return runPlaceholder(template) != nil
    }

    private static func prefix(of placeholder: PinTemplate) -> String {
        String(placeholder.abbrev.prefix(while: { $0.isLetter }))
    }

    private static func isRunMember(_ spec: PinTemplate, prefix: String) -> Bool {
        spec.abbrev.hasPrefix(prefix) && spec.abbrev.dropFirst(prefix.count).allSatisfy(\.isNumber)
    }

    private static func template(for guid: UUID) -> BlockPinTemplate? {
        PinTemplateCatalog.template(forGuid: guid)
    }

    private static func unique(_ names: [String]) -> [String] {
        var taken: [String: Int] = [:]
        return names.map { name in
            var candidate = sanitise(name)
            if let count = taken[candidate] {
                taken[candidate] = count + 1
                candidate += "\(count + 1)"
            } else {
                taken[candidate] = 1
            }
            return candidate
        }
    }
}
