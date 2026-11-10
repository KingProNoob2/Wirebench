import QtQuick
import QtQuick.Controls
import Wirebench

// Configures one block: the fields come from the Swift model (what the block offers, and how each is written back), so
// this is only the form. Apply writes every field; Cancel changes nothing.
Popup {
    id: dialog
    property int moduleId: -1
    property var config: ({title: "", fields: []})
    property var values: ({})

    function openFor(id) {
        const reply = controller.command({cmd: "config", id: id})
        if (!reply.ok) return false
        moduleId = id
        config = reply.config
        const v = {}
        for (const f of config.fields) v[f.key] = f.value
        values = v
        open()
        return true
    }
    // Reads the block's configuration again, for edits that take effect at once (a macro's pins).
    function reload() {
        const reply = controller.command({cmd: "config", id: moduleId})
        if (!reply.ok) return
        config = reply.config
        const v = {}
        for (const f of config.fields) v[f.key] = f.value
        values = v
    }
    function setValue(key, value) { const v = Object.assign({}, values); v[key] = String(value); values = v }
    function apply() {
        controller.command({cmd: "applyConfig", id: moduleId, values: values})
        close()
    }

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

    component FieldLabel: Text { color: AppTheme.text; font.pixelSize: 13; wrapMode: Text.WordWrap }
    component Hint: Text { color: AppTheme.faint; font.pixelSize: 11; wrapMode: Text.WordWrap }

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
        spacing: 14

        Column {
            spacing: 2
            Text { text: "Configure " + dialog.config.title; color: AppTheme.text; font.pixelSize: 16; font.weight: Font.Bold }
            Text { text: "Changes apply when you press Apply."; color: AppTheme.faint; font.pixelSize: 11 }
        }

        Repeater {
            model: dialog.config.fields
            delegate: Column {
                id: field
                required property var modelData
                width: dialog.width - 40
                spacing: 6

                FieldLabel { text: field.modelData.label; width: parent.width
                             visible: field.modelData.kind !== "bool" && field.modelData.kind !== "info" && field.modelData.kind !== "link" }

                // A read-only line.
                Row {
                    visible: field.modelData.kind === "info"
                    spacing: 10
                    Text { text: field.modelData.label; color: AppTheme.faint; font.pixelSize: 12; width: 110 }
                    Text { text: field.modelData.value; color: AppTheme.text; font.pixelSize: 12; font.family: "monospace" }
                }

                // A page to open.
                IconButton {
                    visible: field.modelData.kind === "link"
                    label: field.modelData.label
                    onClicked: { controller.command({cmd: "setPage", page: field.modelData.value}); dialog.close() }
                }

                // Pin names, edited at once: Return renames, the bin removes, the plus adds.
                Column {
                    visible: field.modelData.kind === "pins"
                    width: parent.width
                    spacing: 6
                    readonly property var names: field.modelData.kind === "pins" ? JSON.parse(dialog.values[field.modelData.key] || "[]") : []
                    Repeater {
                        model: parent.names
                        delegate: Row {
                            required property var modelData
                            required property int index
                            spacing: 6
                            Rectangle {
                                width: dialog.width - 40 - 46; height: 32; radius: 8; color: AppTheme.field
                                border.width: pn.activeFocus ? 2 : 0; border.color: AppTheme.accent
                                TextInput {
                                    id: pn
                                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                    verticalAlignment: Text.AlignVCenter; color: AppTheme.text; font.pixelSize: 13; selectByMouse: true; clip: true
                                    text: modelData
                                    onAccepted: { controller.command({cmd: "interfacePin", module: dialog.moduleId, op: "rename", pin: index, name: text}); dialog.reload() }
                                }
                            }
                            IconButton { icon: "trash"; enabled: parent.parent.names.length > 1
                                         onClicked: { controller.command({cmd: "interfacePin", module: dialog.moduleId, op: "remove", pin: index}); dialog.reload() } }
                        }
                    }
                    IconButton { icon: "plus"; label: "Add pin"; onClicked: { controller.command({cmd: "interfacePin", module: dialog.moduleId, op: "add"}); dialog.reload() } }
                }

                // A number, with steppers.
                Row {
                    visible: field.modelData.kind === "int"
                    spacing: 6
                    IconButton { icon: "minus"; onClicked: dialog.setValue(field.modelData.key, Math.max(field.modelData.min, (parseInt(dialog.values[field.modelData.key]) || 0) - 1)) }
                    Rectangle {
                        width: 120; height: 32; radius: 8; color: AppTheme.field
                        border.width: num.activeFocus ? 2 : 0; border.color: AppTheme.accent
                        TextInput {
                            id: num
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                            color: AppTheme.text; font.pixelSize: 13; font.family: "monospace"; selectByMouse: true
                            text: dialog.values[field.modelData.key] ?? ""
                            onTextEdited: dialog.setValue(field.modelData.key, text)
                        }
                    }
                    IconButton { icon: "plus"; onClicked: dialog.setValue(field.modelData.key, Math.min(field.modelData.max, (parseInt(dialog.values[field.modelData.key]) || 0) + 1)) }
                }

                // Free text.
                Rectangle {
                    visible: field.modelData.kind === "text"
                    width: parent.width; height: 32; radius: 8; color: AppTheme.field
                    border.width: txt.activeFocus ? 2 : 0; border.color: AppTheme.accent
                    TextInput {
                        id: txt
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: Text.AlignVCenter
                        color: AppTheme.text; font.pixelSize: 13; selectByMouse: true; clip: true
                        text: dialog.values[field.modelData.key] ?? ""
                        onTextEdited: dialog.setValue(field.modelData.key, text)
                    }
                }

                // A switch.
                Row {
                    visible: field.modelData.kind === "bool"
                    spacing: 10
                    Rectangle {
                        width: 40; height: 22; radius: 11
                        color: dialog.values[field.modelData.key] === "1" ? AppTheme.accent : AppTheme.field
                        Rectangle {
                            x: dialog.values[field.modelData.key] === "1" ? 20 : 2; y: 2; width: 18; height: 18; radius: 9; color: "white"
                            Behavior on x { NumberAnimation { duration: 110 } }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: dialog.setValue(field.modelData.key, dialog.values[field.modelData.key] === "1" ? "0" : "1") }
                    }
                    FieldLabel { text: field.modelData.label; width: dialog.width - 40 - 50; anchors.verticalCenter: parent.verticalCenter }
                }

                // One of several.
                Column {
                    visible: field.modelData.kind === "choice"
                    width: parent.width
                    spacing: 4
                    Repeater {
                        model: field.modelData.options || []
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool chosen: dialog.values[field.modelData.key] === modelData.value
                            width: parent.width; height: 34; radius: 8
                            color: chosen ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.16) : (opt.containsMouse ? AppTheme.hover : "transparent")
                            border.width: chosen ? 1 : 0; border.color: AppTheme.accent
                            SmoothRect { x: 10; anchors.verticalCenter: parent.verticalCenter; width: 14; height: 14; radius: 7; color: "transparent"
                                        borderWidth: 2; borderColor: parent.chosen ? AppTheme.accent : AppTheme.faint
                                        SmoothRect { anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: AppTheme.accent; visible: parent.parent.chosen } }
                            Text { x: 34; anchors.verticalCenter: parent.verticalCenter; text: modelData.label; color: AppTheme.text; font.pixelSize: 13 }
                            MouseArea { id: opt; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.setValue(field.modelData.key, modelData.value) }
                        }
                    }
                }

                // A row of channels to show or hide.
                Flow {
                    visible: field.modelData.kind === "bits"
                    width: parent.width
                    spacing: 6
                    Repeater {
                        model: {
                            let n = field.modelData.bitCount || 16
                            if (field.modelData.countKey) n = Math.max(0, Math.min(n, parseInt(dialog.values[field.modelData.countKey]) || 0))
                            return n
                        }
                        delegate: Rectangle {
                            required property int index
                            readonly property bool on: (dialog.values[field.modelData.key] || "").charAt(index) === "1"
                            width: 66; height: 30; radius: 8
                            color: on ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.2) : AppTheme.field
                            border.width: on ? 1 : 0; border.color: AppTheme.accent
                            Text { anchors.centerIn: parent; text: field.modelData.prefix + index; color: on ? AppTheme.text : AppTheme.faint; font.pixelSize: 12 }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const bits = (dialog.values[field.modelData.key] || "").padEnd(16, "0").split("")
                                    bits[index] = on ? "0" : "1"
                                    dialog.setValue(field.modelData.key, bits.join(""))
                                } }
                        }
                    }
                }

                // A list of cases, each the values it matches.
                Column {
                    id: caseList
                    visible: field.modelData.kind === "cases"
                    width: parent.width
                    spacing: 6
                    property var list: field.modelData.kind === "cases" ? JSON.parse(dialog.values[field.modelData.key] || "[]") : []
                    function commit(next) { dialog.setValue(field.modelData.key, JSON.stringify(next)) }
                    Repeater {
                        model: caseList.list
                        delegate: Row {
                            required property var modelData
                            required property int index
                            spacing: 6
                            Rectangle {
                                width: caseList.width - 40; height: 32; radius: 8; color: AppTheme.field
                                border.width: ci.activeFocus ? 2 : 0; border.color: AppTheme.accent
                                TextInput {
                                    id: ci
                                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                    verticalAlignment: Text.AlignVCenter; color: AppTheme.text; font.pixelSize: 13; selectByMouse: true; clip: true
                                    text: modelData.values
                                    onTextEdited: { const next = caseList.list.slice(); next[index] = {id: modelData.id, values: text}; caseList.commit(next) }
                                }
                            }
                            IconButton { icon: "trash"; onClicked: { const next = caseList.list.slice(); next.splice(index, 1); caseList.commit(next) } }
                        }
                    }
                    IconButton { icon: "plus"; label: "Add case"; onClicked: caseList.commit(caseList.list.concat([{id: "", values: ""}])) }
                }

                Hint { text: field.modelData.hint || ""; width: parent.width; visible: !!field.modelData.hint }
            }
        }

        Row {
            anchors.right: parent.right; anchors.rightMargin: 20
            spacing: 8
            IconButton { label: "Cancel"; onClicked: dialog.close() }
            IconButton { label: "Apply"; accented: true; onClicked: dialog.apply() }
        }
    }
    }
}
