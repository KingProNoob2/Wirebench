import Foundation
import DirigoCore

// MARK: - Timer Block (All 4 Dirigo TTimerMode variants)
public final class TimerBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "80945F79-BD39-4629-AB89-948E9BEAFE89")!
    public static let typeName = "Timer"

    public enum Mode: Int, Sendable {
        case onDelay = 0               // tmOnDelay (TON)
        case onDelayContinuous = 1     // tmOnDelayContinuous
        case fixedPulse = 2            // tmFixedPulse (TP)
        case truncatedPulse = 3        // tmTruncatedPulse
    }

    // Help order: En, In, Rst. Omitting En meant the module's En wire drove the timer.
    public var inPins: [PinValue] = [.bool(true), .bool(false), .bool(false)]
    // `Dly` default is 1 per the help, not 10.
    public var paramPins: [PinValue] = [.int32(1)] // Preset time PT (in ticks/cycles)
    public var outPins: [PinValue] = [.bool(false), .int32(0)] // Out 0 = Q, Out 1 = ET (Elapsed Time)

    public var mode: Mode = .onDelay
    private var elapsedTicks: Int = 0
    private var lastIn: Bool = false

    public init(mode: Mode = .onDelay) {
        self.mode = mode
    }

    public func process(sample: SampleContext) {
        // "not executed": hold the outputs rather than driving them low.
        guard inPins.count > 0, inPins[0].asBool else { return }
        let currentIn = inPins.count > 1 ? inPins[1].asBool : false
        let rst = inPins.count > 2 ? inPins[2].asBool : false
        let pt = paramPins.count > 0 ? max(1, paramPins[0].asInt) : 10

        if rst {
            reset()
            lastIn = currentIn
            return
        }

        switch mode {
        case .onDelay:
            if currentIn {
                if elapsedTicks < pt {
                    elapsedTicks += 1
                }
                outPins[0] = .bool(elapsedTicks >= pt)
            } else {
                elapsedTicks = 0
                outPins[0] = .bool(false)
            }

        case .onDelayContinuous:
            if currentIn {
                elapsedTicks += 1
                outPins[0] = .bool(elapsedTicks >= pt)
            } else {
                outPins[0] = .bool(false)
            }

        case .fixedPulse:
            let rising = !lastIn && currentIn
            if rising && elapsedTicks == 0 {
                elapsedTicks = 1
                outPins[0] = .bool(true)
            } else if elapsedTicks > 0 {
                if elapsedTicks < pt {
                    elapsedTicks += 1
                    outPins[0] = .bool(true)
                } else {
                    outPins[0] = .bool(false)
                    if !currentIn {
                        elapsedTicks = 0
                    }
                }
            } else {
                outPins[0] = .bool(false)
            }

        case .truncatedPulse:
            let rising = !lastIn && currentIn
            if rising {
                elapsedTicks = 1
                outPins[0] = .bool(true)
            } else if currentIn && elapsedTicks > 0 && elapsedTicks < pt {
                elapsedTicks += 1
                outPins[0] = .bool(true)
            } else {
                elapsedTicks = 0
                outPins[0] = .bool(false)
            }
        }

        lastIn = currentIn
        outPins[1] = .int32(Int32(elapsedTicks))
    }

    public func reset() {
        elapsedTicks = 0
        lastIn = false
        outPins[0] = .bool(false)
        outPins[1] = .int32(0)
    }
}

// MARK: - Ramp Block (Rate-of-Change Limiter)
public final class RampBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "03F8EC0B-5B59-43F3-ADB2-3B3BBC186BD8")!
    public static let typeName = "Ramp"

    // Help pins: En, X in; SU/SD parameters (both default 0); Y out. The old block had one input, so
    // it ramped towards the *En* value (0 or 1) and X was dropped, and its rates were Floats
    // defaulting to 1.0 rather than the documented Int 0.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]                  // En, X
    public var paramPins: [PinValue] = [.int32(0), .int32(0)]                 // SU, SD
    public var outPins: [PinValue] = [.int32(0)]                              // Y

    private var value = 0

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = inPins.count > 1 ? inPins[1].asInt : 0
        let stepUp = max(0, paramPins.count > 0 ? paramPins[0].asInt : 0)
        let stepDown = max(0, paramPins.count > 1 ? paramPins[1].asInt : 0)

        // "In each cycle Y is increased or decreased by at most SU/SD." With the documented
        // defaults of 0 an unconfigured ramp stands still.
        if x > value {
            value = min(x, value + stepUp)
        } else if x < value {
            value = max(x, value - stepDown)
        }
        outPins[0] = .int32(Int32(value))
    }

    public func reset() {
        value = 0
        outPins[0] = .int32(0)
    }
}


// MARK: - Valve Block (Three-Point Motorized Valve Positioning)
public final class ValveBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "51067C30-0E78-4519-9C4E-8AB38D4426D0")!
    public static let typeName = "Valve"

    // Help pins: En, Op, Cl — plus parameters St/Max/Min and a single Int output. The old block had
    // two inputs and no En, so `En` drove Open and `Op` drove Close, with `Cl` unreachable and
    // three outputs where the help has one.
    public var inPins: [PinValue] = [.bool(true), .bool(false), .bool(false)]   // En, Op, Cl
    public var paramPins: [PinValue] = [.int32(1), .int32(0), .int32(0)]         // St, Max, Min
    public var outPins: [PinValue] = [.int32(0)]                                 // Y

    private var value = 0

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }         // not executed: hold

        let open = inPins.count > 1 ? inPins[1].asBool : false
        let close = inPins.count > 2 ? inPins[2].asBool : false
        let step = paramPins.count > 0 ? paramPins[0].asInt : 1
        let maximum = paramPins.count > 1 ? paramPins[1].asInt : 0
        let minimum = paramPins.count > 2 ? paramPins[2].asInt : 0

        // "If one of the inputs Op or Cl is active, the output value is increased or decreased by
        // St in every process cycle. If both inputs are 0, or both are 1, output Y does not change."
        if open != close {
            value += open ? step : -step
        }
        // "The resulting value is also limited by the parameters Min and Max."
        if value > maximum { value = maximum }
        if value < minimum { value = minimum }
        outPins[0] = .int32(Int32(value))
    }

    public func reset() {
        value = 0
        outPins[0] = .int32(0)
    }
}


// MARK: - Water Regulator (PID Heating / Cooling Controller)
public final class WaterRegulatorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "82FD83B4-6F13-4B7F-B63F-F2A1F4339415")!
    public static let typeName = "WaterRegulator"

    // Help pins: En, T in; ReqT, InsensBand, HalfHyst, Cooling as parameters; Op/Cl out.
    //
    // The old implementation was a PID with two Float inputs and a 0-100 % output — a different
    // algorithm on a different pin surface. The help specifies a dead-band comparator with
    // hysteresis driving a mixing valve, so an existing project was controlling nothing.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]                      // En, T
    public var paramPins: [PinValue] = [.int32(0), .int32(0), .int32(0), .bool(false)] // ReqT, InsensBand, HalfHyst, Cooling
    public var outPins: [PinValue] = [.bool(false), .bool(false)]                 // Op, Cl

    private var openLatch = false
    private var closeLatch = false

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let temperature = inPins.count > 1 ? inPins[1].asInt : 0
        let required = paramPins.count > 0 ? paramPins[0].asInt : 0
        let band = paramPins.count > 1 ? paramPins[1].asInt : 0
        let half = paramPins.count > 2 ? paramPins[2].asInt : 0
        let cooling = paramPins.count > 3 ? paramPins[3].asBool : false

        // The help's four inequalities, verbatim, on the difference (T - ReqT):
        //   Cl set when d >  band+half,  cleared when d <  band-half
        //   Op set when d < -band-half,  cleared when d > -band+half
        // The gap between set and clear points is what makes them latched.
        let delta = temperature - required
        if delta > band + half { closeLatch = true }
        if delta < band - half { closeLatch = false }
        if delta < -band - half { openLatch = true }
        if delta > -band + half { openLatch = false }

        // "In cooling mode the logic of outputs Op and Cl is reversed."
        outPins[0] = .bool(cooling ? closeLatch : openLatch)
        outPins[1] = .bool(cooling ? openLatch : closeLatch)
    }

    public func reset() {
        openLatch = false
        closeLatch = false
        outPins = [.bool(false), .bool(false)]
    }
}


// MARK: - Stepper Driver Block (StepDrv)
public final class StepDriverBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "815660C4-1C63-4256-A8F6-B3A85C5D6D6C")!
    public static let typeName = "StepDriver"

    // The help's pin table. The old block had two inputs, so its boolean `Start` landed on the
    // `Preset` slot and the implementation then read index 1 as a *target position* — a boolean
    // consumed as a Long, with `Speed`, `StartS`, `Accel`, `Posit` and `PrPos` unreachable. Its
    // outputs were `CurrentPos/StepPulse/Dir` rather than the documented `Run/Spd/Pos`, so a wire
    // on `Pos` read a step pulse and one on `Run` read a position.
    public var inPins: [PinValue] = [
        .bool(true),    // En
        .bool(false),   // Start
        .bool(false),   // Preset
        .int32(0),      // Speed   — units of 10 Hz; 0 stops
        .int32(32),     // StartS  — ramp applies above this
        .int32(64),     // Accel   — 1...255
        .int32(0),      // Posit   — target position (Long)
        .int32(0),      // PrPos   — preset position (Long)
    ]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false), .int32(0), .int32(0)]   // Run, Spd, Pos

    private var position = 0
    private var speed = 0        // instantaneous, same units as `Speed`
    private var target = 0
    /// True between a `Start` and reaching the target. Without this the driver would "run" back to
    /// position 0 after a `Preset`, since the target defaults to zero.
    private var commanded = false

    public init() {}

    public func process(sample: SampleContext) {
        // `En = 0` means the block is not executed at all, so every output and all state hold.
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let start = inPins.count > 1 ? inPins[1].asBool : false
        let preset = inPins.count > 2 ? inPins[2].asBool : false
        let requested = inPins.count > 3 ? inPins[3].asInt : 0
        let startSpeed = inPins.count > 4 ? inPins[4].asInt : 32
        let accel = max(1, inPins.count > 5 ? inPins[5].asInt : 64)
        let posit = inPins.count > 6 ? inPins[6].asInt : 0
        let prpos = inPins.count > 7 ? inPins[7].asInt : 0

        // "Preset ... can only be performed while the motor is standing (Run = 0)."
        if preset && speed == 0 {
            position = prpos
        }

        // "Start ... starts the motor moving from Pos to the target given by Posit."
        if start {
            target = posit
            commanded = true
        }

        // Ramp the instantaneous speed toward the requested one. "The acceleration only takes
        // effect at speeds above StartSpeed", so below it the speed jumps straight to the request.
        if requested == 0 {
            speed = max(0, speed - accel)
        } else if speed < requested {
            speed = speed >= startSpeed ? min(requested, speed + accel) : requested
        } else if speed > requested {
            speed = max(requested, speed - accel)
        }

        // The help gives Speed in units of 10 Hz; one execution advances that many steps. This is a
        // cycle-based approximation of the hardware pulse train, which is not observable in a .pcc.
        let distance = target - position
        if speed > 0 && distance != 0 && commanded {
            let step = min(abs(distance), speed)
            position += distance > 0 ? step : -step
            if position == target { commanded = false }   // arrived: Run goes to 0
        }

        outPins[0] = .bool(speed > 0 && (target - position) != 0 && commanded)   // Run
        outPins[1] = .int32(Int32(speed))                            // Spd
        outPins[2] = .int32(Int32(position))                         // Pos
    }

    public func reset() {
        position = 0
        speed = 0
        target = 0
        commanded = false
        outPins = [.bool(false), .int32(0), .int32(0)]
    }
}


// MARK: - Hysteresis Comparator Block
public final class HysteresisComparatorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "55518D69-608C-482B-BBB7-18DF9A9EB073")!
    public static let typeName = "HystComparator"

    // Help pins: En, A, B in; HalfHyst parameter; AGtB/AEqB/ALtB out. The old block was a
    // three-Float, one-Bool threshold comparator with no hysteresis and no A/B comparison at all.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]   // En, A, B
    public var paramPins: [PinValue] = [.int32(0)]                        // HalfHyst
    public var outPins: [PinValue] = [.bool(false), .bool(false), .bool(false)]   // AGtB, AEqB, ALtB

    private var greater = false
    private var less = false

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let a = inPins.count > 1 ? inPins[1].asInt : 0
        let b = inPins.count > 2 ? inPins[2].asInt : 0
        let half = max(0, paramPins.count > 0 ? paramPins[0].asInt : 0)

        // The comparison latches outside the band and holds inside it — that is the hysteresis.
        // AEqB reports the band itself, which is why it can overlap neither latch.
        if a > b + half {
            greater = true
            less = false
        } else if a < b - half {
            less = true
            greater = false
        }
        let equal = a >= b - half && a <= b + half

        outPins[0] = .bool(greater)
        outPins[1] = .bool(equal)
        outPins[2] = .bool(less)
    }

    public func reset() {
        greater = false
        less = false
        outPins = [.bool(false), .bool(false), .bool(false)]
    }
}


// MARK: - Multi-Stage Comparator Block
public final class MultiComparatorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "6AD541B3-82E9-4AF6-9396-F7AA8ACF2754")!
    public static let typeName = "MultiComparator"

    // Help pins: En, X. The constants `C1..Cn` (1..16, configurable) are parameters. The old block
    // had no En — so `X` was read from the En slot — and it returned the highest threshold X had
    // reached, a level/stage function rather than the documented equality search.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = [.int32(0)]   // C1..Cn
    public var outPins: [PinValue] = [.int32(0)]     // N, 1-based ordinal of the first match, else 0

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = inPins.count > 1 ? inPins[1].asInt : 0

        // "N = the ordinal of the FIRST constant equal to X, 0 if none."
        var ordinal = 0
        for (index, constant) in paramPins.enumerated() where constant.asInt == x {
            ordinal = index + 1
            break
        }
        outPins[0] = .int32(Int32(ordinal))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


// MARK: - Structured Control Flow Blocks (If / Else / EndIf)
public final class IfBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "6B0C4496-86AB-4113-A91C-4022FE6DC7CA")!
    public static let typeName = "If"

    public var inPins: [PinValue] = [.bool(true)] // Condition
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(true)] // TrueBranchActive

    public init() {}

    public func process(sample: SampleContext) {
        outPins[0] = inPins.first ?? .bool(true)
    }

    public func reset() {
        outPins[0] = .bool(true)
    }
}

public final class ElseBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "76D0013D-0CF1-406C-8366-16E299A0F7EC")!
    public static let typeName = "Else"

    // A label, like `Case`: the engine flips the innermost condition bit here. It has no pins —
    // the old block's input/output were invented and the engine never consulted them.
    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init() {}

    public func process(sample: SampleContext) {}
    public func reset() {}
}

public final class EndIfBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "506CF9FC-364B-47AF-8E3F-965F94224B06")!
    public static let typeName = "EndIf"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(true)]

    public init() {}
    public func process(sample: SampleContext) { outPins[0] = .bool(true) }
    public func reset() { outPins[0] = .bool(true) }
}

// MARK: - Switch / Case / Default / EndSwitch Blocks
public final class SwitchBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "D99B35AC-31D2-40B0-B529-12C8C9B356BB")!
    public static let typeName = "Switch"

    // Help pins: En, Sw — and no outputs. `En` is the construct's own condition (like `If`), and
    // `Sw` is the selector the engine captures once per activation. The old block had a single
    // input and a pass-through output that the original does not have.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init() {}

    public func process(sample: SampleContext) {}
    public func reset() {}
}

public final class CaseBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "4D83C589-DE5F-4FB1-9222-F5836722340B")!
    public static let typeName = "Case"

    // A label inside a `Switch`: no pins of its own. The accepted value set is configuration —
    // written by the config dialog as `VALUES`, e.g. "1, 5..7, 9" — and it is matched against the
    // enclosing switch's captured selector. See docs/spec/blocks-stateful.md.
    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []
    public var values: [ClosedRange<Int>] = []

    public init() {}
    public init(valuesSpec: String) {
        self.values = CaseBlock.parse(valuesSpec)
    }

    /// Parses the config dialog's value list: comma- or semicolon-separated items, each either a
    /// single number (`7`) or a range (`5..7`, `5-7`). Anything unrecognised is ignored rather
    /// than guessed at.
    public static func parse(_ spec: String) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for raw in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let item = raw.trimmingCharacters(in: .whitespaces)
            if item.isEmpty { continue }
            let parts = item.components(separatedBy: "..").count > 1
                ? item.components(separatedBy: "..")
                : item.components(separatedBy: "-")
            if parts.count == 2, let lo = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let hi = Int(parts[1].trimmingCharacters(in: .whitespaces)), lo <= hi {
                ranges.append(lo...hi)
            } else if let value = Int(item) {
                ranges.append(value...value)
            }
        }
        return ranges
    }

    public func accepts(_ selector: Int) -> Bool {
        values.contains { $0.contains(selector) }
    }

    public func process(sample: SampleContext) {}
    public func reset() {}
}

public final class ResultsBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "DCBB46C5-E84E-4E0C-9272-15AF376A34B5")!
    public static let typeName = "Results"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init(count: Int = 1) {
        inPins = Array(repeating: .int32(0), count: max(1, count))
        outPins = Array(repeating: .int32(0), count: max(1, count))
    }

    public func process(sample: SampleContext) {
        for i in 0..<min(inPins.count, outPins.count) {
            outPins[i] = inPins[i]
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .int32(0) }
    }
}


// MARK: - Default / EndSwitch

/// The `Default` arm of a `Switch`: a label, no pins. The engine marks its condition as satisfied
/// when no `Case` in the construct matched the selector.
public final class DefaultBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "A99FFBCE-0803-4939-AB9D-DE413F16A36F")!
    public static let typeName = "Default"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init() {}
    public func process(sample: SampleContext) {}
    public func reset() {}
}

/// Terminates a `Switch`. Inherits `EndIf`'s behaviour in the original: it pops the condition bit
/// and the construct stack, and it is the module that *owns* the output pins `Results` writes into.
public final class EndSwitchBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "0E92235F-6CE0-4FEC-8EB4-556846E16695")!
    public static let typeName = "EndSwitch"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init() {}
    public func process(sample: SampleContext) {}
    public func reset() {}
}
