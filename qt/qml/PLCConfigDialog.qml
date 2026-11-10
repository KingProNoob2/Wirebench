import QtQuick
import QtQuick.Controls
import Wirebench

// The PLC configuration: the commands the PLC is sent when the program runs, with what each is and presets for its parameters. In Dirigo they are
// `SystemCmd` blocks on a sheet; here they are a list in the project, and Export Legacy .PCC writes them back as blocks. The Swift model holds the
// state (`PLCConfiguration`); this reads it with `plcConfig` and changes it with `plcAdd`, `plcSetCommand`, `plcSetPar` and `plcRemove`.
Popup {
    id: dialog
    property var plc: ({commands: [], catalogue: []})
    modal: true
    anchors.centerIn: Overlay.overlay
    width: 600
    height: Math.min(680, (Overlay.overlay ? Overlay.overlay.height : 800) - 60)
    padding: 0
    closePolicy: Popup.CloseOnEscape
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.4) }
    background: Rectangle { radius: 14; color: AppTheme.card; border.color: AppTheme.panelStroke }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 140 } }

    function refresh(reply) { if (reply && reply.plc) plc = reply.plc }
    function ask(command) { refresh(controller.command(command)) }
    onAboutToShow: ask({cmd: "plcConfig"})

    // Takes what was typed as a decimal, 0x… or $…, as the SwiftUI field does.
    function parse(text) {
        const t = text.trim()
        const v = t.startsWith("$") ? parseInt(t.slice(1), 16) : (t.startsWith("0x") || t.startsWith("0X") ? parseInt(t.slice(2), 16) : parseInt(t, 10))
        return isNaN(v) ? null : v
    }
    function hex(v) { return "0x" + (v >>> 0).toString(16).toUpperCase() }

    component Parameter: Column {
        id: par
        required property var info
        required property int entry
        width: parent.width
        spacing: 5
        Row {
            spacing: 8
            width: parent.width
            Text { text: "Par" + par.info.which; color: AppTheme.faint; font.pixelSize: 11; font.weight: Font.Bold; width: 34; anchors.verticalCenter: parent.verticalCenter }
            Text { text: par.info.name + " (" + par.info.dataType + ")"; color: AppTheme.text; font.pixelSize: 13; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
        Row {
            visible: par.info.used
            spacing: 8
            leftPadding: 42
            Rectangle {
                width: 96; height: 28; radius: 7; color: AppTheme.field
                border.width: input.activeFocus ? 2 : 0; border.color: AppTheme.accent
                TextInput {
                    id: input
                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                    verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignRight
                    color: AppTheme.text; font.pixelSize: 13; font.family: "monospace"; selectByMouse: true
                    text: String(par.info.value)
                    onEditingFinished: { const v = dialog.parse(text); if (v !== null) dialog.ask({cmd: "plcSetPar", index: par.entry, which: par.info.which, value: v}); else text = String(par.info.value) }
                }
            }
            Text { text: dialog.hex(par.info.value); color: AppTheme.faint; font.pixelSize: 11; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
            IconButton {
                visible: par.info.presets.length > 0
                label: "Presets"
                onClicked: presetList.openBelow(this)
                PopupList {
                    id: presetList
                    minWidth: 300
                    labels: par.info.presets.map(p => p.label + "  (" + p.value + ")")
                    onPicked: index => dialog.ask({cmd: "plcSetPar", index: par.entry, which: par.info.which, value: par.info.presets[index].value})
                }
            }
        }
        Text {
            leftPadding: 42; width: parent.width
            text: par.info.meaning; wrapMode: Text.WordWrap
            color: par.info.used ? AppTheme.dim : AppTheme.faint; font.pixelSize: 12
        }
        // A row of pins, highest first as in Dirigo's tutorial; the serial link's cannot be changed.
        Row {
            visible: par.info.used && par.info.bits !== undefined
            leftPadding: 42; spacing: 4
            Repeater {
                model: par.info.bits ? par.info.bits.names.length : 0
                delegate: Column {
                    required property int index
                    readonly property int bit: par.info.bits.names.length - 1 - index
                    readonly property bool fixed: par.info.bits.fixed.indexOf(bit) >= 0
                    readonly property bool on: (par.info.value & (1 << bit)) !== 0
                    spacing: 2
                    Text { text: bit; color: AppTheme.faint; font.pixelSize: 9; font.family: "monospace"; anchors.horizontalCenter: parent.horizontalCenter }
                    Rectangle {
                        width: 30; height: 22; radius: 5
                        color: fixed ? Qt.rgba(1, 1, 1, 0.04) : (on ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.4) : AppTheme.field)
                        Text { anchors.centerIn: parent; font.pixelSize: 10; font.weight: Font.DemiBold; color: fixed ? AppTheme.faint : AppTheme.text
                               text: fixed ? (bit === 0 ? "Tx" : "Rx") : (on ? "In" : "Out") }
                        MouseArea { anchors.fill: parent; enabled: !fixed; cursorShape: Qt.PointingHandCursor
                                    onClicked: dialog.ask({cmd: "plcSetPar", index: par.entry, which: par.info.which, value: par.info.value ^ (1 << bit)}) }
                    }
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        Column {
            id: head
            x: 20; y: 18; width: parent.width - 40; spacing: 6
            Text { text: "PLC Configuration"; color: AppTheme.text; font.pixelSize: 17; font.weight: Font.Bold }
            Text { width: parent.width; wrapMode: Text.WordWrap; color: AppTheme.dim; font.pixelSize: 12
                   text: "Commands sent to the PLC's firmware. They are part of the program, run before the circuit, and are written to Dirigo as SystemCmd blocks when you export a legacy .pcc." }
        }
        Row {
            id: hardware
            visible: dialog.plc.profiles && dialog.plc.profiles.length > 0
            anchors { left: parent.left; leftMargin: 20; top: head.bottom; topMargin: 10 }
            spacing: 10
            height: visible ? 30 : 0
            Text { text: "Hardware"; color: AppTheme.dim; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            IconButton {
                label: dialog.plc.profile + "  ▾"
                onClicked: profileList.openBelow(this)
                PopupList {
                    id: profileList
                    minWidth: 240
                    labels: dialog.plc.profiles
                    onPicked: index => dialog.ask({cmd: "plcSetProfile", name: dialog.plc.profiles[index]})
                }
            }
            Text { text: "The commands on offer depend on the hardware."; color: AppTheme.faint; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
        }
        Flickable {
            anchors { left: parent.left; right: parent.right; top: hardware.visible ? hardware.bottom : head.bottom; bottom: foot.top; topMargin: 14; bottomMargin: 8 }
            contentWidth: width; contentHeight: list.implicitHeight + 24
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            Column {
                id: list
                x: 20; width: parent.width - 40; spacing: 12
                Text { visible: dialog.plc.commands.length === 0; width: parent.width; horizontalAlignment: Text.AlignHCenter; topPadding: 20; wrapMode: Text.WordWrap
                       color: AppTheme.dim; font.pixelSize: 13; text: "No commands. A new project sends the PLC none; add one to set up its pins, for example." }
                Repeater {
                    model: dialog.plc.commands
                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        width: list.width; radius: 12; color: AppTheme.field
                        height: body.implicitHeight + 28
                        Column {
                            id: body
                            x: 14; y: 14; width: parent.width - 28; spacing: 10
                            Row {
                                spacing: 10
                                width: parent.width
                                Text { text: card.modelData.title; color: AppTheme.text; font.pixelSize: 15; font.weight: Font.Bold; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: card.modelData.word; color: AppTheme.faint; font.pixelSize: 11; font.family: "monospace"; anchors.verticalCenter: parent.verticalCenter }
                                IconButton { label: "Change command"; onClicked: commandList.openBelow(this)
                                    PopupList {
                                        id: commandList
                                        minWidth: 300
                                        labels: dialog.plc.catalogue.map(c => c.title + "  ·  " + c.word)
                                        onPicked: index => dialog.ask({cmd: "plcSetCommand", index: card.modelData.index, tag: dialog.plc.catalogue[index].tag})
                                    } }
                                IconButton { label: "Remove"; onClicked: dialog.ask({cmd: "plcRemove", index: card.modelData.index}) }
                            }
                            Text { width: parent.width; text: card.modelData.summary; wrapMode: Text.WordWrap; color: AppTheme.dim; font.pixelSize: 12 }
                            Repeater {
                                model: card.modelData.params
                                delegate: Parameter { required property var modelData; info: modelData; entry: card.modelData.index }
                            }
                        }
                    }
                }
            }
        }
        Item {
            id: foot
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 56
            IconButton { x: 20; anchors.verticalCenter: parent.verticalCenter; label: "Add Command"; icon: "plus"
                         enabled: dialog.plc.catalogue.length > 0; onClicked: dialog.ask({cmd: "plcAdd"}) }
            IconButton { anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter } label: "Done"; accented: true; onClicked: dialog.close() }
        }
    }
}
