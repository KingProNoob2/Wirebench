import Foundation
import WirebenchCore

/// A block whose output is *stored state* rather than a recomputed expression.
///
/// `Set` and `SetIdx` write "the value from input X into the variable (output of another module)
/// connected to input P". Writing that block's output pin alone is not enough: a variable recomputes
/// its output from its stored value on the next pass, so the written value would survive exactly
/// until the variable next executes. Conforming blocks are written through their state instead.
public protocol WritableVariable: AnyObject {
    func writeVariable(_ value: PinValue)
}

// MARK: - Main / Other

/// A block whose behaviour cannot be reproduced without the hardware it drives, but whose pin
/// surface can and must be right.
///
/// Used for `P3Menu` (which the help says "has no inputs or outputs — it only serves to configure
/// the menu"), `SaveData` (stores into FRAM) and `Switch2`. Taking the shape from the module means
/// wires land on the right pins and the card draws correctly, while nothing is invented: with no
/// FRAM, no menu and no documented `Switch2` semantics, a fabricated output would look right and
/// mean nothing.
public final class ShapePreservingBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic (one class backs several Dirigo types), so never used for dispatch.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D5")!
    public static let typeName = "ShapePreserving"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    public init(inPins: Int, params: Int, outPins: Int) {
        self.inPins = Array(repeating: .int32(0), count: inPins)
        if inPins > 0 { self.inPins[0] = .bool(true) }          // En, when the type has one
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .int32(0), count: outPins)
    }

    public func process(sample: SampleContext) {}
    public func reset() {}
}

/// `Logger` — "writes data log into archive memory".
///
/// Pin shape: `En`, then user-configurable `I1..In` (Int), `L1..Ln` (Long) and `F1..Fn` (Float)
/// inputs, with an `Idx` index output. The archive does not exist here, so `Idx` reports 0 rather
/// than an index into a log that was never written.
public final class LoggerBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "3CB29B37-0D87-4A38-B09C-0C67F2E1F801")!
    public static let typeName = "Logger"

    public var inPins: [PinValue]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]   // Idx

    public init(inPins: Int, outPins: Int) {
        self.inPins = Array(repeating: .int32(0), count: max(1, inPins))
        self.inPins[0] = .bool(true)               // En
        self.outPins = Array(repeating: .int32(0), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // Not executed means nothing is logged and every output holds.
        guard enabled else { return }
        // No archive to write to, so no index to report.
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }
}

/// `SetIdx` (`TMSetIndexed`) — "the value from input X is written into the variable connected to
/// input P_idx".
///
/// Pin order is `En, Idx, X, P0...Pn-1`, so the selectable pins start at index 3; `Set`, by
/// contrast, writes through *every* P pin. The number of inputs is user-configurable (1–126), so the
/// shape comes from the module. As with `Set`, the write itself is performed by the engine: a block
/// cannot reach the producers of its own inputs.
public final class SetIdxBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "E2B4D6F6-EDCC-43A9-97B8-B4D62199A58E")!
    public static let typeName = "SetIdx"

    public var inPins: [PinValue]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init(inPins: Int) {
        self.inPins = Array(repeating: .int32(0), count: max(3, inPins))
        self.inPins[0] = .bool(true)          // En
        // Idx (1) and X (2) stay Int; P0... begin at 3.
    }

    /// The P pin to write through, or nil when `Idx` is outside `0..<N` — in which case, per the
    /// help, "no write takes place".
    public var targetPinIndex: Int? {
        guard inPins.count > 3 else { return nil }
        let index = inPins[1].asInt
        let selectable = inPins.count - 3
        guard index >= 0, index < selectable else { return nil }
        return 3 + index
    }

    public func process(sample: SampleContext) {}

    public func reset() {}
}
