import Foundation
import WirebenchCore
import WirebenchLibrary

/// What a row of the block picker carries when it is dragged onto the sheet, and what the sheet does with it.
extension AppModel {
    public static func palettePayload(block guid: UUID) -> String { "wirebench-block:\(guid.uuidString)" }
    public static func palettePayload(macro sheet: String) -> String { "wirebench-macro:\(sheet)" }
    public static func palettePayload(interface kind: MacroInterface.Kind) -> String { "wirebench-interface:\(kind.rawValue)" }

    /// Adds what `payload` names with its middle at `point` (sheet coordinates). Reports whether anything was added;
    /// text that did not come from the picker is not.
    @MainActor @discardableResult
    public func placePaletteItem(_ payload: String, atContent point: CGPoint) -> Bool {
        let topLeft = CGPoint(x: point.x - CardGeometry.defaultWidth / 2, y: point.y - 24)
        func rest(after prefix: String) -> String? { payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil }
        if let guid = rest(after: "wirebench-block:").flatMap(UUID.init(uuidString:)) {
            return addBlock(guid: guid, at: topLeft) != nil
        }
        if let sheet = rest(after: "wirebench-macro:") {
            return addMacroCall(sheet: sheet, at: topLeft) != nil
        }
        if let kind = rest(after: "wirebench-interface:").flatMap(Int.init).flatMap(MacroInterface.Kind.init(rawValue:)) {
            return addMacroInterface(kind, at: topLeft) != nil
        }
        return false
    }
}
