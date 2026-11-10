import Testing
import Foundation
import SwiftUI
import WirebenchCore
import WirebenchLibrary
#if canImport(SwiftUI)
@testable import WirebenchApp
#endif
@testable import WirebenchModel

/// The two layers that are drawn over (and behind) the cards: the grid behind them, the pin values in front.
///
/// Both are `Canvas`es that apply the pan and the zoom themselves, so both have to be redrawn in the same update as the
/// cards. They were not: the grid and the pin layer were asynchronous, and the pin layer's finished drawing was shifted to
/// follow a pan and only redrawn when the shift ran out of margin — so the text lagged its card and left it on a fast pan,
/// and a zoom left the text at the previous scale until the pass landed. These pin down the part of that which is a
/// property of the views: that a pan and a zoom are both part of what each layer is drawn for.
@Suite("Canvas layers")
@MainActor
struct CanvasLayerTests {
    static func module(_ id: Int) -> PCCModule {
        PCCModule(id: id, guid: NotBlock.guid, name: "Not\(id)", x: 0, y: 0, order: 10, threadId: 1, page: "main",
                  inPins: [Pin(id: 0, value: .bool(true)), Pin(id: 1, value: .bool(false))],
                  outPins: [Pin(id: 0, value: .bool(false))])
    }

    private func layer(zoom: CGFloat = 1, anchor: CGSize = .zero) -> LiveValuesCanvas {
        LiveValuesCanvas(zoom: zoom, anchor: anchor, margin: CGSize(width: 500, height: 350),
                         modules: [Self.module(1)], snapshots: [:], drags: [:])
    }

    /// The pin layer is drawn for an *anchor* pan and moved for everything since, because drawing every visible row costs
    /// milliseconds (measured: 9.7 ms for 36 blocks at 100 %) — so a pan must not redraw it, but a zoom, a new value or
    /// blocks moving must, and the shift has to be re-centred before it runs out of margin.
    @Test("A pan shifts the pin layer; a zoom, a value or blocks moving redraw it")
    func pinLayerRedrawsOnlyWhenItMust() {
        #expect(layer() == layer(), "identical inputs must not redraw it")
        #expect(layer(anchor: CGSize(width: 1, height: 0)) != layer(), "re-centring on a new pan must redraw it")
        #expect(layer(zoom: 1.01) != layer(), "a zoom must redraw them at the new scale")
        #expect(layer() != LiveValuesCanvas(zoom: 1, anchor: .zero, margin: CGSize(width: 500, height: 350),
                                            modules: [Self.module(2)], snapshots: [:], drags: [:]),
                "another page's blocks must redraw them")
    }

    @Test("A shift is re-centred only once it has used up half its margin")
    func recentreRule() {
        let margin = CGSize(width: 500, height: 350)
        #expect(!LiveValuesCanvas.needsRecentre(pan: CGSize(width: 240, height: 0), anchor: .zero, margin: margin))
        #expect(!LiveValuesCanvas.needsRecentre(pan: CGSize(width: 0, height: 170), anchor: .zero, margin: margin))
        #expect(LiveValuesCanvas.needsRecentre(pan: CGSize(width: 260, height: 0), anchor: .zero, margin: margin))
        #expect(LiveValuesCanvas.needsRecentre(pan: CGSize(width: 0, height: 180), anchor: .zero, margin: margin))
    }

    @Test("A pan or a zoom is part of what the grid is drawn for")
    func gridFollowsTheView() {
        #expect(CanvasGrid(zoomScale: 1, panOffset: .zero) == CanvasGrid(zoomScale: 1, panOffset: .zero))
        #expect(CanvasGrid(zoomScale: 1, panOffset: CGSize(width: 2, height: 0))
                != CanvasGrid(zoomScale: 1, panOffset: .zero))
        #expect(CanvasGrid(zoomScale: 1.2, panOffset: .zero) != CanvasGrid(zoomScale: 1, panOffset: .zero))
        #expect(CanvasGrid(zoomScale: 1, panOffset: .zero, colorScheme: .light)
                != CanvasGrid(zoomScale: 1, panOffset: .zero, colorScheme: .dark),
                "a scheme change must redraw the grid at its other strengths")
    }

    /// A sidebar or window resize changes the viewport on every frame of its animation. The canvas is sized to a step,
    /// and never shrinks, so those frames do not redraw every visible pin; but it must still cover the viewport.
    @Test("The pin layer is sized in steps, grows only, and always covers the viewport")
    @MainActor
    func canvasSizeCoversTheViewport() {
        let stepped = LiveValuesLayer.canvasSize(for: CGSize(width: 1000, height: 700), atLeast: .zero)
        #expect(stepped == CGSize(width: 1024, height: 704))
        // A viewport that shrinks (the sidebar opening) keeps the size it had: already covered, and no redraw.
        #expect(LiveValuesLayer.canvasSize(for: CGSize(width: 800, height: 600), atLeast: stepped) == stepped)
        // Growing past a step takes the next one.
        #expect(LiveValuesLayer.canvasSize(for: CGSize(width: 1030, height: 700), atLeast: stepped)
                == CGSize(width: 1088, height: 704))
        #expect(LiveValuesLayer.canvasSize(for: .zero, atLeast: .zero) == CGSize(width: 64, height: 64))
        for viewport in [CGSize(width: 1, height: 1), CGSize(width: 999, height: 1_001), CGSize(width: 2_560, height: 1_440)] {
            let size = LiveValuesLayer.canvasSize(for: viewport, atLeast: .zero)
            #expect(size.width >= viewport.width && size.height >= viewport.height,
                    "\(viewport) would leave part of the viewport undrawn at \(size)")
        }
    }

    /// The layers draw with `content * zoom + pan`, and every gesture converts back with the same mapping. A grid line at
    /// a world position and the card sitting on it must therefore land on the same screen point.
    @Test("The content transform round-trips at every zoom and pan the app allows")
    func transformIsConsistent() {
        let points = [CGPoint.zero, CGPoint(x: 123.5, y: 87.25), CGPoint(x: -40, y: 1_800.75)]
        for zoom in [CGFloat(0.2), 0.5, 1, 1.37, 2.5, 3.5] {
            for pan in [CGSize.zero, CGSize(width: 13.25, height: -7.5), CGSize(width: -300, height: 2_000)] {
                for point in points {
                    let viewport = CanvasTransform.viewportPoint(from: point, zoom: zoom, pan: pan)
                    let back = CanvasTransform.contentPoint(from: viewport, zoom: zoom, pan: pan)
                    #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9,
                            "zoom \(zoom), pan \(pan), point \(point) came back as \(back)")
                }
            }
        }
    }
}
