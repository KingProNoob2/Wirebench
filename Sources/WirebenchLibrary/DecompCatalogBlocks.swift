
// MARK: - Dirigo's date epoch

/// Dirigo dates are "days since 1 Jan 1980", and `DOW` is 0 for Monday.
///
/// Both matter: the old date blocks decoded Unix timestamps or packed `YYYYMMDD` values, neither of
/// which is what a `.pcc` stores, so a real `Date` (about 16000) fell through and the outputs kept
/// their hard-coded defaults.
public enum DirigoEpoch {
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return c
    }

    public static var reference: Date {
        calendar.date(from: DateComponents(year: 1980, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }

    public static func days(from date: Date) -> Int {
        calendar.dateComponents([.day], from: reference, to: date).day ?? 0
    }

    public static func date(fromDays days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: reference) ?? reference
    }

    /// 0 = Monday ... 6 = Sunday, as the help specifies.
    public static func dayOfWeek(from date: Date) -> Int {
        // `Calendar` gives 1 = Sunday ... 7 = Saturday.
        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }
}

import Foundation
import WirebenchCore

// MARK: - Equitherm Block (Heating Curve Interpolation)
/// Calculates water temperature calculated by equitherm [AX, AY]-[BX, BY] from outdoor temperature (OT).
public final class EquithermBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "93F44752-514B-4B8C-A422-DF52B0677374")!
    public static let typeName = "Equitherm"

    // Help pins: En, OT in; AX/AY/BX/BY parameters; WT out. The parameters were missing, so the
    // heating curve had no points to run through and its output was fixed.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]                        // En, OT
    public var paramPins: [PinValue] = [.int32(0), .int32(0), .int32(0), .int32(0)]  // AX, AY, BX, BY
    public var outPins: [PinValue] = [.int32(0)]                                     // WT

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let ot = inPins.count > 1 ? inPins[1].asInt : 0
        guard paramPins.count >= 4 else { return }

        // "Computes the required water temperature WT as a function of the outdoor temperature OT
        // according to the heating curve" — the line through A and B. It extrapolates beyond the
        // segment, which is what a heating curve does at the ends of its range.
        let ax = paramPins[0].asInt, ay = paramPins[1].asInt
        let bx = paramPins[2].asInt, by = paramPins[3].asInt

        let wt = bx == ax ? ay : ay + (by - ay) * (ot - ax) / (bx - ax)
        outPins[0] = .int32(Int32(truncatingIfNeeded: wt))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}

// MARK: - Copy Block
/// Multi-channel value buffer/latch with optional Wr enable pin.
public final class CopyBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "63CBABBD-AB84-4E75-9E0E-CCCC4F3C81D4")!
    public static let typeName = "Copy"

    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []
    public var hasWrPin: Bool = false

    public init(count: Int = 1, hasWrPin: Bool = false) {
        self.hasWrPin = hasWrPin
        let totalIn = hasWrPin ? count + 1 : count
        inPins = Array(repeating: .int32(0), count: max(1, totalIn))
        if hasWrPin {
            inPins[0] = .bool(true)
        }
        outPins = Array(repeating: .int32(0), count: max(1, count))
    }

    public func process(sample: SampleContext) {
        if hasWrPin {
            let wr = inPins.first?.asBool ?? true
            guard wr else { return } // Hold values
            for i in 0..<outPins.count {
                let inIdx = i + 1
                if inIdx < inPins.count {
                    outPins[i] = inPins[inIdx]
                }
            }
        } else {
            for i in 0..<min(inPins.count, outPins.count) {
                outPins[i] = inPins[i]
            }
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .int32(0) }
    }
}

// MARK: - Date Encoding and Decoding Blocks
public final class EncodeDateBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "55BE1899-3119-4123-923C-508A7CE66C60")!
    public static let typeName = "EncodeDate"

    // Help pins: En, Day, Mon, Year -> Date (days since 1 Jan 1980). The old block had no En and
    // ordered the parts Year, Month, Day, so the engine mapped En onto Year and dropped the real
    // year; it also emitted Unix *seconds*, not a day count.
    public var inPins: [PinValue] = [.bool(true), .int32(1), .int32(1), .int32(2000)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]   // Date

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let day = inPins.count > 1 ? inPins[1].asInt : 1
        let month = inPins.count > 2 ? inPins[2].asInt : 1
        let year = inPins.count > 3 ? inPins[3].asInt : 2000

        guard (1...31).contains(day), (1...12).contains(month), (1980...2190).contains(year),
              let date = DirigoEpoch.calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return }   // out of the documented ranges: hold

        outPins[0] = .int32(Int32(DirigoEpoch.days(from: date)))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


public final class DecodeDateBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "A4B12957-3EB8-468A-BFD2-03CF43B560F0")!
    public static let typeName = "DecodeDate"

    // Help pins: En, Date -> Day, Mon, Year, MMDD. The old block had no En (so `Date` was read from
    // the En slot), emitted Year/Month/Day in the wrong order, and had no MMDD at all.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]   // En, Date
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0), .int32(0), .int32(0), .int32(0)]   // Day, Mon, Year, MMDD

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let days = inPins.count > 1 ? inPins[1].asInt : 0

        let date = DirigoEpoch.date(fromDays: days)
        let parts = DirigoEpoch.calendar.dateComponents([.day, .month, .year], from: date)
        let day = parts.day ?? 1, month = parts.month ?? 1, year = parts.year ?? 1980

        outPins[0] = .int32(Int32(day))
        outPins[1] = .int32(Int32(month))
        outPins[2] = .int32(Int32(year))
        outPins[3] = .int32(Int32(month * 100 + day))   // MMDD, e.g. 0101 ... 1231
    }

    public func reset() {
        outPins = Array(repeating: .int32(0), count: 4)
    }
}


// MARK: - Demultiplexer Blocks (IDemux, FDemux, LDemux)
public final class IntDemuxBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "E4DF23AE-9D4B-432B-88C2-7AE0B097A0F9")!
    public static let typeName = "IDemux"

    // In 0 = En, In 1 = Sel, In 2 = In
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [] // Out 0 ... Out N-1

    public init(outputCount: Int = 4) {
        outPins = Array(repeating: .int32(0), count: max(1, outputCount))
    }

    public func process(sample: SampleContext) {
        // The help is explicit: "The values of the other Y outputs remain unchanged", and an
        // out-of-range selector performs no write at all. Clearing every output first made a
        // demultiplexer behave like a switch with a cleared default.
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let sel = inPins.count > 1 ? inPins[1].asInt : 0
        let val = inPins.count > 2 ? inPins[2].asInt32 : 0

        if sel >= 0 && sel < outPins.count {
            outPins[sel] = .int32(val)
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .int32(0) }
    }
}

public final class FloatDemuxBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "B1ECD57E-7D15-4F61-8396-A60847D3E76D")!
    public static let typeName = "FDemux"

    public var inPins: [PinValue] = [.bool(true), .int32(0), .float(0.0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = []

    public init(outputCount: Int = 4) {
        outPins = Array(repeating: .float(0.0), count: max(1, outputCount))
    }

    public func process(sample: SampleContext) {
        // The help is explicit: "The values of the other Y outputs remain unchanged", and an
        // out-of-range selector performs no write at all. Clearing every output first made a
        // demultiplexer behave like a switch with a cleared default.
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let sel = inPins.count > 1 ? inPins[1].asInt : 0
        let val = inPins.count > 2 ? inPins[2].asFloat : 0.0

        if sel >= 0 && sel < outPins.count {
            outPins[sel] = .float(val)
        }
    }

    public func reset() {
        for i in 0..<outPins.count { outPins[i] = .float(0.0) }
    }
}

// MARK: - Advanced Counter Block (TMAdvCounter)
public final class AdvCounterBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "CBD854FF-873C-46DD-81E4-249A7D5FFF43")!
    public static let typeName = "AdvCounter"

    // Help pins: En, Tr, Rst, Pres, EnH, EnL in; PV, Max, Min, St parameters; Y, H, L out.
    //
    // The old block was a different counter entirely: En/Up/Down/Preset/Clear/Limit inputs, no
    // parameters at all, and it counted +1/-1 on Up/Down edges instead of adding `St` on a rising
    // `Tr`. Its H compared a single `limit` and its L tested `<= 0`, so neither matched Max/Min.
    public var inPins: [PinValue] = [
        .bool(true),    // En
        .bool(false),   // Tr
        .bool(false),   // Rst
        .bool(false),   // Pres
        .bool(false),   // EnH
        .bool(false),   // EnL
    ]
    public var paramPins: [PinValue] = [.int32(0), .int32(0), .int32(0), .int32(1)]  // PV, Max, Min, St
    public var outPins: [PinValue] = [.int32(0), .bool(false), .bool(false)]         // Y, H, L

    private var value = 0
    private var lastTrigger = false

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let trigger = inPins.count > 1 ? inPins[1].asBool : false
        let reset = inPins.count > 2 ? inPins[2].asBool : false
        let preset = inPins.count > 3 ? inPins[3].asBool : false
        let enableHigh = inPins.count > 4 ? inPins[4].asBool : false
        let enableLow = inPins.count > 5 ? inPins[5].asBool : false

        let presetValue = paramPins.count > 0 ? paramPins[0].asInt : 0
        let maximum = paramPins.count > 1 ? paramPins[1].asInt : 0
        let minimum = paramPins.count > 2 ? paramPins[2].asInt : 0
        let step = paramPins.count > 3 ? paramPins[3].asInt : 1

        // "On a rising edge (transition from 0 to 1) it increases Y by the value of St."
        let rising = trigger && !lastTrigger
        lastTrigger = trigger

        if reset {
            value = 0
        } else if preset {
            value = presetValue
        } else if rising {
            value += step
        }

        // Limiting only applies when the corresponding enable is active ...
        if enableHigh && value > maximum { value = maximum }
        if enableLow && value < minimum { value = minimum }

        outPins[0] = .int32(Int32(value))
        // ... but H and L report the limits regardless: "These outputs work independently of
        // whether output limiting is enabled by the EnH and EnL inputs."
        outPins[1] = .bool(value >= maximum)
        outPins[2] = .bool(value <= minimum)
    }

    public func reset() {
        value = 0
        lastTrigger = false
        outPins = [.int32(0), .bool(false), .bool(false)]
    }
}


// MARK: - Digital Filter Block (TMFilter / TMP1DelayFilter)
public final class FilterBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "93575E1B-4236-4327-9C3A-A1B93D7F1E96")!
    public static let typeName = "Filter"

    // Help pins: En, X in; T parameter (default 10); Y out. The old block had one input — so the
    // module's En was filtered as if it were the signal — a default T of 1.0, and it treated T as
    // *seconds* off the sample delta. The help gives T no unit, and a "cycle" is a pass of the
    // block's own thread, so T is a count of cycles.
    public var inPins: [PinValue] = [.bool(true), .int32(0)]   // En, X
    public var paramPins: [PinValue] = [.int32(10)]            // T
    public var outPins: [PinValue] = [.int32(0)]               // Y

    private var value: Double = 0

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let x = Double(inPins.count > 1 ? inPins[1].asInt : 0)
        let t = max(1, paramPins.count > 0 ? paramPins[0].asInt : 10)

        // First-order lag: after T cycles the output has covered 1-(1-1/T)^T, which is the "about
        // 63%" the help describes.
        value += (x - value) / Double(t)
        outPins[0] = .int32(Int32(value.rounded()))
    }

    public func reset() {
        value = 0
        outPins[0] = .int32(0)
    }
}


// MARK: - Bitwise Integer Logic Blocks (TMIntAnd, TMIntOr, TMIntXor, TMIntNot)
public final class IntAndBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "C1C74C15-7193-4282-8680-D651405F9180")!
    public static let typeName = "IntAnd"
    // In 0 = En, then the operands (help: En, X0, X1).
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]
    public init() {}
    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let a = inPins.count > 1 ? inPins[1].asInt32 : 0
        let b = inPins.count > 2 ? inPins[2].asInt32 : 0
        outPins[0] = .int32(a & b)
    }
    public func reset() { outPins[0] = .int32(0) }
}

public final class IntOrBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "E8567F34-DA1A-4336-9807-ACD8BCBD58FF")!
    public static let typeName = "IntOr"
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]
    public init() {}
    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let a = inPins.count > 1 ? inPins[1].asInt32 : 0
        let b = inPins.count > 2 ? inPins[2].asInt32 : 0
        outPins[0] = .int32(a | b)
    }
    public func reset() { outPins[0] = .int32(0) }
}

public final class IntXorBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "DC77A98A-9D9F-4852-B3ED-184BF8D36B4C")!
    public static let typeName = "IntXor"
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]
    public init() {}
    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let a = inPins.count > 1 ? inPins[1].asInt32 : 0
        let b = inPins.count > 2 ? inPins[2].asInt32 : 0
        outPins[0] = .int32(a ^ b)
    }
    public func reset() { outPins[0] = .int32(0) }
}

public final class IntNotBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "92D1553F-C8FC-4FE4-A38A-7772EBF0BED5")!
    public static let typeName = "IntNot"
    public var inPins: [PinValue] = [.bool(true), .int32(0)]
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]
    public init() {}
    public func process(sample: SampleContext) {
        guard inPins.count > 0, inPins[0].asBool else { return }
        let a = inPins.count > 1 ? inPins[1].asInt32 : 0
        outPins[0] = .int32(~a)
    }
    public func reset() { outPins[0] = .int32(0) }
}
