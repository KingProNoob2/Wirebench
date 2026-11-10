import QtQuick

// A small line icon drawn in code, so there is no icon font to ship. `name` picks the glyph.
Canvas {
    id: icon
    property string name: ""
    property color color: AppTheme.text
    property real size: 16
    width: size; height: size
    onNameChanged: requestPaint()
    onColorChanged: requestPaint()
    onSizeChanged: requestPaint()

    onPaint: {
        const c = getContext("2d")
        c.reset()
        const s = size / 16
        c.scale(s, s)
        c.strokeStyle = color
        c.fillStyle = color
        c.lineWidth = 1.6
        c.lineCap = "round"
        c.lineJoin = "round"
        c.beginPath()
        switch (name) {
        case "play": c.moveTo(4.5, 2.5); c.lineTo(13, 8); c.lineTo(4.5, 13.5); c.closePath(); c.fill(); return
        case "pause": c.rect(3.5, 2.5, 3, 11); c.rect(9.5, 2.5, 3, 11); c.fill(); return
        case "step": c.moveTo(3, 2.5); c.lineTo(10.5, 8); c.lineTo(3, 13.5); c.closePath(); c.fill()
                     c.beginPath(); c.moveTo(13, 3); c.lineTo(13, 13); c.stroke(); return
        case "reset": {
            // A circular arrow: nearly a full circle, open at the top right, with an arrowhead where it ends.
            const end = 4.6, r = 5
            c.arc(8, 8, r, -0.6, end, false); c.stroke()
            const ex = 8 + r * Math.cos(end), ey = 8 + r * Math.sin(end)          // where the arc ends
            const tx = -Math.sin(end), ty = Math.cos(end)                           // direction of travel there
            const nx = Math.cos(end), ny = Math.sin(end)                            // outward
            c.beginPath()
            c.moveTo(ex + tx * 3, ey + ty * 3)
            c.lineTo(ex + nx * 2.4, ey + ny * 2.4)
            c.lineTo(ex - nx * 2.4, ey - ny * 2.4)
            c.closePath(); c.fill(); return
        }
        case "undo": c.moveTo(5.5, 3.5); c.lineTo(2.5, 6.5); c.lineTo(5.5, 9.5)
                     c.moveTo(2.8, 6.5); c.lineTo(9.5, 6.5); c.bezierCurveTo(12.5, 6.5, 13.5, 8, 13.5, 10); c.bezierCurveTo(13.5, 12, 12.5, 13, 10, 13); c.stroke(); return
        case "redo": c.moveTo(10.5, 3.5); c.lineTo(13.5, 6.5); c.lineTo(10.5, 9.5)
                     c.moveTo(13.2, 6.5); c.lineTo(6.5, 6.5); c.bezierCurveTo(3.5, 6.5, 2.5, 8, 2.5, 10); c.bezierCurveTo(2.5, 12, 3.5, 13, 6, 13); c.stroke(); return
        case "open": c.moveTo(2, 4.5); c.lineTo(2, 12.5); c.lineTo(13, 12.5); c.lineTo(14, 6.5); c.lineTo(5.5, 6.5); c.lineTo(4.5, 4); c.lineTo(2, 4)
                     c.stroke(); return
        case "save": c.moveTo(3, 2.5); c.lineTo(11.5, 2.5); c.lineTo(13.5, 4.5); c.lineTo(13.5, 13.5); c.lineTo(3, 13.5); c.closePath()
                     c.moveTo(5.5, 2.8); c.lineTo(5.5, 6); c.lineTo(10.5, 6); c.lineTo(10.5, 2.8)
                     c.moveTo(5.5, 13.5); c.lineTo(5.5, 9.5); c.lineTo(10.5, 9.5); c.lineTo(10.5, 13.5); c.stroke(); return
        case "plus": c.moveTo(8, 3); c.lineTo(8, 13); c.moveTo(3, 8); c.lineTo(13, 8); c.stroke(); return
        case "minus": c.moveTo(3, 8); c.lineTo(13, 8); c.stroke(); return
        case "search": c.arc(7, 7, 4.2, 0, 6.3); c.moveTo(10.2, 10.2); c.lineTo(13.5, 13.5); c.stroke(); return
        case "sidebar": c.rect(2, 3, 12, 10); c.moveTo(10, 3); c.lineTo(10, 13); c.stroke(); return
        case "fit": c.moveTo(2.5, 6); c.lineTo(2.5, 2.5); c.lineTo(6, 2.5); c.moveTo(10, 2.5); c.lineTo(13.5, 2.5); c.lineTo(13.5, 6)
                    c.moveTo(13.5, 10); c.lineTo(13.5, 13.5); c.lineTo(10, 13.5); c.moveTo(6, 13.5); c.lineTo(2.5, 13.5); c.lineTo(2.5, 10); c.stroke(); return
        case "chip": c.rect(4, 4, 8, 8); c.moveTo(6.5, 1.8); c.lineTo(6.5, 4); c.moveTo(9.5, 1.8); c.lineTo(9.5, 4)
                     c.moveTo(6.5, 12); c.lineTo(6.5, 14.2); c.moveTo(9.5, 12); c.lineTo(9.5, 14.2)
                     c.moveTo(1.8, 6.5); c.lineTo(4, 6.5); c.moveTo(1.8, 9.5); c.lineTo(4, 9.5)
                     c.moveTo(12, 6.5); c.lineTo(14.2, 6.5); c.moveTo(12, 9.5); c.lineTo(14.2, 9.5); c.stroke(); return
        case "upload": c.moveTo(8, 11); c.lineTo(8, 2.5); c.moveTo(4.5, 6); c.lineTo(8, 2.5); c.lineTo(11.5, 6)
                       c.moveTo(2.5, 11.5); c.lineTo(2.5, 13.5); c.lineTo(13.5, 13.5); c.lineTo(13.5, 11.5); c.stroke(); return
        case "rect": c.rect(2.5, 4, 11, 8); c.stroke(); return
        case "ellipse": c.arc(8, 8, 5.5, 0, 6.3); c.stroke(); return
        case "text": c.moveTo(3, 4); c.lineTo(13, 4); c.moveTo(8, 4); c.lineTo(8, 13); c.moveTo(6, 13); c.lineTo(10, 13); c.stroke(); return
        case "gear": c.arc(8, 8, 2.4, 0, 6.3)
                     for (let i = 0; i < 8; ++i) { const a = i * Math.PI / 4; c.moveTo(8 + Math.cos(a) * 4.6, 8 + Math.sin(a) * 4.6); c.lineTo(8 + Math.cos(a) * 6.4, 8 + Math.sin(a) * 6.4) }
                     c.moveTo(12.6, 8); c.arc(8, 8, 4.6, 0, 6.3); c.stroke(); return
        case "arrange": c.rect(1.5, 2.5, 4.5, 3.5); c.rect(10, 2.5, 4.5, 3.5); c.rect(5.75, 10, 4.5, 3.5)
                        c.moveTo(6, 4.25); c.lineTo(10, 4.25); c.moveTo(3.75, 6); c.lineTo(3.75, 8); c.lineTo(8, 8); c.lineTo(8, 10)
                        c.moveTo(12.25, 6); c.lineTo(12.25, 8); c.lineTo(8, 8); c.stroke(); return
        case "menu": c.moveTo(2.5, 4); c.lineTo(13.5, 4); c.moveTo(2.5, 8); c.lineTo(13.5, 8); c.moveTo(2.5, 12); c.lineTo(13.5, 12); c.stroke(); return
        case "copy": c.rect(5.5, 5.5, 8, 8)                                       // two sheets, one behind the other
                     c.moveTo(3.5, 10.5); c.lineTo(2.5, 10.5); c.lineTo(2.5, 2.5); c.lineTo(10.5, 2.5); c.lineTo(10.5, 3.5); c.stroke(); return
        case "cut": c.moveTo(11.2, 2.5); c.lineTo(5, 9.6); c.moveTo(4.8, 2.5); c.lineTo(11, 9.6)       // scissors: two blades, two rings
                    c.moveTo(6.9, 11.5); c.arc(4.8, 11.5, 2.1, 0, 6.3); c.moveTo(13.1, 11.5); c.arc(11, 11.5, 2.1, 0, 6.3); c.stroke(); return
        case "paste": c.moveTo(6, 3.2); c.lineTo(3.5, 3.2); c.lineTo(3.5, 14); c.lineTo(12.5, 14); c.lineTo(12.5, 3.2); c.lineTo(10, 3.2)   // a clipboard
                      c.rect(6, 1.8, 4, 2.8); c.moveTo(5.8, 8); c.lineTo(10.2, 8); c.moveTo(5.8, 10.8); c.lineTo(10.2, 10.8); c.stroke(); return
        case "chevup": c.moveTo(3.5, 10.5); c.lineTo(8, 6); c.lineTo(12.5, 10.5); c.stroke(); return
        case "chevdown": c.moveTo(3.5, 5.5); c.lineTo(8, 10); c.lineTo(12.5, 5.5); c.stroke(); return
        case "sparkle": c.moveTo(7, 2.5); c.lineTo(8.4, 6.6); c.lineTo(12.5, 8); c.lineTo(8.4, 9.4); c.lineTo(7, 13.5); c.lineTo(5.6, 9.4); c.lineTo(1.5, 8); c.lineTo(5.6, 6.6); c.closePath()
                        c.moveTo(12.6, 2.2); c.lineTo(12.6, 5); c.moveTo(11.2, 3.6); c.lineTo(14, 3.6); c.stroke(); return
        case "help": c.arc(8, 8, 6, 0, 6.3); c.stroke(); c.beginPath()
                     c.moveTo(6.1, 6.3); c.bezierCurveTo(6.1, 3.9, 9.9, 3.9, 9.9, 6.2); c.bezierCurveTo(9.9, 7.8, 8, 7.7, 8, 9.4); c.stroke()
                     c.beginPath(); c.arc(8, 11.5, 0.5, 0, 6.3); c.fill(); return
        case "trash": c.moveTo(3, 4.5); c.lineTo(13, 4.5); c.moveTo(6, 4.5); c.lineTo(6, 2.8); c.lineTo(10, 2.8); c.lineTo(10, 4.5)
                      c.moveTo(4.2, 4.5); c.lineTo(4.8, 13.5); c.lineTo(11.2, 13.5); c.lineTo(11.8, 4.5); c.stroke(); return
        }
    }
}
