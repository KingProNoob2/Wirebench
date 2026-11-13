import Foundation
import WirebenchLibrary

/// Completion for the Structured Text editor: keywords, types, instance names, and the members of the instance before
/// the cursor. Pure, so it can be tested without AppKit — the text view only supplies the partial word.
public enum SourceCompletion {
    public static func suggestions(in source: String, partial: String, beforeCaret: String) -> [String] {
        let prefix = partial.lowercased()
        var words: Set<String> = SourceHighlighter.vocabulary
        let program = (try? SourceParser.parse(source))
        var instances: [String: String] = [:]
        for unit in program?.units ?? [] {
            for instance in unit.instances {
                instances[instance.name.lowercased()] = instance.typeName
                words.insert(instance.name)
            }
            words.formUnion(unit.variables.map(\.name))
            words.formUnion(unit.arrays.map(\.name))
            words.formUnion(unit.pins.map(\.name))
        }
        // `name.` asks for that instance's outputs (and, for a macro, its declared output pins).
        if let memberOf = memberOwner(beforeCaret) {
            if let type = instances[memberOf.lowercased()] {
                if let block = program?.units.first(where: {
                    $0.kind == .functionBlock && $0.name.lowercased() == type.lowercased()
                }) {
                    words.formUnion(block.outputs.map(\.name))
                } else if let guid = BlockLabels.guid(forSourceName: type) {
                    words.formUnion(BlockLabels.outputLabels(for: guid))
                }
            }
            return words.filter { $0.lowercased().hasPrefix(prefix) }.sorted { $0 < $1 }
        }
        words.formUnion(BlockLabels.sourceNames.keys)
        return words.filter { $0.lowercased().hasPrefix(prefix) }.sorted { $0 < $1 }
    }

    /// The identifier before a trailing dot: `t.` -> `t`.
    private static func memberOwner(_ beforeCaret: String) -> String? {
        let trimmed = beforeCaret.hasSuffix(".") ? String(beforeCaret.dropLast()) : nil
        guard let trimmed else { return nil }
        let name = trimmed.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed()
        return name.isEmpty ? nil : String(name)
    }
}
