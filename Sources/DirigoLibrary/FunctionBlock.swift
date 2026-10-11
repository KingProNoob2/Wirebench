import Foundation
import DirigoCore

public struct SampleContext: Sendable {
    public var tickCount: UInt64
    public var deltaMs: Double
    public var timestamp: Date

    public init(tickCount: UInt64 = 0, deltaMs: Double = 10.0, timestamp: Date = Date()) {
        self.tickCount = tickCount
        self.deltaMs = deltaMs
        self.timestamp = timestamp
    }
}

public protocol FunctionBlock: AnyObject, Sendable {
    static var guid: UUID { get }
    static var typeName: String { get }

    var inPins: [PinValue] { get set }
    var paramPins: [PinValue] { get set }
    var outPins: [PinValue] { get set }

    func process(sample: SampleContext)
    func reset()
}
