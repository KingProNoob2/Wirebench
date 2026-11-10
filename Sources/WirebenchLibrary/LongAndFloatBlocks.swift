import Foundation
import WirebenchCore

// MARK: - Long and Float arithmetic
//
// These 21 types were placeholders: a real module of one of these types ran as an inert
// `UnresolvedBlock`, so every wire through it produced nothing. The help gives each type a
// one-line rule (`Y = X0 + X1 ...`, `Y = Sin(X * K)`, ...), which is what these implement.
//
// Pin counts are taken from the module rather than hardcoded. The family is not uniform — `LAdd`
// is `En, X0, X1`, `LAbs` is `En, X`, and `FSin`/`FSqrt` carry an extra `K` — and the module is
// the only place that distinction is recorded. The simulation then fills the pins
// positionally, so types and constants come from the file.

/// The Long (`Int32`) arithmetic operations, keyed by their Dirigo block names.
public enum LongMathOperation: Sendable {
    case add, subtract, absolute, negate, logicalNot, increment, bitAnd, bitOr, bitXor

    public init?(blockName: String) {
        switch blockName {
        case "LAdd": self = .add
        case "LSub": self = .subtract
        case "LAbs": self = .absolute
        case "LNeg": self = .negate
        case "LNot": self = .logicalNot
        case "LInc": self = .increment
        case "LAnd": self = .bitAnd
        case "LOr": self = .bitOr
        case "LXor": self = .bitXor
        default: return nil
        }
    }
}

/// The Float arithmetic operations.
public enum FloatMathOperation: Sendable {
    case add, subtract, multiply, divide, absolute, negate, squareRoot, modulo
    case sine, cosine, arcSine, arcCosine

    public init?(blockName: String) {
        switch blockName {
        case "FAdd": self = .add
        case "FSub": self = .subtract
        case "FMul": self = .multiply
        case "FDiv": self = .divide
        case "FAbs": self = .absolute
        case "FNeg": self = .negate
        case "FSqrt": self = .squareRoot
        case "FMod": self = .modulo
        case "FSin": self = .sine
        case "FCos": self = .cosine
        case "FASin": self = .arcSine
        case "FACos": self = .arcCosine
        default: return nil
        }
    }
}

public final class LongMathBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic. One class backs nine Dirigo types, each registered under its own *real* GUID, so
    /// this static is never used for dispatch — it exists only to satisfy `FunctionBlock`. It sits in
    /// this reimplementation's namespace, like the other synthetic GUIDs here.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2CE")!
    public static let typeName = "LongMath"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    private let operation: LongMathOperation

    public init(operation: LongMathOperation, inPins: Int, params: Int, outPins: Int) {
        self.operation = operation
        self.inPins = [.bool(true)] + Array(repeating: .int32(0), count: max(0, inPins - 1))
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .int32(0), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let operands = inPins.dropFirst().map { $0.asInt }

        let result: Int
        switch operation {
        case .add:        result = operands.reduce(0, +)
        case .subtract:   result = operands.dropFirst().reduce(operands.first ?? 0, -)
        case .absolute:   result = abs(operands.first ?? 0)
        case .negate:     result = -(operands.first ?? 0)
        case .logicalNot: result = ~(operands.first ?? 0)
        case .increment:  result = (operands.first ?? 0) + 1
        case .bitAnd:     result = operands.dropFirst().reduce(operands.first ?? 0, &)
        case .bitOr:      result = operands.dropFirst().reduce(operands.first ?? 0, |)
        case .bitXor:     result = operands.dropFirst().reduce(operands.first ?? 0, ^)
        }
        for i in 0..<outPins.count {
            outPins[i] = .int32(Int32(truncatingIfNeeded: result))
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .int32(0) }
    }
}

public final class FloatMathNumericBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic, for the same reason as `LongMathBlock.guid`.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2CF")!
    public static let typeName = "FloatMathNumeric"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    private let operation: FloatMathOperation

    public init(operation: FloatMathOperation, inPins: Int, params: Int, outPins: Int) {
        self.operation = operation
        self.inPins = [.bool(true)] + Array(repeating: .float(0), count: max(0, inPins - 1))
        self.paramPins = Array(repeating: .float(0), count: params)
        self.outPins = Array(repeating: .float(0), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let operands = inPins.dropFirst().map { Double($0.asFloat) }

        // `K` is an input on the trigonometric types whose rule is `Y = Sin(X * K)`, and a parameter
        // on others. Prefer the second operand and fall back to the parameter, then to 1.
        let x = operands.first ?? 0
        let k = operands.count > 1 ? operands[1] : (paramPins.first.map { Double($0.asFloat) } ?? 1)

        let result: Double
        switch operation {
        case .add:        result = operands.reduce(0, +)
        case .subtract:   result = operands.dropFirst().reduce(x, -)
        case .multiply:   result = operands.reduce(1, *)
        case .divide:     result = operands.dropFirst().reduce(x) { $1 == 0 ? $0 : $0 / $1 }
        case .absolute:   result = abs(x)
        case .negate:     result = -x
        case .squareRoot: result = x < 0 ? 0 : x.squareRoot()
        case .modulo:     result = operands.count > 1 && operands[1] != 0 ? x.truncatingRemainder(dividingBy: operands[1]) : 0
        case .sine:       result = Foundation.sin(x * k)
        case .cosine:     result = Foundation.cos(x * k)
        case .arcSine:    result = x < -1 || x > 1 ? 0 : Foundation.asin(x) * k
        case .arcCosine:  result = x < -1 || x > 1 ? 0 : Foundation.acos(x) * k
        }
        for i in 0..<outPins.count {
            outPins[i] = .float(Float(result))
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .float(0) }
    }
}
