import Foundation
import DirigoCore

// MARK: - DelayFilter

/// Filters short pulses of a binary value.
///
/// Documented behaviour (`extracted_chm/ModuleDelayFilter.html`):
///
/// * `En`  (input, Boolean, default 1) — when 0 the function is not executed.
/// * `In`  (input, Boolean, default 0) — the signal being filtered.
/// * `Dly` (parameter, Int, default 0) — the delay length, in passes through this thread.
/// * `Cnt` (output, Int) — countdown of the remaining cycles.
/// * `Out` (output, Boolean) — the filtered signal.
///
/// "If a logical 1 appears on input `In`, the module starts counting the passes through the
/// process cycle in which it is processed. The initial countdown value `Cnt` equals the size of
/// the parameter `Dly` and is decremented by 1 with each cycle while the input is active. After
/// counting down to 0, a logical 1 is set on output `Out`. Whenever input `In` is cleared,
/// output `Out` is also cleared and `Cnt` is set to the value of the parameter `Dly`."
///
/// The help does not pin down whether the first active cycle already decrements; this
/// implementation decrements on every active cycle so that a `Dly` of *n* cycles produces `Out`
/// after exactly *n* cycles, with `Cnt` showing the remaining count. `DelayFilterBlockTests`
/// pins that behaviour down.
public final class DelayFilterBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "FD544E0C-C661-49E9-8E85-8369AD4DB43C")!
    public static let typeName = "DelayFilter"

    // In 0 = En, In 1 = In
    public var inPins: [PinValue] = [.bool(true), .bool(false)]
    // Param 0 = Dly
    public var paramPins: [PinValue] = [.int32(0)]
    // Out 0 = Cnt (remaining cycles), Out 1 = Out (filtered signal)
    public var outPins: [PinValue] = [.int32(0), .bool(false)]

    /// Cycles still to wait. `nil` means "not armed"; it is loaded from `Dly` the first time the
    /// input goes active after having been inactive.
    private var remaining: Int?
    private var latched = false

    public init() {}

    public func process(sample: SampleContext) {
        let enabled = inPins.count > 0 ? inPins[0].asBool : true
        guard enabled else { return }

        let input = inPins.count > 1 ? inPins[1].asBool : false
        let delay = max(0, paramPins.first?.asInt ?? 0)

        if !input {
            remaining = delay
            latched = false
        } else if !latched {
            let current = remaining ?? delay
            let next = max(0, current - 1)
            remaining = next
            if next == 0 { latched = true }
        }

        if outPins.count > 0 { outPins[0] = .int32(Int32(remaining ?? delay)) }
        if outPins.count > 1 { outPins[1] = .bool(latched) }
    }

    public func reset() {
        remaining = nil
        latched = false
        if outPins.count > 0 { outPins[0] = .int32(0) }
        if outPins.count > 1 { outPins[1] = .bool(false) }
    }
}

// MARK: - Unresolved blocks

/// Stands in for a block whose type this reimplementation does not simulate.
///
/// It deliberately **does nothing**: it neither propagates values nor invents behaviour. The
/// alternative — the old passthrough fallback — silently copied the first input to
/// the first output, which produced plausible-looking but meaningless simulation results for
/// blocks that had never been implemented. An inert block makes the gap visible: callers can ask
/// `isUnresolved`, and `SimulationEngine.unresolvedModules()` lists them.
public final class UnresolvedBlock: FunctionBlock, @unchecked Sendable {
    public static let guid = UUID(uuidString: "09904072-D3B3-5455-932F-B18CA530EA60")!
    public static let typeName = "Unresolved"

    /// The Dirigo block name when the type is known from the recovered registry, otherwise the
    /// instance name from the project file.
    public let resolvedName: String
    /// The Delphi class implementing the type, when the registry knows it.
    public let delphiClass: String?
    /// Always `true`: this block is a placeholder.
    public let isUnresolved = true

    public var inPins: [PinValue]
    public var paramPins: [PinValue]
    public var outPins: [PinValue]

    public init(resolvedName: String, delphiClass: String? = nil, inCount: Int = 0, outCount: Int = 0) {
        self.resolvedName = resolvedName
        self.delphiClass = delphiClass
        self.inPins = Array(repeating: .undefined, count: max(0, inCount))
        self.paramPins = []
        self.outPins = Array(repeating: .undefined, count: max(0, outCount))
    }

    public func process(sample: SampleContext) {
        // Intentionally empty — see the type documentation.
    }

    public func reset() {
        for i in 0..<inPins.count { inPins[i] = .undefined }
        for i in 0..<outPins.count { outPins[i] = .undefined }
    }
}
