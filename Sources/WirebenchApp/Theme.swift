import SwiftUI
import WirebenchModel
import WirebenchLibrary

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
    static var wireIdle: Color { Color.primary.opacity(0.32) }
    static var wireLive: Color { Color.accentColor }

    /// A flat hairline edge. This used to be a light-to-dark specular gradient; gradients were
    /// removed by request, so panels now get a single subtle stroke.
    static var panelStroke: Color { Color.primary.opacity(0.14) }

    static var softShadow: Color { Color.black.opacity(0.28) }

    // MARK: - Block card contrast tokens

    static func canvasBackdrop(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.90)
    }

    static func cardFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.23) : Color.white
    }

    static func cardStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.24)
    }

    static func cardShadow(for colorScheme: ColorScheme, isSelected: Bool) -> Color {
        if colorScheme == .dark {
            return Color.black.opacity(isSelected ? 0.56 : 0.44)
        }
        return Color.black.opacity(isSelected ? 0.24 : 0.16)
    }

    static func pinPrimaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88)
    }

    static func pinSecondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color.black.opacity(0.70)
    }

    static func pinBeadIdleFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.22)
    }

    static func pinBeadIdleStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.32) : Color.black.opacity(0.30)
    }

    static func pinBeadHighStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.50) : Color.black.opacity(0.25)
    }

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

// MARK: - Appearance

extension AppearanceMode {
    /// `nil` leaves the choice to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
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

/// A block card's face: solid grey, not a blur. A material re-blurs what is behind it whenever the card or the sheet moves, for every card on the
/// sheet; a flat grey costs nothing and reads the same on any background. A selected block's tint is laid over it.
private struct GreyCardSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let tintOpacity: Double
    let shadowColor: Color?
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if let shadowColor, shadowRadius > 0 {
                        shape.fill(Theme.cardFill(for: colorScheme))
                            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
                    } else {
                        shape.fill(Theme.cardFill(for: colorScheme))
                    }
                    if let tint {
                        shape.fill(tint.opacity(tintOpacity))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(Theme.cardStroke(for: colorScheme), lineWidth: 1)
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

    /// The surface used for *content* (the block cards), as opposed to chrome: flat grey.
    ///
    /// Apple's guidance is that Liquid Glass belongs to the navigation and control layer, not to
    /// content, and there is a hard performance reason too: glass and materials blur the backdrop
    /// behind each shape independently, and a full sheet has dozens of cards. Glass was replaced by a
    /// material once (which roughly halved canvas render cost), and the material by solid grey.
    /// Chrome (the zoom control, inspector hero tiles, dialogs) still uses the real glass effect.
    func cardSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        tintOpacity: Double = 0.10,
        shadowColor: Color? = nil,
        shadowRadius: CGFloat = 0,
        shadowY: CGFloat = 0
    ) -> some View {
        modifier(GreyCardSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            tintOpacity: tintOpacity,
            shadowColor: shadowColor,
            shadowRadius: shadowRadius,
            shadowY: shadowY
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

// MARK: - Glass buttons and groups

extension View {
    /// The system's glass button on macOS 26, a plain bordered one before. `prominent` is the tinted, main-action one.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Glass shapes that blend and morph into one another on macOS 26 (a selection moving from row to row); on earlier systems, the content as it is.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Signal indicator

/// A small bead showing a live pin value: a plain dot, lit or not. No halo, no blur, no shadow —
/// there is one of these per pin, so anything expensive here is paid hundreds of times over.
struct PinBead: View {
    let isHigh: Bool
    var scale: CGFloat = 1
    var tint: Color = Theme.signalHigh
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(isHigh ? tint : Theme.pinBeadIdleFill(for: colorScheme))
            .overlay {
                Circle().strokeBorder(
                    isHigh ? Theme.pinBeadHighStroke(for: colorScheme) : Theme.pinBeadIdleStroke(for: colorScheme),
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Theme.canvasBackdrop(for: colorScheme)
            .ignoresSafeArea()
    }
}
