import QtQuick
import QtQuick.Controls
import Wirebench

// A short list that drops down from the control that opens it, in the app's own look (the same as the Agent window's drop-downs) and not the
// platform's menu. `labels` are the lines; `picked(index)` says which was chosen; `openBelow(item)` opens it under `item`.
Popup {
    id: list
    property var labels: []
    property real minWidth: 0
    signal picked(int index)
    function openBelow(item) { parent = item; open() }

    y: parent ? parent.height + 4 : 0
    width: Math.max(minWidth, parent ? parent.width : 0, 200)
    padding: 6
    implicitHeight: Math.min(view.contentHeight + 12, 320)
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    background: Item { SmoothRect { anchors.fill: parent; radius: 10; color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.panelStroke } }
    contentItem: ListView {
        id: view
        clip: true
        model: list.labels
        implicitHeight: contentHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: ItemDelegate {
            required property string modelData
            required property int index
            width: view.width
            height: 32
            highlighted: hovered
            contentItem: Text { text: modelData; color: AppTheme.text; font.pixelSize: 13; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
            background: Item { SmoothRect { anchors.fill: parent; radius: 6; color: parent.parent.hovered ? AppTheme.hover : "transparent" } }
            onClicked: { list.close(); list.picked(index) }
        }
    }
}
