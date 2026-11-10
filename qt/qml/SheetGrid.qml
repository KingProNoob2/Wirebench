import QtQuick
import Wirebench

// The drafting grid: dots at the intersections, every tenth stronger (twice as many dots across as the 32 px sheet grid, so the strong ones keep their spacing). On the GPU a shader works each pixel out (nothing is
// drawn on the CPU as the sheet pans); the software renderer, which has no shaders, draws them on a canvas.
Item {
    id: grid
    property real zoom: 1
    property real panX: 0
    property real panY: 0

    // Doubled or halved to stay in a legible band, as the SwiftUI canvas does: 16 px at 100%, so twice as many dots across as before.
    readonly property real pitch: {
        let value = 16 * Math.max(0.1, zoom)
        while (value < 7) value *= 2
        while (value > 28) value /= 2
        return value
    }

    ShaderEffect {
        visible: gpuRendering
        anchors.fill: parent
        property vector2d size: Qt.vector2d(width, height)
        property vector2d pan: Qt.vector2d(grid.panX, grid.panY)
        property real pitch: grid.pitch
        property real majorEvery: 10
        property real minorRadius: 1.2
        property real majorRadius: 1.8
        // As plain vectors, not `color`s: Qt hands a `color` to a shader already multiplied by its alpha, and the shader multiplies by it
        // again, which dimmed light dots to almost nothing and made faint ones darker than the sheet.
        property vector4d minorColor: Qt.vector4d(AppTheme.dot.r, AppTheme.dot.g, AppTheme.dot.b, AppTheme.dot.a)
        property vector4d majorColor: Qt.vector4d(AppTheme.dotMajor.r, AppTheme.dotMajor.g, AppTheme.dotMajor.b, AppTheme.dotMajor.a)
        fragmentShader: "qrc:/shaders/grid.frag.qsb"
    }

    Canvas {
        id: canvas
        visible: !gpuRendering
        anchors.fill: parent
        onPaint: {
            const c = getContext("2d")
            c.clearRect(0, 0, width, height)
            const i0 = Math.floor(-grid.panX / grid.pitch), i1 = Math.ceil((width - grid.panX) / grid.pitch)
            const j0 = Math.floor(-grid.panY / grid.pitch), j1 = Math.ceil((height - grid.panY) / grid.pitch)
            for (const major of [false, true]) {
                c.fillStyle = major ? AppTheme.dotMajor : AppTheme.dot
                const r = major ? 1.8 : 1.2
                c.beginPath()
                for (let j = j0; j <= j1; ++j)
                    for (let i = i0; i <= i1; ++i) {
                        if ((i % 10 === 0 && j % 10 === 0) !== major) continue
                        const x = grid.panX + i * grid.pitch, y = grid.panY + j * grid.pitch
                        c.moveTo(x + r, y)
                        c.arc(x, y, r, 0, Math.PI * 2)
                    }
                c.fill()
            }
        }
        Connections {
            target: grid
            function onPanXChanged() { if (!gpuRendering) canvas.requestPaint() }
            function onPanYChanged() { if (!gpuRendering) canvas.requestPaint() }
            function onZoomChanged() { if (!gpuRendering) canvas.requestPaint() }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
