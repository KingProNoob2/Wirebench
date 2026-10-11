import Foundation
import DirigoCore

// MARK: - Subtraction Block (Int and Float)
public final class SubBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "930794F2-FA27-4BD8-A42D-15A13162E96D")!
    public static let typeName = "Sub"

    // In 0 = En, In 1 = A, In 2 = B
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)] // Y = A - B

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        let b = inPins.count > 2 ? inPins[2].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: a - b))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Absolute Value Block
public final class AbsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "896864FC-42F9-44E4-A091-310F35EB4134")!
    public static let typeName = "Abs"

    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: abs(a)))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Increment Block
public final class IncBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "F0E6DEF4-5DD3-4643-9BEC-C0090EE433C8")!
    public static let typeName = "Inc"

    // Help pins: En, X -> Y, and nothing else. "The module increases the value of input X by 1 and
    // stores the result in output Y. Y = X + 1" — the old block carried an undocumented `Step`
    // parameter, so a real module (which has none) got a parameter pin the sheet cannot show.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = inPins.count > 1 ? inPins[1].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: x + 1))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Negation Block
public final class NegBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "328E7D67-FF39-4419-A8FA-2EBF891D2454")!
    public static let typeName = "Neg"

    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: -a))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Limiter Block (Clamps to Min / Max)
public final class LimiterBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "F5956E98-9252-4103-8D8C-D098BD8ED82A")!
    public static let typeName = "ILimiter"

    // Help pins: X in; Max/Min *parameters*; Y out. There is NO En on this block — the old code
    // invented one, which pushed X into the En slot, and it read the limits from input pins the
    // engine never fills, so they were always 0/100.
    public var inPins: [PinValue] = [.int32(0)]                  // X
    public var paramPins: [PinValue] = [.int32(0), .int32(0)]    // Max, Min
    public var outPins: [PinValue] = [.int32(0)]                 // Y

    public init() {}

    public func process(sample: SampleContext) {
        let x = inPins.count > 0 ? inPins[0].asInt : 0
        let maximum = paramPins.count > 0 ? paramPins[0].asInt : 0
        let minimum = paramPins.count > 1 ? paramPins[1].asInt : 0
        // "If X < Min, output Y takes the value Min"; likewise for Max.
        outPins[0] = .int32(Int32(min(max(x, minimum), maximum)))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


// MARK: - InRange Block
public final class InRangeBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "C9F81058-F2D9-40D7-B52F-491C7B821DF6")!
    public static let typeName = "InRange"

    // Help pins: En, X. The limits `L` and `H` are *parameters*, not inputs. The old block read
    // them from two extra input pins, which the engine never fills from PARAM_PINS — so they always
    // ran on the hardcoded defaults of 0 and 100 regardless of how the block was configured.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = [.int32(0), .int32(100)]   // L, H
    public var outPins: [PinValue] = [.bool(false)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = inPins.count > 1 ? inPins[1].asInt : 0
        guard paramPins.count >= 2 else { return }
        let l = paramPins[0].asInt
        let h = paramPins[1].asInt

        // Upper bound is exclusive (help: "L (inclusive) and H"), and L > H wraps.
        //
        // For the wrap the help says "(X<L) or (X>=H)", which is a tautology — every X satisfies
        // it — and would make the block useless as the time switch it is documented to be. The
        // help's own purpose sentence settles it: "L gives the switch-on time and H the switch-off
        // time, with the transition across midnight also handled", which requires (X>=L) or (X<H).
        // The two comparisons are transposed in the prose; the intent is implemented here.
        outPins[0] = .bool(l <= h ? (x >= l && x < h) : (x >= l || x < h))
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}


// MARK: - Moving Average (Mean) Block
public final class CalibratedTransformBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "EAE57494-0396-44F3-8A5D-4220D62D2977")!
    public static let typeName = "CalibTransf"

    // Help pins: En, X in; XMax/XMid/XMin and YMax/YMid/YMin parameters; Y out. The old block had a
    // single input (no En), no parameters at all, and carried its points in Swift-side state, so a
    // real module's configured points were never read.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]                       // En, X
    public var paramPins: [PinValue] = [.int32(100), .int32(50), .int32(0),         // XMax, XMid, XMin
                                        .int32(100), .int32(50), .int32(0)]         // YMax, YMid, YMin
    public var outPins: [PinValue] = [.int32(0)]                                    // Y

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = inPins.count > 1 ? inPins[1].asInt : 0
        guard paramPins.count >= 6 else { return }

        let xMax = paramPins[0].asInt, xMid = paramPins[1].asInt, xMin = paramPins[2].asInt
        let yMax = paramPins[3].asInt, yMid = paramPins[4].asInt, yMin = paramPins[5].asInt

        // "The parameters XMin, XMid and XMax divide the range of input X into 4 intervals."
        // Interpolation is linear within each of the middle two.
        func interpolate(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            guard x1 != x0 else { return y0 }
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }

        let result: Int
        if x <= xMin {
            result = yMin
        } else if x <= xMid {
            result = interpolate(xMin, yMin, xMid, yMid)
        } else if x <= xMax {
            result = interpolate(xMid, yMid, xMax, yMax)
        } else {
            result = yMax
        }
        outPins[0] = .int32(Int32(truncatingIfNeeded: result))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}



// MARK: - Multi-Point Calibrated Transform Block
/// Implements piece-wise linear interpolation through 2 to 17 calibration points (X_i, Y_i).


// MARK: - Float Math Operations
public final class FloatMathBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "5433DDF6-3C3B-5391-A7AE-279D65A1AA3C")!
    public static let typeName = "FloatMath"

    public enum Operation: String, Sendable {
        case add, sub, mul, div, sqrt, sin, cos
    }

    public var operation: Operation
    public var inPins: [PinValue] = [.float(0.0), .float(0.0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.float(0.0)]

    public init(operation: Operation = .add) {
        self.operation = operation
    }

    public func process(sample: SampleContext) {
        let a = inPins.count > 0 ? inPins[0].asFloat : 0.0
        let b = inPins.count > 1 ? inPins[1].asFloat : 0.0

        switch operation {
        case .add: outPins[0] = .float(a + b)
        case .sub: outPins[0] = .float(a - b)
        case .mul: outPins[0] = .float(a * b)
        case .div: outPins[0] = b != 0 ? .float(a / b) : .float(0.0)
        case .sqrt: outPins[0] = a >= 0 ? .float(sqrt(a)) : .float(0.0)
        case .sin: outPins[0] = .float(sin(a))
        case .cos: outPins[0] = .float(cos(a))
        }
    }

    public func reset() {
        outPins[0] = .float(0.0)
    }
}


/// `Mean` — averages the values stored while the trigger is high.
///
/// Help order is `En, Tr, X`: `Tr` is the store trigger and `X` is the value being averaged. An
/// earlier version had only `En` and `X`, so it read the *trigger* as the signal and appended on
/// every cycle regardless — every average it produced was wrong from the first cycle.
public final class MeanBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "8EB0C80D-4737-4368-B2BD-0831DAC95747")!
    public static let typeName = "Mean"

    public var inPins: [PinValue] = [.bool(true), .bool(false), .int32(0)]
    // The window is configuration, not a pin: the help documents no parameter row for it and real
    // modules carry no PARAM_PINS.
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    /// Number of stored values to average. The help's default is 12.
    public var windowSize: Int = 12

    private var history: [Int] = []

    public init(windowSize: Int = 12) {
        self.windowSize = max(1, windowSize)
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let trigger = inPins.count > 1 ? inPins[1].asBool : false
        let value = inPins.count > 2 ? inPins[2].asInt : 0
        let window = max(1, windowSize)

        // "If the value on input Tr is 1, the value of input X is stored." The help is
        // self-contradictory about edge versus level; this is the literal reading, so a held
        // trigger stores once per cycle.
        if trigger {
            history.append(value)
            if history.count > window {
                history.removeFirst(history.count - window)
            }
        }

        guard !history.isEmpty else { return }   // no samples yet: hold
        outPins[0] = .int32(Int32(history.reduce(0, +) / history.count))
    }

    public func reset() {
        history.removeAll()
        outPins[0] = .int32(0)
    }
}
