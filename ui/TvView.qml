import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Lichess TV page, laid out like a game board: live board on the left; on the right a panel with the
// head-to-head score, channels and the shown game's moves. The game is streamed only for this page and
// never becomes a board game unless "Open on board" is used. Loaded only while shown.
RowLayout {
    id: tvView
    objectName: "tvView"
    required property var app
    required property Item focusScope
    anchors.fill: parent; spacing: app.zen ? 0 : 20

    // Standard chess channels: the move list needs the board's rules, which don't cover variants.
    readonly property var channelInfo: [
        ["best", "Top rated", "♛"], ["bullet", "Bullet", "➹"], ["blitz", "Blitz", "ϟ"], ["rapid", "Rapid", "◷"],
        ["classical", "Classical", "♜"], ["ultraBullet", "UltraBullet", "»"], ["bot", "Bot", "⚙"], ["computer", "Computer", "⌬"]
    ]
    property var channels: ({})
    property string channel: "best"
    property var crosstable: null
    // The TV game streamed for its moves (the daemon's watch, counted per viewer).
    property string watchedId: ""
    readonly property var game: watchedId ? app.games.find(g => g.id === watchedId) || null : null
    readonly property int index: channelInfo.findIndex(c => c[0] === channel)
    readonly property bool showScore: !!crosstable && board.streaming && crosstable.nbGames > 0

    function select(i) { channel = channelInfo[Math.max(0, Math.min(channelInfo.length - 1, i))][0]; crosstable = null; }
    // Opens the shown game on the main board, where the engine and analysis boards work.
    function analyse() {
        if (!board.streaming) { app.tell("Waiting for the TV game…", true); return; }
        app.watchOrientation[board.tv.id] = board.orientation;
        app.send("watch", {game: board.tv.id});
    }
    function follow(id) {
        if (id === watchedId) return;
        if (watchedId) app.send("unwatch", {game: watchedId, quiet: true});
        watchedId = id;
        // Quiet: the game streams for this panel only and must not open on the board.
        if (id) app.send("watch", {game: id, quiet: true});
    }

    Connections {
        target: tvView.app
        function onReplied(cmd, data, error) {
            if (cmd === "tv_channels" && data) tvView.channels = data.tv_channels;
            else if (cmd === "crosstable" && data) tvView.crosstable = data.crosstable;
        }
    }
    Timer { interval: 20000; repeat: true; running: true; triggeredOnStart: true; onTriggered: tvView.app.send("tv_channels") }
    Component.onCompleted: {
        app.viewKeys = (key, event) => {
            if (key === "j" || event.key === Qt.Key_Down) tvView.select(tvView.index + 1);
            else if (key === "k" || event.key === Qt.Key_Up) tvView.select(tvView.index - 1);
            else if (key === "o" || event.key === Qt.Key_Return) tvView.analyse();
            else if (key === "z") tvView.app.zen = !tvView.app.zen;
            else return false;
            return true;
        };
    }
    Component.onDestruction: {
        if (app.viewKeys) app.viewKeys = null;
        if (watchedId && app.daemonConnected) app.send("unwatch", {game: watchedId, quiet: true});
    }

    Item {
        Layout.fillWidth: true; Layout.fillHeight: true
        TvBoard {
            id: board
            objectName: "tvMainBoard"
            anchors.centerIn: parent
            app: tvView.app; channel: tvView.channel; textSize: 15
            // Two player rows (~30 px each) around the board.
            boardSize: Math.max(200, Math.min(parent.height - 64, parent.width))
            onActivated: tvView.analyse()
            // New featured game: follow its moves and ask for the players' head-to-head score.
            onTvChanged: {
                if (!tv || tv.id === tvView.watchedId) return;
                tvView.follow(tv.id);
                const names = tv.players.map(p => p.user ? p.user.name : "");
                if (names.length === 2 && names.every(n => n)) tvView.app.send("crosstable", {a: names[0], b: names[1]});
            }
        }
        // Leaves zen mode; the only control on screen while the panel is hidden.
        ActionButton { objectName: "tvZenExit"; visible: app.zen; anchors { right: parent.right; top: parent.top } theme: app; compact: true; icon: "⤡"; hint: "z"; onClicked: app.zen = false }
    }

    Rectangle {
        objectName: "tvSidebar"
        visible: !app.zen
        Layout.preferredWidth: 330; Layout.fillHeight: true; radius: 14
        color: app.panel; border.width: 1; border.color: app.line
        ColumnLayout {
            anchors { fill: parent; margins: 14 } spacing: 10
            RowLayout {
                Layout.fillWidth: true; spacing: 10
                ActionButton { objectName: "tvBack"; theme: app; compact: true; icon: "←"; hint: "g"; onClicked: app.view = "" }
                Column {
                    Layout.fillWidth: true; spacing: 1
                    Text { width: parent.width; elide: Text.ElideRight; text: "Lichess TV · " + tvView.channelInfo[tvView.index][1]; color: app.fg; font { pixelSize: 15; weight: Font.DemiBold } }
                    Text { width: parent.width; elide: Text.ElideRight; text: tvView.game ? [tvView.game.speed, tvView.game.rated ? "rated" : "casual", "move " + (Math.floor(tvView.game.san.length / 2) + 1)].filter(x => x).join(" · ") : "Live"; color: app.muted; font.pixelSize: 11 }
                }
                ActionButton { objectName: "tvZen"; theme: app; compact: true; icon: "⤢"; hint: "z"; onClicked: app.zen = true }
            }
            // Head-to-head score of the two players.
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 34; radius: 10; color: app.bg; border.width: 1; border.color: app.line
                visible: tvView.showScore
                // Leading score in green, trailing in red, ties neutral; names stay in text ink.
                RowLayout {
                    objectName: "tvCrosstable"
                    anchors { fill: parent; leftMargin: 10; rightMargin: 10 } spacing: 8
                    readonly property var names: board.tv ? board.tv.players.map(p => p.user ? p.user.name : "?") : ["", ""]
                    readonly property var points: tvView.crosstable && board.tv ? names.map(n => tvView.crosstable.users[n.toLowerCase()] || 0) : [0, 0]
                    function score(v) { return String(Math.floor(v)) + (v % 1 ? "½" : ""); }
                    function tint(i) { const a = points[i], b = points[1 - i]; return a > b ? app.winColor : a < b ? app.danger : app.fg; }
                    Text { Layout.fillWidth: true; Layout.preferredWidth: 1; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight; text: parent.names[0]; color: app.fg; font { family: app.mono; pixelSize: 12 } }
                    Text { objectName: "tvScore0"; text: parent.score(parent.points[0]); color: parent.tint(0); font { family: app.mono; pixelSize: 13; weight: Font.DemiBold } }
                    Text { text: "–"; color: app.muted; font { family: app.mono; pixelSize: 12 } }
                    Text { objectName: "tvScore1"; text: parent.score(parent.points[1]); color: parent.tint(1); font { family: app.mono; pixelSize: 13; weight: Font.DemiBold } }
                    Text { Layout.fillWidth: true; Layout.preferredWidth: 1; elide: Text.ElideRight; text: parent.names[1]; color: app.fg; font { family: app.mono; pixelSize: 12 } }
                }
            }
            // Channels, compact: one line each with the current player.
            Rectangle {
                Layout.fillWidth: true; implicitHeight: channelList.contentHeight + 12; radius: 10; color: app.bg; border.width: 1; border.color: app.line
                ListView {
                    id: channelList
                    objectName: "tvChannels"
                    anchors { fill: parent; margins: 6 } interactive: false; spacing: 1
                    model: tvView.channelInfo
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        readonly property var current: tvView.channels[modelData[0]]
                        readonly property bool active: modelData[0] === tvView.channel
                        objectName: "channel_" + modelData[0]
                        width: channelList.width; height: 26; radius: 6
                        color: active ? app.raised : channelMouse.containsMouse ? app.panel : "transparent"
                        RowLayout {
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 } spacing: 8
                            Text { Layout.preferredWidth: 16; horizontalAlignment: Text.AlignHCenter; text: modelData[2]; color: active ? app.fg : app.muted; font { family: "DejaVu Sans"; pixelSize: 13 } }
                            Text { Layout.preferredWidth: 84; text: modelData[1]; color: app.fg; font { pixelSize: 12; weight: active ? Font.DemiBold : Font.Normal } }
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight; color: app.muted; font.pixelSize: 11; text: !current ? "" : [current.user.title, current.user.name, current.rating].filter(x => x).join(" ") }
                        }
                        MouseArea { id: channelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tvView.select(parent.index) }
                    }
                }
            }
            // The shown game's moves, like the board's move list.
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 100; radius: 10; color: app.bg; border.width: 1; border.color: app.line
                ListView {
                    id: moveList
                    objectName: "tvMoves"
                    anchors { fill: parent; margins: 6 } clip: true
                    model: tvView.game ? Math.ceil(tvView.game.san.length / 2) : 0
                    onCountChanged: positionViewAtEnd()
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        id: moveRow
                        required property int index
                        width: moveList.width; height: 26; radius: 6
                        color: index % 2 ? "transparent" : app.alpha(app.fg, 0.035)
                        Row {
                            anchors { fill: parent; leftMargin: 8 } spacing: 4
                            Text { width: 34; anchors.verticalCenter: parent.verticalCenter; text: (moveRow.index + 1) + "."; color: app.faint; font { family: app.mono; pixelSize: 12 } }
                            Repeater {
                                model: 2
                                Text {
                                    required property int index
                                    readonly property int ply: moveRow.index * 2 + index
                                    readonly property bool last: !!tvView.game && ply === tvView.game.san.length - 1
                                    width: (moveRow.width - 50) / 2; anchors.verticalCenter: parent.verticalCenter
                                    text: tvView.game ? tvView.game.san[ply] || "" : ""
                                    color: app.fg; font { family: app.mono; pixelSize: 13; weight: last ? Font.DemiBold : Font.Normal }
                                }
                            }
                        }
                    }
                    Text { anchors.centerIn: parent; visible: moveList.count === 0; text: board.streaming ? "Loading moves…" : "Connecting…"; color: app.faint; font.pixelSize: 12 }
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                ActionButton { objectName: "tvAnalyse"; Layout.fillWidth: true; theme: app; compact: true; icon: "⤢"; label: "Open on board"; hint: "o"; enabled: board.streaming; opacity: enabled ? 1 : 0.4; onClicked: tvView.analyse() }
                ActionButton { theme: app; compact: true; icon: "↗"; enabled: board.streaming; opacity: enabled ? 1 : 0.4; onClicked: Qt.openUrlExternally("https://lichess.org/" + board.tv.id) }
            }
        }
    }
}
