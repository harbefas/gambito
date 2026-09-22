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
    property string subscription: ""
    property bool liveConnected: false
    property string liveError: ""
    property string liveWarning: ""
    property double lastUpdate: 0
    property var liveGames: ({})
    property string gameFilter: "all"
    readonly property var games: round ? (round.games || []).map(g => liveGames[g.id] || g).concat(Object.keys(liveGames).filter(id => !(round.games || []).some(g => g.id === id)).map(id => liveGames[id])) : []
    readonly property var rows: round ? games.filter(g => gameFilter === "all" || gameState(g) === gameFilter) : tournament ? (tournament.rounds || []) : tournaments
    function gameState(game) {
        if (["1-0", "0-1", "1/2-1/2"].includes(game.status)) return "finished";
        if (game.state) return game.state;
        return game.lastMove ? "playing" : "waiting";
    }
    function statusText(game) {
        const value = gameState(game);
        return value === "finished" ? "Finished · " + game.status : value === "playing" ? "In progress" : "Awaiting first move";
    }
    function statusTone(game) { const value = gameState(game); return value === "playing" ? "live" : value === "finished" ? "muted" : "muted"; }
    function count(value) { return games.filter(g => gameState(g) === value).length; }
    function filter(value) { gameFilter = value; index = 0; }
    function follow() {
        if (!round || !app.daemonConnected) return;
        liveConnected = false; liveError = "";
        subscription = app.send("broadcast_watch", {round: round.round.id, quiet: true}) || "";
    }
    function stop() {
        subscription = ""; liveConnected = false;
        if (app.daemonConnected) app.send("broadcast_stop", {quiet: true});
    }
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
        if (liveGames[selected.id]) { history = liveGames[selected.id].history; return; }
        historyError = "";
        historyRequest = app.send("broadcast_game", {round: round.round.id, chapter: selected.id}) || "";
    }
    function open(i) {
        if (busy || i < 0 || i >= rows.length) return;
        index = i; error = "";
        if (round) { selected = rows[i]; history = selected.history || null; historyRequest = ""; moves(); }
        else if (tournament) request = app.send("broadcast_round", {id: rows[i].id}) || "";
        else request = app.send("broadcast_tournament", {id: rows[i].tour.id}) || "";
    }
    function back() {
        request = ""; historyRequest = ""; error = ""; historyError = ""; index = 0;
        if (round) { stop(); round = null; selected = null; history = null; liveGames = ({}); gameFilter = "all"; }
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
        else if (key === "r") { refresh(); if (round && !liveConnected) follow(); }
        else if (round && ["1", "2", "3", "4"].includes(key)) filter(["all", "playing", "finished", "waiting"][Number(key)-1]);
        else if (key === "a") analyse();
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
        function onBroadcastEvent(event) {
            if (!root.round || event.round !== root.round.round.id || event.subscription !== root.subscription) return;
            if (event.connected !== undefined) root.liveConnected = event.connected;
            root.liveError = event.error || "";
            if (event.warning) root.liveWarning = event.warning;
            if (event.game) {
                const focused = root.rows[root.index];
                const game = event.game;
                root.liveGames = Object.assign({}, root.liveGames, {[game.id]: game});
                root.lastUpdate = Date.now();
                if (root.selected && root.selected.id === game.id) {
                    root.selected = game; root.history = game.history; root.historyError = ""; root.historyRequest = "";
                }
                if (focused) {
                    const next = root.rows.findIndex(g => g.id === focused.id);
                    root.index = next >= 0 ? next : Math.max(0, Math.min(root.index, root.rows.length - 1));
                }
            }
        }
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
            else if (cmd === "broadcast_tournament") { const entering = !root.tournament || root.tournament.tour.id !== data.tour.id; root.tournament = data; if (entering) root.index = 0; }
            else if (cmd === "broadcast_round") {
                const entering = !root.round || root.round.round.id !== data.round.id;
                root.round = data;
                if (entering) { root.index = 0; root.selected = null; root.history = null; root.liveGames = ({}); root.gameFilter = "all"; root.lastUpdate = 0; root.liveWarning = ""; root.follow(); }
                if (root.selected) {
                    root.selected = root.games.find(g => g.id === root.selected.id) || null;
                    root.moves();
                }
            }
            root.index = Math.max(0, Math.min(root.index, root.rows.length - 1));
        }
        function onDaemonConnectedChanged() {
            root.request = ""; root.historyRequest = "";
            root.liveConnected = false; root.subscription = "";
            if (root.app.daemonConnected) { root.refresh(); root.follow(); }
        }
    }
    Component.onCompleted: refresh()
    Component.onDestruction: stop()
    Timer { interval: 60000; running: root.app.daemonConnected; repeat: true; onTriggered: root.refresh() }

    PageHeader {
        theme: root.app
        title: root.title
        subtitle: root.tournament ? root.tournament.tour.name : "Live tournament broadcast"
        secondaryLabel: "Refresh"
        secondaryHint: "r"
        primaryLabel: "Lichess"
        primaryHint: "L"
        onBackRequested: root.back()
        onSecondaryRequested: { root.refresh(); if (root.round && !root.liveConnected) root.follow(); }
        onPrimaryRequested: root.external()
    }
    Text { Layout.fillWidth: true; text: root.busy ? "Loading…" : !app.daemonConnected ? "Disconnected — waiting to reconnect…" : root.error || (root.round ? (root.liveError || (root.liveConnected ? "Live connection · moves update as received" : "Connecting to live broadcast…")) : "Live and recent broadcasts · j/k select · Enter open"); textFormat: Text.PlainText; wrapMode: Text.Wrap; color: root.error ? app.danger : app.muted; font.pixelSize: 12 }
    Text {
        Layout.fillWidth: true; visible: !!root.round; wrapMode: Text.Wrap
        text: root.count("playing") + " in progress · " + root.count("finished") + " finished · " + root.count("waiting") + " awaiting first move"
        color: app.fg; font.pixelSize: 13
    }
    Flow {
        visible: !!root.round; Layout.fillWidth: true; spacing: 6
        Repeater {
            model: [{value: "all", label: "All", key: "1"}, {value: "playing", label: "In progress", key: "2"}, {value: "finished", label: "Finished", key: "3"}, {value: "waiting", label: "Not started", key: "4"}]
            delegate: ActionButton {
                required property var modelData
                objectName: "broadcastFilter_" + modelData.value
                theme: app; compact: true; label: (root.gameFilter === modelData.value ? "● " : "") + modelData.label; hint: modelData.key
                onClicked: root.filter(modelData.value)
            }
        }
    }
    Text {
        Layout.fillWidth: true; visible: !!root.round; wrapMode: Text.Wrap
        text: (root.lastUpdate ? "Last update " + Math.max(0, Math.floor((app.clockNow - root.lastUpdate) / 1000)) + "s ago · " : "") + "Clocks show the last reported time; the event may delay its broadcast." + (root.liveWarning ? " " + root.liveWarning : "")
        color: app.muted; font.pixelSize: 11
    }
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
                        StatusBadge {
                            theme: root.app
                            label: root.round ? root.statusText(modelData) : ((modelData.round || modelData).ongoing ? "Live" : (modelData.round || modelData).finished ? "Finished" : "Scheduled")
                            tone: root.round ? root.statusTone(modelData) : ((modelData.round || modelData).ongoing ? "live" : "muted")
                        }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.open(parent.index) }
                }
                EmptyState {
                    anchors.centerIn: parent
                    visible: !root.busy && !root.rows.length
                    width: parent.width - 20
                    theme: root.app
                    title: root.error ? "Unable to load broadcasts" : root.round && root.games.length ? "No games match this filter" : "No broadcasts available"
                    detail: root.error ? "Try refreshing the feed." : root.round && root.games.length ? "Choose another status filter to see more games." : "Refresh to check for new tournaments."
                    action: "Refresh"
                    onActivated: root.refresh()
                }
            }
        }
        ColumnLayout {
            visible: !!root.selected; Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 560; Layout.topMargin: root.narrow ? 0 : -112; spacing: 8
            Repeater {
                model: root.selected ? [1] : []
                delegate: Text {
                    required property int modelData
                    readonly property var player: (root.selected.players || [])[modelData] || {}
                    Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
                    text: [player.title, player.name || "Black", player.rating, root.clock(player)].filter(v => v !== undefined && v !== null && v !== "").join("  ")
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
                text: [player.title, player.name || "White", player.rating, root.clock(player)].filter(v => v !== undefined && v !== null && v !== "").join("  ")
                color: app.fg; font.pixelSize: 14
            }
            Text { Layout.fillWidth: true; text: root.selected ? root.statusText(root.selected) : ""; color: app.muted; font.pixelSize: 12 }
            Text {
                objectName: "broadcastMoves"; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
                text: root.historyError || root.moveText()
                color: root.historyError ? app.danger : app.muted; font { family: app.mono; pixelSize: 12 }
            }
            ActionButton { objectName: "broadcastAnalyse"; theme: app; label: "Open analysis copy"; hint: "a"; enabled: !!root.history; opacity: enabled ? 1 : 0.4; onClicked: root.analyse() }
        }
    }
}
