import QtQuick
import QtQuick.Controls
import Wirebench

// The hamburger menu: everything that is not needed on every click, so the top bar can stay short. Each row has an icon, a name and
// its shortcut; a thin line separates the groups. `activated(id)` says which was chosen.
Popup {
    id: menu
    signal activated(string id)
    padding: 6
    width: 290
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    // When it last began to close. A press on the button that opened it closes it (press outside), and the click that follows must not open it again.
    property real closedAt: 0
    onAboutToHide: closedAt = Date.now()

    property var entries: [
        {section: "File"},
        {id: "new", icon: "open", label: "New Project", hint: "Ctrl+N"},
        {id: "open", icon: "open", label: "Open…", hint: "Ctrl+O"},
        {id: "save", icon: "save", label: "Save", hint: "Ctrl+S"},
        {id: "saveAs", icon: "save", label: "Save As…", hint: "Ctrl+Shift+S"},
        {id: "exportPcc", icon: "upload", label: "Export Legacy .PCC…", hint: "Ctrl+Shift+E"},
        {section: "Insert"},
        {id: "rect", icon: "rect", label: "Rectangle", hint: "Meta+Ctrl+R"},
        {id: "ellipse", icon: "ellipse", label: "Ellipse", hint: "Meta+Ctrl+C"},
        {id: "text", icon: "text", label: "Text", hint: "Ctrl+Shift+T"},
        {section: "Sheet"},
        {id: "arrange", icon: "arrange", label: "Auto-arrange", hint: "Ctrl+Shift+L"},
        {id: "resetWires", icon: "reset", label: "Reset Wire Routing", hint: "Ctrl+Shift+R"},
        {section: "Project"},
        {id: "build", icon: "chip", label: "Build…", hint: "Ctrl+B"},
        {id: "plc", icon: "upload", label: "PLC…", hint: "Ctrl+Shift+U"},
        {id: "plcConfig", icon: "chip", label: "PLC Configuration…", hint: "Ctrl+Alt+K"},
        {id: "agent", icon: "sparkle", label: "Agent Panel", hint: "Ctrl+Shift+A"},
        {id: "help", icon: "help", label: "Block Reference", hint: "F1"},
        {id: "settings", icon: "gear", label: "Settings…", hint: "Ctrl+,"}
    ]

    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 100; easing.type: Easing.InCubic } }

    background: Item {
        Rectangle { x: 0; y: 4; width: parent.width; height: parent.height; radius: 12; color: AppTheme.shadow; opacity: 0.45 }
        Rectangle { x: 0; y: 10; width: parent.width; height: parent.height; radius: 14; color: AppTheme.shadow; opacity: 0.18 }
        SmoothRect { anchors.fill: parent; radius: 12; color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.panelStroke }
    }

    contentItem: Column {
        spacing: 1
        Repeater {
            model: menu.entries
            delegate: Item {
                id: row
                required property var modelData
                // Off when the entry says so, and the agent's with no project open: it works on the project.
                readonly property bool off: modelData.disabled === true || ((modelData.id === "agent" || modelData.id === "plcConfig") && !controller.hasProject)
                width: menu.availableWidth
                height: modelData.section !== undefined ? 26 : 34
                Text {
                    visible: row.modelData.section !== undefined
                    x: 10; anchors.bottom: parent.bottom; anchors.bottomMargin: 3
                    text: (row.modelData.section || "").toUpperCase()
                    color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8
                }
                Rectangle {
                    visible: row.modelData.id !== undefined
                    anchors.fill: parent; radius: 8
                    opacity: row.off ? 0.4 : 1
                    color: area.pressed && !row.off ? AppTheme.press : (area.containsMouse && !row.off ? AppTheme.hover : "transparent")
                    Icon { x: 10; anchors.verticalCenter: parent.verticalCenter; name: row.modelData.icon || ""; color: AppTheme.text; size: 16 }
                    Text { x: 38; anchors.verticalCenter: parent.verticalCenter; text: row.modelData.label || ""; color: AppTheme.text; font.pixelSize: 13 }
                    Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                           text: row.modelData.hint || ""; color: AppTheme.faint; font.pixelSize: 11 }
                    MouseArea {
                        id: area
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (!row.off) { menu.close(); menu.activated(row.modelData.id) }
                    }
                }
            }
        }
    }
}
