import SwiftUI
import DirigoLibrary

// MARK: - Palette and metrics

/// Shared visual language for the editor.
///
/// The look is "Liquid Glass": translucent, specular panels with soft depth. macOS 26 and later
/// get Apple's real `glassEffect`; earlier systems get a material-based treatment that keeps the
/// same shapes, spacing, hairline highlights and shadows so the app looks coherent everywhere.
enum Theme {
    // Radii
    static let cardRadius: CGFloat = 11
    static let chromeRadius: CGFloat = 14
    static let chipRadius: CGFloat = 7

    // Signals
    /// A live signal. This was green, and the live wires a green of their own; both now follow the
    /// system accent, so the palette is the user's chosen accent rather than a colour we picked.
    static let signalHigh = Color.accentColor

    /// Search matches are highlighted on the sheet in this colour.
    static let searchHighlight = Color(red: 1.0, green: 0.78, blue: 0.25)


    /// Wire colours. Live wires glow; idle wires recede so the eye follows the active signal.
    static var wireIdle: Color { Color.primary.opacity(0.22) }
    static var wireLive: Color { Color.accentColor }

    /// A flat hairline edge. This used to be a light-to-dark specular gradient; gradients were
    /// removed by request, so panels now get a single subtle stroke.
    static var panelStroke: Color { Color.white.opacity(0.14) }

    static var softShadow: Color { Color.black.opacity(0.28) }

    /// Tint used for a block's category, matching the Dirigo block-palette grouping.
    static func tint(forBlockNamed name: String, guid: UUID?) -> Color {
        let info = guid.flatMap { BlockTypeCatalog.info(forGuid: $0) }
        if let info { return tint(forCategory: info.category) }
        _ = name
        return .accentColor
    }

    static func tint(forCategory category: String) -> Color {
        switch category {
        case "Bool": return .blue
        case "Math": return .indigo
        case "I/O": return .teal
        case "Communication": return .purple
        case "Vars": return .orange
        case "Visual": return .pink
        case "Macro": return .mint
        case "Thermostat": return .red
        case "Switches": return .cyan
        default:
            if category.hasPrefix("Main") { return .accentColor }
            return .accentColor
        }
    }
}

// MARK: - Glass panels

/// Applies the platform's Liquid Glass material, with a compatible fallback before macOS 26.
///
/// Generic over the shape so it can back rounded cards, capsules and chips without type erasure.
@available(macOS 26.0, *)
private struct LiquidGlassPanel<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        content.glassEffect(glass, in: shape)
    }

    private var glass: Glass {
        var value: Glass = .regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }
}

/// The pre-macOS 26 equivalent: an ultra-thin material with a top sheen and a specular hairline.
private struct MaterialGlassPanel<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(tint.opacity(tintOpacity))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(Theme.panelStroke, lineWidth: 1)
            }
    }
}

extension View {
    /// Wraps the view in a translucent panel in the app's glass language.
    @ViewBuilder
    func glassPanel<S: InsettableShape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        tintOpacity: Double = 0.10
    ) -> some View {
        if #available(macOS 26.0, *) {
            modifier(LiquidGlassPanel(shape: shape, tint: tint, interactive: interactive))
        } else {
            modifier(MaterialGlassPanel(shape: shape, tint: tint, tintOpacity: tintOpacity))
        }
    }

    func glassPanel(
        cornerRadius: CGFloat = Theme.chromeRadius,
        tint: Color? = nil,
        interactive: Bool = false,
        tintOpacity: Double = 0.10
    ) -> some View {
        glassPanel(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            interactive: interactive,
            tintOpacity: tintOpacity
        )
    }

    /// The surface used for *content* (the block cards), as opposed to chrome.
    ///
    /// Apple's guidance is that Liquid Glass belongs to the navigation and control layer, not to
    /// content, and there is a hard performance reason too: `glassEffect` samples and blurs the
    /// backdrop behind each shape independently, and a full sheet has dozens of cards. Measured on
    /// this project, switching cards to the material surface roughly halved canvas render cost.
    /// Chrome (the zoom control, inspector hero tiles, dialogs) still uses the real glass effect.
    func cardSurface(cornerRadius: CGFloat, tint: Color? = nil, tintOpacity: Double = 0.10) -> some View {
        modifier(MaterialGlassPanel(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            tintOpacity: tintOpacity
        ))
    }

    func glassCapsule(
        tint: Color? = nil,
        interactive: Bool = false,
        tintOpacity: Double = 0.10
    ) -> some View {
        glassPanel(Capsule(), tint: tint, interactive: interactive, tintOpacity: tintOpacity)
    }
}

// MARK: - Signal indicator

/// A small bead showing a live pin value: a plain dot, lit or not. No halo, no blur, no shadow —
/// there is one of these per pin, so anything expensive here is paid hundreds of times over.
struct PinBead: View {
    let isHigh: Bool
    var scale: CGFloat = 1
    var tint: Color = Theme.signalHigh

    var body: some View {
        Circle()
            .fill(isHigh ? tint : Color.primary.opacity(0.18))
            .overlay {
                Circle().strokeBorder(
                    isHigh ? Color.white.opacity(0.50) : Color.white.opacity(0.16),
                    lineWidth: 0.5 * scale
                )
            }
            .frame(width: 6 * scale, height: 6 * scale)
            .frame(width: 11 * scale, height: 11 * scale)
    }
}

// MARK: - Canvas backdrop

/// The canvas background: one flat neutral colour.
///
/// This used to be four full-window radial gradients. Besides being the "background
/// colorization" that was asked to go, they were re-rasterised on every frame of a pan or zoom —
/// which is precisely when the canvas can least afford it.
struct AmbientBackdrop: View {
    var body: some View {
        Color(nsColor: .underPageBackgroundColor)
            .ignoresSafeArea()
    }
}
