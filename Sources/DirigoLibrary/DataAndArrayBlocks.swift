
// MARK: - Integer array data area

/// The PLC's integer-array data area.
///
/// The original keeps one data area per PLC, addressed by each block's `Id` input, so the store is
/// shared rather than owned by a block: an array created by one `CreateIntArray` is visible to a
/// `ReadIntArray`/`WriteIntArray` elsewhere on the sheet. `SimulationEngine.reset()` clears it.
public final class IntArrayStore: @unchecked Sendable {
    public static let shared = IntArrayStore()
    /// The help states the identifier range is firmware-dependent and "0 to 15" on PIC32.
    public static let idRange = 0...15

    /// Element kind of an array. The `Create*Array` blocks do not record one — the accessing
    /// `Read*`/`Write*` block decides how the same storage is interpreted.
    public enum Element { case integer, floating }

    private let lock = NSLock()
    // Stored as Double so one `Id` can be seen as Int, Long or Float, matching the original's single
    // data area. Both a 32-bit int and a 32-bit float round-trip through Double exactly.
    private var arrays: [Int: [Double]] = [:]

    public init() {}

    /// Allocates or reuses the array for `id`.
    ///
    /// "If an array with the same length has already been created previously, no action is taken" —
    /// so an existing array of the right length keeps its contents. Any other length reallocates,
    /// and the old data is lost, which is what the help says happens.
    public func create(id: Int, length: Int) -> Bool {
        guard Self.idRange.contains(id), length > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        if let existing = arrays[id], existing.count == length { return true }
        arrays[id] = Array(repeating: 0, count: length)
        return true
    }

    public func readDouble(id: Int, index: Int) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let array = arrays[id], index >= 0, index < array.count else { return nil }
        return array[index]
    }

    @discardableResult
    public func writeDouble(id: Int, index: Int, value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var array = arrays[id], index >= 0, index < array.count else { return false }
        array[index] = value
        arrays[id] = array
        return true
    }

    public func read(id: Int, index: Int) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let array = arrays[id], index >= 0, index < array.count else { return nil }
        return Int32(truncatingIfNeeded: Int(array[index]))
    }

    @discardableResult
    public func write(id: Int, index: Int, value: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var array = arrays[id], index >= 0, index < array.count else { return false }
        array[index] = Double(value)
        arrays[id] = array
        return true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        arrays.removeAll()
    }
}

import Foundation
import DirigoCore

// MARK: - Variable Storage Blocks (IntVar, LongVar, FloatVar)
public final class IntVarBlock: FunctionBlock, WritableVariable, @unchecked Sendable {
    public static let guid = UUID(uuidString: "BED01E1C-997E-48A7-B4DA-9608FBA16A72")!
    public static let typeName = "IntVar"

    // The help gives this block a single output and nothing else: "The module performs no
    // operation; it only allocates space for a variable of type Int in the data block." The old
    // block invented NewVal/Wr inputs and an Init parameter, none of which exist on a real module,
    // so `Wr` could never be true and the value was frozen at construction.
    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]   // Y

    private var value: Int32 = 0

    public init(initialValue: Int32 = 0) {
        value = initialValue
        outPins = [.int32(initialValue)]
    }

    /// Writes the variable. The documented write path is the `Set`/`SetIdx` block, which the engine
    /// performs by overwriting this block's output pin.
    public func setValue(_ newValue: Int32) {
        value = newValue
        outPins[0] = .int32(newValue)
    }

    /// `Set`/`SetIdx` write through here, so the value persists across the variable's own passes.
    public func writeVariable(_ newValue: PinValue) {
        setValue(Int32(truncatingIfNeeded: newValue.asInt))
    }

    public func process(sample: SampleContext) {
        outPins[0] = .int32(value)
    }

    public func reset() {
        outPins[0] = .int32(value)
    }
}


public final class FloatVarBlock: FunctionBlock, WritableVariable, @unchecked Sendable {
    public static let guid = UUID(uuidString: "609939DE-0B5E-43F7-903F-2B743CFDEAF5")!
    public static let typeName = "FloatVar"

    // Same shape as IntVar: one output, no inputs, no parameters.
    public var inPins: [PinValue] = []
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.float(0)]   // Y

    private var value: Float = 0

    public init(initialValue: Float = 0) {
        value = initialValue
        outPins = [.float(initialValue)]
    }

    public func setValue(_ newValue: Float) {
        value = newValue
        outPins[0] = .float(newValue)
    }

    /// `Set`/`SetIdx` write through here, so the value persists across the variable's own passes.
    public func writeVariable(_ newValue: PinValue) {
        setValue(newValue.asFloat)
    }

    public func process(sample: SampleContext) {
        outPins[0] = .float(value)
    }

    public func reset() {
        outPins[0] = .float(value)
    }
}


// MARK: - Array Management Blocks
public final class CreateArrayBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "E71AED20-3AF5-4AC2-85F6-3760AB5C3746")!
    public static let typeName = "CreateIntArray"

    // Help pins: En, Id, Len -> St. The old block had *no inputs at all* — Id/Len were parameters
    // — and it emitted an Int "size" instead of the documented Boolean status.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(16)]   // En, Id, Len
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.bool(false)]                        // St

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let id = inPins.count > 1 ? inPins[1].asInt : 0
        let length = inPins.count > 2 ? inPins[2].asInt : 16

        // "Output St is set to 1 if the operation succeeded, otherwise 0."
        outPins[0] = .bool(IntArrayStore.shared.create(id: id, length: length))
    }

    public func reset() {
        outPins[0] = .bool(false)
    }
}


public final class ReadArrayBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "3979E09F-6012-4FDC-9D2D-6D073F6D8DB1")!
    public static let typeName = "ReadIntArray"

    // Help pins: En, Id, Idx -> Y. The old block had one input and one parameter, so `En` was used
    // as the *index* and neither the array identifier nor the index was ever read.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0)]   // En, Id, Idx
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]                          // Y

    /// Long arrays share the integer form; only the Float variants differ.
    public let element: IntArrayStore.Element

    public init(element: IntArrayStore.Element = .integer) {
        self.element = element
        if element == .floating { outPins = [.float(0)] }
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let id = inPins.count > 1 ? inPins[1].asInt : 0
        let index = inPins.count > 2 ? inPins[2].asInt : 0

        // "If the array Id or the Index is outside the permitted range, the value 0 is written."
        let stored = IntArrayStore.shared.readDouble(id: id, index: index) ?? 0
        outPins[0] = element == .floating ? .float(Float(stored)) : .int32(Int32(truncatingIfNeeded: Int(stored)))
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


public final class WriteArrayBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "8276B575-42B0-48C7-908B-898BC2183DEC")!
    public static let typeName = "WriteIntArray"

    // Help pins: En, Id, Idx, X -> Y. The old block's four pins were shifted, so it wrote the
    // array *identifier* into the slot and treated the index as a write-enable.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0), .int32(0)]   // En, Id, Idx, X
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]                                      // Y

    public let element: IntArrayStore.Element

    public init(element: IntArrayStore.Element = .integer) {
        self.element = element
        if element == .floating { outPins = [.float(0)] }
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        let id = inPins.count > 1 ? inPins[1].asInt : 0
        let index = inPins.count > 2 ? inPins[2].asInt : 0

        let stored = element == .floating
            ? Double(inPins.count > 3 ? inPins[3].asFloat : 0)
            : Double(inPins.count > 3 ? inPins[3].asInt : 0)

        // "writes the same value to the module output" ... and if Id or Index is out of range the
        // element is not written and "the value of output Y remains unchanged" — so Y holds.
        if IntArrayStore.shared.writeDouble(id: id, index: index, value: stored) {
            outPins[0] = element == .floating ? .float(Float(stored)) : .int32(Int32(truncatingIfNeeded: Int(stored)))
        }
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}


// MARK: - Value Display Block
/// Instantaneous signal value monitor supporting decimal, hex (0x), binary (0b),
/// custom enum mapping syntax {1:On|0:Off}, and horizontal/vertical LED bar display.
public final class ValueDisplayBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "112B3FE6-C440-4463-80EF-FDD1F6F74F56")!
    public static let typeName = "Value"

    public var inPins: [PinValue] = [.int32(0)]
    public var paramPins: [PinValue] = []
    // Display-only: the help's table and every real `<OUT_PINS/>` give this block no outputs.
    public var outPins: [PinValue] = []

    public var formatString: String = ""
    public var formattedText: String = "0"

    public init(format: String = "") {
        self.formatString = format
    }

    public func process(sample: SampleContext) {
        let val = inPins.first ?? .int32(0)
        if !outPins.isEmpty { outPins[0] = val }

        // Evaluate format string
        if formatString.hasPrefix("{") && formatString.hasSuffix("}") {
            // Enum mapping syntax: {1:Jedna|2:Dva|*:Jine}
            let inner = String(formatString.dropFirst().dropLast())
            let pairs = inner.split(separator: "|")
            var matched = false
            for pair in pairs {
                let parts = pair.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let k = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let text = String(parts[1])
                    if k == "*" || k == "\(val.asInt)" {
                        formattedText = text
                        matched = true
                        break
                    }
                }
            }
            if !matched { formattedText = "\(val.asInt)" }
        } else if formatString.contains("0x") {
            formattedText = String(format: "0x%04X", UInt32(bitPattern: val.asInt32))
        } else if formatString.contains("0b") {
            let bin = String(UInt32(bitPattern: val.asInt32), radix: 2)
            formattedText = "0b" + String(repeating: "0", count: max(0, 8 - bin.count)) + bin
        } else {
            formattedText = val.description
        }
    }

    public func reset() {
        // This block has no output pins (the help's table and every real `<OUT_PINS/>` are empty),
        // so writing outPins[0] unconditionally is an out-of-range trap.
        if !outPins.isEmpty { outPins[0] = .int32(0) }
        formattedText = "0"
    }
}

// MARK: - Date & Time Clock Generator Block
public final class DateTimeBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "B55EB21E-44AC-44EF-8E39-BF734BFFA408")!
    public static let typeName = "DateTime"

    // A real module carries 1 IN_PIN and 5 OUT_PINS (`SSemafor(1).pcc`), against the help table's
    // 2 in / 6 out: `Offs` is a parameter, and the set of outputs is user-configurable ("In the
    // module configuration dialog the output ..."). So the shape comes from the module.
    public var inPins: [PinValue] = [.bool(true)]      // En
    // `Offs` is not a pin either: a real module is 1/0/5 (`SSemafor(1).pcc`), so the offset is
    // configuration held in the module's attributes.
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue]

    /// Optional offset in seconds, added to the system time (e.g. UTC to local).
    public var offsetSeconds: Int = 0

    public init(outPins: Int = 6, offsetSeconds: Int = 0) {
        self.outPins = Array(repeating: .int32(0), count: max(1, outPins))
        self.offsetSeconds = offsetSeconds
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        // A legacy param pin is still honoured if a file carries one.
        let offset = paramPins.count > 0 ? paramPins[0].asInt : offsetSeconds
        // `sample.timestamp`, not `Date()`: the engine stamps one instant per cycle, and reading the
        // clock here instead ignored it — so a block could not be tested against a fixed time, and two
        // engines could never agree on a value. See `SimulationEngine.now`.
        let now = sample.timestamp.addingTimeInterval(TimeInterval(offset))
        let parts = DirigoEpoch.calendar.dateComponents([.hour, .minute, .second], from: now)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0, second = parts.second ?? 0

        let values: [Int32] = [
            Int32(DirigoEpoch.days(from: now)),                 // D  — days since 1 Jan 1980
            Int32(hour),                                        // H
            Int32(minute),                                      // M
            Int32(second),                                      // S
            Int32(DirigoEpoch.dayOfWeek(from: now)),            // DOW — 0 = Monday
            Int32(hour * 3600 + minute * 60 + second),          // SOD
        ]
        for index in 0..<outPins.count where index < values.count {
            outPins[index] = .int32(values[index])
        }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }
}


// MARK: - 7-Day Weekly Program Schedule Block
public final class WeekProgramBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "76CED144-3B89-434E-998A-68978C3DE167")!
    public static let typeName = "WeekProgram"

    // Help pins: En, DOW, H, M in; a single T out. The old block had three Int inputs with no En —
    // so DOW was read from the En slot and M was dropped — and it emitted two outputs: a Boolean
    // "active" that does not exist, plus the temperature.
    public var inPins: [PinValue] = [.bool(true), .int32(0), .int32(0), .int32(0)]  // En, DOW, H, M
    public var paramPins: [PinValue] = []
    public var outPins: [PinValue] = [.int32(0)]                                     // T

    public init() {}

    /// The weekly program is "configured via the module configuration dialog" and this build does
    /// not know that encoding. Rather than invent one and emit fabricated temperatures, `T` holds at
    /// its configured value. The pin surface — which is what decides where wires land — is exact.
    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
    }

    public func reset() {
        outPins[0] = .int32(0)
    }
}
