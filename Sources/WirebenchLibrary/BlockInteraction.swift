import Foundation
import WirebenchCore

/// How a block can be driven from the user interface.
///
/// This is derived from the module's **recovered block type** — never from its instance name.
/// The earlier name-substring heuristic gave a push-button to any block whose name contained
/// "switch" (including `ISwitch`, which is a multiplexer, not a control) or "input" (even though
/// those blocks' individual pins are already clickable).
public enum BlockInteraction: Sendable, Equatable {
    /// Display only.
    case none
    /// A single control: `BoolVar`, whether it is a momentary pulse button or a latch.
    case control
    /// A variable set by a slider on its card: `IntVar` and `LongVar`.
    case slider
    /// Individually clickable output pins: the macro `Inputs` block and `8xDI`.
    case pinToggles


    /// The slider's largest value on an `IntVar` / `LongVar` when the project does not say.
    public static let defaultSliderMax = 100

    /// The affordance a module should be given, based on what the block actually is.
    public static func classify(_ module: PCCModule) -> BlockInteraction {
        guard let info = BlockTypeCatalog.info(forGuid: module.guid) else {
            // An unrecognised type runs as an inert `UnresolvedBlock`; it has no controls.
            return .none
        }
        switch info.blockName {
        case "BoolVar":
            return .control
        case "IntVar", "LongVar":
            return .slider
        case "8xDI":
            return .pinToggles
        case "Macro IO":
            // `TMacroInterface` backs both the Inputs block (KIND 0) and the Outputs block
            // (KIND 1); only Inputs carries user-driven values.
            return module.rawAttributes["KIND"] == "1" ? .none : .pinToggles
        default:
            return .none
        }
    }
}
