import Foundation
import WirebenchCore
import WirebenchLibrary

/// Where every bar of a seven-segment display sits. Plain geometry, so any frontend draws the same digit.
///
/// The digit is fitted to a window — the recessed panel the card gives it — and fills as much of it as its proportions allow, so a taller card
/// has a bigger digit. Bars are in the digit's own coordinates (`origin` is where its body starts in the window); `barsInWindow` has them placed.
public struct SegmentDisplayLayout: Sendable {
    /// The window the digit sits in: what the card reserves for the display.
    public let windowSize: CGSize
    /// Where the digit's body starts in the window: the bars and the point are centred in it.
    public let origin: CGPoint
    /// The digit's body: the region the seven bars occupy, excluding the decimal point.
    public let bodySize: CGSize
    /// The bars plus the decimal point — everything the window has to contain.
    public let contentSize: CGSize
    public let thickness: CGFloat
    /// Bars in A…G, DP order, matching the pin order the block uses, in the digit's own coordinates.
    public let bars: [CGRect]
    /// The window's margin around the digit, when the window is exactly as proportioned as the digit.
    public let padding: CGFloat

    /// What the whole view measures. The card reserves exactly this, so the display and the card geometry cannot drift apart.
    public var intrinsicSize: CGSize { windowSize }

    /// The bars placed in the window.
    public var barsInWindow: [CGRect] { bars.map { $0.offsetBy(dx: origin.x, dy: origin.y) } }

    /// The digit as designed: 44 wide and 76 tall, the point 8 across, 6 from the body. Everything else is this, scaled.
    private static let designBody = CGSize(width: 44, height: 76)
    private static let designContentWidth: CGFloat = 44 + 6 + 8

    /// The window's margin for a window `height` tall: 10, less in a small one.
    public static func margin(forHeight height: CGFloat) -> CGFloat { min(10, 0.08 * height) }

    /// The width at which a window `height` tall has the digit filling it, margin included.
    public static func width(forHeight height: CGFloat) -> CGFloat {
        let margin = margin(forHeight: height)
        return (height - margin * 2) * designContentWidth / designBody.height + margin * 2
    }

    /// The digit as large as fits in `window`, centred in it.
    public static func fitting(_ window: CGSize) -> SegmentDisplayLayout {
        let margin = margin(forHeight: window.height)
        let k = max(0.1, min((window.height - margin * 2) / designBody.height, (window.width - margin * 2) / designContentWidth))

        let thickness: CGFloat = 6 * k
        let bodyWidth = designBody.width * k
        let bodyHeight = designBody.height * k
        let dotSize: CGFloat = 8 * k
        let dotGap: CGFloat = 6 * k

        let half = bodyHeight / 2                 // every vertical distance mirrors about this
        let barLength = bodyWidth - thickness     // horizontals stop short of the corners
        let verticalLength = half - thickness     // verticals run between the horizontal bars

        let bars: [CGRect] = [
            // A — top, B — upper right, C — lower right, D — bottom,
            // E — lower left, F — upper left, G — middle, DP — decimal point.
            CGRect(x: thickness / 2, y: 0, width: barLength, height: thickness),
            CGRect(x: bodyWidth - thickness, y: thickness, width: thickness, height: verticalLength),
            CGRect(x: bodyWidth - thickness, y: half, width: thickness, height: verticalLength),
            CGRect(x: thickness / 2, y: bodyHeight - thickness, width: barLength, height: thickness),
            CGRect(x: 0, y: half, width: thickness, height: verticalLength),
            CGRect(x: 0, y: thickness, width: thickness, height: verticalLength),
            // G is inset by a whole thickness at each end, so it reads as a middle bar rather
            // than a third horizontal.
            CGRect(x: thickness, y: half - thickness / 2, width: bodyWidth - thickness * 2, height: thickness),
            // The point sits outside the body on the baseline — the one deliberate asymmetry, as on
            // a real display.
            CGRect(x: bodyWidth + dotGap, y: bodyHeight - dotSize, width: dotSize, height: dotSize),
        ]
        let content = CGSize(width: bodyWidth + dotGap + dotSize, height: bodyHeight)
        return SegmentDisplayLayout(windowSize: window,
                                    origin: CGPoint(x: (window.width - content.width) / 2, y: (window.height - content.height) / 2),
                                    bodySize: CGSize(width: bodyWidth, height: bodyHeight),
                                    contentSize: content, thickness: thickness, bars: bars, padding: margin)
    }

    /// The display of a card whose body is `bodyHeight` tall, with the window the geometry gives it.
    public static let standard: SegmentDisplayLayout = {
        let height = CardGeometry.segmentWindowHeight(bodyHeight: CardGeometry.segmentBodyHeight(pinCount: 9, pitch: 16))
        return fitting(CGSize(width: width(forHeight: height), height: height))
    }()
}

/// The size of a block's card and where its pins sit, shared by every frontend and by the wire router.
public enum CardGeometry {
    /// A card's width. 110 is the SwiftUI card's; a frontend that draws roomier cards sets a wider one at start-up, and the
    /// output pins, the wire router and hit-testing follow it.
    nonisolated(unsafe) public static var defaultWidth: CGFloat = 110.0

    /// The vertical space a control card gives its chip (a `BoolVar`'s `Pulse`/`LATCHED`, and the
    /// macro button). Shared with `cardHeight` so the reserved space and the drawn chip cannot
    /// drift: they had, by about 7pt, which showed up as dead space under the button.
    nonisolated public static let controlHeight: CGFloat = 28.0

    /// A `Segment` card carries its display *beside* the pin list: the pin column (names and dots, measured at about 37 pt in the
    /// SwiftUI card and 40 in the Qt one) and then the display, which is given the whole body's height and as much width as the digit
    /// needs to fill it. So a taller card has a wider, bigger digit.
    nonisolated public static let segmentPinColumn: CGFloat = 46.0
    /// The room right of the display's window.
    nonisolated public static let segmentMargin: CGFloat = 6.0
    /// The least a Segment's body is tall, for a block with few pins.
    nonisolated public static let segmentMinBody: CGFloat = 96.0

    /// The body (between header and foot) of a Segment with `pinCount` inputs: its pins, or the least the display is given.
    nonisolated public static func segmentBodyHeight(pinCount: Int, pitch: CGFloat) -> CGFloat {
        max(CGFloat(max(1, pinCount)) * pitch + 8.0, segmentMinBody)
    }

    /// The display's window is the body's height less a margin of 4 above and below.
    nonisolated public static func segmentWindowHeight(bodyHeight: CGFloat) -> CGFloat { bodyHeight - 8.0 }

    /// Where a Segment's display window sits in its card, in card coordinates; nil for any other block.
    nonisolated public static func segmentWindow(for module: PCCModule) -> CGRect? {
        guard BlockTypeCatalog.info(forGuid: module.guid)?.blockName == "Segment" else { return nil }
        let height = segmentWindowHeight(bodyHeight: segmentBodyHeight(pinCount: max(module.inPins.count, module.outPins.count), pitch: pinPitch))
        return CGRect(x: segmentPinColumn, y: Metrics.headerHeight + 4.0, width: SegmentDisplayLayout.width(forHeight: height), height: height)
    }

    /// The distance between one pin row and the next. 16 is the SwiftUI card's, which draws its rows at that pitch; a frontend
    /// that draws its own cards (the Qt one) may set a roomier value at start-up, and every pin position and the wire router
    /// follow it. Not changed while a sheet is being edited.
    nonisolated(unsafe) public static var pinPitch: CGFloat = 16

    /// The room a macro call's card keeps under its pins, for the SwiftUI card's open-macro button. A frontend with no such button
    /// sets 0, and the card is then only as tall as its pins.
    nonisolated(unsafe) public static var macroCallerSpace: CGFloat = controlHeight

    /// Layout constants. These are load-bearing: `inPinPoint`/`outPinPoint` and the wire router
    /// derive pin positions from them, so any change here must be mirrored there.
    public enum Metrics {
        public static let headerHeight: CGFloat = 23
        public static let bodyTopPadding: CGFloat = 4
        public static let pinRowHeight: CGFloat = 12
        public static let pinRowSpacing: CGFloat = 4
        /// How far inside the card's edge a pin's bead is centred: the pin area's 6 pt padding and half the 11 pt bead column. A wire is anchored at the
        /// edge, but the bead is what a person aims at and what a wire being drawn leaves from.
        public static let beadInset: CGFloat = 11.5
        /// Distance from the card's top edge to the centre of the first pin row.
        ///
        /// At the SwiftUI card's own pitch (16) this is its fixed 33. At any other pitch the rows are centred in the body
        /// between the header and the card's foot, which is what a roomier frontend wants.
        public static var firstPinCentre: CGFloat {
            pinPitch == 16 ? headerHeight + bodyTopPadding + pinRowHeight / 2 : headerHeight + 5 + (pinPitch / 2).rounded()
        }
    }

    /// A block's card size is a whole number of grid cells, so its edges sit on the sheet's dots whatever the content
    /// needs. The measured size is rounded up; the extra room is padding at the right/bottom.
    nonisolated public static func gridAligned(_ value: CGFloat) -> CGFloat {
        let grid = CGFloat(GridSnap.step)
        return max(grid, (value / grid).rounded(.up) * grid)
    }

    nonisolated public static func cardWidth(for module: PCCModule) -> CGFloat {
        gridAligned(measuredWidth(for: module))
    }

    /// The width the content asks for, before the grid rounds it up. Exports to Dirigo use this, not the padded width.
    nonisolated static func measuredWidth(for module: PCCModule) -> CGFloat {
        if let window = segmentWindow(for: module) { return window.maxX + segmentMargin }
        return max(defaultWidth, widthForRows(of: module))
    }

    /// The width the pin rows need, for a block whose parameter pins are rows beside its outputs: a left row (bead, name, value) and the right row on
    /// the same line (value, name, bead) must not meet, or a long name such as a macro's `SecondDigit` runs into the output beside it. A
    /// monospaced glyph at the rows' size is 4.5 pt wide. Blocks without parameters keep the default width, as before.
    nonisolated static func widthForRows(of module: PCCModule) -> CGFloat {
        guard !module.paramPins.isEmpty else { return 0 }
        let glyph: CGFloat = 4.5
        func left(_ chars: Int) -> CGFloat { 14 + CGFloat(chars + 1 + 3) * glyph }
        func right(_ chars: Int) -> CGFloat { 14 + CGFloat(chars + 1 + 3) * glyph }
        let leftRows = module.inPins.count + module.paramPins.count
        var need: CGFloat = 0
        for row in 0..<max(leftRows, module.outPins.count) {
            var width: CGFloat = 0
            if row < module.inPins.count {
                width += left(ModulePinCatalog.inputPinLabel(for: module, index: row).count)
            } else if row < leftRows {
                width += left(ModulePinCatalog.paramPinLabel(for: module, index: row - module.inPins.count).count)
            }
            if row < module.outPins.count { width += right(ModulePinCatalog.outputPinLabel(for: module, index: row).count) }
            // Only a row with both sides can collide.
            if row < leftRows, row < module.outPins.count { need = max(need, width + 18) }
        }
        return (need / 4).rounded(.up) * 4
    }

    nonisolated public static func cardHeight(for module: PCCModule) -> CGFloat {
        gridAligned(cardHeight(for: module, pitch: pinPitch, macroCallerSpace: macroCallerSpace))
    }

    /// The size of a block in Dirigo itself, as this port assumes it: the SwiftUI card's, whatever pin pitch or width the frontend in use draws with. What
    /// an export for the original Dirigo has to fit on its sheet. It is an approximation: the original derives a block's pitch (text height + 1) and its
    /// width from its font (`TModuleView.CalcSize`, `docs/port-status.md`), so no constant is exactly right.
    nonisolated public static func dirigoExtent(for module: PCCModule) -> CGSize {
        let pitch: CGFloat = 16
        let pinCount = max(module.inPins.count + module.paramPins.count, module.outPins.count)
        var width: CGFloat = 110
        if BlockTypeCatalog.info(forGuid: module.guid)?.blockName == "Segment" {
            let height = segmentWindowHeight(bodyHeight: segmentBodyHeight(pinCount: pinCount, pitch: pitch))
            width = segmentPinColumn + SegmentDisplayLayout.width(forHeight: height) + segmentMargin
        }
        return CGSize(width: width, height: cardHeight(for: module, pitch: pitch, macroCallerSpace: controlHeight))
    }

    nonisolated static func cardHeight(for module: PCCModule, pitch pinPitch: CGFloat, macroCallerSpace: CGFloat) -> CGFloat {
        // A parameter is a pin, in the left column under the inputs, as Dirigo draws it: it takes a row, not a strip.
        let pinCount = max(module.inPins.count + module.paramPins.count, module.outPins.count)
        let pinsHeight: CGFloat = CGFloat(max(1, pinCount)) * pinPitch + 8.0
        let paramsHeight: CGFloat = 0.0
        let isSegment = BlockTypeCatalog.info(forGuid: module.guid)?.blockName == "Segment"
        // The display sits *beside* the pins, so the body must fit the taller of the two, not their
        // sum. The size comes from the layout itself so the two cannot drift apart.
        let bodyHeight: CGFloat = isSegment ? segmentBodyHeight(pinCount: pinCount, pitch: pinPitch) : pinsHeight
        let hasControl = [.control, .slider].contains(BlockInteraction.classify(module))
        let controlSpace: CGFloat = hasControl ? controlHeight : (isMacroCaller(module) ? macroCallerSpace : 0.0)
        let calculated = Metrics.headerHeight + bodyHeight + paramsHeight + controlSpace
        return hasControl ? max(76.0, calculated) : calculated
    }

    /// A macro's call site, on a main page or — nested macros — on another macro's sheet. The `Inputs`, `Outputs`
    /// and `Params` interfaces inside a sheet carry a `MACRO_NAME` too and are not calls.
    nonisolated public static func isMacroCaller(_ module: PCCModule) -> Bool {
        MacroCalls.target(of: module) != nil
    }

    nonisolated public static func inPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        CGPoint(x: module.x, y: module.y + Metrics.firstPinCentre + Double(pinIndex) * Double(pinPitch))
    }

    /// Where a parameter pin sits: the left edge, in the row after the module's inputs (`PV`, `Max`, `Min`, `St` under `AdvCounter`'s
    /// inputs in Dirigo).
    nonisolated public static func paramPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        inPinPoint(for: module, pinIndex: module.inPins.count + pinIndex)
    }

    nonisolated public static func outPinPoint(for module: PCCModule, pinIndex: Int) -> CGPoint {
        let w = cardWidth(for: module)
        return CGPoint(
            x: module.x + Double(w),
            y: module.y + Metrics.firstPinCentre + Double(pinIndex) * Double(pinPitch)
        )
    }

    /// Rendering magnification for a given canvas zoom: the zoom rounded up to a quarter, from 1x to 2x.
    ///
    /// The card lays out at `renderScale` and is then scaled back down by `1/renderScale`, so this
    /// controls rasterisation sharpness only — the on-screen size always comes from the canvas
    /// transform. It follows the zoom live, so rounding up to steps keeps a card from ever being softer than
    /// the zoom needs while re-rasterising the cards only a few times over a whole zoom.
    nonisolated public static func renderScale(for zoom: CGFloat) -> CGFloat {
        max(1.0, min(2.0, (zoom * 4).rounded(.up) / 4))
    }
}
