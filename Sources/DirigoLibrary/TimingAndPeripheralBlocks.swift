import Foundation
import DirigoCore

/// Dirigo PulseGen module: continuous square-wave / clock generator (astable oscillator).
/// As long as the input signal is HIGH, it continuously switches / oscillates between high and low
/// indefinitely. When the input signal is OFF (0 / low), it stops and outputs 0 (does not do anything).
public final class PulseGenBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "74F92168-F67B-4364-8AC0-B735DAA400A3")!
    public static let typeName = "PulseGen"

    public var inPins: [PinValue] = [.bool(true), .bool(false)] // In 0 = En, In 1 = Act
    public var paramPins: [PinValue] = [.int32(1), .int32(1)]   // TOn, TOff — in cycles
    // Out 0 = Cnt, an *integer* cycle counter; Out 1 = Out, the Boolean pulse. They are different
    // signals: filling both with the pulse made Cnt sit high for TOn of every TOn+TOff cycles,
    // which reads as a stuck output.
    public var outPins: [PinValue] = [.int32(0), .bool(false)]

    private var cycleCounter: Int = 0

    public init() {}

    /// The help is unambiguous about this block:
    ///
    /// * `En` — "=0..not executed, =1..executed"
    /// * `Act` — "Enables pulse generation"
    /// * "If Act=1, pulses of length TOn with an interval of TOff are generated on output Out."
    /// * "Output Cnt acts as a cycle counter; when its value reaches or exceeds TOn+TOff it is
    ///   cleared."
    /// * "**If Act=0 both outputs are cleared.**"
    ///
    /// Whichever inputs happen to be wired does not change any of that — the previous version
    /// guessed at the intent from which wires existed, so an unwired `Act` was ignored entirely.
    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        let active = inPins.count > 1 ? inPins[1].asBool : false

        guard enabled, active else {
            reset()
            return
        }

        let tOn = paramPins.count > 0 ? max(1, paramPins[0].asInt) : 1
        let tOff = paramPins.count > 1 ? max(1, paramPins[1].asInt) : 1
        let period = tOn + tOff

        // Out: high for TOn cycles, then low for TOff.
        outPins[1] = .bool(cycleCounter < tOn)
        // Cnt: a running count of cycles within the period, cleared once it reaches TOn+TOff.
        outPins[0] = .int32(Int32(cycleCounter + 1))

        cycleCounter += 1
        if cycleCounter >= period {
            cycleCounter = 0
        }
    }

    public func reset() {
        cycleCounter = 0
        outPins[0] = .int32(0)
        if outPins.count > 1 { outPins[1] = .bool(false) }
    }
}

public final class CounterBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "E37509F9-7693-49D7-977E-BAA796F92265")!
    public static let typeName = "Counter"

    public var inPins: [PinValue] = [.bool(true), .bool(false), .bool(false)] // In 0 = En, In 1 = Tr, In 2 = Rst
    public var paramPins: [PinValue] = [.int32(1)] // Param 0 = Step (St)
    public var outPins: [PinValue] = [.int32(0)] // Out 0 = Y (Count)

    private var lastTr: Bool = false
    private var currentCount: Int32 = 0

    public init() {}

    public func process(sample: SampleContext) {
        let enabled: Bool
        let tr: Bool
        let rst: Bool

        if inPins.count <= 2 {
            enabled = true
            tr = inPins.count > 0 ? inPins[0].asBool : false
            rst = inPins.count > 1 ? inPins[1].asBool : false
        } else {
            enabled = inPins[0].asBool
            tr = inPins[1].asBool
            rst = inPins[2].asBool
        }

        let step = paramPins.count > 0 ? Int32(paramPins[0].asInt) : 1

        if rst {
            currentCount = 0
            lastTr = tr
            outPins[0] = .int32(0)
            return
        }

        guard enabled else {
            lastTr = tr
            return
        }

        let rising = !lastTr && tr
        lastTr = tr

        if rising {
            currentCount &+= step
        }

        outPins[0] = .int32(currentCount)
    }

    public func reset() {
        currentCount = 0
        lastTr = false
        outPins[0] = .int32(0)
    }
}



public final class BoolVarBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "4139463D-8956-4642-BE4E-8A02E95392D3")!
    public static let typeName = "BoolVar"

    public enum Mode: Int, Sendable, CaseIterable {
        case pushButton = 2    // Impulz / momentary pulse
        case toggleSwitch = 1  // Prepnúť / stay set (latch)
        case slider = 3        // Posuvník / continuous toggle/slider
    }

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]

    public var mode: Mode = .pushButton {
        didSet {
            isPulseMode = (mode == .pushButton)
        }
    }
    public var isPulseMode: Bool = true
    private var pulseCountdown: Int = 0
    /// True while a momentary control is physically held down.
    public private(set) var isHeld: Bool = false

    public init(isPulseMode: Bool = true) {
        self.isPulseMode = isPulseMode
        self.mode = isPulseMode ? .pushButton : .toggleSwitch
    }

    public init(mode: Mode) {
        self.mode = mode
        self.isPulseMode = (mode == .pushButton)
    }

    public func setOutput(_ value: Bool) {
        outPins[0] = .bool(value)
        pulseCountdown = 0
    }

    /// The control is physically down. A momentary button stays on for exactly as long as this
    /// lasts, which is what a push button means — the previous implementation fired a fixed
    /// two-tick pulse instead, so holding the mouse down made no difference.
    public func press() {
        switch mode {
        case .pushButton:
            isHeld = true
            pulseCountdown = 0
            outPins[0] = .bool(true)
        case .toggleSwitch, .slider:
            outPins[0] = .bool(!outPins[0].asBool)
        }
    }

    /// The control was let go.
    public func release() {
        guard mode == .pushButton, isHeld else { return }
        isHeld = false
        outPins[0] = .bool(false)
    }

    /// A single-shot press, for an activation that has no matching release — a menu command, a
    /// keyboard shortcut, or the inspector's button. It holds the value for a couple of ticks so
    /// that a downstream block cannot miss the edge entirely.
    public func trigger() {
        switch mode {
        case .pushButton:
            outPins[0] = .bool(true)
            pulseCountdown = 2
        case .toggleSwitch, .slider:
            outPins[0] = .bool(!outPins[0].asBool)
        }
    }

    public func process(sample: SampleContext) {
        // A held button owns its own value; only an un-held single-shot pulse may expire.
        guard mode == .pushButton, !isHeld, pulseCountdown > 0 else { return }
        pulseCountdown -= 1
        if pulseCountdown == 0 {
            outPins[0] = .bool(false)
        }
    }

    public func reset() {
        pulseCountdown = 0
        isHeld = false
        outPins[0] = .bool(false)
    }
}

public final class SegmentBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "565E4F34-495E-4988-A572-E789AB4963E8")!
    public static let typeName = "Segment"

    // In 0 = Enable, In 1...8 = Segments A, B, C, D, E, F, G, DP
    public var inPins: [PinValue] = Array(repeating: .bool(false), count: 9)
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [] // Visualization node

    public var segmentsState: [Bool] {
        guard inPins.count >= 9 && inPins[0].asBool else {
            return Array(repeating: false, count: 8)
        }
        return (1...8).map { inPins[$0].asBool }
    }

    public init() {
        inPins[0] = .bool(true)
    }

    public func process(sample: SampleContext) {}

    public func reset() {
        for i in 1..<inPins.count { inPins[i] = .bool(false) }
    }
}

public final class EightDOBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "0F50AC33-F61E-4009-9C60-FDE664DA0ABC")!
    public static let typeName = "8xDO"

    // In 0 = En, In 1... = DO0...DO(n-1). The help lists En first and every real module carries it
    // (`ruleta_kostka_had.pcc` has 10 IN_PINs for an 8-channel block), so treating index 0 as a
    // channel reported the module's En as DO0 and shifted every real output down by one.
    public var inPins: [PinValue] = Array(repeating: .bool(false), count: 9)
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []


    /// Whether the block is enabled.
    public var isEnabled: Bool { inPins.first?.asBool ?? true }

    /// - Parameter pinCount: total input pins, *including* En.
    public init(pinCount: Int = 9) {
        inPins = Array(repeating: .bool(false), count: max(2, pinCount))
        inPins[0] = .bool(true)          // enabled by default, like every other block's En
    }

    public func process(sample: SampleContext) {}
    public func reset() {
        // The channels clear; En is configuration and stays put.
        for i in 1..<inPins.count { inPins[i] = .bool(false) }
    }
}

public final class EightDIBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "035970BC-0033-4051-A525-8579CFF78785")!
    public static let typeName = "8xDI"

    // In 0 = En. The block reads its inputs from the GUI, but the documented En pin still has to
    // exist or the engine drops the wire that carries it.
    public var inPins: [PinValue] = [.bool(true)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = Array(repeating: .bool(false), count: 8)

    /// Whether the block is enabled.
    public var isEnabled: Bool { inPins.first?.asBool ?? true }

    public init(pinCount: Int = 8) {
        outPins = Array(repeating: .bool(false), count: pinCount)
    }

    public func togglePin(_ index: Int) {
        if index >= 0 && index < outPins.count {
            let cur = outPins[index].asBool
            outPins[index] = .bool(!cur)
        }
    }

    public func process(sample: SampleContext) {}
    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .bool(false) }
    }
}

public final class InputsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "3FFBEEC3-FD74-4C54-96F7-864A9D7F5DFC")!
    public static let typeName = "Inputs"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]

    public init(count: Int = 1) {
        outPins = Array(repeating: .bool(false), count: count)
    }

    public func togglePin(_ index: Int = 0) {
        guard index < outPins.count else { return }
        outPins[index] = .bool(!outPins[index].asBool)
    }

    public func process(sample: SampleContext) {}
    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .bool(false) }
    }
}

public final class OutputsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "3FFBEEC3-FD74-4C54-96F7-864A9D7F5DFC")!
    public static let typeName = "Outputs"

    public var inPins: [PinValue] = [.bool(false)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init(count: Int = 1) {
        inPins = Array(repeating: .bool(false), count: count)
    }

    public func process(sample: SampleContext) {}
    public func reset() {
        for i in 0..<inPins.count { inPins[i] = .bool(false) }
    }
}

public final class MacroBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "848C8ACE-58B9-48D8-9CAC-DE5DB5055674")!
    public static let typeName = "Macro"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]
    public let macroName: String

    public init(macroName: String, inCount: Int = 0, paramCount: Int = 0, outCount: Int = 0) {
        self.macroName = macroName
        self.inPins = Array(repeating: .bool(false), count: inCount)
        self.paramPins = Array(repeating: .bool(false), count: paramCount)
        self.outPins = Array(repeating: .bool(false), count: outCount)
    }

    public func process(sample: SampleContext) {}
    public func reset() {
        for i in 0..<inPins.count { inPins[i] = .bool(false) }
        for i in 0..<paramPins.count { paramPins[i] = .bool(false) }
        for i in 0..<outPins.count { outPins[i] = .bool(false) }
    }
}

public final class SystemCmdBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "060906AA-5048-4931-BE5C-714697885084")!
    public static let typeName = "SystemCmd"

    // The help's table lists En, Cmd, Par1, Par2 together, but a real module separates them: the
    // `rulkoshaddirigo.pcc` instance carries 2 IN_PINS and 2 PARAM_PINS. Inputs and parameters are
    // distinct on-disk channels (see docs/spec/blocks-stateful.md), so the file wins over the table's
    // presentation and Par1/Par2 are parameters.
    public var inPins: [PinValue]                                    // En, Cmd
    public var paramPins: [PinValue]                                 // Par1, Par2
    public var outPins: [PinValue]

    public init(inPins: Int, params: Int, outPins: Int) {
        self.inPins = Array(repeating: .int32(0), count: max(1, inPins))
        self.inPins[0] = .bool(true)                                 // En
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .int32(0), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        // Every sub-function in the help (`Firmware Type`, `Firmware Version`, ...) queries the
        // unit. There is no firmware to answer, so `Out` stays at its documented default of 0
        // rather than inventing a plausible-looking version.
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }
}

// MARK: - 8xPWM Block
public final class EightPWMBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "D75D8A2C-5884-4516-83F7-D07284288D88")!
    public static let typeName = "8xPWM"

    // Help pins: En and AO0...AO7 — eight inputs and **no outputs at all**. The module drives the
    // unit's physical PWM outputs; the old block exposed eight Boolean pins that do not exist on a
    // real module, which shifted nothing but made the card show pins that can never be wired.
    public var inPins: [PinValue] = [.bool(true)] + Array(repeating: .int32(0), count: 8)
    // The help's table for this module has no parameter rows either, so N is configuration.
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    /// The instantaneous duty state of each channel. Kept because it is the block's whole job, even
    /// though it is not observable through a pin.
    public private(set) var duty: [Bool] = Array(repeating: false, count: 8)

    private var currentStep = 0

    /// PWM resolution, i.e. the help's `N`. Configuration, not a pin.
    public var pwmSteps: Int = 256

    public init(steps: Int = 256) {
        pwmSteps = max(2, steps)
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // "=0..not executed": the channels hold rather than being forced low.
        guard enabled else { return }

        let n = max(2, pwmSteps)
        currentStep = (currentStep + 1) % n

        for channel in 0..<8 {
            let value = inPins.count > channel + 1 ? inPins[channel + 1].asInt : 0
            if value <= 0 {
                duty[channel] = false
            } else if value >= n {
                duty[channel] = true
            } else {
                duty[channel] = currentStep < value
            }
        }
    }

    public func reset() {
        currentStep = 0
        duty = Array(repeating: false, count: 8)
    }
}

