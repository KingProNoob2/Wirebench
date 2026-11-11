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
    public static func countedInputCount(for guid: UUID, totalPins: Int) -> Int? {
        guard let template = template(for: guid),
              let placeholder = template.inputs.first(where: { $0.isCountedInput }) else { return nil }
        let fixed = template.inputs.filter { !$0.isCountedInput && !isRunMember($0, prefix: prefix(of: placeholder)) }.count
        return max(1, totalPins - fixed)
    }

    /// How many input pins the block has before its configurable run starts.
    public static func fixedInputCount(for guid: UUID) -> Int {
        guard let template = template(for: guid),
              let placeholder = template.inputs.first(where: { $0.isCountedInput }) else {
            return template(for: guid)?.inputs.count ?? 0
        }
        return template.inputs.filter { !$0.isCountedInput && !isRunMember($0, prefix: prefix(of: placeholder)) }.count
    }

    public static func hasConfigurableInputs(_ guid: UUID) -> Bool {
        template(for: guid)?.inputs.contains { $0.isCountedInput } ?? false
    }

    private static func prefix(of placeholder: PinTemplate) -> String {
        String(placeholder.abbrev.prefix(while: { $0 != "(" }))
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
