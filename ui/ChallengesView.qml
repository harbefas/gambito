import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: view
    required property var app
    required property Item focusScope
    objectName: "challengesView"
    spacing: 12
    property int selected: 0
    readonly property var choice: app.challenges[selected] || null
    function respond(action) {
        if (choice) app.send("challenge_" + action, {challenge: choice.id});
    }
    function handleKey(key, event) {
        if (key === "j" || event.key === Qt.Key_Down) selected = Math.min(app.challenges.length - 1, selected + 1);
        else if (key === "k" || event.key === Qt.Key_Up) selected = Math.max(0, selected - 1);
        else if (key === "a" && choice && choice.direction === "in") respond("accept");
        else if (key === "x" && choice) respond(choice.direction === "in" ? "decline" : "cancel");
        else if (key === "u") username.forceActiveFocus();
        else if (key === "r") app.send("challenges");
        else if (key === "s") submit();
        else if (key === "c") color.currentIndex = (color.currentIndex + 1) % 3;
        else if (key === "t") control.currentIndex = (control.currentIndex + 1) % controls.length;
        else if (key === "v") rated.checked = !rated.checked;
        else return false;
        return true;
    }
    readonly property var controls: [{label:"3+2", minutes:3, increment:2}, {label:"5+0", minutes:5, increment:0}, {label:"5+3", minutes:5, increment:3}, {label:"10+5", minutes:10, increment:5}, {label:"15+10", minutes:15, increment:10}, {label:"30+0", minutes:30, increment:0}, {label:"1 day", days:1}, {label:"3 days", days:3}, {label:"7 days", days:7}]
    function submit() {
        if (!username.text.trim()) { username.forceActiveFocus(); return; }
        app.send("challenge", Object.assign({username: username.text.trim(), rated: rated.checked, color: ["random", "white", "black"][color.currentIndex]}, controls[control.currentIndex]));
        username.focus = false; focusScope.forceActiveFocus();
    }
    Component.onCompleted: { app.viewKeys = handleKey; if (app.account) app.send("challenges"); }
    Component.onDestruction: app.viewKeys = null
    Connections {
        target: app
        function onChallengesChanged() { view.selected = Math.max(0, Math.min(view.selected, app.challenges.length - 1)); }
    }
    RowLayout {
        Layout.fillWidth: true
        ActionButton { theme: app; label: "Lobby"; hint: "g"; onClicked: app.view = "" }
        Text { Layout.fillWidth: true; text: "Challenges"; color: app.fg; font.pixelSize: 24 }
        ActionButton { theme: app; label: "Refresh"; hint: "r"; onClicked: app.send("challenges") }
    }
    Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: app.account ? "Standard chess · Blitz, Rapid, Classical or correspondence. Real-time invitations expire after 20 seconds." : "Connect Lichess to send and receive challenges."; color: app.muted }
    ActionButton { visible: !app.account; theme: app; label: "Connect Lichess"; hint: ":login"; onClicked: app.send("login") }
    GridLayout {
        visible: !!app.account
        Layout.fillWidth: true; columns: 2; columnSpacing: 12; rowSpacing: 8
        Text { text: "Player · u"; color: app.muted }
        ThemedTextField { theme: app; id: username; objectName: "challengeUsername"; Layout.fillWidth: true; placeholderText: "Lichess username"; maximumLength: 30; onAccepted: view.submit(); Keys.onEscapePressed: { username.focus = false; focusScope.forceActiveFocus(); } }
        Text { text: "Time control · t"; color: app.muted }
        ThemedComboBox { theme: app; id: control; Layout.fillWidth: true; model: view.controls.map(c => c.label); currentIndex: 3 }
        Text { text: "Your color · c"; color: app.muted }
        ThemedComboBox { theme: app; id: color; Layout.fillWidth: true; model: ["Random", "White", "Black"] }
        ActionButton {
            id: rated
            property bool checked: false
            theme: app; label: checked ? "Rated" : "Casual"; hint: "v"
            onClicked: { checked = !checked; focusScope.forceActiveFocus(); }
        }
        ActionButton { objectName: "sendChallengeButton"; theme: app; Layout.fillWidth: true; label: "Send challenge"; hint: "s"; onClicked: view.submit() }
    }
    Text { text: "Invitations · j/k select · a accept · x decline/cancel"; color: app.muted }
    ListView {
        id: invitations
        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 8
        model: app.challenges
        currentIndex: view.selected
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
            required property var modelData
            required property int index
            width: invitations.width; height: 88; radius: 10
            color: index === view.selected ? app.raised : app.panel
            border.width: 1; border.color: index === view.selected ? app.accent : app.line
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 8
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; elide: Text.ElideRight; color: app.fg; text: (modelData.direction === "in" ? "From " + (modelData.challenger.name || "?") : "To " + (modelData.destUser ? modelData.destUser.name : "?")) + " · " + (modelData.timeControl.show || modelData.speed) + " · " + (modelData.rated ? "Rated" : "Casual") + " · " + modelData.variant.name }
                RowLayout {
                    Layout.fillWidth: true
                    ActionButton { theme: app; compact: true; label: "Select"; hint: "j/k"; onClicked: { view.selected = index; focusScope.forceActiveFocus(); } }
                    Item { Layout.fillWidth: true }
                    ActionButton { objectName: "acceptChallenge_" + modelData.id; theme: app; compact: true; visible: modelData.direction === "in"; enabled: modelData.variant.key === "standard" && !["bullet", "ultraBullet"].includes(modelData.speed); opacity: enabled ? 1 : 0.4; label: "Accept"; hint: "a"; onClicked: { view.selected = index; view.respond("accept"); } }
                    ActionButton { objectName: "declineChallenge_" + modelData.id; theme: app; compact: true; label: modelData.direction === "in" ? "Decline" : "Cancel"; hint: "x"; onClicked: { view.selected = index; view.respond(modelData.direction === "in" ? "decline" : "cancel"); } }
                }
            }
        }
        Text { anchors.centerIn: parent; visible: !app.challenges.length; text: "No pending challenges"; color: app.muted }
    }
}
