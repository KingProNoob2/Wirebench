import Foundation
import DirigoCore

// MARK: - D3-Net
//
// The help describes one subsystem, not seventeen unrelated blocks: the `D3NR*` readers "store the
// values read from the network in an internal buffer", and `Store*Data` then reads that buffer and
// "should come immediately after the D3NRInt/D3NRIntMtx reading module". The writers push local
// values out. All of them require thread 3.
//
// There is no D3-Net network in a simulation, so nothing can actually be read or written. Rather
// than invent plausible traffic, the buffer exists and is populated with the only value that is
// true in its absence — zero — and `St` reports that no link was established. That keeps a
// reader → Store chain coherent and deterministic instead of fabricating readings.

/// The internal buffer the readers fill and `Store*Data` drains, one area per element kind.
public final class D3NetBuffer: @unchecked Sendable {
    public static let shared = D3NetBuffer()
    /// The help does not fix a size; 256 covers the matrix forms without being unbounded.
    public static let capacity = 256

    private let lock = NSLock()
    private var areas: [String: [Double]] = [:]

    public init() {}

    private func key(_ element: IntArrayStore.Element) -> String {
        element == .floating ? "float" : "int"
    }

    /// Fills the addressed span with zeros, which is what "read from an absent network" yields.
    public func fill(element: IntArrayStore.Element, offset: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        var area = areas[key(element)] ?? Array(repeating: 0, count: Self.capacity)
        for index in offset..<(offset + count) where index >= 0 && index < area.count {
            area[index] = 0
        }
        areas[key(element)] = area
    }

    public func read(element: IntArrayStore.Element, offset: Int, count: Int) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        guard let area = areas[key(element)] else { return Array(repeating: 0, count: count) }
        return (0..<count).map { index in
            let i = offset + index
            return (i >= 0 && i < area.count) ? area[i] : 0
        }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        areas.removeAll()
    }
}

/// `D3NRInt`, `D3NRLong`, `D3NRFloat` and their `Mtx` forms.
public final class D3NetReadBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic: one class backs six Dirigo types, each registered under its own real GUID.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D1")!
    public static let typeName = "D3NetRead"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    private let element: IntArrayStore.Element

    public init(inPins: Int, params: Int, outPins: Int, element: IntArrayStore.Element) {
        self.element = element
        self.inPins = Array(repeating: .int32(0), count: max(1, inPins))
        self.inPins[0] = .bool(true)                      // En
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .bool(false), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // "=0..not executed": the buffer and every output hold.
        guard enabled else { return }

        // Addr, WID (and the matrix geometry) are the leading parameters.
        let address = paramPins.count > 1 ? paramPins[1].asInt : 0
        D3NetBuffer.shared.fill(element: element, offset: max(0, address), count: 16)

        // `St` = 1 means the read succeeded. No network, so no success — reported honestly rather
        // than as a plausible-looking 1.
        for index in 0..<outPins.count { outPins[index] = .bool(false) }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .bool(false) }
    }
}

/// `D3NWInt`, `D3NWLong`, `D3NWFloat` and their `Mtx` forms.
public final class D3NetWriteBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic, for the same reason as `D3NetReadBlock.guid`.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D2")!
    public static let typeName = "D3NetWrite"

    public var inPins: [PinValue] = [.bool(true)]        // En
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    public init(inPins: Int, params: Int, outPins: Int) {
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .bool(false), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        // Nothing is transmitted, so the write did not succeed. The parameters still hold the
        // configured Addr/WID/Val, which is what the sheet needs to display them.
        for index in 0..<outPins.count { outPins[index] = .bool(false) }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .bool(false) }
    }
}

/// `StoreIntData`, `StoreLongData`, `StoreFloatData` — drains the internal buffer.
///
/// The output count is user-configurable, so it comes from the module.
public final class D3NetStoreBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic, for the same reason as `D3NetReadBlock.guid`.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D3")!
    public static let typeName = "StoreData"

    public var inPins: [PinValue] = [.bool(true)]        // En
    public var paramPins: [PinValue] = [.int32(0)]       // Ofs
    public var outPins: [PinValue]

    private let element: IntArrayStore.Element

    public init(inPins: Int, params: Int, outPins: Int, element: IntArrayStore.Element) {
        self.element = element
        self.paramPins = Array(repeating: .int32(0), count: max(1, params))
        self.outPins = Array(repeating: element == .floating ? .float(0) : .int32(0),
                             count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let offset = paramPins.count > 0 ? paramPins[0].asInt : 0
        let values = D3NetBuffer.shared.read(element: element, offset: offset, count: outPins.count)
        for (index, value) in values.enumerated() where index < outPins.count {
            outPins[index] = element == .floating
                ? .float(Float(value))
                : .int32(Int32(truncatingIfNeeded: Int(value)))
        }
    }

    public func reset() {
        for index in 0..<outPins.count {
            outPins[index] = element == .floating ? .float(0) : .int32(0)
        }
    }
}

