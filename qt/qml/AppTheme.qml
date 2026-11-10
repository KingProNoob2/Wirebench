pragma Singleton
import QtQuick

// The app's look, following the system's light/dark choice. Panels float over the sheet; blocks and grid stay clearly
// off the page in light mode.
QtObject {
    readonly property string appearance: controller.settings.appearance || "system"
    readonly property bool dark: forceLight ? false
        : appearance === "dark" ? true
        : appearance === "light" ? false
        : Qt.styleHints.colorScheme !== Qt.ColorScheme.Light

    readonly property color window: dark ? "#16171a" : "#e6e7eb"
    readonly property color panel: dark ? Qt.rgba(0.14, 0.145, 0.165, 1) : Qt.rgba(0.97, 0.97, 0.975, 1)
    // The same surface over a blurred backdrop: translucent, so the sheet shows through softly.
    readonly property color panelGlass: dark ? Qt.rgba(0.12, 0.125, 0.145, 0.55) : Qt.rgba(0.985, 0.985, 0.99, 0.6)
    readonly property color panelStroke: dark ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.12)
    readonly property color field: dark ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(0, 0, 0, 0.055)
    readonly property color hover: dark ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.07)
    readonly property color press: dark ? Qt.rgba(1, 1, 1, 0.15) : Qt.rgba(0, 0, 0, 0.12)

    readonly property color card: dark ? "#24262b" : "#ffffff"
    readonly property color cardStroke: dark ? "#3a3c43" : "#a4a6ae"
    readonly property color text: dark ? "#eceef2" : "#17181c"
    readonly property color dim: dark ? "#9b9ea8" : "#5f626c"
    readonly property color faint: dark ? "#6c6f79" : "#8b8e98"

    readonly property color accent: "#4c8dff"
    readonly property color live: "#2fd573"
    readonly property color danger: "#ff5d55"
    readonly property color selection: accent
    readonly property color wireIdle: dark ? "#6e717b" : "#80838d"

    readonly property color dot: dark ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.16)
    readonly property color dotMajor: dark ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(0, 0, 0, 0.30)
    readonly property color shadow: Qt.rgba(0, 0, 0, dark ? 0.45 : 0.22)

    // The blur's standard deviation in pixels for a slider position t in 0...1. Exponential, 4 px to 64 px: what the eye reads as
    // "twice as blurry" is a doubling of the radius, not an equal step in pixels, so equal slider steps give equal-looking steps.
    function blurSigma(t) { return 4 * Math.pow(16, Math.max(0, Math.min(1, t))) }

    // A category's colour: a hue from its name, so a family of blocks reads as one at a glance.
    function categoryColor(name) {
        let h = 7
        for (let i = 0; i < name.length; ++i) h = (h * 31 + name.charCodeAt(i)) % 360
        return Qt.hsla(h / 360, 0.62, dark ? 0.62 : 0.46, 1)
    }
}
