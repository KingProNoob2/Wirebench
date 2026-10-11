import Foundation
import DirigoCore

// MARK: - Yes Block (Signal Buffer / Router)
/// The standard Dirigo Yes block. Routes each input to its corresponding output.
public final class YesBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "EDA9D885-FBAC-4AF9-8FAC-0E9FFB3B5B80")!
    public static let typeName = "Yes"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init(pinCount: Int = 1) {
        let count = max(1, pinCount)
        inPins = Array(repeating: .int32(0), count: count)
        outPins = Array(repeating: .int32(0), count: count)
    }

    public func process(sample: SampleContext) {
        for i in 0..<min(inPins.count, outPins.count) {
            outPins[i] = inPins[i]
        }
    }

    public func reset() {
        for i in 0..<outPins.count {
            outPins[i] = .int32(0)
        }
    }
}

// MARK: - Bits to Int Block
/// Bundles up to 16/32 discrete bit inputs into a single integer output.
public final class Bits2IntBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "A9BD18ED-4059-4B71-97A4-5D52CF189C81")!
    public static let typeName = "Bits2Int"

    // In 0 = En, then B0...B(N-1). Treating En as B0 shifted every bit up one place, so a packed
    // value could only ever be odd when the block was enabled.
    public var inPins: [PinValue] = [.bool(true)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)] // Y = Packed Int

    /// - Parameter totalPins: total input pins, *including* En.
    public init(totalPins: Int = 9) {
        inPins = Array(repeating: .bool(false), count: max(2, totalPins))
        inPins[0] = .bool(true)
    }

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        var packedVal: Int32 = 0
        for i in 0..<min(32, inPins.count - 1) {
            if inPins[i + 1].asBool {
                packedVal |= (1 << i)
            }
        }
        outPins[0] = .int32(packedVal)
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Bitwise Shift Left (Shl) Block
public final class ShlBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "58F7B26E-EE75-4467-A3F7-9D9B918E95E5")!
    public static let typeName = "Shl"

    // Help order: En, X, B. Leaving En out shifted X into the En slot, so the block computed
    // "En << X" and the real shift count never arrived.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let val = inPins.count > 1 ? inPins[1].asInt : 0
        let shift = inPins.count > 2 ? max(0, min(31, inPins[2].asInt)) : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: val << shift))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Arithmetic Shift Right (Sar) Block
public final class SarBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "C9367EE3-EE1C-4FE0-8268-A7DDFDEBF783")!
    public static let typeName = "Sar"

    // Help order: En, X, B (same shift hazard as Shl).
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let val = inPins.count > 1 ? inPins[1].asInt : 0
        let shift = inPins.count > 2 ? max(0, min(31, inPins[2].asInt)) : 0
        outPins[0] = .int32(Int32(truncatingIfNeeded: val >> shift))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Bitfield Extract (Ext) Block
public final class ExtBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "1566429F-BDAE-4DF8-B85C-FA43B9A816A2")!
    public static let typeName = "Ext"

    // In 0 = In, In 1 = Offset, In 2 = Length
    // Help order: En, X, B, Len (Len default 16, not 8).
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0), .int32(16)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let val = inPins.count > 1 ? inPins[1].asInt : 0
        let offset = inPins.count > 2 ? max(0, min(31, inPins[2].asInt)) : 0
        let length = inPins.count > 3 ? max(1, min(32 - offset, inPins[3].asInt)) : 16
        let mask = (1 << length) - 1
        let extracted = (val >> offset) & mask
        outPins[0] = .int32(Int32(truncatingIfNeeded: extracted))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Bitfield Insert (Ins) Block
public final class InsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "8820DF1A-5601-4246-97AE-606637CC09F0")!
    public static let typeName = "Ins"

    // In 0 = Target, In 1 = Value, In 2 = Offset, In 3 = Length
    // Help order: En, X, V, B, Len (Len default 16, not 8).
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0), .int32(0), .int32(16)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]

    public init() {}

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let target = inPins.count > 1 ? inPins[1].asInt : 0
        let val = inPins.count > 2 ? inPins[2].asInt : 0
        let offset = inPins.count > 3 ? max(0, min(31, inPins[3].asInt)) : 0
        let length = inPins.count > 4 ? max(1, min(32 - offset, inPins[4].asInt)) : 16
        let mask = ((1 << length) - 1) << offset
        let inserted = (target & ~mask) | ((val << offset) & mask)
        outPins[0] = .int32(Int32(truncatingIfNeeded: inserted))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Single Pulse (Monostable One-Shot) Block
/// Dirigo SinglePulse module: generates a single pulse of duration TOn cycles upon a rising edge of trigger Tr.
/// Unlike PulseGen (which is an astable oscillator that continues generating periodic pulses indefinitely),
/// SinglePulse is a monostable one-shot: it fires exactly once per trigger edge, then stops until the next rising edge.
public final class SinglePulseBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "252CEA06-915F-4422-9B6D-5CE9815998A8")!
    public static let typeName = "SinglePulse"

    // In 0 = En (default true), In 1 = Tr (default false)
    // Adapts dynamically if schematic provides 1 or 2 pins
    public var inPins: [PinValue] = [.bool(true), .bool(false)]
    public var paramPins: [PinValue] = [.int32(1)] // TOn (Time On in cycles)
    // Out 0 = Cnt (1...TOn during pulse, 0 when idle), Out 1 = Out (true during pulse)
    public var outPins: [PinValue] = [.int32(0), .bool(false)]

    private var remainingCycles: Int = 0
    private var totalDuration: Int = 0
    private var lastTr: Bool = false

    public init(pinCount: Int = 2) {
        if pinCount <= 1 {
            inPins = [.bool(false)]
            outPins = [.bool(false)]
        } else {
            inPins = [.bool(true), .bool(false)]
            outPins = [.int32(0), .bool(false)]
        }
    }

    public func process(sample: SampleContext) {
        let enabled: Bool
        let tr: Bool
        if inPins.count >= 2 {
            enabled = inPins[0].asBool
            tr = inPins[1].asBool
        } else {
            enabled = true
            tr = inPins.first?.asBool ?? false
        }

        let rising = !lastTr && tr
        lastTr = tr

        guard enabled else {
            reset()
            return
        }

        let tOn = paramPins.count > 0 ? max(1, paramPins[0].asInt) : 1

        if rising {
            remainingCycles = tOn
            totalDuration = tOn
        }

        if remainingCycles > 0 {
            let currentCount = totalDuration - remainingCycles + 1
            if outPins.count >= 2 {
                outPins[0] = .int32(Int32(currentCount))
                outPins[1] = .bool(true)
            } else if outPins.count == 1 {
                outPins[0] = .bool(true)
            }
            remainingCycles -= 1
        } else {
            if outPins.count >= 2 {
                outPins[0] = .int32(0)
                outPins[1] = .bool(false)
            } else if outPins.count == 1 {
                outPins[0] = .bool(false)
            }
        }
    }

    public func reset() {
        remainingCycles = 0
        totalDuration = 0
        lastTr = false
        if outPins.count >= 2 {
            outPins[0] = .int32(0)
            outPins[1] = .bool(false)
        } else if outPins.count == 1 {
            outPins[0] = .bool(false)
        }
    }
}

// MARK: - Pulse Length Block
public final class PulseLengthBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "38C04DAA-9696-41F6-B938-2F22A0A2EFA7")!
    public static let typeName = "PulseLen"

    // In 0 = En (default true), In 1 = In (default false) - or 1-pin [In]
    public var inPins: [PinValue] = [.bool(true), .bool(false)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)] // Out 0 = Len (measured length in cycles)

    private var activeCycles: Int = 0
    private var lastIn: Bool = false

    public init(pinCount: Int = 2) {
        if pinCount <= 1 {
            inPins = [.bool(false)]
        } else {
            inPins = [.bool(true), .bool(false)]
        }
    }

    public func process(sample: SampleContext) {
        let enabled: Bool
        let inputVal: Bool
        if inPins.count >= 2 {
            enabled = inPins[0].asBool
            inputVal = inPins[1].asBool
        } else {
            enabled = true
            inputVal = inPins.first?.asBool ?? false
        }

        guard enabled else {
            reset()
            return
        }

        if inputVal {
            activeCycles += 1
            outPins[0] = .int32(Int32(activeCycles))
        } else {
            if lastIn {
                outPins[0] = .int32(Int32(activeCycles))
            }
            activeCycles = 0
        }
        lastIn = inputVal
    }

    public func reset() {
        activeCycles = 0
        lastIn = false
        outPins[0] = .int32(0)
    }
}
