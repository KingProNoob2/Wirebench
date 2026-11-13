import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Wirebench

// The agent panel: a conversation with a chatbot service over the OpenAI chat-completions API. Which service, the model, the key and the
// conversation all live in the Swift `AgentModel` (the SwiftUI app draws the same one); this window reads that state and sends it commands.
// The key is typed here once and handed to the system's secret store; it is never shown again and never kept in this window.
Window {
    id: win
    title: "Agent"
    width: 400; height: 620
    minimumWidth: 340; minimumHeight: 460
    visible: false
    color: AppTheme.window

    property var state: ({presets: [], messages: [], provider: "", model: "", baseURL: "", custom: false, needsKey: true, hasKey: false,
                          keyHelp: "", keyLocation: "", models: [], loadingModels: false, modelsError: "", modelsHint: "", sending: false, error: "", canEdit: false, toolsRefused: false, toolsRefusal: "", currentAction: ""})
    property bool showConnection: true
    /// False when this build was compiled without WIREBENCH_AI: the bridge answers available:false and every command
    /// refuses, so the panel must say so instead of offering a dead Send.
    property bool available: true
    Connections { target: controller; function onSceneChanged() { if (win.visible && !controller.hasProject) win.visible = false } }
    property string seen: ""

    // The agent works on the open project, so there is nothing to open it for without one; and one that is open when the project goes closes.
    function open() { if (!controller.hasProject) return; controller.command({cmd: "agentRefreshModels"}); refresh(); showConnection = state.needsKey && !state.hasKey; visible = true; raise(); requestActivate() }
    function ask(command) { controller.command(command); refresh() }
    function refresh() {
        const reply = controller.command({cmd: "agentState"})
        if (!reply.state) return
        // Replacing the list's model scrolls it back to the top, so only do it when the conversation changed.
        const json = JSON.stringify(reply.state.messages) + reply.state.sending
        const changed = json !== seen
        seen = json
        available = reply.state.available !== false
        state = reply.state
        if (changed) { messages.clear(); for (const m of state.messages) messages.append(m); list.positionViewAtEnd() }
    }
    function send() {
        if (!available) return
        const text = field.text.trim()
        if (text === "") return
        win.ask({cmd: "agentSend", text: text})
        if (state.sending) field.text = ""            // kept if it could not be sent (no key yet), so nothing typed is lost
    }
    function saveKey() {
        if (keyField.text.trim() === "") return
        win.ask({cmd: "agentSetKey", value: keyField.text})
        keyField.text = ""                             // not kept here
        showConnection = false
    }

    // The answer arrives later, from the network, so the window looks again while it is open.
    Timer { interval: 250; repeat: true; running: win.visible; onTriggered: win.refresh() }
    ListModel { id: messages }

    component Field: TextField {
        color: AppTheme.text; placeholderTextColor: AppTheme.faint
        font.pixelSize: 13
        leftPadding: 12; rightPadding: 12; topPadding: 8; bottomPadding: 8
        selectByMouse: true
        // In an Item: a Shape used directly as a control's background takes an implicit size from its own path, which loops.
        background: Item { SmoothRect { anchors.fill: parent; radius: 8; color: AppTheme.field } }
    }

    // A drop-down in the app's own look. `items` are objects with a `name`.
    component Choice: ComboBox {
        id: choice
        property var items: []
        model: items
        textRole: "name"
        font.pixelSize: 13
        leftPadding: 12; rightPadding: 32; topPadding: 8; bottomPadding: 8
        background: Item { SmoothRect { anchors.fill: parent; radius: 8; color: AppTheme.field } }
        contentItem: Text { text: choice.displayText; color: AppTheme.text; font: choice.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
        indicator: Icon { name: "chevdown"; color: AppTheme.dim; x: choice.width - width - 10; anchors.verticalCenter: parent.verticalCenter }
        popup: Popup {
            y: choice.height + 4; width: choice.width; padding: 6
            implicitHeight: Math.min(contentItem.implicitHeight + 12, 320)
            background: Item { SmoothRect { anchors.fill: parent; radius: 10; color: AppTheme.card; borderWidth: 1; borderColor: AppTheme.panelStroke } }
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: choice.popup.visible ? choice.delegateModel : null
                currentIndex: choice.highlightedIndex
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            }
        }
        delegate: ItemDelegate {
            required property var modelData
            required property int index
            width: choice.width - 12
            height: 32
            contentItem: Text { text: modelData.name; color: AppTheme.text; font.pixelSize: 13; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
            background: Item { SmoothRect { anchors.fill: parent; radius: 6; color: highlighted ? AppTheme.hover : "transparent" } }
            highlighted: choice.highlightedIndex === index
        }
    }

    ColumnLayout {
        Text {
            visible: !win.available
            text: "The agent is not built into this copy of Wirebench."
            color: AppTheme.faint
            font.pixelSize: 12
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.topMargin: 8
            wrapMode: Text.WordWrap
        }
        anchors.fill: parent
        spacing: 0

        // Title and status.
        RowLayout {
            Layout.fillWidth: true; Layout.margins: 14; Layout.bottomMargin: 10
            Icon { name: "sparkle"; color: AppTheme.dim; Layout.alignment: Qt.AlignVCenter }
            ColumnLayout {
                spacing: 1
                Text { text: "Agent"; color: AppTheme.text; font.pixelSize: 15; font.weight: Font.Bold }
                Text {
                    text: {
                        const preset = win.state.presets.find(p => p.id === win.state.provider)
                        const name = preset ? preset.name : ""
                        return win.state.needsKey && !win.state.hasKey ? name + ": no key yet" : name + " · " + win.state.model
                    }
                    color: AppTheme.faint; font.pixelSize: 11
                }
            }
            Item { Layout.fillWidth: true }
            IconButton { icon: "gear"; active: win.showConnection; onClicked: win.showConnection = !win.showConnection }
            IconButton { icon: "trash"; enabled: win.state.messages.length > 1; onClicked: win.ask({cmd: "agentClear"}) }
        }

        // Which service, which model, and the key.
        ColumnLayout {
            visible: win.showConnection
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 14
            spacing: 8

            Choice {
                id: service
                Layout.fillWidth: true
                items: win.state.presets
                currentIndex: Math.max(0, win.state.presets.findIndex(p => p.id === win.state.provider))
                onActivated: index => win.ask({cmd: "agentSetProvider", id: win.state.presets[index].id})
            }
            Field {
                visible: win.state.custom === true
                Layout.fillWidth: true
                placeholderText: "Address, e.g. https://example.com/v1"
                text: win.state.baseURL
                onEditingFinished: win.ask({cmd: "agentSetBaseURL", value: text})
            }
            // A key already saved is only ever described; one being entered is hidden as it is typed.
            RowLayout {
                visible: win.state.needsKey && win.state.hasKey
                Layout.fillWidth: true
                Text { text: "Key saved in " + win.state.keyLocation; color: AppTheme.text; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
                IconButton { label: "Remove"; onClicked: win.ask({cmd: "agentRemoveKey"}) }
            }
            RowLayout {
                visible: win.state.needsKey && !win.state.hasKey
                Layout.fillWidth: true
                spacing: 8
                Field {
                    id: keyField
                    Layout.fillWidth: true
                    placeholderText: "API key"
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                    onAccepted: win.saveKey()
                }
                IconButton { label: "Save"; accented: true; enabled: keyField.text.trim() !== ""; onClicked: win.saveKey() }
            }
            Text {
                visible: win.state.needsKey && !win.state.hasKey
                Layout.fillWidth: true
                text: "Get one at " + win.state.keyHelp + ". It is kept in the system's secure storage and sent only to this service."
                color: AppTheme.faint; font.pixelSize: 11; wrapMode: Text.Wrap
            }
            Text {
                visible: !win.state.needsKey
                Layout.fillWidth: true
                text: win.state.keyHelp
                color: AppTheme.faint; font.pixelSize: 11; wrapMode: Text.Wrap
            }

            // Under the key, and only once there is one (a local service needs none): the model has nothing to be chosen from before that.
            ColumnLayout {
                visible: !win.state.needsKey || win.state.hasKey
                Layout.fillWidth: true
                spacing: 8
            RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    // The service's own list when it gave one; otherwise the name is typed.
                    Choice {
                        id: modelPicker
                        visible: win.state.models.length > 0
                        Layout.fillWidth: true
                        // A name typed earlier that the list does not show stays choosable.
                        items: (win.state.models.indexOf(win.state.model) < 0 ? [win.state.model] : []).concat(win.state.models).map(m => ({name: m}))
                        currentIndex: Math.max(0, items.findIndex(i => i.name === win.state.model))
                        onActivated: index => win.ask({cmd: "agentSetModel", value: items[index].name})
                    }
                    Field {
                        visible: win.state.models.length === 0
                        Layout.fillWidth: true
                        placeholderText: "Model"
                        text: win.state.model
                        onEditingFinished: win.ask({cmd: "agentSetModel", value: text})
                    }
                    BusyIndicator { visible: win.state.loadingModels; running: visible; implicitWidth: 24; implicitHeight: 24 }
                    IconButton {
                        visible: !win.state.loadingModels
                        icon: "reset"
                        onClicked: win.ask({cmd: "agentRefreshModels"})
                    }
                }
                Text {
                    visible: win.state.modelsHint !== ""
                    Layout.fillWidth: true
                    text: win.state.modelsHint
                    color: AppTheme.faint; font.pixelSize: 11; wrapMode: Text.Wrap
                }

            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: AppTheme.panelStroke }

        ListView {
            id: list
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            model: messages
            spacing: 10
            topMargin: 14; bottomMargin: 14; leftMargin: 14; rightMargin: 14
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            footer: Item {
                width: list.width; height: win.state.sending ? 30 : 0
                visible: win.state.sending
                Text { x: 14; y: 6; text: win.state.currentAction !== "" ? win.state.currentAction : "Thinking…"; color: AppTheme.faint; font.pixelSize: 13 }
            }
            delegate: Item {
                id: row
                required property string role
                required property string text
                required property bool failed
                readonly property bool fromUser: role === "user"
                // What the agent did to the project: a small line, not a speech bubble.
                readonly property bool isAction: role === "tool"
                width: ListView.view.width - 28
                height: isAction ? action.implicitHeight : bubble.height
                Text {
                    id: action
                    visible: row.isAction
                    x: 4; width: parent.width - 8
                    text: (row.failed ? "!  " : "✓  ") + row.text
                    color: row.failed ? "#ffb454" : AppTheme.faint
                    font.pixelSize: 11; wrapMode: Text.Wrap
                }
                // The bubble is as wide as the text would be on one line, up to the room there is. Measured, not read from the wrapped text:
                // the wrapped text's width depends on the bubble's, and a bubble sized from it loops.
                TextMetrics { id: natural; text: row.text; font.pixelSize: 13 }
                SmoothRect {
                    id: bubble
                    visible: !row.isAction
                    x: row.fromUser ? row.width - width : 0
                    width: Math.min(row.width - 40, Math.ceil(natural.advanceWidth) + 26)
                    height: label.implicitHeight + 16
                    radius: 12
                    color: row.fromUser ? Qt.rgba(AppTheme.accent.r, AppTheme.accent.g, AppTheme.accent.b, 0.24) : AppTheme.field
                    TextEdit {      // selectable, so an answer can be copied
                        id: label
                        x: 12; y: 8; width: parent.width - 24
                        text: row.text
                        readOnly: true; selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: AppTheme.text; selectionColor: AppTheme.accent; font.pixelSize: 13
                    }
                }
            }
        }

        Text {
            visible: win.state.error !== ""
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.bottomMargin: 8
            text: win.state.error
            color: "#ff6b6b"; font.pixelSize: 12; wrapMode: Text.Wrap
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: AppTheme.panelStroke }

        // Whether the agent may change the project. It can always read it.
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 10
            spacing: 12
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text { text: "Allow editing the project"; color: AppTheme.text; font.pixelSize: 13 }
                Text {
                    Layout.fillWidth: true
                    text: win.state.toolsRefused ? "The service would not take tools" + (win.state.toolsRefusal !== "" ? " (" + win.state.toolsRefusal + ")" : "") + ", so the agent cannot see or change the project. Choosing another model tries again."
                          : win.state.canEdit ? "The agent can read and change the open project. Undo takes a change back."
                          : "The agent can read the open project, which is sent to the service as it looks, but cannot change it."
                    color: AppTheme.faint; font.pixelSize: 11; wrapMode: Text.Wrap
                }
            }
            Rectangle {
                width: 40; height: 22; radius: 11
                color: win.state.canEdit ? AppTheme.accent : AppTheme.field
                Rectangle { x: win.state.canEdit ? 20 : 2; y: 2; width: 18; height: 18; radius: 9; color: "white"
                            Behavior on x { NumberAnimation { duration: 110 } } }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: win.ask({cmd: "agentSetCanEdit", value: !win.state.canEdit}) }
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.margins: 12
            spacing: 8
            Field {
                id: field
                Layout.fillWidth: true
                placeholderText: "Ask the agent…"
                onAccepted: win.send()
            }
            IconButton { label: "Send"; accented: true; enabled: win.available && field.text.trim() !== "" && !win.state.sending; onClicked: win.send() }
        }
    }
}
