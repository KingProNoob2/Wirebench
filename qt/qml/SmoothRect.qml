import QtQuick
import QtQuick.Shapes

// A rounded rectangle drawn as exact curves. Qt's own Rectangle tessellates its corners into a few straight segments, which
// shows as facets when it is magnified; this stays round at any zoom. Each corner has its own radius.
Shape {
    id: shape
    property color color: "transparent"
    property color borderColor: "transparent"
    property real borderWidth: 0
    property real radius: 0
    property real topLeftRadius: radius
    property real topRightRadius: radius
    property real bottomRightRadius: radius
    property real bottomLeftRadius: radius
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    // The outline runs along the middle of the border, so a border sits inside the item's bounds.
    readonly property real inset: borderWidth / 2
    readonly property real w: Math.max(0, width - borderWidth)
    readonly property real h: Math.max(0, height - borderWidth)
    function r(value) { return Math.max(0, Math.min(value, w / 2, h / 2)) }

    ShapePath {
        fillColor: shape.color
        strokeColor: shape.borderColor
        strokeWidth: shape.borderWidth > 0 ? shape.borderWidth : -1
        joinStyle: ShapePath.RoundJoin
        startX: shape.inset + shape.r(shape.topLeftRadius)
        startY: shape.inset
        PathLine { x: shape.inset + shape.w - shape.r(shape.topRightRadius); y: shape.inset }
        PathArc { x: shape.inset + shape.w; y: shape.inset + shape.r(shape.topRightRadius)
                  radiusX: shape.r(shape.topRightRadius); radiusY: shape.r(shape.topRightRadius) }
        PathLine { x: shape.inset + shape.w; y: shape.inset + shape.h - shape.r(shape.bottomRightRadius) }
        PathArc { x: shape.inset + shape.w - shape.r(shape.bottomRightRadius); y: shape.inset + shape.h
                  radiusX: shape.r(shape.bottomRightRadius); radiusY: shape.r(shape.bottomRightRadius) }
        PathLine { x: shape.inset + shape.r(shape.bottomLeftRadius); y: shape.inset + shape.h }
        PathArc { x: shape.inset; y: shape.inset + shape.h - shape.r(shape.bottomLeftRadius)
                  radiusX: shape.r(shape.bottomLeftRadius); radiusY: shape.r(shape.bottomLeftRadius) }
        PathLine { x: shape.inset; y: shape.inset + shape.r(shape.topLeftRadius) }
        PathArc { x: shape.inset + shape.r(shape.topLeftRadius); y: shape.inset
                  radiusX: shape.r(shape.topLeftRadius); radiusY: shape.r(shape.topLeftRadius) }
    }
}
