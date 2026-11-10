import Foundation
import WirebenchCore

/// The extra properties this app knows about, by block name.
///
/// Add an entry here when a block needs to carry something the original Dirigo has no concept of.
/// The value is stored in the `.pcc` as an `X_`-prefixed attribute, so it survives editing in this
/// app, and `counterpart` decides what happens to it when the project is exported back to Dirigo.
///
/// ```swift
/// public static let declared: [String: [ExtraPropertyDeclaration]] = [
///     "PulseGen": [
///         ExtraPropertyDeclaration(
///             name: "RampTime",
///             type: .int,
///             defaultValue: .int(0),
///             // Dirigo counts in seconds, this app in milliseconds.
///             counterpart: .dirigoAttribute("TI", transform: { value in
///                 guard let ms = value.doubleValue else { return nil }
///                 return String(ms / 1000)
///             }),
///             summary: "Edge ramp time in milliseconds"),
///     ],
/// ]
/// ```
///
/// A declaration is a statement about what a block *means*, so only what the app really adds is here.
/// Until a block is declared, extras are removed on export and the export report says so.
public enum ExtraPropertyCatalog {

    /// How far the slider on an `IntVar` / `LongVar` goes, for a block that has no `HighValue`. Dirigo writes a slider as
    /// `SimulMode="3" HighValue="…"` and that is read and kept as it is; this is only for a maximum set here on a block without one, so on
    /// export it is removed — and only blocks whose maximum was changed carry it, so only they are reported.
    private static let sliderMax = ExtraPropertyDeclaration(
        name: "SliderMax", type: .int, defaultValue: .int(Int32(BlockInteraction.defaultSliderMax)),
        counterpart: .drop, summary: "Largest value of the block's slider")

    public static let declared: [String: [ExtraPropertyDeclaration]] = [
        "IntVar": [sliderMax],
        "LongVar": [sliderMax],
    ]

    /// The same declarations keyed by GUID, which is what the translator works in — a GUID does not
    /// change when an instance is renamed.
    public static let byGuid: [UUID: [ExtraPropertyDeclaration]] = {
        var result: [UUID: [ExtraPropertyDeclaration]] = [:]
        for (blockName, declarations) in declared {
            guard let info = BlockTypeCatalog.info(forBlockName: blockName) else { continue }
            result[info.guid] = declarations
        }
        return result
    }()

    /// Every declaration for a block type, empty when it has none.
    public static func declarations(forBlockName name: String) -> [ExtraPropertyDeclaration] {
        declared[name] ?? []
    }
}
