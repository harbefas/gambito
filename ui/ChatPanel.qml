import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: chat
    required property var app
    required property Item focusScope
    readonly property string gameId: app.selectedId
    property var lines: []
    property var buffered: []
    property string historyRequest: ""
    property string sendRequest: ""
    property string error: ""
    readonly property bool connected: !!app.game && app.game.connected && app.daemonConnected
    function refresh() {
        if (!gameId || !connected) return;
        buffered = []; error = "";
        historyRequest = app.send("chat_history");
    }
    onGameIdChanged: { lines = []; input.text = ""; sendRequest = ""; refresh(); }
    onConnectedChanged: if (connected) refresh()
    Component.onCompleted: { refresh(); input.forceActiveFocus(); }
    function submit() {
        if (!input.text.trim() || sendRequest) return;
        sendRequest = app.send("chat", {text: input.text});
    }
    Connections {
        target: app
        function onChatLine(id, line) {
            if (id !== chat.gameId) return;
            if (chat.historyRequest) chat.buffered = chat.buffered.concat([line]);
            else chat.lines = chat.lines.concat([line]).slice(-100);
        }
        function onSocialReply(request, cmd, data, failure) {
            if (request === chat.historyRequest) {
                chat.historyRequest = "";
                if (failure) { chat.error = failure; chat.lines = chat.lines.concat(chat.buffered).slice(-100); }
                else if (data.for === chat.gameId) {
                    const history = data.lines;
                    // Stream messages may already be in the HTTP snapshot. Merge overlapping tails.
                    let overlap = Math.min(history.length, chat.buffered.length);
                    while (overlap > 0 && !history.slice(-overlap).every((l, i) => l.user === chat.buffered[i].user && l.text === chat.buffered[i].text)) overlap--;
                    chat.lines = history.concat(chat.buffered.slice(overlap)).slice(-100);
                }
                chat.buffered = [];
            } else if (request === chat.sendRequest) {
                chat.sendRequest = "";
                if (failure) chat.error = failure;
                else { input.text = ""; chat.error = ""; }
            }
        }
    }
    ListView {
        id: messages; objectName: "chatMessages"
        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
        model: chat.lines
        onCountChanged: Qt.callLater(() => messages.positionViewAtEnd())
        ScrollBar.vertical: ScrollBar {}
        delegate: Text {
            required property var modelData
            width: messages.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
            color: app.fg; font.pixelSize: 12
            text: modelData.user + ": " + modelData.text
        }
        Text { anchors.centerIn: parent; visible: !chat.lines.length; text: chat.historyRequest ? "Loading chat…" : "No messages yet"; color: app.muted }
    }
    Text { visible: !!chat.error; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: chat.error; color: app.danger; font.pixelSize: 11 }
    RowLayout {
        Layout.fillWidth: true
        ThemedTextField {
            id: input; objectName: "chatInput"; theme: app
            Layout.fillWidth: true; Layout.preferredHeight: 32
            maximumLength: 140; placeholderText: "Message · Enter sends"
            enabled: !chat.sendRequest && chat.connected
            onAccepted: chat.submit()
            Keys.onEscapePressed: { input.focus = false; focusScope.forceActiveFocus(); }
        }
        ActionButton { objectName: "sendChatButton"; theme: app; compact: true; label: "Send"; hint: "↵"; enabled: !chat.sendRequest && chat.connected; onClicked: chat.submit() }
    }
}
