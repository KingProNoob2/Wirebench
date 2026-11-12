import Foundation
import SwiftParser
import SwiftSyntax

/// A diagnostic from the source compiler, with the position it happened at.
public struct SwiftSourceError: Error, Equatable, CustomStringConvertible {
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

/// One expression of the subset. Positions are kept so a diagnostic can point at the line that caused it.
public struct SourceExpr: Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case boolean(Bool)
        case integer(Int)
        case name(String)
        /// `t.result`: a property of a macro call instance.
        case member(SourceExpr, String)
        /// A call: `pulse(ms: 500)` or a macro `Toggle(value: button)`.
        case call(String, [SourceArgument])
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
    public var label: String?
    public var value: SourceExpr

    public init(label: String? = nil, value: SourceExpr) {
        self.label = label
        self.value = value
    }
}

public struct SourceStmt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bind(String, SourceExpr)
        case assign(String, SourceExpr)
        case ifThen(SourceExpr, [SourceStmt], [SourceStmt]?)
        /// `name.set(pin, value)`: wires one input of a block created earlier, which is what lets a feedback loop be
        /// written down at all.
        case blockSet(String, Int, SourceExpr)
        case returnVoid
    }

    public var kind: Kind
    public var line: Int

    public init(_ kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }
}

/// A property the struct declares as a pin: `@DI(0)`/`@DO(4)` on a page, `@Input(0)`/`@Output(1)` in a macro.
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

/// A stored property: `var lamp: Bool = false`. This is the program's state, one `BoolVar` and one `Set` per name.
public struct SourceVariable: Equatable, Sendable {
    public var name: String
    public var initial: Bool
    public var line: Int

    public init(name: String, initial: Bool = false, line: Int) {
        self.name = name
        self.initial = initial
        self.line = line
    }
}

public struct SourceFunction: Equatable, Sendable {
    public var name: String
    public var body: [SourceStmt]
    public var line: Int

    public init(name: String, body: [SourceStmt], line: Int) {
        self.name = name
        self.body = body
        self.line = line
    }
}

/// A struct: a page of the project, or — marked `@macro` — a macro page.
public struct SourceUnit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case page, macro }

    public var name: String
    public var kind: Kind
    /// The page the document opens on.
    public var isMain: Bool
    public var pins: [SourcePin]
    public var variables: [SourceVariable]
    public var scan: SourceFunction?
    public var line: Int

    public init(name: String, kind: Kind, isMain: Bool = false, pins: [SourcePin] = [],
                variables: [SourceVariable] = [], scan: SourceFunction? = nil, line: Int) {
        self.name = name
        self.kind = kind
        self.isMain = isMain
        self.pins = pins
        self.variables = variables
        self.scan = scan
        self.line = line
    }

    /// The inputs in declaration order, which is the order of the macro's pins.
    public var inputs: [SourcePin] { pins.filter { $0.direction == .input }.sorted { $0.index < $1.index } }
    public var outputs: [SourcePin] { pins.filter { $0.direction == .output }.sorted { $0.index < $1.index } }
    /// The Dirigo caption: a macro is a `*` sheet, a page keeps its name.
    public var caption: String { kind == .macro ? "*\(name)" : name }
}

public struct SourceProgram: Equatable, Sendable {
    public var units: [SourceUnit]
    public var imports: [String]

    public init(units: [SourceUnit] = [], imports: [String] = []) {
        self.units = units
        self.imports = imports
    }

    public var main: SourceUnit? {
        units.first { $0.isMain && $0.kind == .page } ?? units.first { $0.kind == .page }
    }

    public var macros: [SourceUnit] { units.filter { $0.kind == .macro } }
}

// MARK: - Parser

/// Reads PLC Swift with Swift's own parser, then checks it against the subset.
///
/// The syntax is real Swift — `swift-syntax` builds the tree — so the IDE can use the same parse for highlighting and
/// positions. Each `struct` is a page; `@macro` makes it a macro page, called with `let t = Name(...)` and read with
/// `t.output`. Everything outside the subset is refused with a line and a reason.
public struct SourceParser {
    public static func parse(_ source: String) throws -> SourceProgram {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "source.swift", tree: tree)
        var builder = Builder(converter: converter)
        return try builder.build(tree)
    }

    private struct Builder {
        let converter: SourceLocationConverter

        func line(_ node: some SyntaxProtocol) -> Int {
            converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        }

        func failure(_ node: some SyntaxProtocol, _ message: String) -> SwiftSourceError {
            let position = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            return SwiftSourceError(line: position.line, column: position.column, message: message)
        }

        // MARK: File

        mutating func build(_ file: SourceFileSyntax) throws -> SourceProgram {
            var program = SourceProgram()
            for item in file.statements {
                guard let declaration = item.item.as(DeclSyntax.self) else {
                    throw failure(item, "statements belong inside a struct")
                }
                if let importDecl = declaration.as(ImportDeclSyntax.self) {
                    program.imports.append(importDecl.path.trimmedDescription)
                } else if let structDecl = declaration.as(StructDeclSyntax.self) {
                    program.units.append(try unit(structDecl))
                } else {
                    throw failure(declaration, "expected a struct; each struct is a page")
                }
            }
            guard program.main != nil else {
                throw SwiftSourceError(line: 1, message: "the file declares no page; write 'struct Main { func scan() { ... } }'")
            }
            if program.units.filter({ $0.isMain }).count > 1 {
                throw SwiftSourceError(line: 1, message: "only one struct is '@main'")
            }
            let names = program.units.map { $0.name.lowercased() }
            if Set(names).count != names.count {
                throw SwiftSourceError(line: 1, message: "two structs have the same name")
            }
            return program
        }

        mutating func unit(_ decl: StructDeclSyntax) throws -> SourceUnit {
            if decl.memberBlock.rightBrace.presence == .missing {
                throw failure(decl, "the struct is not closed with '}'")
            }
            var kind = SourceUnit.Kind.page
            var isMain = false
            var sawKind = false
            for attribute in decl.attributes {
                guard let attr = attribute.as(AttributeSyntax.self) else { continue }
                switch attr.attributeName.trimmedDescription {
                case "main": isMain = true
                case "macro":
                    if sawKind { throw failure(attr, "a struct is either '@main' or '@macro', not both") }
                    kind = .macro; sawKind = true
                default:
                    throw failure(attr, "unknown attribute '@\(attr.attributeName.trimmedDescription)'; this subset has @main and @macro")
                }
            }
            if kind == .macro && isMain {
                throw failure(decl, "a macro cannot be '@main'")
            }

            var unit = SourceUnit(name: decl.name.text, kind: kind, isMain: isMain, line: line(decl))
            for member in decl.memberBlock.members {
                if let variable = member.decl.as(VariableDeclSyntax.self) {
                    try property(variable, into: &unit)
                } else if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
                    guard functionDecl.name.text == "scan" else {
                        throw failure(functionDecl, "a struct's function is 'scan'; '\\(functionDecl.name.text)' has no meaning here")
                    }
                    if unit.scan != nil { throw failure(functionDecl, "'scan' is already declared") }
                    unit.scan = try function(functionDecl)
                } else {
                    throw failure(member.decl, "expected 'scan' or a property in the struct")
                }
            }
            guard unit.scan != nil else {
                throw failure(decl, "'\\(decl.name.text)' has no 'scan'")
            }
            return unit
        }

        mutating func property(_ decl: VariableDeclSyntax, into unit: inout SourceUnit) throws {
            guard decl.bindings.count == 1, let binding = decl.bindings.first else {
                throw failure(decl, "one name per property")
            }
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw failure(binding.pattern, "expected a plain name")
            }
            let name = pattern.identifier.text
            if let type = binding.typeAnnotation?.type.trimmedDescription, type != "Bool" {
                throw failure(binding.typeAnnotation!, "only 'Bool' is supported for now, not '\\(type)'")
            }
            let initial = binding.initializer.map { $0.value }
            var declared: (SourcePin.Direction, Int)?

            for attribute in decl.attributes {
                guard let attr = attribute.as(AttributeSyntax.self) else { continue }
                let attributeName = attr.attributeName.trimmedDescription
                let direction: SourcePin.Direction
                switch attributeName {
                case "DI", "Input":
                    guard unit.kind == .page && attributeName == "DI" || unit.kind == .macro && attributeName == "Input" else {
                        throw failure(attr, unit.kind == .page
                                      ? "a page's pins are '@DI' and '@DO'; '@\(attributeName)' belongs in a macro"
                                      : "a macro's pins are '@Input' and '@Output'; '@\(attributeName)' belongs on a page")
                    }
                    direction = .input
                case "DO", "Output":
                    guard unit.kind == .page && attributeName == "DO" || unit.kind == .macro && attributeName == "Output" else {
                        throw failure(attr, unit.kind == .page
                                      ? "a page's pins are '@DI' and '@DO'; '@\(attributeName)' belongs in a macro"
                                      : "a macro's pins are '@Input' and '@Output'; '@\(attributeName)' belongs on a page")
                    }
                    direction = .output
                default:
                    throw failure(attr, "unknown attribute '@\(attributeName)' on a property")
                }
                guard let index = integerArgument(attr) else {
                    throw failure(attr, "'@\(attributeName)' takes an index, as in '@\\(attributeName)(0)'")
                }
                if unit.kind == .page {
                    guard (0...7).contains(index) else {
                        throw failure(attr, "pin \(index) does not exist; there are pins 0 to 7")
                    }
                }
                if unit.pins.contains(where: { $0.direction == direction && $0.index == index }) {
                    throw failure(decl, "\\(attributeName)\\(index) is declared twice")
                }
                declared = (direction, index)
            }

            if let (direction, index) = declared {
                guard decl.bindingSpecifier.text == "var" else {
                    throw failure(decl, "a pin is a 'var'")
                }
                if initial != nil { throw failure(decl, "a pin takes its value from the outside; it has no initial value") }
                unit.pins.append(SourcePin(direction: direction, index: index, name: name, line: line(decl)))
            } else {
                guard decl.bindingSpecifier.text == "var" else {
                    throw failure(decl, "a stored property is a 'var'; 'let' is a constant and belongs inside 'scan'")
                }
                var value = false
                if let initial {
                    guard let literal = booleanLiteral(initial) else {
                        throw failure(initial, "a variable's initial value is 'true' or 'false' for now")
                    }
                    value = literal
                }
                if unit.variables.contains(where: { $0.name == name }) || unit.pins.contains(where: { $0.name == name }) {
                    throw failure(decl, "'\\(name)' is declared twice")
                }
                unit.variables.append(SourceVariable(name: name, initial: value, line: line(decl)))
            }
        }

        func integerArgument(_ attr: AttributeSyntax) -> Int? {
            guard case .argumentList(let arguments) = attr.arguments,
                  let first = arguments.first,
                  let literal = first.expression.as(IntegerLiteralExprSyntax.self) else { return nil }
            return Int(literal.literal.text)
        }

        func booleanLiteral(_ expr: ExprSyntax) -> Bool? {
            guard let literal = expr.as(BooleanLiteralExprSyntax.self) else { return nil }
            return literal.literal.text == "true"
        }

        // MARK: Functions and statements

        mutating func function(_ decl: FunctionDeclSyntax) throws -> SourceFunction {
            guard decl.signature.parameterClause.parameters.isEmpty else {
                throw failure(decl, "a function takes no parameters in this subset; a macro's values are its properties")
            }
            if let returnClause = decl.signature.returnClause {
                throw failure(returnClause, "a function returns nothing in this subset")
            }
            guard let body = decl.body else {
                throw failure(decl, "'\\(decl.name.text)' has no body")
            }
            if body.rightBrace.presence == .missing {
                throw failure(decl, "'\\(decl.name.text)' is not closed with '}'")
            }
            return SourceFunction(name: decl.name.text, body: try statements(body.statements), line: line(decl))
        }

        mutating func statements(_ list: CodeBlockItemListSyntax) throws -> [SourceStmt] {
            var statements: [SourceStmt] = []
            for item in list {
                if let decl = item.item.as(DeclSyntax.self) {
                    guard let variable = decl.as(VariableDeclSyntax.self) else {
                        throw failure(decl, "only 'let' belongs inside 'scan'")
                    }
                    statements.append(try letBinding(variable))
                } else if let expr = item.item.as(ExprSyntax.self) {
                    statements.append(try expressionStatement(expr))
                } else if let stmt = item.item.as(StmtSyntax.self) {
                    statements.append(try statement(stmt))
                } else {
                    throw failure(item, "this statement is not supported")
                }
            }
            return statements
        }

        mutating func letBinding(_ decl: VariableDeclSyntax) throws -> SourceStmt {
            guard decl.bindingSpecifier.text == "let" else {
                throw failure(decl, "a local 'var' is not a block yet: use 'let', or a stored property for state")
            }
            guard decl.bindings.count == 1, let binding = decl.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let initializer = binding.initializer else {
                throw failure(decl, "expected 'let name = value'")
            }
            return SourceStmt(.bind(pattern.identifier.text, try expression(initializer.value)), line: line(decl))
        }

        /// An expression used as a statement: an assignment, or an `if` (which is an expression in Swift's grammar).
        mutating func expressionStatement(_ expr: ExprSyntax) throws -> SourceStmt {
            if let seq = expr.as(SequenceExprSyntax.self) {
                let elements = Array(seq.elements)
                // `beep = enable && pulse(ms: 500)` is one operator sequence: [beep, =, enable, &&, pulse]. The right
                // side is every element after the `=`, folded like any other expression.
                if elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) {
                    guard let target = elements[0].as(DeclReferenceExprSyntax.self) else {
                        throw failure(seq, "the left side of an assignment has to be a name")
                    }
                    let value = try fold(elements: Array(elements[2...]))
                    return SourceStmt(.assign(target.baseName.text, value), line: line(seq))
                }
                throw failure(expr, "an expression on its own does nothing; assign it to a name")
            }
            if let ifExpr = expr.as(IfExprSyntax.self) {
                return try ifStatement(ifExpr)
            }
            if let call = expr.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "set",
               let baseExpr = member.base,
               let base = baseExpr.as(DeclReferenceExprSyntax.self) {
                let arguments = Array(call.arguments)
                guard arguments.count == 2,
                      let pinLiteral = arguments[0].expression.as(IntegerLiteralExprSyntax.self),
                      let pin = Int(pinLiteral.literal.text) else {
                    throw failure(call, "set takes a pin number and a value: set(0, true)")
                }
                return SourceStmt(.blockSet(base.baseName.text, pin, try expression(arguments[1].expression)), line: line(call))
            }
            throw failure(expr, "an expression on its own does nothing; assign it to a name")
        }

        mutating func ifStatement(_ ifExpr: IfExprSyntax) throws -> SourceStmt {
            guard ifExpr.conditions.count == 1, let element = ifExpr.conditions.first,
                  case .expression(let conditionSyntax) = element.condition else {
                throw failure(ifExpr, "the condition must be one Boolean expression, without 'let' or 'case'")
            }
            let condition = try expression(conditionSyntax)
            let thenBody = try statements(ifExpr.body.statements)
            var elseBody: [SourceStmt]?
            if let elseBodySyntax = ifExpr.elseBody {
                switch elseBodySyntax {
                case .codeBlock(let block): elseBody = try statements(block.statements)
                case .ifExpr(let nested): elseBody = [try ifStatement(nested)]
                }
            }
            return SourceStmt(.ifThen(condition, thenBody, elseBody), line: line(ifExpr))
        }

        mutating func statement(_ stmt: StmtSyntax) throws -> SourceStmt {
            if let ret = stmt.as(ReturnStmtSyntax.self) {
                if ret.expression != nil {
                    throw failure(ret, "a function returns nothing; drop the value after 'return'")
                }
                return SourceStmt(.returnVoid, line: line(ret))
            }
            if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
                return try expressionStatement(exprStmt.expression)
            }
            if let ifExpr = stmt.as(IfExprSyntax.self) {
                return try ifStatement(ifExpr)
            }
            throw failure(stmt, "this statement is not supported")
        }

        func isAssignment(_ seq: SequenceExprSyntax) -> Bool {
            let elements = Array(seq.elements)
            return elements.count == 3 && elements[1].is(AssignmentExprSyntax.self)
        }

        // MARK: Expressions

        mutating func expression(_ expr: ExprSyntax) throws -> SourceExpr {
            if let seq = expr.as(SequenceExprSyntax.self) {
                return try fold(seq)
            }
            if let decl = expr.as(DeclReferenceExprSyntax.self) {
                return SourceExpr(.name(decl.baseName.text), line: line(decl))
            }
            if let literal = expr.as(IntegerLiteralExprSyntax.self) {
                guard let value = Int(literal.literal.text) else {
                    throw failure(literal, "the number \(literal.literal.text) is too large")
                }
                return SourceExpr(.integer(value), line: line(literal))
            }
            if let literal = expr.as(BooleanLiteralExprSyntax.self) {
                return SourceExpr(.boolean(literal.literal.text == "true"), line: line(literal))
            }
            if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
                return SourceExpr(.unary(prefix.operator.text, try expression(prefix.expression)), line: line(prefix))
            }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                guard let base = member.base else {
                    throw failure(member, "expected a name before '.\\(member.declName.baseName.text)'")
                }
                let name = member.declName.baseName.text
                guard name == "result" || !name.isEmpty else {
                    throw failure(member, "unknown property '\\(name)'")
                }
                return SourceExpr(.member(try expression(base), name), line: line(member))
            }
            if let call = expr.as(FunctionCallExprSyntax.self) {
                // `Block.IAdd(...)`: the library of block constructors. The name flattens to "Block.IAdd".
                var name: String?
                if let called = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    name = called.baseName.text
                } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                          let baseExpr = member.base,
                          let base = baseExpr.as(DeclReferenceExprSyntax.self), base.baseName.text == "Block" {
                    name = "Block.\(member.declName.baseName.text)"
                }
                guard let name else { throw failure(call, "only plain calls and 'Block.<Type>(...)' are understood") }
                var arguments: [SourceArgument] = []
                for argument in call.arguments {
                    arguments.append(SourceArgument(label: argument.label?.text,
                                                    value: try expression(argument.expression)))
                }
                return SourceExpr(.call(name, arguments), line: line(call))
            }
            if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
               let only = tuple.elements.first {
                return try expression(only.expression)
            }
            throw failure(expr, "'\(expr.trimmedDescription)' is not an expression this subset understands")
        }

        /// Folds a chain of operators (`a && b || c`) into a tree by precedence, left-associatively.
        mutating func fold(_ seq: SequenceExprSyntax) throws -> SourceExpr {
            try fold(elements: Array(seq.elements))
        }

        mutating func fold(elements: [ExprSyntax]) throws -> SourceExpr {
            let seq = elements.first ?? ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("")))
            var operands: [ExprSyntax] = []
            var operators: [(text: String, line: Int)] = []
            for element in elements {
                if let op = element.as(BinaryOperatorExprSyntax.self) {
                    operators.append((op.operator.text, line(op)))
                } else if element.is(AssignmentExprSyntax.self) {
                    throw failure(element, "an assignment is a statement, not an expression")
                } else {
                    operands.append(element)
                }
            }
            guard operands.count == operators.count + 1 else {
                throw failure(seq, "could not read this expression")
            }
            var nextOperand = 0
            var nextOperator = 0

            func precedence(_ text: String) -> Int? {
                switch text {
                case "||": return 1
                case "&&": return 2
                case "==", "!=": return 3
                case "<", ">", "<=", ">=": return 4
                case "+", "-": return 5
                case "*", "/", "%": return 6
                default: return nil
                }
            }

            func parse(minimum: Int) throws -> SourceExpr {
                var left = try expression(operands[nextOperand])
                nextOperand += 1
                while nextOperator < operators.count {
                    let (text, opLine) = operators[nextOperator]
                    guard let prec = precedence(text), prec >= minimum else { break }
                    nextOperator += 1
                    let right = try parse(minimum: prec + 1)
                    left = SourceExpr(.binary(text, left, right), line: opLine)
                }
                return left
            }

            let result = try parse(minimum: 0)
            guard nextOperand == operands.count else {
                throw failure(seq, "could not read this expression")
            }
            return result
        }
    }
}
