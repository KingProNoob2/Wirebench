import QtQuick
import QtQuick.Controls
import Wirebench

// Asks for a line of text: a name for a block, a page or a macro.
Popup {
    id: prompt
    property string heading: ""
    property string accept: "OK"
    property alias text: input.text
    signal accepted2(string text)
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 380
    padding: 0
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 240; easing.type: Easing.OutCubic } } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 140; easing.type: Easing.InCubic } }
    onOpened: { input.forceActiveFocus(); input.selectAll() }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.35) }
    background: SmoothRect { radius: 14; color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.panelStroke }

    Column {
        width: parent.width
        padding: 18
        spacing: 12
        Text { text: prompt.heading; color: AppTheme.text; font.pixelSize: 15; font.weight: Font.Bold }
        Rectangle {
            width: prompt.width - 36; height: 36; radius: 9; color: AppTheme.field
            border.width: input.activeFocus ? 2 : 0; border.color: AppTheme.accent
            TextInput {
                id: input
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                verticalAlignment: Text.AlignVCenter
                color: AppTheme.text; font.pixelSize: 13; selectByMouse: true; clip: true
                onAccepted: { prompt.close(); prompt.accepted2(text) }
            }
        }
        Row {
            x: prompt.width - width - 18
            spacing: 8
            IconButton { label: "Cancel"; onClicked: prompt.close() }
            IconButton { label: prompt.accept; accented: true; onClicked: { prompt.close(); prompt.accepted2(input.text) } }
        }
    }
}
