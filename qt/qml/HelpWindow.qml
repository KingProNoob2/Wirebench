import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wirebench

// The block reference: a searchable list of every block and a page for the one chosen, from Dirigo's library manual, in English or Czech.
// What is listed, which page is open and the language all live in the Swift `HelpModel` (the SwiftUI app draws the same one); this window
// reads that state and sends it commands.
Window {
    id: win
    title: state.strings.title
    width: 920; height: 640
    minimumWidth: 640; minimumHeight: 420
    visible: false
    color: AppTheme.window

    property var state: ({language: "en", languages: [], query: "", selected: "", isFallback: false, sections: [], entry: null,
                          strings: {title: "Block Reference", search: "Search blocks", pins: "", abbreviation: "", kind: "", dataType: "", name: "",
                                    description: "", defaultValue: "", notes: "", noResults: "", noPage: "", notTranslated: "", pickABlock: "", source: ""}})
    property string seen: ""

    function open() { refresh(); visible = true; raise(); requestActivate() }
    // Opens the page for a block of the project, by its id.
    function showBlock(id) { controller.command({cmd: "helpShowBlock", id: id}); open() }
    function ask(command) { controller.command(command); refresh() }
    function refresh() {
        const reply = controller.command({cmd: "helpState"})
        if (!reply.state) return
        // Replacing the list's model scrolls it back to the top, so only do it when what is listed changed.
        const json = JSON.stringify(reply.state.sections)
        if (json !== seen) {
            seen = json
            rows.clear()
            for (const section of reply.state.sections)
                for (const entry of section.entries) rows.append({section: section.title, name: entry.name, subtitle: entry.title})
        }
        const opened = state.selected !== reply.state.selected || state.language !== reply.state.language
        state = reply.state
        if (opened) {
            page.contentY = 0
            for (let i = 0; i < rows.count; ++i)
                if (rows.get(i).name === state.selected) { list.positionViewAtIndex(i, ListView.Contain); break }
        }
    }

    ListModel { id: rows }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // The list.
        ColumnLayout {
            Layout.preferredWidth: 270; Layout.minimumWidth: 270; Layout.maximumWidth: 270; Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
                Layout.fillWidth: true; Layout.margins: 12
                spacing: 8
                TextField {
                    id: search
                    Layout.fillWidth: true
                    placeholderText: win.state.strings.search
                    text: win.state.query
                    color: AppTheme.text; placeholderTextColor: AppTheme.faint
                    font.pixelSize: 13
                    leftPadding: 12; rightPadding: 12; topPadding: 8; bottomPadding: 8
                    selectByMouse: true
                    background: Item { SmoothRect { anchors.fill: parent; radius: 8; color: AppTheme.field } }
                    onTextEdited: win.ask({cmd: "helpSetQuery", value: text})
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.state.languages
                        delegate: IconButton {
                            required property var modelData
                            Layout.fillWidth: true
                            label: modelData.label
                            active: win.state.language === modelData.id
                            onClicked: win.ask({cmd: "helpSetLanguage", value: modelData.id})
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: AppTheme.panelStroke }

            ListView {
                id: list
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                model: rows
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                section.property: "section"
                section.criteria: ViewSection.FullString
                section.delegate: Text {
                    required property string section
                    width: list.width
                    leftPadding: 14; topPadding: 14; bottomPadding: 4
                    text: section.toUpperCase()
                    color: AppTheme.faint; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8
                }
                delegate: Item {
                    id: row
                    required property string name
                    required property string subtitle
                    readonly property bool chosen: name === win.state.selected
                    width: list.width; height: 40
                    SmoothRect { x: 6; width: parent.width - 12; height: parent.height - 2; radius: 7
                                 color: row.chosen ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.28)
                                      : mouse.containsMouse ? AppTheme.hover : "transparent" }
                    Column {
                        anchors { left: parent.left; right: parent.right; leftMargin: 16; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        Text { text: row.name; color: AppTheme.text; font.pixelSize: 13; elide: Text.ElideRight; width: parent.width }
                        Text { text: row.subtitle; color: AppTheme.faint; font.pixelSize: 11; elide: Text.ElideRight; width: parent.width }
                    }
                    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: win.ask({cmd: "helpSelect", name: row.name}) }
                }
                Text {
                    anchors.centerIn: parent
                    visible: rows.count === 0
                    text: win.state.strings.noResults
                    color: AppTheme.faint; font.pixelSize: 13
                }
            }
        }
        Rectangle { Layout.fillHeight: true; width: 1; color: AppTheme.panelStroke }

        // A page.
        Flickable {
            id: page
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: body.implicitHeight + 40
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // Nothing chosen, or a block with no page.
            Text {
                anchors.centerIn: parent
                width: parent.width - 80
                visible: !win.state.entry
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: win.state.selected !== "" ? win.state.selected + "\n" + win.state.strings.noPage : win.state.strings.pickABlock
                color: AppTheme.faint; font.pixelSize: 14
            }

            ColumnLayout {
                id: body
                visible: !!win.state.entry
                x: 20; y: 20; width: page.width - 40
                spacing: 16

                ColumnLayout {
                    spacing: 3
                    Text { text: win.state.entry ? win.state.entry.name : ""; color: AppTheme.text; font.pixelSize: 26; font.weight: Font.Bold }
                    Text { text: win.state.entry ? win.state.entry.title : ""; color: AppTheme.text; font.pixelSize: 15; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Text {
                        text: win.state.entry ? (win.state.entry.group !== "" ? win.state.entry.category + " › " + win.state.entry.group : win.state.entry.category) : ""
                        color: AppTheme.faint; font.pixelSize: 12
                    }
                    Text {
                        visible: !!win.state.entry && win.state.entry.formula !== ""
                        text: win.state.entry ? win.state.entry.formula : ""
                        color: AppTheme.dim; font.pixelSize: 12; font.family: "monospace"; wrapMode: Text.Wrap; Layout.fillWidth: true
                    }
                }
                Text {
                    visible: win.state.isFallback
                    text: win.state.strings.notTranslated
                    color: AppTheme.faint; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true
                }

                // The pins.
                Text { text: win.state.strings.pins; color: AppTheme.text; font.pixelSize: 14; font.weight: Font.Bold }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 6; columnSpacing: 14; rowSpacing: 8
                    Repeater {
                        model: [win.state.strings.abbreviation, win.state.strings.kind, win.state.strings.dataType,
                                win.state.strings.name, win.state.strings.description, win.state.strings.defaultValue]
                        delegate: Text {
                            required property string modelData
                            required property int index
                            text: modelData; color: AppTheme.faint; font.pixelSize: 11; font.weight: Font.Bold
                            Layout.fillWidth: index === 4; Layout.preferredWidth: index === 4 ? 1 : implicitWidth
                        }
                    }
                    Repeater {
                        model: win.state.entry ? win.state.entry.pins.length * 6 : 0
                        delegate: Text {
                            required property int index
                            readonly property var pin: win.state.entry.pins[Math.floor(index / 6)]
                            readonly property int column: index % 6
                            text: [pin.abbreviation, pin.kind, pin.dataType, pin.name, pin.text, pin.defaultValue][column]
                            color: column === 0 ? AppTheme.text : (column === 1 || column === 5) ? AppTheme.faint : AppTheme.dim
                            font.pixelSize: 12; font.weight: column === 0 ? Font.Medium : Font.Normal
                            font.family: column === 0 ? "monospace" : Qt.application.font.family
                            wrapMode: Text.Wrap
                            Layout.fillWidth: column === 4; Layout.preferredWidth: column === 4 ? 1 : implicitWidth
                            Layout.alignment: Qt.AlignTop
                        }
                    }
                }

                // Notes: selectable, so a rule can be copied.
                Text { visible: !!win.state.entry && win.state.entry.notes.length > 0; text: win.state.strings.notes; color: AppTheme.text; font.pixelSize: 14; font.weight: Font.Bold }
                Repeater {
                    model: win.state.entry ? win.state.entry.notes : []
                    delegate: TextEdit {
                        required property string modelData
                        Layout.fillWidth: true
                        text: modelData
                        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                        color: AppTheme.dim; selectionColor: AppTheme.accent; font.pixelSize: 13
                    }
                }

                // Tables from the manual, such as a truth table.
                Repeater {
                    model: win.state.entry ? win.state.entry.tables : []
                    delegate: GridLayout {
                        id: tableGrid
                        required property var modelData
                        columns: Math.max(1, modelData.head.length); columnSpacing: 20; rowSpacing: 4
                        Repeater {
                            model: tableGrid.modelData.head
                            delegate: Text { required property string modelData; text: modelData; color: AppTheme.faint; font.pixelSize: 11; font.weight: Font.Bold }
                        }
                        Repeater {
                            model: tableGrid.modelData.rows.reduce((all, r) => all.concat(r), [])
                            delegate: Text { required property string modelData; text: modelData; color: AppTheme.text; font.pixelSize: 12; font.family: "monospace" }
                        }
                    }
                }

                Text { text: win.state.strings.source; color: AppTheme.faint; font.pixelSize: 10; opacity: 0.7 }
            }
        }
    }
}
