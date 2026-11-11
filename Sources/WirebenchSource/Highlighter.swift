import Foundation
import SwiftParser
import SwiftSyntax

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

/// Colours a source file for the editor, from the same parse the compiler uses.
///
/// `swift-syntax` reports positions in UTF-8 bytes; an `NSTextStorage` counts UTF-16 units, and a Czech comment or a
/// string with an accent makes those differ. The spans are therefore converted through one table built from the source,
/// so a colour never drifts onto the wrong characters.
public enum SwiftSourceHighlighter {
    public static func spans(in source: String) -> [SyntaxSpan] {
        let tree = Parser.parse(source: source)
        let offsets = UTF16Offsets(source)
        var spans: [SyntaxSpan] = []

        func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            guard end > start,
                  let location = offsets.utf16(at: start),
                  let finish = offsets.utf16(at: end), finish > location else { return }
            spans.append(SyntaxSpan(location: location, length: finish - location, kind: kind))
        }

        var offset = 0
        for token in tree.tokens(viewMode: .sourceAccurate) {
            for piece in token.leadingTrivia {
                if piece.isComment { add(offset, offset + piece.sourceLength.utf8Length, .comment) }
                offset += piece.sourceLength.utf8Length
            }
            let length = token.text.utf8.count
            if let kind = tokenKind(of: token) {
                add(offset, offset + length, kind)
            }
            offset += length
            for piece in token.trailingTrivia {
                if piece.isComment { add(offset, offset + piece.sourceLength.utf8Length, .comment) }
                offset += piece.sourceLength.utf8Length
            }
        }

        // Names are coloured by their position in the tree, which the token stream alone cannot tell from any other
        // identifier: a declaration's name, a type, an attribute, a call.
        for token in tree.tokens(viewMode: .sourceAccurate) {
            guard let kind = nameKind(of: token) else { continue }
            let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
            add(start, start + token.text.utf8.count, kind)
        }
        return spans
    }

    /// The colour a token's own text carries.
    private static func tokenKind(of token: TokenSyntax) -> SyntaxTokenKind? {
        switch token.tokenKind {
        case .keyword: return .keyword
        case .integerLiteral, .floatLiteral: return .number
        case .stringSegment: return .string
        case .binaryOperator, .prefixOperator, .postfixOperator: return .operatorToken
        default: return nil
        }
    }

    /// The colour of an identifier, decided by the node it names.
    private static func nameKind(of token: TokenSyntax) -> SyntaxTokenKind? {
        guard case .identifier = token.tokenKind, let parent = token.parent else { return nil }
        switch parent.as(SyntaxEnum.self) {
        case .structDecl(let node) where node.name.id == token.id: return .declaration
        case .functionDecl(let node) where node.name.id == token.id: return .declaration
        case .identifierPattern(let node) where node.identifier.id == token.id: return .declaration
        // `@DI` is an attribute whose name is an `IdentifierTypeSyntax`, so the attribute is the parent of the parent.
        case .identifierType(let node):
            if let attribute = node.parent?.as(AttributeSyntax.self), attribute.attributeName.id == node.id {
                return .attribute
            }
            return node.name.id == token.id ? .type : nil
        case .declReferenceExpr(let node) where node.baseName.id == token.id: return .call
        default: return nil
        }
    }
}

/// Maps UTF-8 byte offsets to UTF-16 offsets for one string.
private struct UTF16Offsets {
    private var table: [Int?]
    private let utf8Count: Int

    init(_ source: String) {
        let count = source.utf8.count
        var table = [Int?](repeating: nil, count: count + 1)
        var utf8 = 0
        var utf16 = 0
        for scalar in source.unicodeScalars {
            let width = UTF8Width.width(scalar)
            for step in 0..<width { table[utf8 + step] = utf16 }
            utf8 += width
            utf16 += scalar.utf16.count
        }
        table[count] = utf16
        self.table = table
        self.utf8Count = count
    }

    func utf16(at utf8Offset: Int) -> Int? {
        guard utf8Offset >= 0, utf8Offset <= utf8Count else { return nil }
        return table[utf8Offset]
    }
}

private enum UTF8Width {
    static func width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }
}

private extension TriviaPiece {
    var isComment: Bool {
        switch self {
        case .lineComment, .blockComment, .docLineComment, .docBlockComment:
            return true
        default:
            return false
        }
    }
}
