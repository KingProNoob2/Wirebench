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
        /// `a[3]`: one element of a declared array.
        case element(SourceExpr, SourceExpr)
        /// `Add(1, 2)`: a call of a declared FUNCTION, inlined at lowering.
        case functionCall(String, [SourceExpr])
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
        /// `a[3] := value;` — a write into the PLC array store.
        case arrayAssign(String, SourceExpr, SourceExpr)
        /// `t(value := x);`: calls a function-block or block instance with named arguments.
        case call(String, [SourceArgument])
        case ifThen(SourceExpr, [SourceStmt], [SourceStmt]?)
        /// A sequence of statements: an unrolled loop, lowered inline (not as an IF branch).
        case block([SourceStmt])
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

/// One `VAR_INPUT` parameter of a `FUNCTION`.
public struct SourceParameter: Equatable, Sendable {
    public var name: String
    public var type: SourceType
    public var line: Int

    public init(name: String, type: SourceType, line: Int) {
        self.name = name
        self.type = type
        self.line = line
    }
}

/// `FUNCTION Add : INT VAR_INPUT a, b : INT; END_VAR Add := a + b; END_FUNCTION` — a pure expression with
/// parameters, inlined at every call.
public struct SourceFunction: Equatable, Sendable {
    public var name: String
    public var returnType: SourceType
    public var parameters: [SourceParameter]
    /// `VAR` locals, assigned in the body; inlined as expression bindings.
    public var locals: [SourceVariable]
    /// Straight-line assignments to locals and to the function's own name (its return value).
    public var statements: [SourceStmt]
    public var line: Int

    public init(name: String, returnType: SourceType, parameters: [SourceParameter],
                locals: [SourceVariable] = [], statements: [SourceStmt], line: Int) {
        self.name = name
        self.returnType = returnType
        self.parameters = parameters
        self.locals = locals
        self.statements = statements
        self.line = line
    }
}

/// `a : ARRAY[0..15] OF INT;` — an array in the PLC data area, addressed by index.
public struct SourceArray: Equatable, Sendable {
    public var name: String
    public var lower: Int
    public var upper: Int
    public var type: SourceType
    public var line: Int

    public init(name: String, lower: Int, upper: Int, type: SourceType, line: Int) {
        self.name = name
        self.lower = lower
        self.upper = upper
        self.type = type
        self.line = line
    }

    public var length: Int { upper - lower + 1 }
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
    public var arrays: [SourceArray]
    public var instances: [SourceInstance]
    public var body: [SourceStmt]
    public var line: Int

    public init(name: String, kind: Kind, pins: [SourcePin] = [], variables: [SourceVariable] = [],
                arrays: [SourceArray] = [], instances: [SourceInstance] = [], body: [SourceStmt] = [], line: Int) {
        self.name = name
        self.kind = kind
        self.pins = pins
        self.variables = variables
        self.arrays = arrays
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
    public var functions: [SourceFunction]

    public init(units: [SourceUnit] = [], functions: [SourceFunction] = []) {
        self.units = units
        self.functions = functions
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
    /// The unit being parsed, so `FOR` can check the index's declared type while its statements are read.
    private var currentUnit: SourceUnit?
    /// Expressions the parser has seen assigned unconditionally so far in this statement sequence. A `FOR` starts
    /// from these, so a loop continues from a value assigned earlier in the same scan instead of the scan-start value.
    private var sequenceBindings: [String: SourceExpr] = [:]

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
        var functions: [SourceFunction] = []
        while !isAtEnd {
            if isKeyword("PROGRAM") {
                units.append(try unit(.program))
            } else if isKeyword("FUNCTION_BLOCK") {
                units.append(try unit(.functionBlock))
            } else if isKeyword("FUNCTION") {
                functions.append(try functionDeclaration())
            } else {
                throw error("expected PROGRAM, FUNCTION_BLOCK or FUNCTION but found \(describe(current))")
            }
        }
        guard units.contains(where: { $0.kind == .program }) else {
            throw SourceError(line: 1, message: "the file declares no PROGRAM; write 'PROGRAM Main ... END_PROGRAM'")
        }
        let names = (units.map(\.name) + functions.map(\.name)).map { $0.lowercased() }
        if Set(names).count != names.count {
            throw SourceError(line: 1, message: "two programs, function blocks or functions have the same name")
        }
        return SourceProgram(units: units, functions: functions)
    }

    /// `FUNCTION name : TYPE VAR_INPUT p : TYPE; END_VAR name := expression; END_FUNCTION`.
    private mutating func functionDeclaration() throws -> SourceFunction {
        let keyword = advance()   // FUNCTION
        let nameToken = try expectIdentifier("a name after FUNCTION")
        let name = nameToken.text
        try expectSymbol(":")
        let returnType = try scalarType("a FUNCTION return type")
        var parameters: [SourceParameter] = []
        if isKeyword("VAR_INPUT") {
            advance()
            while !isKeyword("END_VAR") {
                if isAtEnd { throw error("the VAR_INPUT block is not closed with END_VAR") }
                let parameterToken = try expectIdentifier("a parameter name")
                try expectSymbol(":")
                let type = try scalarType("a parameter type")
                try expectSymbol(";")
                guard !parameters.contains(where: { $0.name.lowercased() == parameterToken.text.lowercased() }) else {
                    throw error("'\(parameterToken.text)' is declared twice")
                }
                parameters.append(SourceParameter(name: parameterToken.text, type: type, line: parameterToken.line))
            }
            advance()   // END_VAR
        }
        var locals: [SourceVariable] = []
        if isKeyword("VAR") {
            advance()
            while !isKeyword("END_VAR") {
                if isAtEnd { throw error("the VAR block is not closed with END_VAR") }
                let localToken = try expectIdentifier("a local name")
                try expectSymbol(":")
                let type = try scalarType("a local type")
                var initial: SourceLiteral?
                if isSymbol(":=") {
                    initial = try initialValue(for: type)
                }
                try expectSymbol(";")
                guard !parameters.contains(where: { $0.name.lowercased() == localToken.text.lowercased() })
                        && !locals.contains(where: { $0.name.lowercased() == localToken.text.lowercased() })
                        && localToken.text.lowercased() != name.lowercased() else {
                    throw error("'\(localToken.text)' is declared twice")
                }
                locals.append(SourceVariable(name: localToken.text, type: type, initial: initial, line: localToken.line))
            }
            advance()   // END_VAR
        }
        if isKeyword("VAR_OUTPUT") || isKeyword("VAR_IN_OUT") {
            throw error("a FUNCTION has VAR_INPUT parameters and VAR locals only")
        }
        let body = try statements { $0 == "END_FUNCTION" }
        try expectKeyword("END_FUNCTION")
        guard !body.isEmpty else { throw error("a FUNCTION body is empty") }
        let parameterNames = Set(parameters.map { $0.name.lowercased() })
        let localNames = Set(locals.map { $0.name.lowercased() })
        let allowed = parameterNames.union(localNames).union([name.lowercased()])
        for statement in body {
            try validateFunctionStatement(statement, function: name, parameters: parameterNames,
                                          locals: localNames, allowed: allowed)
        }
        guard assignsFunctionName(body, function: name) else {
            throw error("a FUNCTION body must assign its name, as in '\(name) := …;'")
        }
        return SourceFunction(name: name, returnType: returnType, parameters: parameters, locals: locals,
                              statements: body, line: keyword.line)
    }

    private mutating func scalarType(_ what: String) throws -> SourceType {
        let declared = try typeName()
        guard case .scalar(let type) = declared else {
            throw error("\(what) must be BOOL, INT, LONG or REAL")
        }
        return type
    }

    /// A FUNCTION body may assign locals and its own name, with `IF`/`CASE`; anything else is refused. Expressions
    /// may use parameters, locals and the function name (the last is the return value). Whether a name is assigned on
    /// every path is checked while inlining, so a local read with no value is reported there.
    private func validateFunctionStatement(_ statement: SourceStmt, function: String, parameters: Set<String>,
                                           locals: Set<String>, allowed: Set<String>) throws {
        switch statement.kind {
        case .assign(let target, let expression):
            if parameters.contains(target.lowercased()) {
                throw SourceError(line: statement.line,
                                  message: "a FUNCTION parameter ('\(target)') is read-only; copy it to a local")
            }
            guard target.lowercased() == function.lowercased() || locals.contains(target.lowercased()) else {
                throw SourceError(line: statement.line,
                                  message: "'\(target)' is not a local of '\(function)'; assign locals or '\(function)'")
            }
            try validateFunctionExpression(expression, allowed: allowed, function: function)
        case .ifThen(let condition, let thenBody, let elseBody):
            try validateFunctionExpression(condition, allowed: allowed, function: function)
            for inner in thenBody {
                try validateFunctionStatement(inner, function: function, parameters: parameters,
                                              locals: locals, allowed: allowed)
            }
            for inner in elseBody ?? [] {
                try validateFunctionStatement(inner, function: function, parameters: parameters,
                                              locals: locals, allowed: allowed)
            }
        default:
            throw SourceError(line: statement.line,
                              message: "a FUNCTION body allows assignments and IF/CASE only (no loops, calls as statements or arrays)")
        }
    }

    private func validateFunctionExpression(_ expression: SourceExpr, allowed: Set<String>, function: String) throws {
        switch expression.kind {
        case .boolean, .integer, .real:
            break
        case .name(let name):
            guard allowed.contains(name.lowercased()) else {
                throw SourceError(line: expression.line,
                                  message: "'\(name)' is not a parameter or local of '\(function)'")
            }
        case .member, .element:
            throw SourceError(line: expression.line,
                              message: "a FUNCTION body cannot read instances or arrays")
        case .unary(_, let operand):
            try validateFunctionExpression(operand, allowed: allowed, function: function)
        case .binary(_, let left, let right):
            try validateFunctionExpression(left, allowed: allowed, function: function)
            try validateFunctionExpression(right, allowed: allowed, function: function)
        case .functionCall(_, let arguments):
            for argument in arguments { try validateFunctionExpression(argument, allowed: allowed, function: function) }
        }
    }

    private func assignsFunctionName(_ statements: [SourceStmt], function: String) -> Bool {
        for statement in statements {
            switch statement.kind {
            case .assign(let target, _) where target.lowercased() == function.lowercased():
                return true
            case .ifThen(_, let thenBody, let elseBody):
                if assignsFunctionName(thenBody, function: function)
                    || assignsFunctionName(elseBody ?? [], function: function) { return true }
            default:
                break
            }
        }
        return false
    }

    private mutating func unit(_ kind: SourceUnit.Kind) throws -> SourceUnit {
        let keyword = advance()
        let name = try expectIdentifier("a name after \(kind == .program ? "PROGRAM" : "FUNCTION_BLOCK")").text
        var unit = SourceUnit(name: name, kind: kind, line: keyword.line)
        currentUnit = unit
        sequenceBindings = [:]
        var sawStatement = false
        while !isAtEnd {
            if kind == .program && isKeyword("END_PROGRAM") { advance(); return unit }
            if kind == .functionBlock && isKeyword("END_FUNCTION_BLOCK") { advance(); return unit }
            if isKeyword("VAR") || isKeyword("VAR_INPUT") || isKeyword("VAR_OUTPUT") {
                if sawStatement { throw error("declare every variable before the first statement") }
                try variableBlock(into: &unit)
                currentUnit = unit
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
            if isKeyword("ARRAY") {
                guard region == "VAR", address == nil else {
                    throw error("an ARRAY is declared in a plain VAR block")
                }
                guard unit.kind == .program else {
                    throw error("an ARRAY is only supported in a PROGRAM; a function block's array would share the PLC's Ids")
                }
                let array = try arrayDeclaration(name: name, line: nameToken.line)
                guard !isNameTaken(name, in: unit) else { throw error("'\(name)' is declared twice") }
                guard unit.arrays.count < 16 else {
                    throw error("this subset has at most 16 arrays (the PLC's Id range 0–15)")
                }
                unit.arrays.append(array)
                try expectSymbol(";")
                continue
            }
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
            || unit.arrays.contains { $0.name.lowercased() == folded }
            || unit.instances.contains { $0.name.lowercased() == folded }
            || unit.pins.contains { $0.name.lowercased() == folded }
    }

    /// `ARRAY[0..15] OF INT` after the colon and name have been read.
    private mutating func arrayDeclaration(name: String, line: Int) throws -> SourceArray {
        advance()   // ARRAY
        try expectSymbol("[")
        let lower = try signedInteger("an ARRAY bound")
        try expectSymbol("..")
        let upper = try signedInteger("an ARRAY bound")
        try expectSymbol("]")
        try expectKeyword("OF")
        let element = try typeName()
        guard case .scalar(let type) = element else {
            throw error("an ARRAY element type must be BOOL? No — INT, LONG or REAL")
        }
        guard type != .bool else { throw error("a BOOL array has no block; use INT, LONG or REAL") }
        guard lower <= upper else { throw error("an ARRAY range must count upwards") }
        guard abs(lower) <= 1_000_000, abs(upper) <= 1_000_000 else {
            throw error("an ARRAY bound is too large; keep it within ±1,000,000")
        }
        guard upper - lower + 1 <= 4096 else { throw error("an ARRAY of \(upper - lower + 1) elements is too large") }
        return SourceArray(name: name, lower: lower, upper: upper, type: type, line: line)
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
            let statement = try statement()
            statements.append(statement)
            updateBindings(from: statement, index: "", into: &sequenceBindings)
        }
        return statements
    }

    private mutating func statement() throws -> SourceStmt {
        if isKeyword("IF") { return try ifStatement() }
        if isKeyword("CASE") { return try caseStatement() }
        if isKeyword("FOR") { return try forStatement() }
        if isKeyword("WHILE") {
            throw error("WHILE is not supported: a loop over a live condition cannot be dataflow; use FOR with constant bounds or a counter")
        }
        if isKeyword("REPEAT") {
            throw error("REPEAT is not supported: a loop over a live condition cannot be dataflow; use FOR with constant bounds or a counter")
        }
        guard current.kind == .identifier else {
            throw error("expected a statement but found \(describe(current))")
        }
        let name = advance()
        if isSymbol("[") {
            advance()
            let index = try expression()
            try expectSymbol("]")
            try expectSymbol(":=")
            let value = try expression()
            try expectSymbol(";")
            return SourceStmt(.arrayAssign(name.text, index, value), line: name.line)
        }
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
        let saved = sequenceBindings
        let thenBody = try statements { $0 == "ELSIF" || $0 == "ELSE" || $0 == "END_IF" }
        sequenceBindings = saved
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
        sequenceBindings = saved
        for name in assignedNames(in: thenBody).union(assignedNames(in: elseBody ?? [])) {
            sequenceBindings.removeValue(forKey: name.lowercased())
        }
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

    private mutating func signedInteger(_ what: String = "a CASE label") throws -> Int {
        var negative = false
        if isSymbol("-") { advance(); negative = true }
        guard current.kind == .integer else { throw error("\(what) is a whole number") }
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

    /// `FOR i := 1 TO 3 [BY step] DO … END_FOR`. The loop is unrolled at compile time: bounds and step must be
    /// whole-number literals, the body is capped at 256 iterations, and reads of the index and of variables assigned
    /// earlier in the unrolled body are substituted with their expressions so the sequence keeps the loop's meaning.
    /// The index is a compile-time binding: it is not written to a runtime variable after the loop.
    private mutating func forStatement() throws -> SourceStmt {
        let keyword = advance()   // FOR
        let indexToken = try expectIdentifier("a loop variable")
        let index = indexToken.text
        let declaredVariables = currentUnit?.variables ?? []
        if let variable = declaredVariables.first(where: { $0.name.lowercased() == index.lowercased() }),
           variable.type != .int && variable.type != .long {
            throw error("a FOR index is INT or LONG, not \(variable.type.name)")
        }
        try expectSymbol(":=")
        let start = try signedInteger("a FOR bound")
        try expectKeyword("TO")
        let end = try signedInteger("a FOR bound")
        var step = 1
        if isKeyword("BY") {
            advance()
            step = try signedInteger("a FOR step")
        }
        guard step != 0 else { throw error("a FOR step cannot be zero") }
        guard abs(start) <= 1_000_000, abs(end) <= 1_000_000, abs(step) <= 1_000_000 else {
            throw error("FOR bounds are too large; keep start, end and step within ±1,000,000")
        }
        try expectKeyword("DO")
        let seed = sequenceBindings
        let body = try statements { $0 == "END_FOR" }
        sequenceBindings = seed
        try expectKeyword("END_FOR")
        try expectSymbol(";")

        // The iteration values, in order, bounded before anything is expanded.
        var values: [Int] = []
        var value = start
        if step > 0 {
            while value <= end, values.count < 257 { values.append(value); value += step }
        } else {
            while value >= end, values.count < 257 { values.append(value); value += step }
        }
        guard values.count <= 256 else {
            throw error("this FOR unrolls to more than 256 iterations; the cap is 256")
        }

        var bindings = seed
        var unrolled: [SourceStmt] = []
        var nodes = 0
        for iteration in values {
            for statement in body {
                let substituted = try substitute(statement, index: index, value: iteration, bindings: bindings)
                // Substituting `n := n + n` grows exponentially; stop before a small loop becomes a huge tree.
                nodes += nodeCount(substituted)
                guard nodes <= 50_000 else {
                    throw error("this FOR body grows too large when unrolled; simplify the loop")
                }
                unrolled.append(substituted)
                updateBindings(from: substituted, index: index, into: &bindings)
            }
        }
        return SourceStmt(.block(unrolled), line: keyword.line)
    }

    private func substitute(_ statement: SourceStmt, index: String, value: Int,
                            bindings: [String: SourceExpr]) throws -> SourceStmt {
        switch statement.kind {
        case .assign(let target, let expression):
            guard target.lowercased() != index.lowercased() else {
                throw SourceError(line: statement.line,
                                  message: "a FOR index cannot be assigned inside the loop")
            }
            return SourceStmt(.assign(target, substitute(expression, index: index, value: value, bindings: bindings)),
                              line: statement.line)
        case .arrayAssign(let name, let indexExpression, let expression):
            return SourceStmt(.arrayAssign(name,
                                           substitute(indexExpression, index: index, value: value, bindings: bindings),
                                           substitute(expression, index: index, value: value, bindings: bindings)),
                              line: statement.line)
        case .call(let name, let arguments):
            return SourceStmt(.call(name, arguments.map {
                SourceArgument(label: $0.label,
                               value: substitute($0.value, index: index, value: value, bindings: bindings))
            }), line: statement.line)
        case .ifThen(let condition, let thenBody, let elseBody):
            var thenSub: [SourceStmt] = []
            for inner in thenBody {
                thenSub.append(try substitute(inner, index: index, value: value, bindings: bindings))
            }
            var elseSub: [SourceStmt]?
            if let elseBody {
                var bodies: [SourceStmt] = []
                for inner in elseBody {
                    bodies.append(try substitute(inner, index: index, value: value, bindings: bindings))
                }
                elseSub = bodies
            }
            return SourceStmt(.ifThen(substitute(condition, index: index, value: value, bindings: bindings),
                                      thenSub, elseSub), line: statement.line)
        case .block(let body):
            return SourceStmt(.block(try body.map { try substitute($0, index: index, value: value, bindings: bindings) }),
                              line: statement.line)
        }
    }

    private func substitute(_ expression: SourceExpr, index: String, value: Int,
                            bindings: [String: SourceExpr]) -> SourceExpr {
        switch expression.kind {
        case .name(let name):
            if name.lowercased() == index.lowercased() { return SourceExpr(.integer(value), line: expression.line) }
            if let bound = bindings[name.lowercased()] { return bound }
            return expression
        case .member(let base, let member):
            return SourceExpr(.member(substitute(base, index: index, value: value, bindings: bindings), member),
                              line: expression.line)
        case .element(let base, let subscriptIndex):
            return SourceExpr(.element(substitute(base, index: index, value: value, bindings: bindings),
                                          substitute(subscriptIndex, index: index, value: value, bindings: bindings)),
                              line: expression.line)
        case .functionCall(let name, let arguments):
            return SourceExpr(.functionCall(name, arguments.map {
                substitute($0, index: index, value: value, bindings: bindings)
            }), line: expression.line)
        case .unary(let op, let operand):
            return SourceExpr(.unary(op, substitute(operand, index: index, value: value, bindings: bindings)),
                              line: expression.line)
        case .binary(let op, let left, let right):
            return SourceExpr(.binary(op,
                                      substitute(left, index: index, value: value, bindings: bindings),
                                      substitute(right, index: index, value: value, bindings: bindings)),
                              line: expression.line)
        case .boolean, .integer, .real:
            return expression
        }
    }

    /// Walks the substituted statements in order and remembers the expression a variable was last assigned. A
    /// conditional write cannot be substituted safely, so it drops the bindings for everything it may assign.
    private func updateBindings(from statement: SourceStmt, index: String, into bindings: inout [String: SourceExpr]) {
        switch statement.kind {
        case .assign(let target, let expression):
            guard target.lowercased() != index.lowercased() else { return }
            bindings[target.lowercased()] = expression
        case .block(let body):
            for inner in body { updateBindings(from: inner, index: index, into: &bindings) }
        case .ifThen(_, let thenBody, let elseBody):
            for name in assignedNames(in: thenBody).union(assignedNames(in: elseBody ?? [])) {
                bindings.removeValue(forKey: name.lowercased())
            }
        case .call, .arrayAssign:
            break
        }
    }

    private func nodeCount(_ statement: SourceStmt) -> Int {
        switch statement.kind {
        case .assign(_, let expression): return 1 + nodeCount(expression)
        case .arrayAssign(_, let indexExpression, let expression):
            return 1 + nodeCount(indexExpression) + nodeCount(expression)
        case .call(_, let arguments): return 1 + arguments.reduce(0) { $0 + nodeCount($1.value) }
        case .ifThen(let condition, let thenBody, let elseBody):
            return 1 + nodeCount(condition) + thenBody.reduce(0) { $0 + nodeCount($1) }
                + (elseBody ?? []).reduce(0) { $0 + nodeCount($1) }
        case .block(let body): return 1 + body.reduce(0) { $0 + nodeCount($1) }
        }
    }

    private func nodeCount(_ expression: SourceExpr) -> Int {
        switch expression.kind {
        case .boolean, .integer, .real: return 1
        case .name: return 1
        case .member(let base, _): return 1 + nodeCount(base)
        case .element(let base, let indexExpression): return 1 + nodeCount(base) + nodeCount(indexExpression)
        case .functionCall(_, let arguments): return 1 + arguments.reduce(0) { $0 + nodeCount($1) }
        case .unary(_, let operand): return 1 + nodeCount(operand)
        case .binary(_, let left, let right): return 1 + nodeCount(left) + nodeCount(right)
        }
    }

    private func assignedNames(in statements: [SourceStmt]) -> Set<String> {
        var names: Set<String> = []
        for statement in statements {
            switch statement.kind {
            case .assign(let target, _): names.insert(target)
            case .block(let body): names.formUnion(assignedNames(in: body))
            case .ifThen(_, let thenBody, let elseBody):
                names.formUnion(assignedNames(in: thenBody))
                names.formUnion(assignedNames(in: elseBody ?? []))
            case .call, .arrayAssign: break
            }
        }
        return names
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
            if isSymbol("(") {
                advance()
                var arguments: [SourceExpr] = []
                if !isSymbol(")") {
                    while true {
                        arguments.append(try expression())
                        if isSymbol(",") { advance(); continue }
                        break
                    }
                }
                try expectSymbol(")")
                return SourceExpr(.functionCall(token.text, arguments), line: token.line)
            }
            var base = SourceExpr(.name(token.text), line: token.line)
            if isSymbol("[") {
                advance()
                let index = try expression()
                try expectSymbol("]")
                base = SourceExpr(.element(base, index), line: token.line)
            }
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
        "FOR", "TO", "BY", "DO", "END_FOR", "WHILE", "END_WHILE", "REPEAT", "UNTIL", "END_REPEAT",
        "ARRAY", "OF", "FUNCTION", "END_FUNCTION",
        "AND", "OR", "XOR", "NOT", "MOD", "AT",
        "TRUE", "FALSE",
        "BOOL", "INT", "LONG", "REAL", "LREAL", "WORD",
    ]

    static let symbols = [":=", "<=", ">=", "<>", "..", ";", ":", ",", "(", ")", "[", "]", ".", "%",
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
