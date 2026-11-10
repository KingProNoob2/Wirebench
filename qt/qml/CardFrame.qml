import QtQuick
import QtQuick.Shapes

// A card's body, header and outline as ONE shape of three paths, rather than three shapes: a sheet has dozens of cards, and each
// separate Shape is its own node for the renderer. Exact curves, so the corners stay round at any zoom.
Shape {
    id: frame
    property color color: "#fff"
    property color headerColor: "#ccc"
    property real headerHeight: 24
    property color lineColor: "#999"           // the hairline under the header
    property color borderColor: "#999"
    property real borderWidth: 1
    property real radius: 10
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true
    // The outline eases between its states, so selecting a block is a short transition and not a jump.
    Behavior on borderColor { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on borderWidth { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    // The outline runs along the middle of its stroke, so it sits inside the card by half the border.
    readonly property real i: borderWidth / 2
    readonly property real r: Math.max(0, radius - i)

    ShapePath {      // the card
        fillColor: frame.color
        strokeColor: "transparent"
        strokeWidth: -1
        startX: frame.radius; startY: 0
        PathLine { x: frame.width - frame.radius; y: 0 }
        PathArc { x: frame.width; y: frame.radius; radiusX: frame.radius; radiusY: frame.radius }
        PathLine { x: frame.width; y: frame.height - frame.radius }
        PathArc { x: frame.width - frame.radius; y: frame.height; radiusX: frame.radius; radiusY: frame.radius }
        PathLine { x: frame.radius; y: frame.height }
        PathArc { x: 0; y: frame.height - frame.radius; radiusX: frame.radius; radiusY: frame.radius }
        PathLine { x: 0; y: frame.radius }
        PathArc { x: frame.radius; y: 0; radiusX: frame.radius; radiusY: frame.radius }
    }
    ShapePath {      // the header: rounded at the top with the card, square below
        fillColor: frame.headerColor
        strokeColor: "transparent"
        strokeWidth: -1
        startX: frame.radius; startY: 0
        PathLine { x: frame.width - frame.radius; y: 0 }
        PathArc { x: frame.width; y: frame.radius; radiusX: frame.radius; radiusY: frame.radius }
        PathLine { x: frame.width; y: frame.headerHeight }
        PathLine { x: 0; y: frame.headerHeight }
        PathLine { x: 0; y: frame.radius }
        PathArc { x: frame.radius; y: 0; radiusX: frame.radius; radiusY: frame.radius }
    }
    ShapePath {      // the hairline under the header
        fillColor: "transparent"
        strokeColor: frame.lineColor
        strokeWidth: 1
        capStyle: ShapePath.FlatCap          // a square cap would run past the ends
        // Between the outline's inner edges, so it meets the border and does not poke through it.
        startX: frame.borderWidth; startY: frame.headerHeight + 0.5
        PathLine { x: frame.width - frame.borderWidth; y: frame.headerHeight + 0.5 }
    }
    ShapePath {      // the outline, over the header too: the selection (accent) or the edge (hairline)
        fillColor: "transparent"
        strokeColor: frame.borderColor
        strokeWidth: frame.borderWidth
        joinStyle: ShapePath.RoundJoin
        startX: frame.i + frame.r; startY: frame.i
        PathLine { x: frame.width - frame.i - frame.r; y: frame.i }
        PathArc { x: frame.width - frame.i; y: frame.i + frame.r; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.width - frame.i; y: frame.height - frame.i - frame.r }
        PathArc { x: frame.width - frame.i - frame.r; y: frame.height - frame.i; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.i + frame.r; y: frame.height - frame.i }
        PathArc { x: frame.i; y: frame.height - frame.i - frame.r; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.i; y: frame.i + frame.r }
        PathArc { x: frame.i + frame.r; y: frame.i; radiusX: frame.r; radiusY: frame.r }
    }
}
