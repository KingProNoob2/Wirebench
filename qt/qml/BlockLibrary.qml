import QtQuick
import QtQuick.Controls
import Wirebench

// The block library, always at hand on the left: type to search, click a block to put it on the sheet.
Panel {
    id: library
    signal picked(string guid)
    // A row dragged out of the list: where it is (window coordinates) while it moves, and where it was let go.
    signal dragStarted(string guid, string name)
    signal dragMoved(real x, real y)
    signal dropped(string guid, real x, real y)
    property var blocks: []
    function search() { blocks = controller.command({cmd: "palette", query: field.text}).blocks || [] }
    function focusSearch() { field.forceActiveFocus(); field.selectAll() }
    Component.onCompleted: search()
    // What is likely next depends on the selected block, so the list is ordered again when the selection changes.
    Connections { target: controller; function onInspectorChanged() { if (field.text === "") library.search() } }

    Rectangle {
        id: box
        x: 12; y: 12; width: parent.width - 24; height: 34; radius: 9
        color: AppTheme.field
        border.width: field.activeFocus ? 2 : 0
        border.color: AppTheme.accent
        Icon { name: "search"; color: AppTheme.dim; size: 15; x: 10; anchors.verticalCenter: parent.verticalCenter }
        TextInput {
            id: field
            anchors { left: parent.left; right: parent.right; leftMargin: 34; rightMargin: 10; verticalCenter: parent.verticalCenter }
            color: AppTheme.text
            font.pixelSize: 13
            selectByMouse: true
            clip: true
            onTextChanged: library.search()
            onAccepted: if (library.blocks.length > 0) library.picked(library.blocks[0].guid)
            Text { visible: field.text === "" && !field.activeFocus; text: "Search blocks"; color: AppTheme.faint; font: field.font }
        }
    }

    Text {
        id: heading
        x: 16; y: 58
        text: field.text === "" ? "BLOCKS" : library.blocks.length + (library.blocks.length === 1 ? " RESULT" : " RESULTS")
        color: AppTheme.faint; font.pixelSize: 11; font.weight: Font.Bold; font.letterSpacing: 0.8
    }

    ListView {
        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom; topMargin: 78; bottomMargin: 8; leftMargin: 6; rightMargin: 6 }
        clip: true
        model: library.blocks
        spacing: 1
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { width: 6; policy: ScrollBar.AsNeeded
            contentItem: Rectangle { implicitWidth: 4; radius: 2; color: AppTheme.faint; opacity: 0.5 } }
        delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: ListView.view.width
            height: 46
            Rectangle {
                anchors.fill: parent; anchors.margins: 1
                radius: 8
                color: area.pressed ? AppTheme.press : area.containsMouse ? AppTheme.hover : "transparent"
            }
            Rectangle {
                x: 10; y: 11; width: 24; height: 24; radius: 7
                color: Qt.rgba(tint.r, tint.g, tint.b, 0.2)
                readonly property color tint: AppTheme.categoryColor(row.modelData.category)
                Text { anchors.centerIn: parent; text: row.modelData.name.substring(0, 1).toUpperCase(); color: parent.tint
                       font.pixelSize: 12; font.weight: Font.Bold }
            }
            Column {
                x: 44; y: 7; width: parent.width - 54
                Text { text: row.modelData.name; color: AppTheme.text; font.pixelSize: 13; font.weight: Font.Normal; elide: Text.ElideRight; width: parent.width }
                Text { text: row.modelData.summary || row.modelData.category; color: AppTheme.faint; font.pixelSize: 11; elide: Text.ElideRight; width: parent.width }
            }
            MouseArea {
                id: area
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                property point pressAt
                property bool dragging: false
                preventStealing: dragging           // the list would otherwise take a vertical drag for a scroll
                onPressed: mouse => { pressAt = Qt.point(mouse.x, mouse.y); dragging = false }
                onPositionChanged: mouse => {
                    if (!pressed) return
                    if (!dragging && Math.hypot(mouse.x - pressAt.x, mouse.y - pressAt.y) > 4) {
                        dragging = true
                        library.dragStarted(row.modelData.guid, row.modelData.name)
                    }
                    if (dragging) { const at = mapToItem(null, mouse.x, mouse.y); library.dragMoved(at.x, at.y) }
                }
                onReleased: mouse => { if (dragging) { const at = mapToItem(null, mouse.x, mouse.y); library.dropped(row.modelData.guid, at.x, at.y) } }
                onCanceled: if (dragging) library.dropped("", -1, -1)
                onClicked: if (!dragging) library.picked(row.modelData.guid)
            }
        }
    }
}
