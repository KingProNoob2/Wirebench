import QtQuick
import Wirebench

// A floating surface: rounded, hairline border, soft shadow. With the GPU renderer and the setting on, it is frosted glass: a
// window onto the Gaussian-blurred sheet (`backdrop`, from Main.qml) under the panel's tint. Otherwise it is solid grey.
Item {
    id: panel
    property real radius: 14
    property Item backdrop: null
    default property alias content: inner.data
    readonly property bool glass: backdrop !== null && gpuRendering && controller.blurEnabled

    // Opening and closing: the panel fades, and (on the GPU) its own contents start out blurred and sharpen, or blur away as it
    // closes. `progress` runs 0 (gone) to 1 (shown).
    property bool shown: true
    property real progress: shown ? 1 : 0
    Behavior on progress { NumberAnimation { duration: panel.shown ? 340 : 260; easing.type: Easing.InOutCubic } }
    readonly property bool animating: progress > 0.001 && progress < 0.999
    readonly property bool blurAnimation: animating && gpuRendering
    readonly property real motionSigma: 22 * (1 - progress)                      // pixels, at its largest as the panel appears or goes
    readonly property real motionPad: 48                                       // room the blur spreads into around the panel

    visible: progress > 0.001
    opacity: progress

    Item {
        id: visual
        anchors.fill: parent
        // A soft shadow from layered translucent rectangles.
        Rectangle { x: 0; y: 3; width: parent.width; height: parent.height; radius: panel.radius; color: AppTheme.shadow; opacity: 0.5 }
        Rectangle { x: 0; y: 8; width: parent.width; height: parent.height; radius: panel.radius; color: AppTheme.shadow; opacity: 0.22 }
        Rectangle { x: 0; y: 14; width: parent.width; height: parent.height; radius: panel.radius + 4; color: AppTheme.shadow; opacity: 0.08 }

        // The solid panel.
        SmoothRect { visible: !panel.glass; anchors.fill: parent; radius: panel.radius; color: AppTheme.panel }

        // The glass: the blurred sheet behind the panel, tinted and cut to the panel's shape, all in one shader.
        ShaderEffect {
            visible: panel.glass
            anchors.fill: parent
            property variant source: panel.glass ? panel.backdrop : null
            property vector4d region: panel.backdrop
                ? Qt.vector4d(panel.x / panel.backdrop.width, panel.y / panel.backdrop.height,
                              panel.width / panel.backdrop.width, panel.height / panel.backdrop.height)
                : Qt.vector4d(0, 0, 1, 1)
            property vector2d size: Qt.vector2d(width, height)
            property real radius: panel.radius
            property color tint: AppTheme.panelGlass
            property color backdropColor: AppTheme.window
            property real saturation: 1.25
            property real brightness: AppTheme.dark ? -0.02 : 0.02
            fragmentShader: "qrc:/shaders/glass.frag.qsb"
        }

        SmoothRect {
            anchors.fill: parent
            radius: panel.radius
            borderWidth: 1
            borderColor: AppTheme.panelStroke
        }

        // A panel is solid to the mouse: a wheel turn or click that its contents do not use must not reach the sheet below (where it
        // would zoom, or clear the selection).
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: wheel => wheel.accepted = true
        }
        Item { id: inner; anchors.fill: parent }

    }

    // While it moves, the panel is drawn through a Gaussian blur instead of directly: its picture, blurred along x then along y.
    ShaderEffectSource {
        id: motionSnapshot
        x: -panel.motionPad; y: -panel.motionPad
        width: panel.width + 2 * panel.motionPad; height: panel.height + 2 * panel.motionPad
        visible: panel.blurAnimation
        opacity: 0.001
        sourceItem: visual
        sourceRect: Qt.rect(-panel.motionPad, -panel.motionPad, width, height)
        hideSource: panel.blurAnimation
        textureSize: Qt.size(width, height)
        live: true
    }
    ShaderEffect {
        id: motionHorizontal
        x: -panel.motionPad; y: -panel.motionPad
        width: panel.width + 2 * panel.motionPad; height: panel.height + 2 * panel.motionPad
        visible: panel.blurAnimation
        property variant source: motionSnapshot
        property vector2d texel: Qt.vector2d(1 / width, 0)
        property real sigma: panel.motionSigma
        fragmentShader: "qrc:/shaders/gauss.frag.qsb"
    }
    ShaderEffectSource {
        id: motionHorizontalSnapshot
        x: -panel.motionPad; y: -panel.motionPad
        width: motionHorizontal.width; height: motionHorizontal.height
        visible: panel.blurAnimation
        opacity: 0.001
        sourceItem: motionHorizontal
        hideSource: true
        textureSize: Qt.size(width, height)
        live: true
    }
    ShaderEffect {
        x: -panel.motionPad; y: -panel.motionPad
        width: motionHorizontal.width; height: motionHorizontal.height
        visible: panel.blurAnimation
        property variant source: motionHorizontalSnapshot
        property vector2d texel: Qt.vector2d(0, 1 / height)
        property real sigma: panel.motionSigma
        fragmentShader: "qrc:/shaders/gauss.frag.qsb"
    }
}
