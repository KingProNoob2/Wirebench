import Testing
import Foundation
import CoreGraphics
import DirigoCore
import DirigoLibrary
@testable import DirigoApp

/// The seven-segment digit has to be symmetric. It is drawn from `SegmentDisplayView.layout`, so the
/// symmetry can be asserted here rather than judged by eye in a screenshot — which is how the
/// previous stack-based version went wrong: its bottom bar shared a row with the decimal point and
/// came out both taller and pushed left.
@Suite("Segment display")
struct SegmentDisplayTests {

    private typealias Layout = SegmentDisplayView.Layout
    private static let layout = SegmentDisplayView.layout

    // A — top, B — upper right, C — lower right, D — bottom,
    // E — lower left, F — upper left, G — middle, DP — point.
    private static let a = 0, b = 1, c = 2, d = 3, e = 4, f = 5, g = 6, dp = 7

    private func bar(_ index: Int) -> CGRect { Self.layout.bars[index] }

    @Test("There is one bar per segment, in pin order")
    func hasEveryBar() {
        #expect(Self.layout.bars.count == 8)
    }

    @Test("The digit is symmetric about its horizontal centre line")
    func symmetricHorizontally() throws {
        let half = Self.layout.bodySize.height / 2
        // The top and bottom bars sit the same distance either side of the middle.
        #expect(abs((half - bar(Self.a).midY) - (bar(Self.d).midY - half)) < 0.0001,
                "top bar at \(bar(Self.a).midY), bottom at \(bar(Self.d).midY), centre \(half)")
        // The two upper verticals mirror the two lower ones.
        #expect(abs((half - bar(Self.f).midY) - (bar(Self.e).midY - half)) < 0.0001)
        #expect(abs((half - bar(Self.b).midY) - (bar(Self.c).midY - half)) < 0.0001)
        // And the middle bar is on the centre line.
        #expect(abs(bar(Self.g).midY - half) < 0.0001, "middle bar must straddle the centre line")
    }

    @Test("The digit is symmetric about its vertical centre line")
    func symmetricVertically() throws {
        let width = Self.layout.bodySize.width
        // Left and right verticals are the same distance in from their own edge.
        #expect(abs(bar(Self.f).minX - (width - bar(Self.b).maxX)) < 0.0001)
        #expect(abs(bar(Self.e).minX - (width - bar(Self.c).maxX)) < 0.0001)
        // Horizontals are centred, with equal margins either side.
        for index in [Self.a, Self.d, Self.g] {
            let rect = bar(index)
            #expect(abs(rect.minX - (width - rect.maxX)) < 0.0001,
                    "bar \(index) is off centre: \(rect)")
            #expect(abs(rect.midX - width / 2) < 0.0001)
        }
    }

    @Test("The digit spans its body exactly, with no stray overhang")
    func fillsItsBodyExactly() {
        // The outermost verticals define the body edges, so nothing can stick out.
        #expect(abs(bar(Self.f).minX) < 0.0001)
        #expect(abs(bar(Self.b).maxX - Self.layout.bodySize.width) < 0.0001)
        // Top and bottom bars are flush with the body too.
        #expect(abs(bar(Self.a).minY) < 0.0001)
        #expect(abs(bar(Self.d).maxY - Self.layout.bodySize.height) < 0.0001)
    }

    @Test("Every bar is the same thickness")
    func uniformThickness() {
        // A malformed segment is what made the old bottom bar look wrong, so this is worth pinning.
        for (index, rect) in Self.layout.bars.enumerated() where index != Self.dp {
            #expect(abs(min(rect.width, rect.height) - Self.layout.thickness) < 0.0001,
                    "bar \(index) has thickness \(min(rect.width, rect.height))")
        }
    }

    @Test("The bars meet without overlapping")
    func barsDoNotOverlap() {
        // Verticals start where the top bar ends and stop at the middle; the point is the only thing
        // allowed outside the digit.
        #expect(abs(bar(Self.f).minY - bar(Self.a).maxY) < 0.0001)
        #expect(abs(bar(Self.f).maxY - bar(Self.e).minY) < 0.0001)
        #expect(abs(bar(Self.b).minY - bar(Self.a).maxY) < 0.0001)
        #expect(abs(bar(Self.b).maxY - bar(Self.c).minY) < 0.0001)
        #expect(abs(bar(Self.e).maxY - bar(Self.d).minY) < 0.0001)
    }

    @Test("The decimal point sits outside the body, on the baseline")
    func pointIsWhereItShouldBe() {
        #expect(bar(Self.dp).minX >= Self.layout.bodySize.width, "the point must not eat into the digit")
        #expect(abs(bar(Self.dp).maxY - Self.layout.bodySize.height) < 0.0001, "and must sit on the baseline")
        // It has to fit inside the window the view actually draws.
        #expect(bar(Self.dp).maxX <= Self.layout.contentSize.width)
    }

    @Test("The display is larger than the version it replaces")
    func isBiggerThanBefore() {
        // The old digit was 28 x ~62 with 4.5pt bars, scaled to 0.72 and squeezed into a 50pt frame.
        // This guards against a regression back to that size.
        let size = SegmentDisplayView.displaySize
        #expect(Self.layout.bodySize.width >= 40, "digit width \(Self.layout.bodySize.width)")
        #expect(Self.layout.bodySize.height >= 72, "digit height \(Self.layout.bodySize.height)")
        #expect(Self.layout.thickness >= 5.5, "bars were 4.5pt and hard to read")
        #expect(size.width >= 70 && size.height >= 88, "reserved size is only \(size)")
    }

    @Test("The size the card reserves matches the view's intrinsic size")
    func cardReservationMatchesTheView() {
        // `cardHeight` reserves `displaySize`; if the two ever disagree the block overlaps its
        // neighbours or leaves a gap.
        #expect(SegmentDisplayView.displaySize == Self.layout.intrinsicSize)
        #expect(abs(Self.layout.intrinsicSize.width - (Self.layout.contentSize.width + Self.layout.padding * 2)) < 0.0001)
        #expect(abs(Self.layout.intrinsicSize.height - (Self.layout.contentSize.height + Self.layout.padding * 2)) < 0.0001)
    }

    @Test("The middle bar is shorter than the top and bottom ones")
    func middleBarIsShorter() {
        #expect(bar(Self.g).width < bar(Self.a).width,
                "middle \(bar(Self.g).width) vs top \(bar(Self.a).width)")
        // Top and bottom stay the same length as each other — only the middle is trimmed.
        #expect(abs(bar(Self.a).width - bar(Self.d).width) < 0.0001)
        // It ends exactly where the verticals begin, so the trim is even at both ends.
        #expect(abs(bar(Self.g).minX - bar(Self.f).maxX) < 0.0001)
        #expect(abs(bar(Self.g).maxX - bar(Self.c).minX) < 0.0001)
    }

    @Test("The display fits inside the card, beside the pin list")
    func cardLeavesRoomForPinsAndDisplay() {
        // The card is wider than a normal one, and what it adds comfortably covers the display plus
        // the pin column it now sits next to.
        #expect(ModuleCardView.segmentWidth > ModuleCardView.defaultWidth)
        // What is left once the display has its width has to hold the pin column (about 31pt) plus
        // the card's padding, with the display centred in the remainder.
        let roomForPins = ModuleCardView.segmentWidth - SegmentDisplayView.displaySize.width
        #expect(roomForPins >= 46, "only \(roomForPins)pt left for the pin labels")
    }

    @Test("Height fits the taller of pins and display, not their sum")
    func heightUsesTheTaller() throws {
        func segment(pins: Int) -> PCCModule {
            let values = (0..<pins).map { Pin(id: $0, value: PinValue.bool($0 == 0)) }
            return PCCModule(id: 90, guid: SegmentBlock.guid, name: "Segment1", x: 0, y: 0,
                             order: 1, threadId: 1, page: "main", inPins: values, outPins: [])
        }
        let short = ModuleCardView.cardHeight(for: segment(pins: 2))
        let tall = ModuleCardView.cardHeight(for: segment(pins: 9))
        // 2 pins need 40pt and 9 pins need 152pt, against a 92pt display. So the short card is sized
        // by its display and the tall one by its pins — the difference is 92 - 152, not 40 - 152.
        #expect(short - tall == SegmentDisplayView.displaySize.height - 152,
                "got \(short) and \(tall), display \(SegmentDisplayView.displaySize.height)")
    }
}
