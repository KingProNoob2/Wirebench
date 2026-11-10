import SwiftUI
import AppKit
import WirebenchCore

/// Turns a graphic object's pen and brush into something to draw.
///
/// Dirigo writes colors as Delphi's `TColor`: `$BBGGRR`, low byte first. `had+1block.pcc` uses
/// `$000000` for ink, `$FFFFFF` for the sheet, and `$000080` (`clMaroon`) for a highlighted wire, so
/// the byte order is settled by real files rather than by convention.
enum GraphicColor {

    /// A color decoded from Dirigo's markup, before it becomes a `Color`.
    struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

        /// Within a whisker of black, so a file hand-written at `$010000` gets the same treatment as
        /// `$000000` rather than a near-black hairline nobody can see.
        var isNearBlack: Bool { red < 0.04 && green < 0.04 && blue < 0.04 }
        var isNearWhite: Bool { red > 0.96 && green > 0.96 && blue > 0.96 }
    }

    /// The outline of a shape.
    ///
    /// Dirigo's paper is white and its ink black, which is why black is the default pen. This canvas
    /// adapts to the appearance, so black is drawn as the theme's own ink: a black outline on a dark
    /// canvas would be invisible, and on paper the two mean the same thing.
    static func pen(of graphic: ProjectGraphic) -> Color {
        guard let rgb = decode(graphic.penColor) else { return .primary }
        return rgb.isNearBlack ? .primary : rgb.color
    }

    /// The inside of a shape.
    ///
    /// `BRUSH STYLE="1"` is Delphi's `bsClear` — no fill at all. Anything else is a solid color, but a
    /// sheet-white fill is drawn as a faint wash instead: on Dirigo's white paper it is the same as no
    /// fill, and here a solid white panel would hide the blocks underneath it.
    static func brush(of graphic: ProjectGraphic) -> Color {
        if graphic.brushStyle == 1 { return .clear }
        guard let rgb = decode(graphic.brushColor) else { return .clear }
        return rgb.isNearWhite ? Color.primary.opacity(0.06) : rgb.color
    }

    /// `$BBGGRR`, or `$AABBGGRR` with the leading byte dropped — this app draws on an opaque sheet, so
    /// there is nothing for it to mean. Unreadable markup leaves the caller to pick a fallback.
    static func decode(_ text: String?) -> RGB? {
        guard var digits = text?.uppercased() else { return nil }
        if digits.hasPrefix("$") { digits.removeFirst() }
        if digits.hasPrefix("0X") { digits.removeFirst(2) }
        guard (6...8).contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        let rgb = value & 0xFF_FFFF
        return RGB(red: Double(rgb & 0xFF) / 255,
                   green: Double((rgb >> 8) & 0xFF) / 255,
                   blue: Double((rgb >> 16) & 0xFF) / 255)
    }

    /// The markup for a colour picked in the inspector, in the same `$BBGGRR` the files use — so a
    /// colour chosen here is written back exactly as Dirigo would have written it.
    static func encode(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let byte = { (component: CGFloat) in
            String(format: "%02X", max(0, min(255, Int((component * 255).rounded()))))
        }
        return "$" + byte(ns.blueComponent) + byte(ns.greenComponent) + byte(ns.redComponent)
    }
}
