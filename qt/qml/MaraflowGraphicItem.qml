import QtQuick
import Wirebench

// One imported Maraflow graphic object. Signed boxes, its shape vocabulary, and live indicator/button states come
// from the bridge's `maraflowGraphics` rows; Dirigo's own shapes take the other path.
Item {
    id: item
    required property var model

    readonly property string kind: (model.kind || "").toUpperCase()
    readonly property bool isLine: kind === "LINE"
    readonly property bool isText: kind === "TEXT"
    readonly property bool isButton: kind === "VISUAL_BUTTON"
    readonly property bool indicator: model.indicator === true
    readonly property bool active: model.active === true
    readonly property bool pressed: model.pressed === true
    readonly property real minX: isLine || isText ? model.x : Math.min(model.x, model.x + model.w)
    readonly property real minY: isLine || isText ? model.y : Math.min(model.y, model.y + model.h)
    readonly property real boxW: isLine || isText ? 1 : Math.max(1, Math.abs(model.w))
    readonly property real boxH: isLine || isText ? 1 : Math.max(1, Math.abs(model.h))
    readonly property color strokeColour: active ? model.activeStroke : model.stroke
    readonly property color fillColour: isButton
        ? (pressed ? "#76D7C4" : "#E2E6EA")
        : (indicator ? (active ? model.activeFill : model.fill) : (model.filled ? model.fill : "transparent"))

    x: isText ? model.x : minX
    y: isText ? model.y : minY
    width: isText ? Math.max(80, model.text.length * Math.max(8, model.fontSize) * 0.75) : boxW
    height: isText ? Math.max(16, model.fontSize * 1.7) : boxH
    z: 1

    onActiveChanged: canvas.requestPaint()
    onPressedChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: item.paint(canvas.getContext("2d"), canvas)
    }

    MouseArea {
        visible: item.isButton
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: controller.command({cmd: "pressMaraflowBinding", target: item.model.boundTargetPin})
    }

    function paint(ctx, canvas) {
        ctx.clearRect(0, 0, canvas.width + 4, canvas.height + 4)
        if (item.isText) {
            ctx.fillStyle = item.model.stroke
            ctx.font = Math.max(8, item.model.fontSize * 1.6) + "px sans-serif"
            ctx.textBaseline = "top"
            ctx.fillText(item.model.text, 0, 0)
            return
        }
        if (item.isLine) {
            const sx = item.model.x - item.x
            const sy = item.model.y - item.y
            ctx.beginPath()
            ctx.moveTo(sx, sy)
            ctx.lineTo(sx + item.model.w, sy + item.model.h)
            ctx.strokeStyle = item.model.stroke
            ctx.lineWidth = item.model.strokeWidth
            ctx.stroke()
            return
        }
        const w = item.width, h = item.height
        const roundRect = () => {
            const r = Math.min(14, w / 2, h / 2)
            ctx.beginPath()
            ctx.moveTo(r, 0)
            ctx.lineTo(w - r, 0); ctx.arcTo(w, 0, w, r, r)
            ctx.lineTo(w, h - r); ctx.arcTo(w, h, w - r, h, r)
            ctx.lineTo(r, h); ctx.arcTo(0, h, 0, h - r, r)
            ctx.lineTo(0, r); ctx.arcTo(0, 0, r, 0, r)
            ctx.closePath()
        }
        const ellipse = (cw, ch) => {
            ctx.beginPath()
            ctx.ellipse(0, 0, cw / 2, ch / 2, 0, 0, Math.PI * 2)
        }
        const polygon = sides => {
            ctx.beginPath()
            const rx = w / 2, ry = h / 2
            for (let i = 0; i < sides; ++i) {
                const angle = -Math.PI / 2 + i * 2 * Math.PI / sides
                const px = rx + Math.cos(angle) * rx, py = ry + Math.sin(angle) * ry
                if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
            }
            ctx.closePath()
        }
        const arcPath = sector => {
            const start = sector ? 30 : 20, sweep = sector ? 240 : 220
            ctx.beginPath()
            for (let i = 0; i <= 48; ++i) {
                const a = (start + sweep * i / 48) * Math.PI / 180
                const px = w / 2 + Math.cos(a) * w / 2, py = h / 2 + Math.sin(a) * h / 2
                if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
            }
            if (sector) { ctx.lineTo(w / 2, h / 2); ctx.closePath() }
        }
        // Canvas paths are placed around (0,0) for the ellipse/polygon helpers; translate so they sit in the box.
        ctx.save()
        switch (item.kind) {
        case "RECTANGLE": ctx.beginPath(); ctx.rect(0, 0, w, h); break
        case "ROUNDED_RECTANGLE": roundRect(); break
        case "ELLIPSE":
            ctx.translate(w / 2, h / 2); ellipse(w, h); break
        case "CIRCLE": {
            const side = Math.min(w, h)
            ctx.translate(side / 2, side / 2); ellipse(side, side); break
        }
        case "TRIANGLE": ctx.translate(w / 2, h / 2); polygon(3); break
        case "PENTAGON": ctx.translate(w / 2, h / 2); polygon(5); break
        case "HEXAGON": ctx.translate(w / 2, h / 2); polygon(6); break
        case "OCTAGON": ctx.translate(w / 2, h / 2); polygon(8); break
        case "CUSTOM_NGON": ctx.translate(w / 2, h / 2); polygon(item.model.ngonSides || 6); break
        case "ARC": arcPath(false); break
        case "SECTOR": arcPath(true); break
        default: ctx.beginPath(); ctx.rect(0, 0, w, h); break
        }
        if (item.fillColour.a > 0 && !item.isButton) {
            ctx.fillStyle = item.fillColour
            ctx.fill()
        }
        ctx.strokeStyle = item.strokeColour
        ctx.lineWidth = item.model.strokeWidth
        if (item.model.dashed) ctx.setLineDash([5, 4])
        ctx.stroke()
        ctx.restore()

        if (item.isButton) {
            ctx.fillStyle = item.fillColour
            ctx.fillRect(0, 0, w, h)
            ctx.strokeStyle = "#000000"
            ctx.lineWidth = 1
            ctx.strokeRect(0, 0, w, h)
            ctx.fillStyle = "#000000"
            ctx.font = "bold 14px sans-serif"
            ctx.textAlign = "center"
            ctx.textBaseline = "middle"
            ctx.fillText(item.model.text || "Button", w / 2, h / 2)
        }
    }
}
