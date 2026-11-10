import SwiftUI
import WirebenchModel

/// A seven-segment LED, drawn as a recessed window with lit segments against dim ones.
///
/// The geometry is `SegmentDisplayLayout.fitting` the window the card gives it, so the digit is as large as the window allows and the Qt
/// card draws the same one. The bars are placed as rectangles, which makes the symmetry something that can be *checked* rather than
/// eyeballed.
///
/// The window is dark in both appearances, as a real display's is. It used to be a translucent black over the card, which on a light card was
/// a muddy grey that the dim segments disappeared into.
public struct SegmentDisplayView: View {
    /// `[A, B, C, D, E, F, G, DP]`
    public let segments: [Bool]
    /// The window's size, in card points.
    public let window: CGSize

    public init(segments: [Bool], window: CGSize = SegmentDisplayLayout.standard.windowSize) {
        self.segments = segments
        self.window = window
    }

    @Environment(\.colorScheme) private var colorScheme

    private func isLit(_ index: Int) -> Bool {
        index < segments.count && segments[index]
    }

    private static let led = Color(red: 1.0, green: 0.30, blue: 0.24)
    private static let glass = Color(red: 0.055, green: 0.060, blue: 0.070)

    public var body: some View {
        let layout = SegmentDisplayLayout.fitting(window)
        let corner = min(11, window.height * 0.08)
        ZStack(alignment: .topLeading) {
            // Bars are placed by centre, so a bar's own size can never shift its neighbours.
            ForEach(Array(layout.barsInWindow.enumerated()), id: \.offset) { index, rect in
                RoundedRectangle(cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
                    .fill(isLit(index) ? Self.led : Self.led.opacity(0.16))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .background(Self.glass, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            // An edge that reads on either card: a light rim on the dark card, a dark one on the light card.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.35), lineWidth: 1)
        }
        .compositingGroup()
    }
}
