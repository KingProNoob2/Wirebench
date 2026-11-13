import Foundation

/// A diagnostic from the Structured Text compiler, with the position it happened at.
public struct SourceError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    public var message: String

    public init(line: Int, column: Int = 0, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String {
        column > 0 ? "line \(line), column \(column): \(message)" : "line \(line): \(message)"
    }
}

// MARK: - The syntax tree

/// One expression of the subset.
public struct SourceExpr: Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case boolean(Bool)
        case integer(Int)
        case real(Double)
        case name(String)
        /// `t.result`: one of a function-block instance's outputs.
        case member(SourceExpr, String)
        case unary(String, SourceExpr)
        case binary(String, SourceExpr, SourceExpr)
    }

    public var kind: Kind
    public var line: Int

    public init(_ kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

public struct SourceArgument: Equatable, Sendable {
    public var label: String
    public var value: SourceExpr

    public init(label: String, value: SourceExpr) {
        self.label = label
        self.value = value
    }
}

public struct SourceStmt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case assign(String, SourceExpr)
        /// `t(value := x);`: calls a function-block or block instance with named arguments.
        case call(String, [SourceArgument])
        case ifThen(SourceExpr, [SourceStmt], [SourceStmt]?)
    }

    public var kind: Kind
    public var line: Int

    public init(_ kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

/// A program's hardware pin: `lamp AT %QX0 : BOOL;`. `AT %IX0` reads a digital input, `AT %QX0` drives an output.
public struct SourcePin: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case input, output }

    public var direction: Direction
    public var index: Int
    public var name: String
    public var line: Int

    public init(direction: Direction, index: Int, name: String, line: Int) {
        self.direction = direction
        self.index = index
        self.name = name
        self.line = line
    }
}

/// The scalar types the subset understands. `INT`/`LONG`/`REAL` are internal variables for now: the hardware pins
/// (`AT %IXn` / `AT %QXn`, `VAR_INPUT`/`VAR_OUTPUT`) are still BOOL.
public enum SourceType: Equatable, Sendable {
    case bool, int, long, real

    public var name: String {
        switch self {
        case .bool: return "BOOL"
        case .int: return "INT"
        case .long: return "LONG"
        case .real: return "REAL"
        }
    }
}

/// A declaration's initial value, typed by the declared type.
public enum SourceLiteral: Equatable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case real(Double)
}

/// A stored value: the program's state, one `BoolVar`/`IntVar`/`LongVar`/`FloatVar` and one `Set` per name.
public struct SourceVariable: Equatable, Sendable {
    public var name: String
    public var type: SourceType
    public var initial: SourceLiteral?
    public var line: Int

    public init(name: String, type: SourceType = .bool, initial: SourceLiteral? = nil, line: Int) {
        self.name = name
        self.type = type
        self.initial = initial
        self.line = line
    }
}

/// `running : TON;` — a declared instance of a function block or of a block from the catalogue.
public struct SourceInstance: Equatable, Sendable {
    public var name: String
    public var typeName: String
    public var line: Int

    public init(name: String, typeName: String, line: Int) {
        self.name = name
        self.typeName = typeName
        self.line = line
    }
}

/// A `PROGRAM` (a page) or a `FUNCTION_BLOCK` (a macro page).
public struct SourceUnit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case program, functionBlock }

    public var name: String
    public var kind: Kind
    public var pins: [SourcePin]
    public var variables: [SourceVariable]
    public var instances: [SourceInstance]
    public var body: [SourceStmt]
    public var line: Int

    public init(name: String, kind: Kind, pins: [SourcePin] = [], variables: [SourceVariable] = [],
                instances: [SourceInstance] = [], body: [SourceStmt] = [], line: Int) {
        self.name = name
        self.kind = kind
        self.pins = pins
        self.variables = variables
        self.instances = instances
        self.body = body
        self.line = line
    }

    public var inputs: [SourcePin] { pins.filter { $0.direction == .input }.sorted { $0.index < $1.index } }
    public var outputs: [SourcePin] { pins.filter { $0.direction == .output }.sorted { $0.index < $1.index } }
    /// The Dirigo caption: a macro is a `*` sheet, a page keeps its name.
    public var caption: String { kind == .functionBlock ? "*\(name)" : name }
}

public struct SourceProgram: Equatable, Sendable {
    public var units: [SourceUnit]

    public init(units: [SourceUnit] = []) {
        self.units = units
    }

    /// The page the document opens on: the first `PROGRAM`.
    public var main: SourceUnit? { units.first { $0.kind == .program } }
    public var macros: [SourceUnit] { units.filter { $0.kind == .functionBlock } }
}

// MARK: - Parser

/// Reads IEC 61131-3 Structured Text, the subset the compiler lowers to blocks.
///
/// One file holds `PROGRAM`s (pages) and `FUNCTION_BLOCK`s (macro pages). A program's hardware pins are declared with
/// `AT %IXn` / `AT %QXn`; `VAR` holds state and instances of function blocks or catalogued blocks; `IF`/`ELSIF`/`ELSE`
/// and `:=` are the statements. Everything outside that subset is refused with a line and a reason.
public struct SourceParser {
    private var tokens: [STToken]
    private var index = 0

    public init(_ source: String) throws {
        tokens = try STLexer.tokenize(source)
    }

    public static func parse(_ source: String) throws -> SourceProgram {
        var parser = try SourceParser(source)
        return try parser.program()
    }

    private var current: STToken { tokens[index] }
    private func peek(_ offset: Int = 1) -> STToken {
        let i = index + offset
        return i < tokens.count ? tokens[i] : tokens[tokens.count - 1]
    }
    private var isAtEnd: Bool { current.kind == .endOfFile }

    private mutating func advance() -> STToken {
        let token = current
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func isKeyword(_ word: String) -> Bool {
        current.kind == .keyword && current.text.uppercased() == word
    }

    private func isSymbol(_ text: String) -> Bool { current.kind == .symbol && current.text == text }

    private mutating func expectKeyword(_ word: String) throws {
        guard isKeyword(word) else {
            throw error("expected \(word) but found \(describe(current))")
        }
        _ = advance()
    }

    private mutating func expectSymbol(_ text: String) throws {
        guard isSymbol(text) else {
            throw error("expected '\(text)' but found \(describe(current))")
        }
        _ = advance()
    }

    private mutating func expectIdentifier(_ what: String) throws -> STToken {
        guard current.kind == .identifier else {
            throw error("expected \(what) but found \(describe(current))")
        }
        return advance()
    }

    private func error(_ message: String, at token: STToken? = nil) -> SourceError {
        let token = token ?? current
        return SourceError(line: token.line, column: token.column, message: message)
    }

    private func describe(_ token: STToken) -> String {
        switch token.kind {
        case .endOfFile: return "the end of the file"
        case .integer, .real: return "the number \(token.text)"
        default: return "'\(token.text)'"
        }
    }

    // MARK: Units

    private mutating func program() throws -> SourceProgram {
        var units: [SourceUnit] = []
        while !isAtEnd {
            if isKeyword("PROGRAM") {
                units.append(try unit(.program))
            } else if isKeyword("FUNCTION_BLOCK") {
                units.append(try unit(.functionBlock))
            } else {
                throw error("expected PROGRAM or FUNCTION_BLOCK but found \(describe(current))")
            }
        }
        guard units.contains(where: { $0.kind == .program }) else {
            throw SourceError(line: 1, message: "the file declares no PROGRAM; write 'PROGRAM Main ... END_PROGRAM'")
        }
        let names = units.map { $0.name.lowercased() }
        if Set(names).count != names.count {
            throw SourceError(line: 1, message: "two programs or function blocks have the same name")
        }
        return SourceProgram(units: units)
    }

    private mutating func unit(_ kind: SourceUnit.Kind) throws -> SourceUnit {
        let keyword = advance()
        let name = try expectIdentifier("a name after \(kind == .program ? "PROGRAM" : "FUNCTION_BLOCK")").text
        var unit = SourceUnit(name: name, kind: kind, line: keyword.line)
        var sawStatement = false
        while !isAtEnd {
            if kind == .program && isKeyword("END_PROGRAM") { advance(); return unit }
            if kind == .functionBlock && isKeyword("END_FUNCTION_BLOCK") { advance(); return unit }
            if isKeyword("VAR") || isKeyword("VAR_INPUT") || isKeyword("VAR_OUTPUT") {
                if sawStatement { throw error("declare every variable before the first statement") }
                try variableBlock(into: &unit)
                continue
            }
            sawStatement = true
            unit.body.append(contentsOf: try statements(until: { block in
                kind == .program ? block == "END_PROGRAM" : block == "END_FUNCTION_BLOCK"
            }))
        }
        throw error("the \(kind == .program ? "PROGRAM" : "FUNCTION_BLOCK") is not closed")
    }

    private mutating func variableBlock(into unit: inout SourceUnit) throws {
        let header = advance()   // VAR / VAR_INPUT / VAR_OUTPUT
        let region = header.text.uppercased()
        // `VAR CONSTANT`/`VAR RETAIN` are accepted and treated as plain variables.
        if isKeyword("CONSTANT") || isKeyword("RETAIN") { advance() }
        while !isKeyword("END_VAR") {
            if isAtEnd { throw error("the VAR block is not closed with END_VAR") }
            let nameToken = try expectIdentifier("a variable name")
            let name = nameToken.text
            var address: (SourcePin.Direction, Int)?
            if isKeyword("AT") {
                advance()
                address = try addressPin()
            }
            try expectSymbol(":")
            let declared = try typeName()
            var initial: SourceLiteral?
            if case .scalar(let scalar) = declared { initial = try initialValue(for: scalar) }
            try expectSymbol(";")

            if region == "VAR_INPUT" || region == "VAR_OUTPUT" {
                guard unit.kind == .functionBlock else {
                    throw error("a PROGRAM's pins are declared AT %IXn / AT %QXn")
                }
                guard address == nil else { throw error("a FUNCTION_BLOCK pin takes no address") }
                guard case .scalar(.bool) = declared else {
                    throw error("a pin is BOOL, not \(declared)")
                }
                guard initial == nil else { throw error("a pin takes no initial value") }
                let direction: SourcePin.Direction = region == "VAR_INPUT" ? .input : .output
                if isNameTaken(name, in: unit) { throw error("'\(name)' is declared twice") }
                let index = unit.pins.filter { $0.direction == direction }.count
                unit.pins.append(SourcePin(direction: direction, index: index, name: name, line: nameToken.line))
            } else if let (direction, index) = address {
                guard region == "VAR" else {
                    throw error("AT %… belongs in a plain VAR block")
                }
                guard initial == nil else { throw error("a pin takes no initial value") }
                guard case .scalar(.bool) = declared else { throw error("a pin is BOOL, not \(declared)") }
                if unit.pins.contains(where: { $0.direction == direction && $0.index == index }) {
                    throw error("\(direction == .input ? "I" : "Q")\(index) is declared twice")
                }
                if isNameTaken(name, in: unit) { throw error("'\(name)' is declared twice") }
                unit.pins.append(SourcePin(direction: direction, index: index, name: name, line: nameToken.line))
            } else if case .scalar(let scalar) = declared {
                guard region == "VAR" || initial == nil else {
                    throw error("only an internal variable takes an initial value")
                }
                if isNameTaken(name, in: unit) { throw error("'\(name)' is declared twice") }
                unit.variables.append(SourceVariable(name: name, type: scalar, initial: initial, line: nameToken.line))
            } else if case .instance(let type) = declared {
                if initial != nil { throw error("an instance takes no initial value") }
                guard !isNameTaken(name, in: unit) else { throw error("'\(name)' is declared twice") }
                unit.instances.append(SourceInstance(name: name, typeName: type, line: nameToken.line))
            }
        }
        advance()   // END_VAR
    }

    /// ST names are case-insensitive, so `On` and `on` are the same declaration.
    private func isNameTaken(_ name: String, in unit: SourceUnit) -> Bool {
        let folded = name.lowercased()
        return unit.variables.contains { $0.name.lowercased() == folded }
            || unit.instances.contains { $0.name.lowercased() == folded }
            || unit.pins.contains { $0.name.lowercased() == folded }
    }

    /// `AT %IX0` / `AT %QX0` — input and output bits, 0 to 7.
    private mutating func addressPin() throws -> (SourcePin.Direction, Int) {
        try expectSymbol("%")
        guard current.kind == .identifier else {
            throw error("expected an address after '%', as in %IX0")
        }
        let text = advance().text.uppercased()
        let direction: SourcePin.Direction
        var digits = text
        if digits.hasPrefix("IX") {
            direction = .input
            digits = String(digits.dropFirst(2))
        } else if digits.hasPrefix("QX") {
            direction = .output
            digits = String(digits.dropFirst(2))
        } else {
            throw error("unknown address %\(text); use %IX0…%IX7 or %QX0…%QX7")
        }
        guard let index = Int(digits), (0...7).contains(index) else {
            throw error("address %\(text) is not a digital pin; there are pins 0 to 7")
        }
        return (direction, index)
    }

    /// A declared type: `BOOL`, `INT`, `REAL`, or the name of a function block / catalogued block.
    private enum DeclaredType {
        case scalar(SourceType)
        case instance(String)
    }

    private mutating func typeName() throws -> DeclaredType {
        if current.kind == .keyword {
            switch current.text.uppercased() {
            case "BOOL": advance(); return .scalar(.bool)
            case "INT", "WORD": advance(); return .scalar(.int)
            case "LONG": advance(); return .scalar(.long)
            case "REAL", "LREAL": advance(); return .scalar(.real)
            default: break
            }
        }
        guard current.kind == .identifier else {
            throw error("expected a type but found \(describe(current))")
        }
        return .instance(advance().text)
    }

    /// `:= 5`, `:= -2.5`, `:= TRUE`: the literal a declaration is initialised with, if any.
    private mutating func initialValue(for type: SourceType) throws -> SourceLiteral? {
        guard isSymbol(":=") else { return nil }
        advance()
        if type == .bool {
            return .boolean(try booleanLiteral(required: true))
        }
        var negative = false
        if isSymbol("-") { advance(); negative = true }
        if current.kind == .integer {
            let token = advance()
            guard let value = Int(token.text) else { throw error("the number \(token.text) is too large", at: token) }
            let signed = negative ? -value : value
            if type == .real { return .real(Double(signed)) }
            return .integer(signed)
        }
        if current.kind == .real {
            let token = advance()
            guard type == .real, let value = Double(token.text) else {
                throw error("a \(type.name) starts with a whole number", at: token)
            }
            return .real(negative ? -value : value)
        }
        throw error("expected a literal after ':='")
    }

    private mutating func booleanLiteral(required: Bool) throws -> Bool {
        if isKeyword("TRUE") { advance(); return true }
        if isKeyword("FALSE") { advance(); return false }
        throw error("expected TRUE or FALSE")
    }

    // MARK: Statements

    private mutating func statements(until end: (String) -> Bool) throws -> [SourceStmt] {
        var statements: [SourceStmt] = []
        while !isAtEnd, !end(current.text.uppercased()) {
            if isSymbol(";") { advance(); continue }
            statements.append(try statement())
        }
        return statements
    }

    private mutating func statement() throws -> SourceStmt {
        if isKeyword("IF") { return try ifStatement() }
        if isKeyword("CASE") { return try caseStatement() }
        guard current.kind == .identifier else {
            throw error("expected a statement but found \(describe(current))")
        }
        let name = advance()
        if isSymbol("(") {
            let arguments = try argumentList()
            try expectSymbol(";")
            return SourceStmt(.call(name.text, arguments), line: name.line)
        }
        try expectSymbol(":=")
        let value = try expression()
        try expectSymbol(";")
        return SourceStmt(.assign(name.text, value), line: name.line)
    }

    private mutating func ifStatement() throws -> SourceStmt {
        let keyword = advance()   // IF
        let condition = try expression()
        try expectKeyword("THEN")
        let thenBody = try statements { $0 == "ELSIF" || $0 == "ELSE" || $0 == "END_IF" }
        var elseBody: [SourceStmt]?
        if isKeyword("ELSIF") {
            // `ELSIF c THEN …` is an `ELSE IF c THEN … END_IF` in the tree. The chain does not consume the closing
            // END_IF; it is the outer IF's.
            elseBody = [try elsifClause()]
        } else if isKeyword("ELSE") {
            advance()
            elseBody = try statements { $0 == "END_IF" }
        }
        try expectKeyword("END_IF")
        try expectSymbol(";")
        return SourceStmt(.ifThen(condition, thenBody, elseBody), line: keyword.line)
    }

    /// One `ELSIF` arm, positioned on `ELSIF`; stops before the outer `END_IF`.
    private mutating func elsifClause() throws -> SourceStmt {
        let at = advance()   // ELSIF
        let condition = try expression()
        try expectKeyword("THEN")
        let thenBody = try statements { $0 == "ELSIF" || $0 == "ELSE" || $0 == "END_IF" }
        var elseBody: [SourceStmt]?
        if isKeyword("ELSIF") {
            elseBody = [try elsifClause()]
        } else if isKeyword("ELSE") {
            advance()
            elseBody = try statements { $0 == "END_IF" }
        }
        return SourceStmt(.ifThen(condition, thenBody, elseBody), line: at.line)
    }

    /// `CASE selector OF <labels>: <body> … ELSE <body> END_CASE`. It is sugar for an `IF`/`ELSIF` chain over the
    /// selector, which is why the merge rules, the numeric comparisons and the recovery all behave as they already do.
    private mutating func caseStatement() throws -> SourceStmt {
        let keyword = advance()   // CASE
        let selector = try expression()
        try expectKeyword("OF")
        var arms: [(labels: [(lower: Int, upper: Int)], body: [SourceStmt], line: Int)] = []
        var used: [(lower: Int, upper: Int)] = []
        var elseBody: [SourceStmt]?
        while !isAtEnd, !isKeyword("END_CASE"), !isKeyword("END_PROGRAM"), !isKeyword("END_FUNCTION_BLOCK") {
            if isKeyword("ELSE") {
                advance()
                elseBody = try caseBody()
                break
            }
            let armLine = current.line
            let labels = try caseLabels()
            for label in labels {
                for taken in used where max(label.lower, taken.lower) <= min(label.upper, taken.upper) {
                    throw error("CASE labels overlap: \(label.lower)..\(label.upper) and \(taken.lower)..\(taken.upper)")
                }
                used.append(label)
            }
            let body = try caseBody()
            arms.append((labels, body, armLine))
        }
        try expectKeyword("END_CASE")
        try expectSymbol(";")

        var fallback = elseBody
        for arm in arms.reversed() {
            fallback = [SourceStmt(.ifThen(caseCondition(selector: selector, labels: arm.labels, line: arm.line),
                                           arm.body, fallback), line: arm.line)]
        }
        if let only = fallback, only.count == 1 { return only[0] }
        if let fallback { return SourceStmt(.ifThen(SourceExpr(.boolean(true), line: keyword.line), fallback, nil), line: keyword.line) }
        return SourceStmt(.ifThen(SourceExpr(.boolean(false), line: keyword.line), [], nil), line: keyword.line)
    }

    /// Statements of one CASE arm or the ELSE arm: they end at the next label, `ELSE` or `END_CASE`.
    private mutating func caseBody() throws -> [SourceStmt] {
        var body: [SourceStmt] = []
        while !isAtEnd, !isKeyword("ELSE"), !isKeyword("END_CASE"), !isKeyword("END_PROGRAM"),
              !isKeyword("END_FUNCTION_BLOCK"), !isCaseLabelStart() {
            if isSymbol(";") { advance(); continue }
            body.append(try statement())
        }
        return body
    }

    private func isCaseLabelStart() -> Bool {
        current.kind == .integer || (isSymbol("-") && peek().kind == .integer)
    }

    private mutating func caseLabels() throws -> [(lower: Int, upper: Int)] {
        var labels: [(lower: Int, upper: Int)] = []
        while true {
            let lower = try signedInteger()
            if isSymbol("..") {
                advance()
                let upper = try signedInteger()
                guard lower <= upper else { throw error("a CASE range must count upwards") }
                labels.append((lower, upper))
            } else {
                labels.append((lower, lower))
            }
            if isSymbol(",") { advance(); continue }
            break
        }
        try expectSymbol(":")
        return labels
    }

    private mutating func signedInteger() throws -> Int {
        var negative = false
        if isSymbol("-") { advance(); negative = true }
        guard current.kind == .integer else { throw error("a CASE label is a whole number") }
        let token = advance()
        guard let value = Int(token.text) else { throw error("the number \(token.text) is too large", at: token) }
        return negative ? -value : value
    }

    private func caseCondition(selector: SourceExpr, labels: [(lower: Int, upper: Int)], line: Int) -> SourceExpr {
        var combined: SourceExpr?
        for label in labels {
            let test: SourceExpr
            if label.lower == label.upper {
                test = SourceExpr(.binary("==", selector, SourceExpr(.integer(label.lower), line: line)), line: line)
            } else {
                let lower = SourceExpr(.binary(">=", selector, SourceExpr(.integer(label.lower), line: line)), line: line)
                let upper = SourceExpr(.binary("<=", selector, SourceExpr(.integer(label.upper), line: line)), line: line)
                test = SourceExpr(.binary("&&", lower, upper), line: line)
            }
            if let existing = combined {
                combined = SourceExpr(.binary("||", existing, test), line: line)
            } else {
                combined = test
            }
        }
        return combined ?? SourceExpr(.boolean(false), line: line)
    }

    private mutating func argumentList() throws -> [SourceArgument] {
        try expectSymbol("(")
        var arguments: [SourceArgument] = []
        if isSymbol(")") { advance(); return arguments }
        var seen: Set<String> = []
        while true {
            guard current.kind == .identifier, peek().kind == .symbol, peek().text == ":=" else {
                throw error("an argument is 'name := value'")
            }
            let label = advance().text
            advance()   // :=
            if !seen.insert(label.lowercased()).inserted {
                throw error("'\(label)' is given twice")
            }
            arguments.append(SourceArgument(label: label, value: try expression()))
            if isSymbol(",") { advance(); continue }
            break
        }
        try expectSymbol(")")
        return arguments
    }

    // MARK: Expressions

    private mutating func expression() throws -> SourceExpr { try orExpression() }

    private mutating func orExpression() throws -> SourceExpr {
        var left = try xorExpression()
        while isKeyword("OR") {
            let token = advance()
            left = SourceExpr(.binary("||", left, try xorExpression()), line: token.line)
        }
        return left
    }

    private mutating func xorExpression() throws -> SourceExpr {
        var left = try andExpression()
        while isKeyword("XOR") {
            let token = advance()
            left = SourceExpr(.binary("xor", left, try andExpression()), line: token.line)
        }
        return left
    }

    private mutating func andExpression() throws -> SourceExpr {
        var left = try notExpression()
        while isKeyword("AND") {
            let token = advance()
            left = SourceExpr(.binary("&&", left, try notExpression()), line: token.line)
        }
        return left
    }

    private mutating func notExpression() throws -> SourceExpr {
        if isKeyword("NOT") {
            let token = advance()
            return SourceExpr(.unary("!", try notExpression()), line: token.line)
        }
        return try comparisonExpression()
    }

    private mutating func comparisonExpression() throws -> SourceExpr {
        var left = try additiveExpression()
        while isSymbol("=") || isSymbol("<>") || isSymbol("<") || isSymbol(">")
                || isSymbol("<=") || isSymbol(">=") {
            let token = advance()
            let op: String
            switch token.text {
            case "=": op = "=="
            case "<>": op = "!="
            default: op = token.text
            }
            left = SourceExpr(.binary(op, left, try notExpression()), line: token.line)
        }
        return left
    }

    private mutating func additiveExpression() throws -> SourceExpr {
        var left = try multiplicativeExpression()
        while isSymbol("+") || isSymbol("-") {
            let token = advance()
            left = SourceExpr(.binary(token.text, left, try multiplicativeExpression()), line: token.line)
        }
        return left
    }

    private mutating func multiplicativeExpression() throws -> SourceExpr {
        var left = try unaryExpression()
        while isSymbol("*") || isSymbol("/") || isKeyword("MOD") {
            let token = advance()
            left = SourceExpr(.binary(token.text.uppercased() == "MOD" ? "%" : token.text,
                                      left, try unaryExpression()), line: token.line)
        }
        return left
    }

    private mutating func unaryExpression() throws -> SourceExpr {
        if isSymbol("-") {
            let token = advance()
            return SourceExpr(.unary("-", try unaryExpression()), line: token.line)
        }
        return try primaryExpression()
    }

    private mutating func primaryExpression() throws -> SourceExpr {
        let token = current
        if token.kind == .integer {
            advance()
            guard let value = Int(token.text) else {
                throw error("the number \(token.text) is too large", at: token)
            }
            return SourceExpr(.integer(value), line: token.line)
        }
        if token.kind == .real {
            advance()
            guard let value = Double(token.text) else {
                throw error("the number \(token.text) is not a real", at: token)
            }
            return SourceExpr(.real(value), line: token.line)
        }
        if isKeyword("TRUE") || isKeyword("FALSE") {
            advance()
            return SourceExpr(.boolean(token.text.uppercased() == "TRUE"), line: token.line)
        }
        if isSymbol("(") {
            advance()
            let inner = try expression()
            try expectSymbol(")")
            return inner
        }
        if token.kind == .identifier {
            advance()
            var base = SourceExpr(.name(token.text), line: token.line)
            while isSymbol(".") {
                advance()
                guard current.kind == .identifier else {
                    throw error("expected an output name after '.'")
                }
                let member = advance()
                base = SourceExpr(.member(base, member.text), line: member.line)
            }
            return base
        }
        throw error("expected an expression but found \(describe(token))")
    }
}

// MARK: - Tokens

struct STToken: Equatable {
    enum Kind: Equatable { case identifier, integer, real, keyword, symbol, endOfFile }
    var kind: Kind
    var text: String
    var line: Int
    var column: Int
}

/// The lexer: identifiers and keywords (case-insensitive), integers, the operators of the subset, `(* … *)` and `//`
/// comments.
struct STLexer {
    private let scalars: [Character]
    private var index = 0
    private var line = 1
    private var column = 1

    static let keywords: Set<String> = [
        "PROGRAM", "END_PROGRAM", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK",
        "VAR", "END_VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_GLOBAL", "CONSTANT", "RETAIN",
        "IF", "THEN", "ELSIF", "ELSE", "END_IF", "CASE", "OF", "END_CASE",
        "AND", "OR", "XOR", "NOT", "MOD", "AT",
        "TRUE", "FALSE",
        "BOOL", "INT", "LONG", "REAL", "LREAL", "WORD",
    ]

    static let symbols = [":=", "<=", ">=", "<>", "..", ";", ":", ",", "(", ")", ".", "%",
                          "*", "/", "+", "-", "=", "<", ">"]

    init(_ source: String) { scalars = Array(source) }

    static func tokenize(_ source: String) throws -> [STToken] {
        var lexer = STLexer(source)
        return try lexer.run()
    }

    private var current: Character? { index < scalars.count ? scalars[index] : nil }
    private func peek(_ offset: Int) -> Character? {
        let i = index + offset
        return i < scalars.count ? scalars[i] : nil
    }
    private mutating func advance() -> Character? {
        guard index < scalars.count else { return nil }
        let c = scalars[index]
        index += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    private mutating func run() throws -> [STToken] {
        var tokens: [STToken] = []
        while true {
            try skipTrivia()
            guard let c = current else { break }
            let startLine = line, startColumn = column
            if c.isLetter || c == "_" {
                var text = ""
                while let d = current, d.isLetter || d.isNumber || d == "_" { text.append(advance()!) }
                let upper = text.uppercased()
                tokens.append(STToken(kind: Self.keywords.contains(upper) ? .keyword : .identifier,
                                      text: Self.keywords.contains(upper) ? upper : text,
                                      line: startLine, column: startColumn))
            } else if c.isNumber {
                var text = ""
                while let d = current, d.isNumber { text.append(advance()!) }
                var kind = STToken.Kind.integer
                if current == ".", let next = peek(1), next.isNumber {
                    text.append(advance()!)
                    while let d = current, d.isNumber { text.append(advance()!) }
                    kind = .real
                }
                tokens.append(STToken(kind: kind, text: text, line: startLine, column: startColumn))
            } else if let symbol = Self.symbols.first(where: { symbol in
                var i = index
                for ch in symbol {
                    guard i < scalars.count, scalars[i] == ch else { return false }
                    i += 1
                }
                return true
            }) {
                for _ in symbol { _ = advance() }
                tokens.append(STToken(kind: .symbol, text: symbol, line: startLine, column: startColumn))
            } else {
                throw SourceError(line: line, column: column, message: "unexpected character '\(c)'")
            }
        }
        tokens.append(STToken(kind: .endOfFile, text: "", line: line, column: column))
        return tokens
    }

    private mutating func skipTrivia() throws {
        while let c = current {
            if c == " " || c == "\t" || c.isNewline {
                _ = advance()
            } else if c == "/" && peek(1) == "/" {
                while let d = current, !d.isNewline { _ = advance() }
            } else if c == "(" && peek(1) == "*" {
                let startLine = line
                _ = advance(); _ = advance()
                var depth = 1
                while let d = current {
                    if d == "(" && peek(1) == "*" {
                        _ = advance(); _ = advance()
                        depth += 1
                    } else if d == "*" && peek(1) == ")" {
                        _ = advance(); _ = advance()
                        depth -= 1
                        if depth == 0 { break }
                    } else {
                        _ = advance()
                    }
                }
                if depth > 0 { throw SourceError(line: startLine, message: "an unterminated (* comment") }
            } else {
                return
            }
        }
    }
}
