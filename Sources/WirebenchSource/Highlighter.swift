import Foundation

/// What a span of source is, for the editor's colours.
public enum SyntaxTokenKind: Sendable, Equatable {
    case keyword
    case comment
    case string
    case number
    case attribute
    case declaration
    case type
    case call
    case operatorToken
}

/// A coloured range, in the UTF-16 offsets an `NSTextStorage` uses.
public struct SyntaxSpan: Sendable, Equatable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxTokenKind

    public init(location: Int, length: Int, kind: SyntaxTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// Colours a Structured Text file for the editor.
///
/// A small lexer of its own, so the editor and the compiler need no parser library and no C module: the spans are
/// measured in UTF-16 units as the text is scanned, which is what an `NSTextStorage` counts, so a Czech comment or an
/// accented identifier cannot shift a colour onto the wrong characters.
public enum SourceHighlighter {
    private static let keywords: Set<String> = [
        "PROGRAM", "END_PROGRAM", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK", "FUNCTION", "END_FUNCTION",
        "VAR", "END_VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_GLOBAL", "VAR_IN_OUT", "VAR_TEMP", "VAR_STAT",
        "VAR_EXTERNAL", "CONSTANT", "RETAIN", "NON_RETAIN", "PERSISTENT",
        "IF", "THEN", "ELSIF", "ELSE", "END_IF", "CASE", "OF", "END_CASE",
        "FOR", "TO", "BY", "DO", "END_FOR", "WHILE", "END_WHILE", "REPEAT", "UNTIL", "END_REPEAT",
        "RETURN", "EXIT", "CONTINUE", "TYPE", "END_TYPE", "STRUCT", "END_STRUCT", "ARRAY",
        "AND", "OR", "XOR", "NOT", "MOD", "AT", "TRUE", "FALSE",
        "INTERFACE", "END_INTERFACE", "METHOD", "END_METHOD",
    ]
    private static let types: Set<String> = [
        "BOOL", "SINT", "INT", "LONG", "DINT", "LINT", "USINT", "UINT", "UDINT", "ULINT",
        "REAL", "LREAL", "BYTE", "WORD", "DWORD", "LWORD", "TIME", "DATE", "TOD", "DT",
        "STRING", "WSTRING", "CHAR", "WCHAR",
    ]

    /// Every word the editor colours: keywords and type names, for completion as well.
    public static var vocabulary: Set<String> { keywords.union(types) }

    public static func spans(in source: String) -> [SyntaxSpan] {
        let characters = Array(source)
        // Prefix sums of UTF-16 widths: a character index becomes a text offset in one lookup, and a character can be
        // two UTF-16 units (a Czech letter in a comment, an emoji in a name).
        var offsets = [Int](repeating: 0, count: characters.count + 1)
        for (i, character) in characters.enumerated() {
            offsets[i + 1] = offsets[i] + String(character).utf16.count
        }
        var spans: [SyntaxSpan] = []
        var index = 0

        func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind, in slice: [Character] = []) {
            guard end > start else { return }
            spans.append(SyntaxSpan(location: offsets[start], length: offsets[min(end, characters.count)] - offsets[start],
                                    kind: kind))
        }

        // The scan is over the whole source; `slice` is the full array, and locations are its UTF-16 offsets.
        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" || character.isNewline {
                index += 1
                continue
            }
            if character == "(" && index + 1 < characters.count && characters[index + 1] == "*" {
                var end = index + 2
                var depth = 1
                while end < characters.count {
                    if characters[end] == "(" && end + 1 < characters.count && characters[end + 1] == "*" {
                        depth += 1
                        end += 2
                    } else if characters[end] == "*" && end + 1 < characters.count && characters[end + 1] == ")" {
                        depth -= 1
                        end += 2
                        if depth == 0 { break }
                    } else {
                        end += 1
                    }
                }
                add(index, min(end, characters.count), .comment)
                index = min(end, characters.count)
                continue
            }
            if character == "/" && index + 1 < characters.count && characters[index + 1] == "/" {
                var end = index
                while end < characters.count && !characters[end].isNewline { end += 1 }
                add(index, end, .comment)
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count,
                      characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                let word = String(characters[index..<end])
                let upper = word.uppercased()
                let kind: SyntaxTokenKind?
                if keywords.contains(upper) {
                    kind = .keyword
                } else if types.contains(upper) {
                    kind = .type
                } else if nextSignificant(characters, from: end) == "(" {
                    kind = .call
                } else if isDeclarationColon(characters, from: end) {
                    kind = .declaration
                } else {
                    kind = nil
                }
                if let kind { add(index, end, kind) }
                index = end
                continue
            }
            if character.isNumber {
                var end = index
                while end < characters.count, characters[end].isNumber { end += 1 }
                add(index, end, .number)
                index = end
                continue
            }
            // Operators and punctuation are coloured only where they carry meaning.
            if character == ":" && index + 1 < characters.count && characters[index + 1] == "=" {
                add(index, index + 2, .operatorToken)
                index += 2
                continue
            }
            if character == "<" || character == ">" {
                let two = index + 1 < characters.count && (characters[index + 1] == "=" || characters[index + 1] == ">")
                if two {
                    add(index, index + 2, .operatorToken)
                    index += 2
                    continue
                }
            }
            if character == "=" || character == "<" || character == ">" || character == "+" || character == "-"
                || character == "*" || character == "/" {
                add(index, index + 1, .operatorToken)
            }
            index += 1
        }
        return spans
    }

    /// The next character that is not a space or a tab, for spotting `name(`.
    private static func nextSignificant(_ characters: [Character], from index: Int) -> Character? {
        var i = index
        while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
        return i < characters.count ? characters[i] : nil
    }

    /// `name : BOOL` declares, `name := …` assigns. The `:` of `:=` must not be mistaken for a declaration.
    private static func isDeclarationColon(_ characters: [Character], from index: Int) -> Bool {
        var i = index
        while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
        guard i < characters.count, characters[i] == ":" else { return false }
        var j = i + 1
        while j < characters.count, characters[j] == " " || characters[j] == "\t" { j += 1 }
        return !(j < characters.count && characters[j] == "=")
    }
}
