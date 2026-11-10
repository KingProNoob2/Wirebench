import Foundation
import WirebenchCore

public final class AndBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "058EE871-1370-46E7-AC3E-905CB632A211")!
    public static let typeName = "And"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]

    public init(inputCount: Int = 2) {
        // Pin 0 is Enable, followed by inputs 1...inputCount
        inPins = Array(repeating: .bool(false), count: inputCount + 1)
        inPins[0] = .bool(true) // default enable is 1
    }

    public func process(sample: SampleContext) {
        guard !inPins.isEmpty else { return }
        let enabled = inPins[0].asBool
        // `En = 0` means "not executed": the output HOLDS its previous value. Forcing it to 0 was
        // one of five inconsistent conventions in the old code — the help only ever says "not
        // executed" and never states the output clears. See docs/spec/blocks-datapath.md §0.5.
        guard enabled else { return }

        // AND all operand pins (index 1..<inPins.count)
        var result = true
        for i in 1..<inPins.count {
            if !inPins[i].asBool {
                result = false
                break
            }
        }
        outPins[0] = .bool(result)
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}

public final class OrBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "5745AE44-2B47-4828-AEFA-B96375DA31C4")!
    public static let typeName = "Or"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]

    public init(inputCount: Int = 2) {
        inPins = Array(repeating: .bool(false), count: inputCount + 1)
        inPins[0] = .bool(true)
    }

    public func process(sample: SampleContext) {
        guard !inPins.isEmpty else { return }
        let enabled = inPins[0].asBool
        // `En = 0` means "not executed": the output HOLDS its previous value. Forcing it to 0 was
        // one of five inconsistent conventions in the old code — the help only ever says "not
        // executed" and never states the output clears. See docs/spec/blocks-datapath.md §0.5.
        guard enabled else { return }

        var result = false
        for i in 1..<inPins.count {
            if inPins[i].asBool {
                result = true
                break
            }
        }
        outPins[0] = .bool(result)
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}

public final class NotBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "72ECCB1C-F9E5-42A7-847D-12F37BC9EE47")!
    public static let typeName = "Not"

    public var inPins: [PinValue] = [.bool(true), .bool(false)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(true)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // `En = 0` means "not executed": the output HOLDS its previous value. Forcing it to 0 was
        // one of five inconsistent conventions in the old code — the help only ever says "not
        // executed" and never states the output clears. See docs/spec/blocks-datapath.md §0.5.
        guard enabled else { return }

        let val = inPins.count > 1 ? inPins[1].asBool : false
        outPins[0] = .bool(!val)
    }

    public func reset() {
        outPins[0] = .bool(true)
    }
}

public final class XorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "F6F4BEA6-AE94-429F-B1D2-98A60FA51B3E")!
    public static let typeName = "Xor"

    public var inPins: [PinValue] = [.bool(true), .bool(false), .bool(false)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // `En = 0` means "not executed": the output HOLDS its previous value. Forcing it to 0 was
        // one of five inconsistent conventions in the old code — the help only ever says "not
        // executed" and never states the output clears. See docs/spec/blocks-datapath.md §0.5.
        guard enabled else { return }

        let x0 = inPins.count > 1 ? inPins[1].asBool : false
        let x1 = inPins.count > 2 ? inPins[2].asBool : false
        outPins[0] = .bool(x0 != x1)
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}

public final class RSBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "AEFF2CAB-3B5E-4E09-BB8B-2394FB9CBBCE")!
    public static let typeName = "RS"

    // In 0 = En, In 1 = S, In 2 = R, matching the help. Omitting En was not cosmetic: the engine
    // copies module pins by index, so S landed on En, R landed on S, and the real R was dropped.
    public var inPins: [PinValue] = [.bool(true), .bool(false), .bool(false)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)] // Q
    public var resetPriority: Bool = true

    public init(resetPriority: Bool = true) {
        self.resetPriority = resetPriority
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }        // "not executed": hold the previous state
        let s = inPins.count > 1 ? inPins[1].asBool : false
        let r = inPins.count > 2 ? inPins[2].asBool : false

        if resetPriority {
            if r {
                outPins[0] = .bool(false)
            } else if s {
                outPins[0] = .bool(true)
            }
        } else {
            if s {
                outPins[0] = .bool(true)
            } else if r {
                outPins[0] = .bool(false)
            }
        }
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}

public final class TriggerBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "F8935A1D-00FB-442E-8B67-483EEA1F0B62")!
    public static let typeName = "Trigger"

    // Help order: En, X. Without En the block watched the En wire instead of the signal.
    public var inPins: [PinValue] = [.bool(true), .bool(false)]
    public var paramPins: [PinValue] = []
    // One output. The help documents a single `Y`, "changed since the previous cycle" — not
    // separate rising and falling pins. Modelling two meant the card showed one (the module has
    // one) while the block wrote the rising edge to it, so a 1->0 change produced nothing.
    public var outPins: [PinValue] = [.bool(false)]
    private var lastValue: PinValue = .undefined
    private var hasProcessedOnce: Bool = false

    public init() {}

    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let current = inPins.count > 1 ? inPins[1] : .bool(false)
        if !hasProcessedOnce {
            hasProcessedOnce = true
            lastValue = current
            for i in 0..<outPins.count { outPins[i] = .bool(false) }
            return
        }

        // "Changed since the previous cycle" — any change, in either direction.
        let isChanged = current != lastValue
        lastValue = current
        if !outPins.isEmpty { outPins[0] = .bool(isChanged) }
    }

    public func reset() {
        lastValue = .undefined
        hasProcessedOnce = false
        for i in 0..<outPins.count {
            outPins[i] = .bool(false)
        }
    }
}
