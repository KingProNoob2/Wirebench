import SwiftUI

/// A seven-segment LED, drawn as a recessed glass window with lit segments that bloom.
///
/// The geometry is computed once, in `Layout`, from a single set of dimensions. The previous version
/// built the digit out of nested stacks, which could not be symmetric: the bottom bar shared an
/// `HStack` with the decimal point — so its row was taller than the top row and the bar was pushed
/// left — and the vertical pair spanned 31 points while the horizontal bars were 28. Placing the
/// bars as rectangles makes the symmetry something that can be *checked* rather than eyeballed, and
/// `SegmentDisplayTests` asserts it.
public struct SegmentDisplayView: View {
    /// `[A, B, C, D, E, F, G, DP]`
    public let segments: [Bool]

    public init(segments: [Bool]) {
        self.segments = segments
    }

    /// Where every bar sits, in the display's own coordinates, before padding.
    public struct Layout: Sendable {
        /// The digit's body: the region the seven bars occupy, excluding the decimal point.
        public let bodySize: CGSize
        /// The bars plus the decimal point — everything the recessed window has to contain.
        public let contentSize: CGSize
        public let thickness: CGFloat
        /// Bars in A…G, DP order, matching the pin order the block uses.
        public let bars: [CGRect]
        public let padding: CGFloat

        /// What the whole view measures. The card reserves exactly this, so the display and the card
        /// geometry cannot drift apart.
        public var intrinsicSize: CGSize {
            CGSize(width: contentSize.width + padding * 2, height: contentSize.height + padding * 2)
        }
    }

    public nonisolated static let layout: Layout = {
        let thickness: CGFloat = 6
        let bodyWidth: CGFloat = 44
        let bodyHeight: CGFloat = 76
        let dotSize: CGFloat = 8
        let dotGap: CGFloat = 6
        let padding: CGFloat = 8

        let half = bodyHeight / 2                 // 38 — every vertical distance mirrors about this
        let barLength = bodyWidth - thickness     // 38: horizontals stop short of the corners
        let verticalLength = half - thickness     // 32: verticals run between the horizontal bars

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

        return Layout(bodySize: CGSize(width: bodyWidth, height: bodyHeight),
                      contentSize: CGSize(width: bodyWidth + dotGap + dotSize, height: bodyHeight),
                      thickness: thickness,
                      bars: bars,
                      padding: padding)
    }()

    /// The size the card reserves for this view, in card coordinates.
    public nonisolated static var displaySize: CGSize { layout.intrinsicSize }

    private func isLit(_ index: Int) -> Bool {
        index < segments.count && segments[index]
    }

    private let litColor = Color(red: 1.0, green: 0.30, blue: 0.24)
    private let unlitColor = Color(red: 1.0, green: 0.30, blue: 0.24).opacity(0.10)

    public var body: some View {
        let layout = Self.layout
        ZStack(alignment: .topLeading) {
            // Bars are placed by centre, so a bar's own size can never shift its neighbours.
            ForEach(Array(layout.bars.enumerated()), id: \.offset) { index, rect in
                RoundedRectangle(cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
                    .fill(isLit(index) ? litColor : unlitColor)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
        .padding(layout.padding)
        .background {
            // Recessed window: a dark inset so the LEDs read against it.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.45))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.panelStroke, lineWidth: 1)
        }
        .compositingGroup()
    }
}
