import QtQuick
import QtQuick.Shapes
import Wirebench

// One routed wire; the points come from the Swift wire layout.
Shape {
    id: wire
    required property var model
    property bool picked: false          // the wire the user clicked, which Delete removes
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true
    smooth: true

    ShapePath {
        strokeColor: wire.picked ? AppTheme.accent : (wire.model.high ? AppTheme.live : AppTheme.wireIdle)
        strokeWidth: wire.picked ? 3 : (wire.model.high ? 2.2 : 1.5)
        strokeStyle: wire.model.feedback ? ShapePath.DashLine : ShapePath.SolidLine
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathSvg { path: wire.model.svg }
    }
}
