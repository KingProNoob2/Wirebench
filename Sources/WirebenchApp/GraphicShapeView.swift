import SwiftUI
import WirebenchCore

/// A rectangle or circle on the sheet: drawn from the box Dirigo stores, dragged the way a block is.
///
/// Split out of `CanvasView` because the chain one of these needs — fill, stroke, selection ring,
/// resize handle, two gestures, position — exceeds the type-checker's budget when it is written
/// inline, which is the same reason `CanvasView.wirePreview` is a function of its own.
///
/// The view holds no document state. It reports content-space deltas and lets the canvas decide what
/// a drag does, so moving a shape never writes to the project while the pointer is still moving: that
/// would put an undo step on every frame of the drag.
struct GraphicShapeView: View {
    var graphic: ProjectGraphic
    /// Index into `project.graphics`, which is the only handle a graphic has.
    var index: Int
    /// Live move and resize from the canvas, applied on top of the stored box until the gesture ends.
    var drag: CGSize = .zero
    var grow: CGSize = .zero
    /// The canvas's zoom, asked for when a gesture needs it. A value would have to be handed down at every step of a zoom,
    /// rebuilding the shape each time, for a number only used to turn a drag back into sheet units.
    var zoomScale: () -> CGFloat = { 1 }
    var isSelected = false
    /// The object's connected output is above its active threshold; its active pen/brush are drawn instead.
    var isActive = false
    /// True when nothing else is picked, which is when the resize handle appears: resizing a group
    /// would have to scale every member about a shared anchor, which is a different decision than
    /// moving one.
    var isSoleSelection = false

    var onSelect: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: (CGSize) -> Void = { _ in }
    var onResize: (CGSize) -> Void = { _ in }
    var onResizeEnd: (CGSize) -> Void = { _ in }

    var body: some View {
        let outline = Self.outline(for: graphic)
        let box = shownBox

        outline
            .fill(isActive ? GraphicColor.activeBrush(of: graphic) : GraphicColor.brush(of: graphic))
            .overlay { outline.stroke(isActive ? GraphicColor.activePen(of: graphic)
                                              : GraphicColor.pen(of: graphic),
                                      lineWidth: lineWidth) }
            .frame(width: max(1, CGFloat(box.width)), height: max(1, CGFloat(box.height)))
            .overlay { selectionDecorations(outline: outline, box: box) }
            // The whole box is the hit area, filled or not: a shape whose middle could not be clicked
            // would be harder to grab than the blocks it shares the sheet with.
            .contentShape(Rectangle())
            .gesture(moveGesture)
            .simultaneousGesture(TapGesture().onEnded { onSelect() })
            .contextMenu {
                Button("Inspect Shape", systemImage: "info.circle") {
                    onSelect()
                    NotificationCenter.default.post(name: .showInspector, object: nil)
                }
                Button("Delete Object", systemImage: "trash", role: .destructive) { onDelete() }
            }
            .help(Self.helpText(for: graphic))
            .position(x: CGFloat(box.midX), y: CGFloat(box.midY))
    }

    /// The stored box plus whatever the running gesture has moved it by.
    private var shownBox: GraphicBox {
        let box = graphic.boundingBox ?? GraphicBox(x: 0, y: 0, width: 1, height: 1)
        return GraphicBox(x: box.x + Double(drag.width),
                          y: box.y + Double(drag.height),
                          width: Swift.max(1, box.width + Double(grow.width)),
                          height: Swift.max(1, box.height + Double(grow.height)))
    }

    private var lineWidth: CGFloat {
        CGFloat(max(1, graphic.penWidth ?? 1))
    }

    /// The ring and handle that mark a selected shape.
    ///
    /// The ring is the same outline drawn in a frame 6 points wider than the shape. `AnyShape` is a
    /// `Shape` but not an `InsettableShape`, so the usual way to grow an outline — `inset(by: -3)` — is
    /// not available on it.
    @ViewBuilder
    private func selectionDecorations(outline: AnyShape, box: GraphicBox) -> some View {
        if isSelected {
            outline
                .stroke(Theme.searchHighlight, lineWidth: 2)
                .frame(width: CGFloat(box.width) + 6, height: CGFloat(box.height) + 6)

            if isSoleSelection {
                resizeHandle(box: box)
            }
        }
    }

    private func resizeHandle(box: GraphicBox) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 11, height: 11)
            .position(handleAnchor(in: box))
            .gesture(resizeGesture)
    }

    /// Where the handle sits. For a rectangle that is the corner the drag moves; for a circle the box
    /// corner is outside the drawing, so the handle goes where the outline actually passes at 45° —
    /// the drag still moves the box's corner, which is what Dirigo stores.
    private func handleAnchor(in box: GraphicBox) -> CGPoint {
        let width = CGFloat(box.width)
        let height = CGFloat(box.height)
        guard graphic.objectKind == .ellipse else {
            return CGPoint(x: width, y: height)
        }
        let diagonal = sqrt(0.5)
        return CGPoint(x: width / 2 + width / 2 * diagonal,
                       y: height / 2 + height / 2 * diagonal)
    }

    /// A drag that moves the shape. It takes the selection first, the way a card does, so dragging an
    /// unselected shape moves that shape alone instead of the group that was selected before it.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("CanvasViewport"))
            .onChanged { value in
                if !isSelected { onSelect() }
                onDrag(contentDelta(of: value))
            }
            .onEnded { value in
                onDragEnd(contentDelta(of: value))
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("CanvasViewport"))
            .onChanged { value in
                onResize(contentDelta(of: value))
            }
            .onEnded { value in
                onResizeEnd(contentDelta(of: value))
            }
    }

    /// A viewport translation in sheet coordinates: the content is drawn scaled and panned, so a
    /// gesture's points have to be divided back out before they mean anything to the model.
    private func contentDelta(of value: DragGesture.Value) -> CGSize {
        let zoom = zoomScale()
        return CGSize(width: value.translation.width / zoom, height: value.translation.height / zoom)
    }

    /// The shape that traces this object's outline, so the drawing and the selection ring come from one
    /// place. `AnyShape` because the two kinds are different concrete shapes; the canvas can only pick
    /// between them at runtime.
    static func outline(for graphic: ProjectGraphic) -> AnyShape {
        graphic.objectKind == .ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle())
    }

    static func helpText(for graphic: ProjectGraphic) -> String {
        let name = graphic.objectKind == .ellipse ? "Circle" : "Rectangle"
        return "\(name) object — drag to move, corner to resize"
    }
}
