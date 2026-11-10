import Foundation
import WirebenchCore

// MARK: - Physical I/O
//
// These blocks write to (or read from) the unit's own hardware. They have no module-visible
// behaviour to simulate, so what matters is the pin surface: a wrong count or order silently shifts
// every wire on the sheet. Pin counts therefore come from the module.


/// `ReadDallas` — "reads the temperature from a single Dallas DS18B20 thermometer identified by the
/// unique code on the Code input".
///
/// With no bus there is no device to answer, so `St` reports 0 and `T` stays 0 rather than inventing
/// a plausible temperature. Both hold while disabled.
public final class ReadDallasBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "24007AAA-F865-4445-8E34-D931F415B30F")!
    public static let typeName = "ReadDallas"

    public var inPins: [PinValue] = [.bool(true)]        // En
    public var paramPins: [PinValue] = [.int32(0)]       // Code (Rom Code)
    public var outPins: [PinValue] = [.bool(false), .int32(0)]   // St, T

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }
        outPins[0] = .bool(false)   // no device on the bus
        outPins[1] = .int32(0)
    }

    public func reset() {
        outPins = [.bool(false), .int32(0)]
    }
}
