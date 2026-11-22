import Foundation
import WirebenchLibrary

/// Completion for the Structured Text editor: keywords, types, instance names, and the members of the instance before
/// the cursor. Pure, so it can be tested without AppKit — the text view only supplies the partial word.
public enum SourceCompletion {
    public enum Kind: String, Sendable {
        /// An IEC keyword (IF, VAR, END_FOR, …).
        case keyword
        /// A type name: an IEC scalar or a catalogued block type.
        case type
        /// A declared variable, pin, array, instance, or instance member.
        case name
    }

    public struct Suggestion: Sendable, Hashable {
        /// What the row shows and what the partial filters by.
        public var text: String
        public var kind: Kind
        /// What Tab writes; nil writes `text`. A declaration choice expands to the whole
        /// declaration (`And_ : And;`), not only the type name.
        public var insert: String?

        public init(text: String, kind: Kind, insert: String? = nil) {
            self.text = text
            self.kind = kind
            self.insert = insert
        }
    }

    /// Where the caret sits, decided by the declaration blocks before it.
    public enum Context: String, Sendable {
        /// An executable position: statements, expressions, arguments.
        case statement
        /// The name half of a declaration (`VAR <here>`): block types, expanding to a full declaration.
        case declarationName
        /// The type half (`name : <here>`): IEC scalars and block types.
        case declarationType
    }

    /// Scans the declaration blocks before the caret line by line, so `VAR x : B` reads as the type
    /// position and `VAR x` as the name position. Tokens after the caret are not in `beforeCaret`,
    /// so a one-line `VAR x : INT; END_VAR` is handled by construction.
    public static func context(beforeCaret: String) -> Context {
        var inDeclaration = false
        var lastLineHasColon = false
        let lines = beforeCaret.split(omittingEmptySubsequences: false) { $0 == "\n" }
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 { lastLineHasColon = line.contains(":") }
            var token = ""
            func flush() {
                let upper = token.uppercased()
                if upper == "END_VAR" { inDeclaration = false }
                else if upper == "VAR" || (upper.hasPrefix("VAR_") && upper != "VARIABLE") { inDeclaration = true }
                token = ""
            }
            for character in line {
                if character.isLetter || character == "_" { token.append(character) } else { flush() }
            }
            flush()
        }
        guard inDeclaration else { return .statement }
        return lastLineHasColon ? .declarationType : .declarationName
    }

    /// Kinded suggestions for the context around the caret.
    public static func suggestionsWithKinds(in source: String, partial: String, beforeCaret: String,
                                            context: Context? = nil) -> [Suggestion] {
        let resolved = context ?? self.context(beforeCaret: beforeCaret)
        let prefix = partial.lowercased()
        var result: [Suggestion] = []
        var seen: Set<String> = []
        func add(_ text: String, _ kind: Kind, insert: String? = nil) {
            guard text.lowercased().hasPrefix(prefix), seen.insert(text.lowercased()).inserted else { return }
            result.append(Suggestion(text: text, kind: kind, insert: insert))
        }
        if resolved == .declarationType {
            for scalar in ["BOOL", "INT", "DINT", "LINT", "REAL", "LREAL", "WORD", "STRING"] {
                add(scalar, .type)
            }
            for name in BlockLabels.sourceNames.keys { add(name, .type) }
            return result.sorted { $0.text.caseInsensitiveCompare($1.text) == .orderedAscending }
        }
        if resolved == .declarationName {
            // An instance is named after its type with a trailing underscore, as the decompiler
            // writes it (`And_ : And;`): a type name reads as itself in a declaration, and the
            // keyword collision (`AND`) must not reach the parser as a variable.
            for name in BlockLabels.sourceNames.keys {
                add(name, .type, insert: "\(name)_ : \(name);")
            }
            return result.sorted { $0.text.caseInsensitiveCompare($1.text) == .orderedAscending }
        }
        let program = (try? SourceParser.parse(source))
        var instances: [String: String] = [:]
        for unit in program?.units ?? [] {
            for instance in unit.instances {
                instances[instance.name.lowercased()] = instance.typeName
                add(instance.name, .name)
            }
            for variable in unit.variables { add(variable.name, .name) }
            for array in unit.arrays { add(array.name, .name) }
            for pin in unit.pins { add(pin.name, .name) }
        }
        // `name.` asks for that instance's outputs (and, for a macro, its declared output pins).
        if let memberOf = memberOwner(beforeCaret) {
            if let type = instances[memberOf.lowercased()] {
                if let block = program?.units.first(where: {
                    $0.kind == .functionBlock && $0.name.lowercased() == type.lowercased()
                }) {
                    for output in block.outputs { add(output.name, .name) }
                } else if let guid = BlockLabels.guid(forSourceName: type) {
                    for label in BlockLabels.outputLabels(for: guid) { add(label, .name) }
                }
            }
            return result.sorted { $0.text.caseInsensitiveCompare($1.text) == .orderedAscending }
        }
        for word in SourceHighlighter.vocabulary { add(word, .keyword) }
        for name in BlockLabels.sourceNames.keys { add(name, .type) }
        return result.sorted { $0.text.caseInsensitiveCompare($1.text) == .orderedAscending }
    }

    public static func suggestions(in source: String, partial: String, beforeCaret: String) -> [String] {
        suggestionsWithKinds(in: source, partial: partial, beforeCaret: beforeCaret).map(\.text)
    }

    /// The identifier before a trailing dot: `t.` -> `t`.
    private static func memberOwner(_ beforeCaret: String) -> String? {
        let trimmed = beforeCaret.hasSuffix(".") ? String(beforeCaret.dropLast()) : nil
        guard let trimmed else { return nil }
        let name = trimmed.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed()
        return name.isEmpty ? nil : String(name)
    }
}
