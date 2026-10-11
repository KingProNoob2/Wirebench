import Foundation
import DirigoCore

public final class ComparatorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "8942245A-7E82-43FF-94E8-E7BCF69FDEE9")!
    public static let typeName = "Comparator"

    // In 0 = En, In 1 = A, In 2 = B
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false), .bool(false), .bool(false)] // AGtB, AEqB, ALtB

    public init() {}

    public func process(sample: SampleContext) {
        let enabled: Bool
        let a: Int
        let b: Int

        if inPins.count <= 2 {
            enabled = true
            a = inPins.count > 0 ? inPins[0].asInt : 0
            b = inPins.count > 1 ? inPins[1].asInt : 0
        } else {
            enabled = inPins[0].asBool
            a = inPins[1].asInt
            b = inPins[2].asInt
        }

        guard enabled else {
            reset()
            return
        }

        outPins[0] = .bool(a > b)
        if outPins.count > 1 { outPins[1] = .bool(a == b) }
        if outPins.count > 2 { outPins[2] = .bool(a < b) }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .bool(false) }
    }
}

public final class Int2BitsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "F319DECC-7D91-4684-A813-83DBB5C70245")!
    public static let typeName = "Int2Bits"

    public var inPins: [PinValue] = [.int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [] // Bits 0 to N-1

    public init(bitCount: Int = 8) {
        outPins = Array(repeating: .bool(false), count: bitCount)
    }

    public func process(sample: SampleContext) {
        let val = inPins.first?.asInt ?? 0
        for i in 0..<outPins.count {
            let bit = (val & (1 << i)) != 0
            outPins[i] = .bool(bit)
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .bool(false) }
    }
}

public final class DivBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "05ED6F8C-A885-4F72-9671-6D6AB3D556E2")!
    public static let typeName = "Div"

    // In 0 = En, In 1 = A, In 2 = B
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(1)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0), .int32(0)] // Y (Quotient), Mod (Remainder)

    public init() {}

    public func process(sample: SampleContext) {
        // `En = 0` means "not executed": the output holds its previous value. Clearing it here was
        // one of several inconsistent conventions; see docs/spec/blocks-datapath.md §0.5.
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let a = inPins.count > 1 ? inPins[1].asInt : 0
        let b = inPins.count > 2 ? inPins[2].asInt : 0   // help default for B

        if b == 0 {
            outPins[0] = .int32(0)
            if outPins.count > 1 { outPins[1] = .int32(0) }
            return
        }

        let q = a / b
        let r = a % b
        outPins[0] = .int32(Int32(truncatingIfNeeded: q))
        if outPins.count > 1 { outPins[1] = .int32(Int32(truncatingIfNeeded: r)) }
    }

    public func reset() {
        outPins[0] = .int32(0)
        if outPins.count > 1 { outPins[1] = .int32(0) }
    }
}

public final class ISwitchBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "0FAE4998-FD44-4CA1-B55F-7E148FDFF20A")!
    public static let typeName = "ISwitch"

    // In 0 = En, In 1 = Sw, In 2...N+1 = Values X0...X(N-1)
    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)] // Y

    /// The Float form (`FSwitch`) differs only in the element type; the Long form shares the Int one.
    public let isFloat: Bool

    public init(inputCount: Int = 2, isFloat: Bool = false) {
        self.isFloat = isFloat
        // En (0), Sw (1), X0...X(inputCount-1)
        inPins = Array(repeating: isFloat ? .float(0) : .int32(0), count: inputCount + 2)
        inPins[0] = .bool(true) // En = 1
        outPins = [isFloat ? .float(0) : .int32(0)]
    }

    public func process(sample: SampleContext) {
        guard inPins.count >= 2 else { return }
        let enabled = inPins[0].asBool
        // En = 0 holds. (An out-of-range `Sw` with En = 1 does clear the output — that is a
        // separate, documented case, handled below.)
        guard enabled else { return }

        let sw = inPins[1].asInt
        let targetIndex = 2 + sw

        if targetIndex >= 2 && targetIndex < inPins.count {
            outPins[0] = inPins[targetIndex]
        } else {
            // "If the Sw input is outside the range 0 to (N-1), output Y is cleared."
            outPins[0] = isFloat ? .float(0) : .int32(0)
        }
    }

    public func reset() {
        outPins[0] = isFloat ? .float(0) : .int32(0)
    }
}

public final class SetBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "D163B0B9-D7AE-4BB8-800C-167B9E26488B")!
    public static let typeName = "Set"

    // "If the En input = 1, the value from input X is written into the variables connected to
    // inputs P1-Pn." A real instance is `En, X` plus a parameter, and the P pins appear only when
    // the module is configured with them — so the shape comes from the module rather than being
    // assumed. The write-through itself is performed by `SimulationEngine.stepNode`, because a
    // block cannot reach the producers of its own inputs.
    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue] = []

    public init(inPins: Int, params: Int) {
        self.inPins = Array(repeating: .int32(0), count: max(2, inPins))
        self.inPins[0] = .bool(true)      // En
        self.paramPins = Array(repeating: .int32(0), count: params)
    }

    /// The value written through the P pins.
    public var writeValue: PinValue { inPins.count > 1 ? inPins[1] : .int32(0) }

    public func process(sample: SampleContext) {}

    public func reset() {}
}


public final class AddBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "9263D26F-F78B-4380-B34D-797232F865CD")!
    public static let typeName = "IAdd"

    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        let b = inPins.count > 2 ? inPins[2].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: a + b))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

public final class MulBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "6FF39366-0C38-4C4D-9962-81E89261D7C9")!
    public static let typeName = "IMul"

    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        let b = inPins.count > 2 ? inPins[2].asInt : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: a * b))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


// MARK: - Move

/// `En, Tr, X -> Y`: "On a rising edge (transition from 0 to 1) it copies the value of input X to
/// output Y." A sample-and-hold, so Y keeps the last captured value between triggers.
public final class MoveBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "BC2C94BA-D36C-4323-9650-4BEC5A5C32F3")!
    public static let typeName = "Move"

    public var inPins: [PinValue] = [.bool(true), .bool(false), .int32(0)]   // En, Tr, X
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]                             // Y

    private var lastTrigger = false

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // Not executed means the edge detector does not advance either, so a trigger that arrives
        // while the block is disabled is not silently consumed.
        guard enabled else { return }

        let trigger = inPins.count > 1 ? inPins[1].asBool : false
        let rising = trigger && !lastTrigger
        lastTrigger = trigger

        if rising, inPins.count > 2 {
            outPins[0] = inPins[2]
        }
    }

    public func reset() {
        lastTrigger = false
        outPins[0] = .int32(0)
    }
}
