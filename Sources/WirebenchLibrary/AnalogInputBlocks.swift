import Foundation
import WirebenchCore

// MARK: - Analog and counter inputs

/// `8xAI`, `ReadAI`, `IIC_8xAI`, `IIC_16xAI`, `IIC_9xDI`, `IIC_9xDICnt`, `IRC`, `Cnt`.
///
/// These read the unit's own inputs — analog channels, the counters behind them, and an incremental
/// encoder. There is no PLC here, so a reading is the only honest answer that exists: zero. That is
/// not a placeholder: "the module reads the values of the PLC analog inputs and stores them in the
/// corresponding outputs" describes exactly what happens when nothing is connected.
///
/// The pin counts are user-configurable (8-channel and 16-channel variants exist, and `ReadAI`/`Cnt`
/// take a channel selector), so the shape comes from the module rather than from a constant.
public final class HardwareInputBlock: FunctionBlock, @unchecked Sendable {
    /// Synthetic: one class backs eight Dirigo types, each registered under its own real GUID.
    public static let guid = UUID(uuidString: "9C3CEBD2-534F-5FDA-AAD8-8095CC41C2D6")!
    public static let typeName = "HardwareInput"

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    public init(inPins: Int, params: Int, outPins: Int) {
        self.inPins = Array(repeating: .int32(0), count: max(1, inPins))
        self.inPins[0] = .bool(true)                       // En, default 1
        self.paramPins = Array(repeating: .int32(0), count: params)
        self.outPins = Array(repeating: .int32(0), count: max(1, outPins))
    }

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        // "=0..not executed": every output holds rather than being re-read.
        guard enabled else { return }
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }

    public func reset() {
        for index in 0..<outPins.count { outPins[index] = .int32(0) }
    }
}
