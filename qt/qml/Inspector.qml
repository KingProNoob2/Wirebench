import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wirebench

// The inspector: what the selected block is, its signals (click a boolean input to flip it, type over a number),
// its parameters, and where it runs.
Panel {
    id: panel
    readonly property var info: controller.inspector
    readonly property bool has: info.id !== undefined

    // A number the user can type over; the block's own value shows again whenever the field is not being edited.
    component NumberField: Rectangle {
        id: field
        property string shown: ""
        signal committed(string text)
        implicitWidth: 72; implicitHeight: 26
        radius: 7
        color: AppTheme.field
        border.width: input.activeFocus ? 2 : 0
        border.color: AppTheme.accent
        TextInput {
            id: input
            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignRight
            color: AppTheme.text
            font.pixelSize: 12
            font.family: "monospace"
            selectByMouse: true
            text: field.shown
            onTextEdited: field.committed(text)
        }
        onShownChanged: if (!input.activeFocus) input.text = shown
    }

    component Section: Text {
        Layout.topMargin: 14
        color: AppTheme.faint; font.pixelSize: 11; font.weight: Font.Bold; font.letterSpacing: 0.8
    }

    component SignalRow: RowLayout {
        id: row
        required property int index
        property string side: "in"
        property var rows: []
        // The row's data is read by index, so a step of the simulation updates its values and does not rebuild the row.
        readonly property var modelData: rows[index] || ({label: "", value: "", high: false, kind: "text"})
        Layout.fillWidth: true
        spacing: 8
        Rectangle {
            width: 10; height: 10; radius: 5
            color: row.modelData.high ? AppTheme.live : "transparent"
            border.width: 2
            border.color: row.modelData.high ? AppTheme.live : AppTheme.wireIdle
            MouseArea {
                anchors.fill: parent; anchors.margins: -5
                enabled: row.side === "in" && row.modelData.kind === "toggle"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: controller.command({cmd: "toggleInput", module: panel.info.id, pin: row.index})
            }
        }
        Text { text: row.modelData.label; Layout.fillWidth: true; elide: Text.ElideRight; color: AppTheme.text; font.pixelSize: 12 }
        Loader {
            sourceComponent: row.modelData.kind === "int" ? numberEditor : valueText
            Component { id: valueText
                Text { text: row.modelData.value; color: AppTheme.dim; font.family: "monospace"; font.pixelSize: 12 } }
            Component {
                id: numberEditor
                NumberField {
                    shown: row.modelData.value
                    onCommitted: text => {
                        const v = parseInt(text)
                        if (isNaN(v)) return
                        if (row.side === "in") controller.command({cmd: "setInputInt", module: panel.info.id, pin: row.index, value: v})
                        else if (row.side === "param") controller.command({cmd: "setParam", module: panel.info.id, pin: row.index, text: text})
                        else controller.command({cmd: "setVariable", module: panel.info.id, value: v})
                    }
                }
            }
        }
    }

    Column {
        visible: !panel.has
        anchors.centerIn: parent
        spacing: 6
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "No selection"; color: AppTheme.text; font.pixelSize: 14; font.weight: Font.Bold }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Select a block to inspect it."; color: AppTheme.faint; font.pixelSize: 12 }
    }

    ScrollView {
        visible: panel.has
        anchors { fill: parent; margins: 16 }
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: parent.width
            spacing: 7
            RowLayout {
                spacing: 10
                Rectangle {
                    width: 34; height: 34; radius: 10
                    readonly property color tint: AppTheme.categoryColor(panel.info.category || "")
                    color: Qt.rgba(tint.r, tint.g, tint.b, 0.2)
                    Text { anchors.centerIn: parent; text: (panel.info.type || "?").substring(0, 1).toUpperCase(); color: parent.tint; font.pixelSize: 16; font.weight: Font.Bold }
                }
                ColumnLayout {
                    spacing: 0
                    Text { text: panel.info.name || ""; font.pixelSize: 16; font.weight: Font.Bold; color: AppTheme.text }
                    Text { text: (panel.info.type || "") + "  ·  " + (panel.info.category || "").replace("Main\\", ""); color: AppTheme.faint; font.pixelSize: 11 }
                }
            }
            Text { text: panel.info.summary || ""; wrapMode: Text.WordWrap; Layout.fillWidth: true; color: AppTheme.dim; font.pixelSize: 12 }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    IconButton { label: "Configure…"; onClicked: configDialog.openFor(panel.info.id) }
                    IconButton { icon: "help"; label: "Help"; onClicked: helpWindow.showBlock(panel.info.id) }
                    IconButton { icon: "reset"; label: "Reset"; onClicked: controller.command({cmd: "resetState", module: panel.info.id}) }
                }
                RowLayout {
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        color: panel.info.simulated ? AppTheme.live : AppTheme.faint
                    }
                    Text { text: panel.info.simulated ? "Simulated" : "Not simulated"; color: AppTheme.faint; font.pixelSize: 11 }
                }
            }

            Section { text: "INPUTS"; visible: (panel.info.inputs || []).length > 0 }
            Repeater { model: (panel.info.inputs || []).length; delegate: SignalRow { side: "in"; rows: panel.info.inputs || [] } }
            Section { text: "OUTPUTS"; visible: (panel.info.outputs || []).length > 0 }
            Repeater { model: (panel.info.outputs || []).length; delegate: SignalRow { side: "out"; rows: panel.info.outputs || [] } }
            Section { text: "PARAMETERS"; visible: (panel.info.params || []).length > 0 }
            Repeater { model: (panel.info.params || []).length; delegate: SignalRow { side: "param"; rows: panel.info.params || [] } }

            Section { text: "DETAILS" }
            GridLayout {
                columns: 2; columnSpacing: 12; rowSpacing: 6
                Layout.fillWidth: true
                Text { text: "Class"; color: AppTheme.faint; font.pixelSize: 12 }
                Text { text: panel.info.className || ""; color: AppTheme.text; font.pixelSize: 12 }
                Text { text: "Module ID"; color: AppTheme.faint; font.pixelSize: 12 }
                Text { text: panel.has ? panel.info.id : ""; color: AppTheme.text; font.pixelSize: 12 }
                Text { text: "Execution order"; color: AppTheme.faint; font.pixelSize: 12 }
                NumberField { shown: String(panel.info.order); onCommitted: t => { const v = parseInt(t); if (!isNaN(v)) controller.command({cmd: "setOrder", module: panel.info.id, value: v}) } }
                Text { text: "Thread"; color: AppTheme.faint; font.pixelSize: 12 }
                NumberField { shown: String(panel.info.thread); onCommitted: t => { const v = parseInt(t); if (!isNaN(v)) controller.command({cmd: "setThread", module: panel.info.id, value: v}) } }
                Text { text: "Page"; color: AppTheme.faint; font.pixelSize: 12 }
                Text { text: panel.info.page || ""; color: AppTheme.text; font.pixelSize: 12 }
                Text { text: "Position"; color: AppTheme.faint; font.pixelSize: 12 }
                Text { text: "(" + Math.round(panel.info.x || 0) + ", " + Math.round(panel.info.y || 0) + ")"; color: AppTheme.text; font.pixelSize: 12 }
            }
        }
    }
}
