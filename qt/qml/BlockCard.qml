import QtQuick
import QtQuick.Shapes
import Wirebench

// A block on the sheet: a flat rounded card with a tinted header, input pins on the left, outputs on the right, and
// parameters along the foot. Sizes and pin rows follow the Swift card geometry (header 23, the first pin and the distance between pins from the model), which the wire router also uses, so the room is made with padding rather than by moving pins.
Item {
    id: card
    required property var model
    property real dragX: 0
    property real dragY: 0
    readonly property color tint: AppTheme.categoryColor(model.category)
    readonly property real pad: 26              // where labels start, clear of the pin dot
    readonly property real dotInset: 7          // from the card's edge to the pin dot: room between the dot and the outline
    readonly property real pitch: controller.settings.pinPitch || 16
    readonly property real firstPin: controller.settings.firstPin || 33
    // Label widths, so each side lines up instead of following each label's own end. A pin shows its name and its dot, lit while the signal is
    // high, and no number: the values live in the inspector.
    FontMetrics { id: metrics; font.pixelSize: 10 }
    function widest(pins) { let w = 0; for (const p of pins) w = Math.max(w, metrics.advanceWidth(p.label)); return Math.ceil(w) }
    readonly property real inLabelW: widest(model.inPins)
    readonly property real outLabelW: widest(model.outPins)
    readonly property real beside: dotInset + 10 + 6            // from the card's edge to the name beside its dot
    readonly property real inLabelX: beside
    readonly property real outLabelStart: width - beside - outLabelW

    signal pressed(int id, bool extend)
    signal configure(int id)
    signal contextRequested(int id, point at)
    signal moved(int id, real dx, real dy)
    signal dragging(int id, real dx, real dy)
    signal wireStarted(int id, int pin, point at, point from)     // `from` is the pin's centre, on the sheet
    signal wireDragged(point at)
    signal wireEnded()

    x: model.x
    y: model.y
    width: model.w
    height: model.h

    // A soft shadow from stacked translucent rectangles: cheap, and it cannot go blocky when zoomed the way a texture does.
    Rectangle { x: -3; y: 5; width: parent.width + 6; height: parent.height + 3; radius: 14; antialiasing: true; color: AppTheme.shadow; opacity: 0.10 }
    Rectangle { x: -1; y: 3; width: parent.width + 2; height: parent.height + 1; radius: 12; antialiasing: true; color: AppTheme.shadow; opacity: 0.20 }
    Rectangle { x: 0; y: 1.5; width: parent.width; height: parent.height; radius: 10; antialiasing: true; color: AppTheme.shadow; opacity: 0.30 }

    // A soft ring around a selected card that grows in from the card's edge as it is selected, and shrinks back as it is not.
    SmoothRect {
        id: halo
        readonly property real t: card.model.selected ? 1 : 0
        property real progress: t
        Behavior on progress { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        visible: progress > 0.01
        opacity: progress
        x: -1 - 4 * progress; y: -1 - 4 * progress
        width: parent.width + 2 + 8 * progress; height: parent.height + 2 + 8 * progress
        radius: 10 + 4 * progress
        borderWidth: 4
        borderColor: Qt.rgba(AppTheme.selection.r, AppTheme.selection.g, AppTheme.selection.b, 0.22)
    }

    Item {
        id: body
        anchors.fill: parent
        CardFrame {
            anchors.fill: parent
            color: AppTheme.card
            headerColor: Qt.tint(AppTheme.card, Qt.rgba(card.tint.r, card.tint.g, card.tint.b, AppTheme.dark ? 0.16 : 0.13))
            lineColor: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.30)
            borderWidth: card.model.selected ? 2 : 1
            borderColor: card.model.selected ? AppTheme.selection : AppTheme.cardStroke
        }
    }

    // Header text, centred on its capital letters: a text item's own box includes room for descenders below the baseline, so
    // centring the box puts the capitals visibly high.
    FontMetrics { id: nameFont; font.pixelSize: 12; font.weight: Font.Bold }
    TextMetrics { id: nameCaps; text: "H"; font.pixelSize: 12; font.weight: Font.Bold }
    FontMetrics { id: typeFont; font.pixelSize: 9 }
    TextMetrics { id: typeCaps; text: "H"; font.pixelSize: 9 }
    // `area` is the header's height plus the outline's thickness: the outline takes room from the top, so the middle is below 12.
    function captop(font, caps, area) { return (area - (-caps.tightBoundingRect.y)) / 2 - (font.ascent - (-caps.tightBoundingRect.y)) }

    Text {
        x: 13; y: card.captop(nameFont, nameCaps, 26); width: parent.width - 26
        elide: Text.ElideRight
        text: card.model.name
        color: AppTheme.text
        font.pixelSize: 12; font.weight: Font.Bold
    }
    // The block's type, small, at the right of the header when the name leaves room for it.
    Text {
        visible: card.model.type !== "" && card.model.type !== card.model.name && x > 13 + nameWidth.width + 14
        x: parent.width - width - 13; y: card.captop(typeFont, typeCaps, 26)
        text: card.model.type
        color: AppTheme.faint
        font.pixelSize: 9
        TextMetrics { id: nameWidth; text: card.model.name; font.pixelSize: 12; font.bold: true }
    }

    // A pin's marker: a ring that fills and glows while its signal is high. Drawn as exact curves, so it is a true circle at
    // any zoom (a rounded rectangle is a polygon, and shows its facets when magnified).
    component PinDot: Item {
        id: dot
        property bool high
        width: 10; height: 10
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            antialiasing: true
            ShapePath {   // the glow, an exact circle like the ring, not a rounded rectangle's polygon
                strokeColor: "transparent"
                strokeWidth: -1
                fillColor: dot.high ? Qt.rgba(AppTheme.live.r, AppTheme.live.g, AppTheme.live.b, 0.22) : "transparent"
                PathAngleArc { centerX: 5; centerY: 5; radiusX: 7; radiusY: 7; startAngle: 0; sweepAngle: 360 }
            }
            ShapePath {
                strokeWidth: 2
                strokeColor: dot.high ? AppTheme.live : AppTheme.wireIdle
                fillColor: dot.high ? AppTheme.live : AppTheme.card
                PathAngleArc { centerX: 5; centerY: 5; radiusX: 4; radiusY: 4; startAngle: 0; sweepAngle: 360 }
            }
        }
    }

    // A value, as a small monospace chip.
    component Chip: Item {
        property alias text: chipText.text
        property bool high
        width: Math.max(18, chipText.implicitWidth + 10); height: 13
        SmoothRect {
            anchors.fill: parent; radius: height / 2
            color: parent.high ? Qt.rgba(AppTheme.live.r, AppTheme.live.g, AppTheme.live.b, 0.16) : AppTheme.field
        }
        Text { id: chipText; anchors.centerIn: parent; color: parent.high ? AppTheme.live : AppTheme.dim
               font.pixelSize: 9; font.family: "monospace" }
    }

    Repeater {
        model: card.model.inPins.length
        delegate: Item {
            readonly property var pin: card.model.inPins[index] || ({label: "", value: 0, isBool: true})
            required property int index
            y: card.firstPin + card.pitch * index - 6
            Rectangle { visible: pin.connected; x: 0; y: 5; width: card.dotInset + 1; height: 2; color: pin.value !== 0 ? AppTheme.live : AppTheme.wireIdle }   // from the edge to the dot, only where a wire arrives
            PinDot { x: card.dotInset; y: 1; high: pin.value !== 0 }
            Text {
                x: card.inLabelX; height: 12
                verticalAlignment: Text.AlignVCenter
                text: pin.label
                color: AppTheme.text; opacity: 0.88; font.pixelSize: 10
            }
            // A click on an input row sets or clears it, as in the SwiftUI card. A tap handler, so a drag that starts here still
            // moves the card.
            Item {
                x: 0; y: -1; width: card.inLabelX + card.inLabelW + 6; height: 14
                TapHandler { onTapped: controller.command({cmd: "toggleInput", module: card.model.id, pin: index}) }
            }
        }
    }

    Repeater {
        model: card.model.outPins.length
        delegate: Item {
            id: outPin
            readonly property var pin: card.model.outPins[index] || ({label: "", value: 0, isBool: true})
            required property int index
            y: card.firstPin + card.pitch * index - 6
            Rectangle { visible: outPin.pin.connected; x: card.width - card.dotInset - 1; y: 5; width: card.dotInset + 1; height: 2; color: outPin.pin.value !== 0 ? AppTheme.live : AppTheme.wireIdle }
            PinDot { x: card.width - card.dotInset - 10; y: 1; high: outPin.pin.value !== 0 }
            Text {
                x: card.width - card.beside - width; height: 12
                verticalAlignment: Text.AlignVCenter
                text: outPin.pin.label
                color: AppTheme.text; opacity: 0.88; font.pixelSize: 10
            }
            MouseArea {
                x: card.width - card.dotInset - 14; y: -3; width: card.dotInset + 14; height: 18
                cursorShape: Qt.CrossCursor
                onPressed: mouse => card.wireStarted(card.model.id, outPin.index, mapToItem(card.parent, mouse.x, mouse.y),
                                                    Qt.point(card.x + card.width - card.dotInset - 5, card.y + card.firstPin + card.pitch * outPin.index))
                onPositionChanged: mouse => card.wireDragged(mapToItem(card.parent, mouse.x, mouse.y))
                onReleased: card.wireEnded()
            }
            // The macro Inputs block and 8xDI are driven by clicking their outputs; dragging from the dot still draws a wire.
            Item {
                visible: card.model.interaction === "pinToggles"
                x: card.outLabelStart - 4; y: -1; width: card.width - card.outLabelStart + 4; height: 14
                TapHandler { onTapped: controller.command({cmd: "toggleInput", module: card.model.id, pin: outPin.index}) }
            }
        }
    }

    // Parameters are pins, as in Dirigo: rows under the inputs, on a shaded cell, with the value after the name. A wire can end on one.
    Repeater {
        model: card.model.paramPins.length
        delegate: Item {
            readonly property var pin: card.model.paramPins[index] || ({label: "", value: 0})
            required property int index
            y: card.firstPin + card.pitch * (card.model.inPins.length + index) - 6
            SmoothRect {
                x: 2; y: -1; height: 14; radius: 4
                width: card.inLabelX + paramName.implicitWidth + paramValue.width + 16
                color: Qt.rgba(AppTheme.dark ? 1 : 0, AppTheme.dark ? 1 : 0, AppTheme.dark ? 1 : 0, AppTheme.dark ? 0.07 : 0.06)
            }
            Rectangle { visible: pin.connected; x: 0; y: 5; width: card.dotInset + 1; height: 2; color: AppTheme.wireIdle }
            PinDot { x: card.dotInset; y: 1; high: false }
            Text {
                id: paramName
                x: card.inLabelX; height: 12
                verticalAlignment: Text.AlignVCenter
                text: pin.label
                color: AppTheme.text; opacity: 0.88; font.pixelSize: 10
            }
            Chip { id: paramValue; x: card.inLabelX + paramName.implicitWidth + 4; y: -0.5; text: pin.value }
        }
    }

    // A BoolVar's button, or an IntVar's slider, in the room the card keeps below its pins.
    readonly property real footHeight: 0     // the parameters are rows now, not a strip
    readonly property bool hasControl: model.interaction === "control" || model.interaction === "slider"
    readonly property var driven: model.outPins[0] || ({value: 0})
    readonly property bool driveHigh: driven.value !== 0

    Item {
        id: control
        visible: card.hasControl
        x: 8; width: card.width - 16; height: 24
        y: card.height - card.footHeight - height - 6

        // BoolVar: "Pulse" is held for as long as the button is, a latch flips on a click.
        SmoothRect {
            visible: card.model.interaction === "control"
            anchors.fill: parent; radius: 7
            color: card.driveHigh ? Qt.rgba(AppTheme.live.r, AppTheme.live.g, AppTheme.live.b, 0.22) : AppTheme.field
            borderWidth: 1
            borderColor: card.driveHigh ? Qt.rgba(AppTheme.live.r, AppTheme.live.g, AppTheme.live.b, 0.6) : AppTheme.panelStroke
            Row {
                anchors.centerIn: parent; spacing: 6
                PinDot { anchors.verticalCenter: parent.verticalCenter; high: card.driveHigh }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.model.boolMode === "pushButton" ? "Pulse" : (card.model.boolMode === "toggleSwitch" ? (card.driveHigh ? "LATCHED" : "OFF") : (card.driveHigh ? "ON" : "OFF"))
                    color: card.driveHigh ? AppTheme.live : AppTheme.dim; font.pixelSize: 10; font.weight: Font.DemiBold
                }
            }
            MouseArea {
                anchors.fill: parent
                property bool held: false
                onPressed: {
                    card.pressed(card.model.id, false)
                    if (card.model.boolMode === "pushButton") { held = true; controller.command({cmd: "pressInput", module: card.model.id, pin: 0, down: true}) }
                    else controller.command({cmd: "toggleInput", module: card.model.id, pin: 0})
                }
                function letGo() { if (held) { held = false; controller.command({cmd: "pressInput", module: card.model.id, pin: 0, down: false}) } }
                onReleased: letGo()
                onCanceled: letGo()
            }
        }

        // IntVar / LongVar: a thumb on a track from 0 to the block's maximum, the variable following the thumb.
        Item {
            id: slider
            visible: card.model.interaction === "slider"
            anchors.fill: parent
            readonly property real maximum: Math.max(1, card.model.sliderMax)
            readonly property real current: Math.min(Math.max(card.driven.value, 0), maximum)
            // SmoothRect, not Rectangle: Qt's own rounded rectangles are polygons, and a small circle made of a few straight edges looks rough.
            SmoothRect { x: 7; width: parent.width - 14; height: 4; radius: 2; anchors.verticalCenter: parent.verticalCenter; color: AppTheme.field }
            SmoothRect { x: 7; width: (parent.width - 14) * slider.current / slider.maximum; height: 4; radius: 2; anchors.verticalCenter: parent.verticalCenter; color: card.tint }
            SmoothRect {
                x: 7 + (parent.width - 14) * slider.current / slider.maximum - width / 2
                width: 16; height: 16; radius: 8; anchors.verticalCenter: parent.verticalCenter
                color: AppTheme.card; borderWidth: 2; borderColor: card.tint
            }
            MouseArea {
                anchors.fill: parent
                function setFrom(mouse) {
                    const next = Math.round(Math.min(Math.max((mouse.x - 7) / (width - 14), 0), 1) * slider.maximum)
                    if (next !== slider.current) controller.command({cmd: "setVariable", module: card.model.id, value: next})
                }
                onPressed: mouse => { card.pressed(card.model.id, false); setFrom(mouse) }
                onPositionChanged: mouse => { if (pressed) setFrom(mouse) }
            }
        }
    }

    // A Segment block's display, beside its pins: a dark window that fills the body, and the digit as the model fits it to the window
    // (`segmentWindow` and `segmentBars`, in card coordinates, so this draws the SwiftUI card's digit). Dark in both appearances, with an edge
    // that reads on either card.
    SmoothRect {
        visible: card.model.segmentWindow.length === 4
        x: card.model.segmentWindow[0] || 0; y: card.model.segmentWindow[1] || 0
        width: card.model.segmentWindow[2] || 0; height: card.model.segmentWindow[3] || 0
        radius: Math.min(11, height * 0.08)
        color: "#0e0f12"
        borderWidth: 1; borderColor: AppTheme.dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.35)
    }
    Repeater {
        model: card.model.segmentBars
        delegate: Rectangle {
            required property var modelData
            required property int index
            x: modelData[0]; y: modelData[1]; width: modelData[2]; height: modelData[3]
            radius: Math.min(width, height) / 2; antialiasing: true
            color: card.model.segments[index] === true ? "#ff4d3d" : Qt.rgba(1, 0.3, 0.24, 0.16)      // no live values yet: all dim
        }
    }

    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point origin
        property bool moving: false
        onPressed: mouse => {
            if (mouse.button === Qt.RightButton) { card.contextRequested(card.model.id, mapToItem(null, mouse.x, mouse.y)); return }
            origin = mapToItem(card.parent, mouse.x, mouse.y)
            moving = false
            card.pressed(card.model.id, mouse.modifiers & Qt.ShiftModifier)
        }
        onPositionChanged: mouse => {
            if (!(pressedButtons & Qt.LeftButton)) return
            const now = mapToItem(card.parent, mouse.x, mouse.y)
            card.dragX = now.x - origin.x
            card.dragY = now.y - origin.y
            moving = true
            card.dragging(card.model.id, card.dragX, card.dragY)
        }
        onDoubleClicked: { if (card.model.macroTarget !== "") controller.command({cmd: "setPage", page: card.model.macroTarget}); else card.configure(card.model.id) }
        onReleased: {
            if (moving && (card.dragX !== 0 || card.dragY !== 0)) card.moved(card.model.id, card.dragX, card.dragY)
            card.dragX = 0; card.dragY = 0
        }
    }
}
