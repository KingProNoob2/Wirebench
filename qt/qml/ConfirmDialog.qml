import QtQuick
import QtQuick.Controls
import Wirebench

// A question with up to three answers. `answered(id)` says which button was pressed; closing it any other way answers "cancel".
Popup {
    id: dialog
    property string heading: ""
    property string message: ""
    // [{id, label, role}] with role "accent", "danger" or "" ; the last one with id "cancel" is also what Esc means.
    property var buttons: []
    signal answered(string id)
    property bool done: false
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 420
    padding: 0
    closePolicy: Popup.CloseOnEscape
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
        NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 240; easing.type: Easing.OutCubic } } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 140; easing.type: Easing.InCubic } }
    onAboutToShow: done = false
    onClosed: if (!done) { done = true; answered("cancel") }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.4) }
    background: SmoothRect { radius: 14; color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.panelStroke }

    // The column pads its children on the left, so a child placed by an absolute x has to allow for that padding as well
    // as for the margin it wants on the right.
    Column {
        width: parent.width
        padding: 20
        spacing: 12
        Text { text: dialog.heading; color: AppTheme.text; font.pixelSize: 15; font.weight: Font.Bold; width: dialog.width - 40; wrapMode: Text.WordWrap }
        Text { visible: dialog.message !== ""; text: dialog.message; color: AppTheme.dim; font.pixelSize: 13; width: dialog.width - 40; wrapMode: Text.WordWrap }
        Row {
            // Without the left padding in this sum the buttons ended flush with the dialog's edge, and the accent one was
            // clipped by its curve.
            x: dialog.width - parent.leftPadding - width - 20
            spacing: 8
            Repeater {
                model: dialog.buttons
                delegate: IconButton {
                    required property var modelData
                    label: modelData.label
                    accented: modelData.role === "accent"
                    onClicked: { dialog.done = true; dialog.close(); dialog.answered(modelData.id) }
                }
            }
        }
    }
}
