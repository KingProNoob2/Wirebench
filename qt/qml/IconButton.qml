import QtQuick

// A flat icon-and-label button with hover and press states; the building block of the top bar and the zoom control.
Item {
    id: button
    property string icon: ""
    property string label: ""
    property bool active: false
    property bool accented: false
    signal clicked()
    signal rightClicked(point at)       // in window coordinates, for a context menu
    signal pressedChanged2(bool down)

    implicitHeight: 32
    implicitWidth: row.implicitWidth + 20
    opacity: enabled ? 1 : 0.35

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: button.accented ? (mouse.pressed ? Qt.darker(AppTheme.accent, 1.2) : AppTheme.accent)
             : mouse.pressed ? AppTheme.press
             : (mouse.containsMouse || button.active) ? AppTheme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        Icon {
            visible: button.icon !== ""
            name: button.icon
            color: button.accented ? "white" : button.active ? AppTheme.accent : AppTheme.text
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: button.label !== ""
            text: button.label
            color: button.accented ? "white" : AppTheme.text
            font.pixelSize: 13
            font.weight: Font.Normal
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onPressedChanged: button.pressedChanged2(pressed)
        onClicked: mouse => { if (mouse.button === Qt.RightButton) button.rightClicked(mapToItem(null, mouse.x, mouse.y)); else button.clicked() }
    }
}
