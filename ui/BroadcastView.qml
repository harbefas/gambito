import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Broadcasts are spectator data local to this view. Only an explicit analysis action saves a board.
ColumnLayout {
    id: root
    objectName: "broadcastView"
    required property var app
    property real viewportHeight: 660
    signal closeRequested()
    spacing: 12
    property var tournaments: []
    property var tournament: null
    property var round: null
    property var selected: null
    property var history: null
    property int index: 0
    property string request: ""
    property string historyRequest: ""
    property string error: ""
    property string historyError: ""
    property double retryAt: 0
    readonly property var rows: round ? (round.games || []) : tournament ? (tournament.rounds || []) : tournaments
    readonly property bool busy: request !== ""
    readonly property bool narrow: width < 700
    readonly property string title: round ? round.round.name : tournament ? tournament.tour.name : "Tournaments"

    function refresh() {
        if (busy || Date.now() < retryAt || !app.daemonConnected) return;
        error = "";
        if (round) request = app.send("broadcast_round", {id: round.round.id}) || "";
        else if (tournament) request = app.send("broadcast_tournament", {id: tournament.tour.id}) || "";
        else request = app.send("broadcasts") || "";
    }
    function moves() {
        if (!round || !selected || historyRequest) return;
        historyError = "";
        historyRequest = app.send("broadcast_game", {round: round.round.id, chapter: selected.id}) || "";
    }
    function open(i) {
        if (busy || i < 0 || i >= rows.length) return;
        index = i; error = "";
        if (round) { selected = rows[i]; history = null; historyRequest = ""; moves(); }
        else if (tournament) request = app.send("broadcast_round", {id: rows[i].id}) || "";
        else request = app.send("broadcast_tournament", {id: rows[i].tour.id}) || "";
    }
    function back() {
        request = ""; historyRequest = ""; error = ""; historyError = ""; index = 0;
        if (round) { round = null; selected = null; history = null; }
        else if (tournament) tournament = null;
        else closeRequested();
    }
    function analyse() {
        if (round && selected && history) app.send("broadcast_open", {round: round.round.id, chapter: selected.id});
    }
    function external() {
        if (round) Qt.openUrlExternally("https://lichess.org/broadcast/-/-/" + round.round.id + (selected ? "/" + selected.id : ""));
        else if (tournament) Qt.openUrlExternally("https://lichess.org/broadcast/-/" + tournament.tour.id);
        else Qt.openUrlExternally("https://lichess.org/broadcast");
    }
    function handleKey(key, event) {
        if (key === "j" || event.key === Qt.Key_Down) index = Math.min(rows.length - 1, index + 1);
        else if (key === "k" || event.key === Qt.Key_Up) index = Math.max(0, index - 1);
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) open(index);
        else if (event.key === Qt.Key_Backspace) back();
        else if (key === "r") refresh();
        else if (key === "o") analyse();
        else if (key === "L") external();
        else return false;
        list.positionViewAtIndex(index, ListView.Contain);
        return true;
    }
    function moveText() {
        if (!history) return "Loading moves…";
        const fields = (history.initial_fen || "startpos").split(" ");
        const first = Number(fields[5]) || 1;
        const offset = fields[1] === "b" ? 1 : 0;
        return history.san.map((san, i) => {
            const ply = i + offset, number = first + Math.floor(ply / 2);
            return (ply % 2 === 0 ? number + ". " : i === 0 ? number + "… " : "") + san;
        }).join(" ");
    }
    function clock(player) {
        // Lichess reports centiseconds. Source updates may be delayed, so keep the reported reading.
        if (!player || player.clock === undefined || player.clock === null) return "—";
        const seconds = Math.max(0, Math.floor(player.clock / 100));
        return Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
    }
    Connections {
        target: root.app
        function onBroadcastReply(id, cmd, payload, failure) {
            if (id === root.historyRequest && cmd === "broadcast_game") {
                root.historyRequest = "";
                if (failure) { root.historyError = failure; root.retryAt = Date.now() + 60000; return; }
                if (root.round && root.selected && payload.round === root.round.round.id && payload.chapter === root.selected.id) root.history = payload.broadcast_game;
                return;
            }
            if (id !== root.request) return;
            root.request = "";
            if (failure) { root.error = failure; root.retryAt = Date.now() + 60000; return; }
            const data = payload.broadcast;
            if (cmd === "broadcasts") root.tournaments = (data.active || []).concat(data.upcoming || [], data.past ? data.past.currentPageResults || [] : []);
            else if (cmd === "broadcast_tournament") { root.tournament = data; root.index = 0; }
            else if (cmd === "broadcast_round") {
                const entering = !root.round || root.round.round.id !== data.round.id;
                root.round = data;
                if (entering) { root.index = 0; root.selected = null; root.history = null; }
                if (root.selected) {
                    root.selected = (data.games || []).find(g => g.id === root.selected.id) || null;
                    root.moves();
                }
            }
            root.index = Math.max(0, Math.min(root.index, root.rows.length - 1));
        }
        function onDaemonConnectedChanged() {
            root.request = ""; root.historyRequest = "";
            if (root.app.daemonConnected) root.refresh();
        }
    }
    Component.onCompleted: refresh()
    Timer { interval: root.round ? 15000 : 60000; running: root.app.daemonConnected; repeat: true; onTriggered: root.refresh() }

    Flow {
        Layout.fillWidth: true; spacing: 6
        ActionButton { objectName: "broadcastBack"; theme: app; compact: true; label: "Back"; hint: "⌫"; onClicked: root.back() }
        ActionButton { theme: app; compact: true; label: "TV channels"; hint: "b"; onClicked: root.closeRequested() }
        ActionButton { objectName: "broadcastRefresh"; theme: app; compact: true; label: "Refresh"; hint: "r"; enabled: !root.busy && app.clockNow >= root.retryAt; opacity: enabled ? 1 : 0.4; onClicked: root.refresh() }
        ActionButton { theme: app; compact: true; label: "Lichess"; hint: "L"; onClicked: root.external() }
    }
    Text { Layout.fillWidth: true; text: root.title; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.fg; font { pixelSize: 22; weight: Font.DemiBold } }
    Text { Layout.fillWidth: true; visible: !!root.tournament; text: root.tournament ? root.tournament.tour.name : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.muted; font.pixelSize: 12 }
    Text { Layout.fillWidth: true; text: root.busy ? "Loading…" : !app.daemonConnected ? "Disconnected — waiting to reconnect…" : root.error || (root.round ? "Boards update every 15 seconds · clocks show the last reported time" : "Live and recent broadcasts · j/k select · Enter open"); textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.error ? app.danger : app.muted; font.pixelSize: 12 }
    GridLayout {
        Layout.fillWidth: true; Layout.fillHeight: true
        columns: root.narrow || !root.selected ? 1 : 2; columnSpacing: 18; rowSpacing: 12
        Rectangle {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 220
            Layout.preferredWidth: root.selected ? 330 : 700
            Layout.preferredHeight: root.narrow && root.selected ? 220 : 430
            color: app.panel; radius: 12; border.color: app.line
            ListView {
                id: list
                objectName: "broadcastList"
                anchors { fill: parent; margins: 8 } clip: true; spacing: 4
                model: root.rows
                ScrollBar.vertical: ScrollBar {}
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: list.width; height: 62; radius: 8
                    color: index === root.index ? app.raised : "transparent"
                    Column {
                        anchors { fill: parent; margins: 9 } spacing: 5
                        Text { width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText; text: modelData.tour ? modelData.tour.name : modelData.name || "Game"; color: app.fg; font.pixelSize: 13 }
                        Text {
                            width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText; color: app.muted; font.pixelSize: 11
                            text: root.round ? (modelData.status && modelData.status !== "*" ? modelData.status : "In progress") : ((modelData.round || modelData).ongoing ? "Live · " : (modelData.round || modelData).finished ? "Finished · " : "Scheduled · ") + (modelData.round ? modelData.round.name : "Enter to view games")
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.open(parent.index) }
                }
                Text { anchors.centerIn: parent; width: parent.width - 20; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: !root.busy && !root.rows.length; text: root.error ? "Use Refresh to try again." : "No broadcasts or games available yet."; color: app.muted; font.pixelSize: 13 }
            }
        }
        ColumnLayout {
            visible: !!root.selected; Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 560; spacing: 8
            Repeater {
                model: root.selected ? [1] : []
                delegate: Text {
                    required property int modelData
                    readonly property var player: (root.selected.players || [])[modelData] || {}
                    Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
                    text: [player.title, player.name || "Black", player.rating, root.clock(player)].filter(v => v !== undefined && v !== "").join("  ")
                    color: app.fg; font.pixelSize: 14
                }
            }
            MiniBoard {
                objectName: "broadcastBoard"; app: root.app
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.max(120, Math.min(root.narrow ? root.width : root.width * 0.55, root.narrow ? root.viewportHeight * 0.6 : root.viewportHeight - 320, 540))
                Layout.preferredHeight: Layout.preferredWidth
                fen: root.selected ? root.selected.fen || "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" : ""
                lastMove: root.selected ? root.selected.lastMove || "" : ""; flipped: false
            }
            Text {
                readonly property var player: root.selected ? (root.selected.players || [])[0] || {} : ({})
                Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
                text: [player.title, player.name || "White", player.rating, root.clock(player)].filter(v => v !== undefined && v !== "").join("  ")
                color: app.fg; font.pixelSize: 14
            }
            Text { Layout.fillWidth: true; text: root.selected && root.selected.status !== "*" ? root.selected.status || "" : "In progress"; color: app.muted; font.pixelSize: 12 }
            Text {
                objectName: "broadcastMoves"; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
                text: root.historyError || root.moveText()
                color: root.historyError ? app.danger : app.muted; font { family: app.mono; pixelSize: 12 }
            }
            ActionButton { objectName: "broadcastAnalyse"; theme: app; label: "Open analysis copy"; hint: "o"; enabled: !!root.history; opacity: enabled ? 1 : 0.4; onClicked: root.analyse() }
        }
    }
}
