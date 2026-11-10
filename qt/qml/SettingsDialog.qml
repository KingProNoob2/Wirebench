import QtQuick
import QtQuick.Controls
import Wirebench

// Preferences: appearance, how the sheet behaves, and whether builds are optimised. The model remembers them.
Popup {
    id: dialog
    readonly property var s: controller.settings
    // The same motion as the panels, without the blur (a popup has no snapshot of its contents): a fade with a slight grow.
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 260; easing.type: Easing.OutCubic } } }
    exit: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InCubic }
        NumberAnimation { property: "scale"; from: 1; to: 0.97; duration: 160; easing.type: Easing.InCubic } } }
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 420
    padding: 0
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.4) }
    background: Rectangle { radius: 14; color: AppTheme.card; border.color: AppTheme.panelStroke }

    component Toggle: Item {
        id: row
        property string label
        property string hint
        property bool checked
        signal toggled(bool value)
        width: parent.width; height: hint !== "" ? 50 : 34
        Column {
            anchors { left: parent.left; right: sw.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
            Text { text: row.label; color: AppTheme.text; font.pixelSize: 13 }
            Text { visible: row.hint !== ""; text: row.hint; color: AppTheme.faint; font.pixelSize: 11; width: parent.width; wrapMode: Text.WordWrap }
        }
        Rectangle {
            id: sw
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            width: 40; height: 22; radius: 11
            color: row.checked ? AppTheme.accent : AppTheme.field
            Rectangle { x: row.checked ? 20 : 2; y: 2; width: 18; height: 18; radius: 9; color: "white"
                        Behavior on x { NumberAnimation { duration: 110 } } }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.toggled(!row.checked) }
        }
    }

    // Taller than the window: the form scrolls instead of running off the screen.
    height: Math.min(form.implicitHeight, (Overlay.overlay ? Overlay.overlay.height : 800) - 60)
    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: form.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    Column {
        id: form
        width: parent.width
        padding: 20
        spacing: 10

        Text { text: "Settings"; color: AppTheme.text; font.pixelSize: 16; font.weight: Font.Bold }

        Text { text: "APPEARANCE"; color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; topPadding: 6 }
        Row {
            spacing: 4
            Repeater {
                model: [["system", "System"], ["light", "Light"], ["dark", "Dark"]]
                delegate: IconButton {
                    required property var modelData
                    label: modelData[1]
                    active: (dialog.s.appearance || "system") === modelData[0]
                    onClicked: controller.command({cmd: "setSetting", key: "appearance", value: modelData[0]})
                }
            }
        }

        Text { text: "PANELS"; color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; topPadding: 10 }
        Column {
            width: dialog.width - 40
            Toggle { label: "Frosted glass"; hint: gpuRendering ? "Blur the sheet behind the panels. Off: solid grey panels, which are also lighter to draw."
                                                                : "Needs the GPU renderer, which is not in use."
                     checked: controller.blurEnabled; enabled: gpuRendering; opacity: gpuRendering ? 1 : 0.5
                     onToggled: v => controller.blurEnabled = v }
            // Blur depth: how strongly the sheet is blurred behind a panel.
            Item {
                width: parent.width; height: 44
                opacity: controller.blurEnabled && gpuRendering ? 1 : 0.4
                Text { id: depthLabel; text: "Blur radius"; color: AppTheme.text; font.pixelSize: 13; anchors { left: parent.left; verticalCenter: parent.verticalCenter } }
                Text { text: Math.round(AppTheme.blurSigma(controller.blurDepth)) + " px"; color: AppTheme.faint; font.pixelSize: 11
                       anchors { right: parent.right; verticalCenter: parent.verticalCenter } }
                Rectangle {
                    id: track
                    anchors { left: depthLabel.right; right: parent.right; leftMargin: 18; rightMargin: 46; verticalCenter: parent.verticalCenter }
                    height: 4; radius: 2; color: AppTheme.field
                    Rectangle { width: handle.x + handle.width / 2; height: parent.height; radius: 2; color: AppTheme.accent }
                    Rectangle {
                        id: handle
                        width: 16; height: 16; radius: 8; color: "white"; border.width: 1; border.color: AppTheme.panelStroke
                        anchors.verticalCenter: parent.verticalCenter
                        x: controller.blurDepth * (track.width - width)
                    }
                    MouseArea {
                        anchors { fill: parent; topMargin: -12; bottomMargin: -12 }
                        enabled: controller.blurEnabled && gpuRendering
                        cursorShape: Qt.PointingHandCursor
                        function set(mouseX) { controller.blurDepth = Math.max(0, Math.min(1, (mouseX - handle.width / 2) / (track.width - handle.width))) }
                        onPressed: mouse => set(mouse.x)
                        onPositionChanged: mouse => set(mouse.x)
                    }
                }
            }
        }

        Text { text: "SHEET"; color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; topPadding: 10 }
        Column {
            width: dialog.width - 40
            Toggle { label: "Snap to grid"; hint: "Blocks and shapes land on the grid when moved."
                     checked: !!dialog.s.snapToGrid; onToggled: v => controller.command({cmd: "setSetting", key: "snapToGrid", value: v}) }
            Toggle { label: "Scroll wheel zooms"; hint: "Off: the wheel pans, and Ctrl+wheel zooms."
                     checked: !!dialog.s.scrollZooms; onToggled: v => controller.command({cmd: "setSetting", key: "scrollZooms", value: v}) }
        }

        Column {
            width: dialog.width - 40
            Toggle { label: "Roomier blocks"; hint: "More space between a block's pins. Wires follow; blocks get taller."
                     checked: (dialog.s.pinPitch || 16) > 18; onToggled: v => controller.setPinPitch(v ? 20 : 16) }
        }

        Text { text: "BUILD"; color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; topPadding: 10 }
        Column {
            width: dialog.width - 40
            Toggle { label: "Optimise the program"; hint: "Records in dataflow order; unread or switched-off logic is dropped."
                     checked: !!dialog.s.optimize; onToggled: v => controller.command({cmd: "setSetting", key: "optimize", value: v}) }
        }

        Item { width: 1; height: 4 }
        IconButton { anchors.right: parent.right; anchors.rightMargin: 20; label: "Done"; accented: true; onClicked: dialog.close() }
        Item { width: 1; height: 4 }
    }
    }
}
