import QtQuick
import QtQuick.Shapes
import Wirebench

// A rectangle, ellipse or text object on the sheet. Dirigo's black ink and white paper are drawn in the theme's own
// colours, so a drawing made on white paper stays readable on the dark sheet.
Item {
    id: item
    required property var model
    property real dragX: 0
    property real dragY: 0
    // While the corner is dragged, the shape is shown at its new size; the model is told on release.
    property real growW: 0
    property real growH: 0
    readonly property bool isText: model.kind === "text"
    readonly property color ink: model.penInk ? AppTheme.text : model.pen
    readonly property color fill: model.brush === "" ? "transparent"
        : model.brushWash ? Qt.rgba(AppTheme.text.r, AppTheme.text.g, AppTheme.text.b, 0.06) : model.brush

    signal pressed(int index)
    signal dragging(int index, real dx, real dy)
    signal moved(int index, real dx, real dy)
    signal resized(int index, real w, real h)
    signal editRequested(int index)

    x: model.x
    y: model.y
    width: isText ? label.width : Math.max(16, model.w + growW)
    height: isText ? label.height : Math.max(16, model.h + growH)

    Rectangle {
        visible: item.model.kind === "rectangle"
        anchors.fill: parent
        color: item.fill
        border.color: item.ink
        border.width: Math.max(1, Math.round(item.model.penWidth))
        antialiasing: true
    }

    Shape {
        visible: item.model.kind === "ellipse"
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        antialiasing: true
        ShapePath {
            strokeColor: item.ink
            strokeWidth: Math.max(1, item.model.penWidth)
            fillColor: item.fill
            PathAngleArc {
                centerX: item.width / 2; centerY: item.height / 2
                radiusX: item.width / 2; radiusY: item.height / 2
                startAngle: 0; sweepAngle: 360
            }
        }
    }

    Text {
        id: label
        visible: item.isText
        text: item.model.text
        color: item.model.fontInk || item.model.fontColor === "" ? AppTheme.text : item.model.fontColor
        font.pixelSize: Math.max(8, item.model.fontSize)
        font.bold: item.model.bold
        font.italic: item.model.italic
    }

    // Selection outline and the corner to pull a shape's size by.
    Rectangle {
        visible: item.model.selected
        x: -3; y: -3; width: parent.width + 6; height: parent.height + 6
        color: "transparent"; border.color: AppTheme.selection; border.width: 2; radius: 3
    }
    Rectangle {
        visible: item.model.selected && !item.isText
        x: parent.width - 5; y: parent.height - 5; width: 11; height: 11; radius: 3
        color: AppTheme.selection
        MouseArea {
            anchors.fill: parent; anchors.margins: -4
            cursorShape: Qt.SizeFDiagCursor
            property point origin
            onPressed: mouse => { origin = mapToItem(item.parent, mouse.x, mouse.y); item.growW = 0; item.growH = 0 }
            onPositionChanged: mouse => {
                const now = mapToItem(item.parent, mouse.x, mouse.y)
                item.growW = now.x - origin.x
                item.growH = now.y - origin.y
            }
            onReleased: {
                const w = item.width, h = item.height
                item.resized(item.model.index, w, h)
                item.growW = 0; item.growH = 0
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        z: -1
        property point origin
        property bool moving: false
        onPressed: mouse => { origin = mapToItem(item.parent, mouse.x, mouse.y); moving = false; item.pressed(item.model.index) }
        onPositionChanged: mouse => {
            if (item.isText) return
            const now = mapToItem(item.parent, mouse.x, mouse.y)
            item.dragX = now.x - origin.x; item.dragY = now.y - origin.y
            moving = true
            item.dragging(item.model.index, item.dragX, item.dragY)
        }
        onDoubleClicked: if (item.isText) item.editRequested(item.model.index)
        onReleased: {
            if (moving && (item.dragX !== 0 || item.dragY !== 0)) item.moved(item.model.index, item.dragX, item.dragY)
            item.dragX = 0; item.dragY = 0
        }
    }
}
