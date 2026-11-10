import SwiftUI
import WirebenchModel
import WirebenchCore
import WirebenchLibrary

/// The live pin values of every block on the sheet — each pin's bead, name and value — drawn in one `Canvas` over the cards.
///
/// The cards themselves are static: nothing a card draws depends on a pin's value, so a simulation tick re-renders no card at all, where it used
/// to rebuild the view tree of every card whose values had moved (a bead and two texts per pin, a dozen cards at a time). Here a tick is one
/// canvas update.
///
/// The canvas lives in viewport space and applies the pan and the zoom itself, so what it draws is vector at any zoom, as sharp as the text on a
/// card. It is above the cards, so where one card covers another it must not draw the text of the one below: each card's rows are clipped by
/// the cards after it, which are the ones drawn on top.
///
/// **Drawn synchronously, and only when the drawing has to change.** Two costs meet here: the drawing is the *same* transform the cards get, so
/// a delay in it is visible (the text arrives a frame after its card — outside it); and drawing every visible pin takes several milliseconds, so
/// doing it on every pan event drops frames. So the canvas is drawn **synchronously** for an anchor pan, and a pan since then moves the finished
/// drawing with the cards (a view offset, in the same update) until the shift uses up half its margin — then it is drawn again, synchronously, so
/// the new drawing is in the same frame as the offset that needed it. A zoom always redraws: the scale is part of the drawing.
struct LiveValuesLayer: View {
    let model: AppModel
    /// The blocks of the page being shown, in the order the cards are stacked.
    let modules: [PCCModule]
    /// Live drag translation per block, as the cards have it.
    let dragOffsets: [Int: CGSize]

    /// The pan the canvas was last drawn for. A pan since then is only a shift of the finished drawing; see the type's note.
    @State private var anchor: CGSize?
    /// The viewport the canvas was last *sized* for, rounded up. It only grows: the drawing has to cover the viewport, and
    /// a viewport that is getting smaller is already covered. Without this every frame of a sidebar or window resize was
    /// a new size, and so a redraw of every visible pin.
    @State private var drawnSize: CGSize = .zero

    var body: some View {
        // Read here, so a pan, a zoom or a tick re-evaluates this view — and only the canvas redraws when it must.
        let zoom = model.zoomScale, pan = model.panOffset, snapshots = model.snapshots
        let modules = modules, drags = dragOffsets
        return GeometryReader { geometry in
            let size = Self.canvasSize(for: geometry.size, atLeast: drawnSize)
            // Half of it again on every side, so a shift reveals rows that are already drawn.
            let margin = CGSize(width: size.width / 2, height: size.height / 2)
            let base = anchor ?? pan
            LiveValuesCanvas(zoom: zoom, anchor: base, margin: margin, modules: modules, snapshots: snapshots, drags: drags)
                .equatable()
                .frame(width: size.width + margin.width * 2, height: size.height + margin.height * 2)
                .offset(x: pan.width - base.width - margin.width, y: pan.height - base.height - margin.height)
                .onChange(of: pan) { _, new in
                    if LiveValuesCanvas.needsRecentre(pan: new, anchor: base, margin: margin) { anchor = new }
                }
                .onAppear { if anchor == nil { anchor = pan } }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport in
            let grown = Self.canvasSize(for: viewport, atLeast: drawnSize)
            if grown != drawnSize { drawnSize = grown }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

extension LiveValuesLayer {
    /// The size the canvas is drawn for: the viewport rounded up to a step, and never smaller than what was drawn before.
    ///
    /// A redraw costs about 5.6 ms for a 36-block page, and a sidebar or window resize changes the viewport on every frame
    /// of its animation; sizing to each of those drew the whole page again and again. Rounding up means a resize within a
    /// step changes nothing, and a viewport that shrinks is already covered, so it does not redraw at all.
    nonisolated static func canvasSize(for viewport: CGSize, atLeast current: CGSize) -> CGSize {
        let step: CGFloat = 64
        let width = max(current.width, (max(0, viewport.width) / step).rounded(.up) * step)
        let height = max(current.height, (max(0, viewport.height) / step).rounded(.up) * step)
        return CGSize(width: max(width, step), height: max(height, step))
    }
}

/// The canvas itself. Equatable, so a tick that changed no visible value does not draw it again.
struct LiveValuesCanvas: View, Equatable {
    let zoom: CGFloat
    /// The pan this is drawn for. The viewport's top left is `margin` in from the canvas's.
    let anchor: CGSize
    let margin: CGSize
    let modules: [PCCModule]
    let snapshots: [Int: BlockSnapshot]
    let drags: [Int: CGSize]

    /// Whether a pan has moved far enough from what was drawn that the drawing has to be made again.
    ///
    /// The margin is drawn beyond the viewport on every side, so a shift that stays within half of it still shows drawn rows.
    /// One past that, the moved drawing would run out of margin at the edge it is moving away from.
    nonisolated static func needsRecentre(pan: CGSize, anchor: CGSize, margin: CGSize) -> Bool {
        abs(pan.width - anchor.width) > margin.width / 2 || abs(pan.height - anchor.height) > margin.height / 2
    }

    /// The pan is deliberately *not* compared: a pan only shifts this view (see `LiveValuesLayer`). A zoom, a value or a
    /// block's position is a redraw.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.zoom == rhs.zoom && lhs.anchor == rhs.anchor && lhs.margin == rhs.margin
            && lhs.modules == rhs.modules && lhs.snapshots == rhs.snapshots && lhs.drags == rhs.drags
    }

    var body: some View {
        let zoom = zoom, anchor = anchor, margin = margin
        let modules = modules, snapshots = snapshots, drags = drags
        return Canvas { context, size in
            let pan = CGSize(width: anchor.width + margin.width, height: anchor.height + margin.height)
            Self.draw(in: &context, size: size, zoom: zoom, pan: pan, modules: modules, snapshots: snapshots, drags: drags)
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, zoom: CGFloat, pan: CGSize,
                             modules: [PCCModule], snapshots: [Int: BlockSnapshot], drags: [Int: CGSize]) {
        guard zoom > 0 else { return }
        context.translateBy(x: pan.width, y: pan.height)
        context.scaleBy(x: zoom, y: zoom)
        let visible = CGRect(x: -pan.width / zoom, y: -pan.height / zoom, width: size.width / zoom, height: size.height / zoom)
        let frames = modules.map { module -> CGRect in
            let drag = drags[module.id] ?? .zero
            return CGRect(x: module.x + drag.width, y: module.y + drag.height,
                          width: ModuleCardView.cardWidth(for: module), height: ModuleCardView.cardHeight(for: module))
        }
        let top = CardGeometry.Metrics.headerHeight + CardGeometry.Metrics.bodyTopPadding
        for (index, module) in modules.enumerated() where frames[index].intersects(visible) && ModuleCardView.drawsRowsInLayer(module) {
            let frame = frames[index]
            let snapshot = snapshots[module.id]
            let inputValues = snapshot?.inValues ?? module.inPins.map(\.value)
            let outputValues = snapshot?.outValues ?? []
            let inputs = (0..<module.inPins.count).map {
                PinRows.row(inputValues, $0, label: ModulePinCatalog.inputPinLabel(for: module, index: $0), inputOf: module.guid)
            }
            let outputs = (0..<module.outPins.count).map {
                PinRows.row(outputValues, $0, label: ModulePinCatalog.outputPinLabel(for: module, index: $0))
            }
            // The parameters are pins too: rows under the inputs, with their live value (`Set` writes one at run time).
            let paramValues = snapshot?.paramValues ?? module.paramPins.map(\.value)
            let params = (0..<module.paramPins.count).map { index -> PinRows.Row in
                var row = PinRows.row(paramValues, index, label: ModulePinCatalog.paramPinLabel(for: module, index: index))
                row = PinRows.Row(label: row.label, valueText: row.valueText, isHigh: false, isParam: true)
                return row
            }

            var card = context
            // Whatever a later card covers of this one is not drawn.
            let covering = frames[(index + 1)...].filter { $0.intersects(frame) }
            if !covering.isEmpty {
                var clip = Path(frame.insetBy(dx: -40, dy: -40))
                for cover in covering { clip.addPath(Path(roundedRect: cover, cornerRadius: Theme.cardRadius, style: .continuous)) }
                card.clip(to: clip, style: FillStyle(eoFill: true))
            }
            card.translateBy(x: frame.minX + 6, y: frame.minY + top)
            PinRows.draw(in: &card, width: frame.width - 12, inputs: inputs + params, outputs: outputs, scale: 1,
                         clickableOutputs: BlockInteraction.classify(module) == .pinToggles)
        }
    }
}
