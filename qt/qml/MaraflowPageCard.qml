import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wirebench

// The hidden ST/LD runtime page shown as a floating note. Drag it to move it out of the sheet's way.
Rectangle {
    id: card
    required property var pageInfo
    signal editRequested()
    property real cardX: 120
    property real cardY: 70
    property real startX: 0
    property real startY: 0
    x: cardX
    y: cardY
    width: 360
    height: layout.implicitHeight + 28
    radius: 14
    color: AppTheme.card
    border.color: AppTheme.panelStroke
    z: 30

    ColumnLayout {
        id: layout
        anchors { fill: parent; margins: 14 }
        spacing: 8
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: card.pageInfo.kind || "Maraflow page"
                color: AppTheme.text
                font.pixelSize: 14
                font.weight: Font.Bold
                Layout.fillWidth: true
            }
            IconButton { label: "ST"; icon: "text"; onClicked: card.editRequested() }
        }
        Text {
            text: (card.pageInfo.lines || 0) + " lines · runs through the native " + (card.pageInfo.kind === "Structured Text" ? "ST interpreter" : "ladder evaluator")
            color: AppTheme.dim
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Text {
            Layout.fillWidth: true
            text: {
                const lines = (card.pageInfo.code || "").split("\n")
                return lines.slice(0, 8).join("\n")
            }
            color: AppTheme.dim
            font.family: "monospace"
            font.pixelSize: 10
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            maximumLineCount: 8
        }
        Button {
            text: "Structured Text…"
            visible: card.pageInfo.kind === "Structured Text"
            onClicked: card.editRequested()
        }
    }

    MouseArea {
        anchors.fill: parent
        z: -1
        property point origin
        property bool moving: false
        onPressed: mouse => {
            origin = mapToItem(card.parent, mouse.x, mouse.y)
            card.startX = card.cardX
            card.startY = card.cardY
            moving = false
        }
        onPositionChanged: mouse => {
            const now = mapToItem(card.parent, mouse.x, mouse.y)
            card.cardX = card.startX + now.x - origin.x
            card.cardY = card.startY + now.y - origin.y
            moving = true
        }
    }
}
