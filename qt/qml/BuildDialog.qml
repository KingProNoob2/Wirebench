import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import Wirebench

// Build and hardware: compile the project to a PLC program, write it out, and send it over the serial link.
Popup {
    id: dialog
    property int tab: 0               // 0 report, 1 hardware
    property var report: null
    property string exportKind: ""
    property string exportExtension: ""
    property string message: ""
    readonly property var hw: controller.hardware

    function show(which) {
        tab = which
        if (which === 0 || !report) build()
        if (which === 1) controller.command({cmd: "refreshPorts"})
        open()
    }
    function build() {
        const reply = controller.command({cmd: "build"})
        report = reply.ok ? reply.report : null
        message = reply.ok ? "" : "The project could not be built."
    }
    // Asks where to write, then exports what a build produced.
    // `suffix` goes between the project's name and the extension: the legacy export suggests "name-dirigo.pcc", as the SwiftUI app does, so
    // that the default is never the open project itself.
    function exportAs(kind, extension, suffix) {
        exportKind = kind
        exportExtension = extension
        exportDialog.currentFile = "file://" + controller.suggestedName((suffix || "") + extension)
        exportDialog.open()
    }
    FileDialog {
        id: exportDialog
        title: "Export"
        fileMode: FileDialog.SaveFile
        nameFilters: ["*" + dialog.exportExtension, "All files (*)"]
        onAccepted: {
            const path = controller.localPath(selectedFile)
            const reply = controller.command({cmd: "export", kind: dialog.exportKind, path: path})
            dialog.message = reply.ok ? "Wrote " + path : "Could not write " + path
        }
    }

    // The same motion as the panels, without the blur (a popup has no snapshot of its contents): a fade with a slight grow.
    enter: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
        NumberAnimation { property: "scale"; from: 0.95; to: 1; duration: 260; easing.type: Easing.OutCubic } } }
    exit: Transition { ParallelAnimation {
        NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InCubic }
        NumberAnimation { property: "scale"; from: 1; to: 0.97; duration: 160; easing.type: Easing.InCubic } } }
    FileDialog {
        id: templateDialog
        title: "Use a program binary as the build template"
        fileMode: FileDialog.OpenFile
        nameFilters: ["Program binaries (*.pbd)", "All files (*)"]
        onAccepted: {
            controller.command({cmd: "buildTemplate", path: controller.localPath(selectedFile)})
            dialog.build()
        }
    }

    modal: true
    anchors.centerIn: Overlay.overlay
    width: 640
    height: Math.min(600, (Overlay.overlay ? Overlay.overlay.height : 700) - 60)
    padding: 0
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.4) }
    background: Rectangle { radius: 14; color: AppTheme.card; border.color: AppTheme.panelStroke }

    component Stat: Column {
        property string label
        property var value
        width: 130
        Text { text: parent.value; color: AppTheme.text; font.pixelSize: 20; font.weight: Font.Bold }
        Text { text: parent.label; color: AppTheme.faint; font.pixelSize: 11 }
    }

    Item {
        anchors.fill: parent

        Row {
            id: tabs
            x: 20; y: 16
            spacing: 4
            IconButton { icon: "chip"; label: "Build report"; active: dialog.tab === 0; onClicked: dialog.tab = 0 }
            IconButton { icon: "upload"; label: "Hardware"; active: dialog.tab === 1; onClicked: { dialog.tab = 1; controller.command({cmd: "refreshPorts"}) } }
        }
        IconButton { anchors { right: parent.right; rightMargin: 14; top: parent.top; topMargin: 16 } label: "Close"; onClicked: dialog.close() }

        // ── Report ─────────────────────────────────────────────────────────────────────────────
        Item {
            visible: dialog.tab === 0
            anchors { left: parent.left; right: parent.right; top: tabs.bottom; bottom: parent.bottom; margins: 20 }

            Flow {
                id: stats
                width: parent.width
                spacing: 14
                Stat { label: "Modules"; value: dialog.report ? dialog.report.modules : "–" }
                Stat { label: "Compiled"; value: dialog.report ? dialog.report.compiled : "–" }
                Stat { label: "Display blocks"; value: dialog.report ? dialog.report.display : "–" }
                Stat { label: "Record bytes"; value: dialog.report ? dialog.report.recordBytes : "–" }
                Stat { label: "Data slots"; value: dialog.report ? dialog.report.dataSlots : "–" }
                Stat { label: "Terminals"; value: dialog.report ? dialog.report.terminals : "–" }
                Stat { label: "Symbol rows"; value: dialog.report ? dialog.report.symbolRows : "–" }
                Stat { label: "Table bytes"; value: dialog.report ? dialog.report.tableBytes : "–" }
            }

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: stats.bottom; topMargin: 14; bottom: exportRow.top; bottomMargin: 12 }
                radius: 10; color: AppTheme.field
                ScrollView {
                    anchors { fill: parent; margins: 10 }
                    clip: true
                    TextArea {
                        readOnly: true
                        text: dialog.report ? dialog.report.summary : ""
                        color: AppTheme.dim; font.pixelSize: 12; font.family: "monospace"
                        wrapMode: TextEdit.Wrap
                        background: null
                    }
                }
            }

            Column {
                id: exportRow
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                spacing: 8
                Text { text: dialog.message; color: AppTheme.dim; font.pixelSize: 12; visible: text !== ""; width: parent.width; wrapMode: Text.WordWrap }
                Row {
                    spacing: 6
                    IconButton { label: "Rebuild"; icon: "reset"; onClicked: dialog.build() }
                    IconButton { label: "Program .pbd"; onClicked: dialog.exportAs("pbd", ".pbd") }
                    IconButton { label: "Symbols .csv"; onClicked: dialog.exportAs("csv", ".csv") }
                    IconButton { label: "Variables .dbf"; onClicked: dialog.exportAs("dbf", ".dbf") }
                    IconButton { label: "Dirigo .pcc"; onClicked: dialog.exportAs("pcc", ".pcc") }
                    IconButton { label: "Template…"; onClicked: templateDialog.open() }
                }
            }
        }

        // ── Hardware ───────────────────────────────────────────────────────────────────────────
        Item {
            visible: dialog.tab === 1
            anchors { left: parent.left; right: parent.right; top: tabs.bottom; bottom: parent.bottom; margins: 20 }

            Row {
                id: status
                spacing: 8
                Rectangle { width: 10; height: 10; radius: 5; anchors.verticalCenter: parent.verticalCenter
                            color: dialog.hw.connected ? AppTheme.live : AppTheme.faint }
                Text { text: dialog.hw.connected ? "Connected to " + dialog.hw.port : (dialog.hw.port !== "" ? "Ready to upload · " + dialog.hw.port : ((dialog.hw.ports || []).length === 0 ? "No serial port" : "Choose a serial port")); color: AppTheme.text
                       font.pixelSize: 14; font.weight: Font.Bold }
            }

            Rectangle {
                id: portBox
                anchors { left: parent.left; right: parent.right; top: status.bottom; topMargin: 12 }
                height: Math.min(150, Math.max(46, (dialog.hw.ports || []).length * 34 + 12))
                radius: 10; color: AppTheme.field
                Text { visible: (dialog.hw.ports || []).length === 0; anchors.centerIn: parent; color: AppTheme.faint; font.pixelSize: 12
                       text: "No serial ports found" }
                ListView {
                    anchors { fill: parent; margins: 6 }
                    clip: true
                    model: dialog.hw.ports || []
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width; height: 32; radius: 7
                        readonly property bool chosen: dialog.hw.port === modelData.path
                        color: chosen ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.18) : (hov.containsMouse ? AppTheme.hover : "transparent")
                        Text { x: 10; anchors.verticalCenter: parent.verticalCenter; text: modelData.name || modelData.path; color: AppTheme.text; font.pixelSize: 12 }
                        Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter } text: modelData.path; color: AppTheme.faint; font.pixelSize: 11 }
                        MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: controller.command({cmd: "selectPort", path: modelData.path}) }
                    }
                }
            }

            Row {
                id: hwButtons
                anchors { top: portBox.bottom; topMargin: 12 }
                spacing: 6
                IconButton { label: "Refresh"; icon: "reset"; onClicked: controller.command({cmd: "refreshPorts"}) }
                IconButton { label: "Build & upload"; icon: "upload"; accented: true; enabled: dialog.hw.port !== "" && !dialog.hw.uploading
                             onClicked: controller.command({cmd: "upload"}) }
            }

            Column {
                id: progress
                anchors { left: parent.left; right: parent.right; top: hwButtons.bottom; topMargin: 14 }
                spacing: 6
                Text { text: (dialog.hw.phase || "") + (dialog.hw.status ? "  ·  " + dialog.hw.status : ""); color: AppTheme.dim
                       font.pixelSize: 12; width: parent.width; elide: Text.ElideRight; visible: text !== ""  }
                Rectangle {
                    visible: dialog.hw.progress >= 0
                    width: parent.width; height: 6; radius: 3; color: AppTheme.field
                    Rectangle { width: parent.width * Math.max(0, Math.min(1, dialog.hw.progress)); height: parent.height; radius: 3; color: AppTheme.accent }
                }
            }

            Rectangle {
                anchors { left: parent.left; right: parent.right; top: progress.bottom; topMargin: 8; bottom: parent.bottom }
                radius: 10; color: AppTheme.field
                ScrollView {
                    anchors { fill: parent; margins: 10 }
                    clip: true
                    TextArea {
                        readOnly: true
                        text: (dialog.hw.log || []).join("\n")
                        color: AppTheme.dim; font.pixelSize: 11; font.family: "monospace"
                        wrapMode: TextEdit.Wrap
                        background: null
                    }
                }
            }
        }
    }
}
