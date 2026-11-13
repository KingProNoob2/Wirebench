import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wirebench

// The imported Maraflow Structured Text page, editable and written back through the bridge.
Dialog {
    id: dialog
    property string code: ""
    signal sourceApplied(string code)
    modal: true
    title: "Maraflow Structured Text"
    width: Math.min(900, parent ? parent.width - 80 : 900)
    height: Math.min(700, parent ? parent.height - 80 : 700)
    anchors.centerIn: parent
    standardButtons: Dialog.NoButton

    onOpened: editor.text = dialog.code

    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "This source runs through the native Maraflow ST interpreter."
                color: AppTheme.dim
                font.pixelSize: 12
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            TextArea {
                id: editor
                font.family: "monospace"
                font.pixelSize: 12
                wrapMode: TextArea.NoWrap
                selectByMouse: true
                color: AppTheme.text
                background: Rectangle { color: AppTheme.field; radius: 8 }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: "Cancel"; onClicked: dialog.close() }
            Button {
                text: "Apply to Page"
                highlighted: true
                onClicked: { dialog.sourceApplied(editor.text); dialog.close() }
            }
        }
    }
}
