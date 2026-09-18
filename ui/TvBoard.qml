import QtQuick
import QtQuick.Layouts

// Live Lichess TV game: players with running clocks around a board. Streams its channel while loaded
// (one feed per window connection; the daemon closes it with tv_stop or the connection).
ColumnLayout {
    id: tvBoard
    required property var app
    property bool active: true
    property real boardSize: 240
    property string channel: ""          // "" = featured game, else a /api/tv/channels key
    property int textSize: 12
    signal activated()
    // Featured game plus clocks at the last event (at).
    property var tv: null
    property string orientation: "white"
    property double at: 0
    property bool failed: false
    readonly property bool streaming: !!tv
    spacing: 6

    function watch() { if (!active) return; tv = null; failed = false; app.tvOwner = tvBoard; app.send("tv_watch", channel ? {channel: channel} : {}); }
    onActiveChanged: {
        if (active) watch();
        else if (app.tvOwner === tvBoard) { app.tvOwner = null; app.send("tv_stop"); tv = null; }
    }
    onChannelChanged: watch()
    Component.onCompleted: watch()
    Component.onDestruction: if (app.tvOwner === tvBoard) { app.tvOwner = null; if (app.daemonConnected) app.send("tv_stop"); }

    Connections {
        target: tvBoard.app
        function onTvEvent(event, error) {
            if (!tvBoard.active || tvBoard.app.tvOwner !== tvBoard) return;
            if (error || !event) { tvBoard.failed = true; return; }
            const d = event.d;
            if (event.t === "featured") {
                const seconds = side => (d.players.find(p => p.color === side) || {}).seconds || 0;
                tvBoard.orientation = d.orientation;
                tvBoard.tv = {id: d.id, players: d.players, fen: d.fen, lm: "", wc: seconds("white"), bc: seconds("black")};
            } else if (event.t === "fen" && tvBoard.tv) tvBoard.tv = Object.assign({}, tvBoard.tv, {fen: d.fen, lm: d.lm, wc: d.wc, bc: d.bc});
            tvBoard.at = Date.now(); tvBoard.failed = false;
        }
    }

    Repeater { model: tvBoard.tv ? [tvBoard.orientation === "white" ? "black" : "white"] : []; delegate: player }
    MiniBoard {
        objectName: "tvBoard"
        Layout.preferredWidth: tvBoard.boardSize; Layout.preferredHeight: tvBoard.boardSize
        app: tvBoard.app; fen: tvBoard.tv ? tvBoard.tv.fen : ""; flipped: tvBoard.orientation === "black"; lastMove: tvBoard.tv ? tvBoard.tv.lm || "" : ""
        MouseArea { objectName: "tvOpen"; anchors.fill: parent; enabled: tvBoard.streaming; cursorShape: Qt.PointingHandCursor; onClicked: tvBoard.activated() }
        Text { anchors.centerIn: parent; visible: !tvBoard.tv; text: tvBoard.failed ? "TV unavailable" : "Connecting…"; color: tvBoard.app.muted; font.pixelSize: 12 }
    }
    Repeater { model: tvBoard.tv ? [tvBoard.orientation] : []; delegate: player }

    Component {
        id: player
        RowLayout {
            required property string modelData
            readonly property var info: tvBoard.tv.players.find(p => p.color === modelData) || {}
            readonly property bool toMove: tvBoard.tv.fen.split(" ")[1] === modelData[0]
            readonly property real seconds: Math.max(0, (modelData === "white" ? tvBoard.tv.wc : tvBoard.tv.bc) - (toMove ? (tvBoard.app.clockNow - tvBoard.at) / 1000 : 0))
            Layout.preferredWidth: tvBoard.boardSize; spacing: 6
            Text { visible: !!info.user && !!info.user.title; text: info.user && info.user.title ? info.user.title : ""; color: tvBoard.app.mistakeColor; font { pixelSize: tvBoard.textSize; weight: Font.DemiBold } }
            Text { elide: Text.ElideRight; Layout.maximumWidth: implicitWidth; Layout.minimumWidth: Math.min(implicitWidth, tvBoard.boardSize < 240 ? 60 : 160); Layout.fillWidth: true; text: (info.user ? info.user.name : info.ai ? "Stockfish level " + info.ai : "Anonymous") + (info.rating ? "  " + info.rating : ""); color: toMove ? tvBoard.app.fg : tvBoard.app.muted; font.pixelSize: tvBoard.textSize }
            // Pieces this player has captured and the material lead, like Lichess.
            Text {
                objectName: "tvCaptured_" + modelData
                readonly property var taken: tvBoard.app.captures(tvBoard.tv.fen)
                readonly property int lead: modelData === "white" ? taken.lead : -taken.lead
                // Small boards keep the name and clock; captures come back with room.
                visible: tvBoard.boardSize >= 220
                Layout.fillWidth: true; elide: Text.ElideRight
                text: taken[modelData] + (lead > 0 ? " +" + lead : "")
                color: tvBoard.app.muted; font { family: "DejaVu Sans"; pixelSize: tvBoard.textSize - 1 }
            }
            Text { text: Math.floor(seconds / 60) + ":" + String(Math.floor(seconds % 60)).padStart(2, "0"); color: toMove ? tvBoard.app.fg : tvBoard.app.muted; font { family: tvBoard.app.mono; pixelSize: tvBoard.textSize + (tvBoard.textSize > 12 ? 6 : 0); weight: toMove ? Font.DemiBold : Font.Normal } }
        }
    }
}
