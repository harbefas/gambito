import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Openings page: walk the opening tree from the Masters or Lichess database, with each continuation's
// position, name, popularity and results, plus example games. Loaded only while shown.
ColumnLayout {
    id: openings
    objectName: "openingsView"
    required property var app
    required property Item focusScope
    anchors.fill: parent; spacing: 12
    // In a narrow pane the current position stacks instead of overflowing.
    readonly property bool narrow: width < 560

    // The line walked so far, one step per move: {uci, san, name}.
    property var line: []
    property string db: "masters"
    property int speedAt: 0
    property int ratingAt: 0
    property string tab: "continuations"
    property int index: 0
    property var result: null       // latest explorer reply: {explorer, fen}
    property string error: ""
    property string request: ""
    readonly property var speedOptions: [["All speeds", null], ["Bullet", ["bullet"]], ["Blitz", ["blitz"]], ["Rapid", ["rapid"]], ["Classical", ["classical"]]]
    readonly property var ratingOptions: [["All ratings", null], ["1000–1600", [1000, 1200, 1400, 1600]], ["1600–2000", [1600, 1800, 2000]], ["2000+", [2000, 2200, 2500]]]
    readonly property var book: result ? result.explorer : null
    readonly property real total: book ? book.white + book.draws + book.black : 0
    readonly property var continuations: book ? book.moves.map(m => Object.assign({games: m.white + m.draws + m.black}, m)) : []
    readonly property var examples: book ? (book.topGames || []).concat(book.recentGames || []) : []
    readonly property var currentList: tab === "continuations" ? continuations : examples
    readonly property string name: book && book.opening ? book.opening.name : line.length ? line[line.length - 1].name : "Starting position"
    readonly property string eco: book && book.opening ? book.opening.eco : ""

    function load() {
        result = null; error = ""; index = 0;
        const query = {line: line.map(s => s.uci), db: db, games: true};
        if (db === "lichess") {
            if (speedOptions[speedAt][1]) query.speeds = speedOptions[speedAt][1];
            if (ratingOptions[ratingAt][1]) query.ratings = ratingOptions[ratingAt][1];
        }
        request = app.send("explorer", query) || "";
    }
    function play(i) {
        const m = continuations[i];
        if (!m) return;
        line = line.concat([{uci: m.uci, san: m.san, name: m.opening ? m.opening.name : name}]);
        tab = "continuations";
        load();
    }
    function back() { if (line.length) { line = line.slice(0, -1); load(); } else app.view = ""; }
    function toStart() { line = []; load(); }
    function cycleSpeed() { speedAt = (speedAt + 1) % speedOptions.length; load(); }
    function cycleRating() { ratingAt = (ratingAt + 1) % ratingOptions.length; load(); }
    function analyse() { app.send("analyse", {line: line.map(s => s.uci)}); }
    function openExample(i) {
        const g = examples[i];
        if (!g) return;
        // Masters games live on the explorer host (PGN → analysis board); Lichess games are watched.
        if (db === "masters") app.send("analyse", {master: g.id});
        else app.send("watch", {game: g.id});
    }
    function percent(part, whole) { return whole ? Math.round(100 * part / whole) : 0; }
    function count(n) { return n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? Math.round(n / 1e3) + "k" : String(n); }
    function lineText() {
        if (!line.length) return "Starting position";
        return line.map((s, i) => (i % 2 ? "" : (i / 2 + 1) + ". ") + s.san).join(" ");
    }

    onDbChanged: load()
    Connections {
        target: openings.app
        function onReplied(cmd, data, error) {
            if (cmd !== "explorer:" + openings.request) return;
            openings.result = data;
            openings.error = data ? "" : error;
        }
    }
    Component.onCompleted: {
        app.viewKeys = (key, event) => {
            const columns = Math.max(1, grid.columns);
            const last = openings.currentList.length - 1;
            if (key === "1") { openings.tab = "continuations"; openings.index = 0; }
            else if (key === "2") { openings.tab = "examples"; openings.index = 0; }
            else if (key === "m") openings.db = openings.db === "masters" ? "lichess" : "masters";
            else if (key === "a") openings.analyse();
            else if (key === "s" && openings.db === "lichess") openings.cycleSpeed();
            else if (key === "r" && openings.db === "lichess") openings.cycleRating();
            else if (event.key === Qt.Key_Home && openings.line.length) openings.toStart();
            else if (event.key === Qt.Key_Backspace) openings.back();
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { if (openings.tab === "continuations") openings.play(openings.index); else openings.openExample(openings.index); }
            else if (key === "l" || event.key === Qt.Key_Right) openings.index = Math.min(last, openings.index + 1);
            else if (key === "h" || event.key === Qt.Key_Left) openings.index = Math.max(0, openings.index - 1);
            else if (key === "j" || event.key === Qt.Key_Down) openings.index = Math.min(last, openings.index + (openings.tab === "continuations" ? columns : 1));
            else if (key === "k" || event.key === Qt.Key_Up) openings.index = Math.max(0, openings.index - (openings.tab === "continuations" ? columns : 1));
            else return false;
            return true;
        };
        load();
    }
    Component.onDestruction: if (app.viewKeys) app.viewKeys = null

    RowLayout {
        Layout.fillWidth: true; spacing: 10
        ActionButton { objectName: "openingsBack"; theme: app; compact: true; icon: "←"; label: "Back"; hint: "⌫"; onClicked: app.navigateBack() }
        Text { text: "Openings"; color: app.fg; font { pixelSize: 18; weight: Font.DemiBold } }
        Item { Layout.fillWidth: true }
        Repeater {
            model: [["masters", "Masters"], ["lichess", "Lichess"]]
            ActionButton {
                required property var modelData
                objectName: "openingsDb_" + modelData[0]
                theme: app; compact: true; label: modelData[1]; hint: modelData[0] === openings.db ? "" : "m"
                kind: openings.db === modelData[0] ? "primary" : "normal"
                onClicked: openings.db = modelData[0]
            }
        }
        // Lichess database filters; they cycle through their options and refetch.
        ActionButton { objectName: "openingsSpeed"; visible: openings.db === "lichess"; theme: app; compact: true; label: openings.speedOptions[openings.speedAt][0] + " ▾"; hint: "s"; onClicked: openings.cycleSpeed() }
        ActionButton { objectName: "openingsRating"; visible: openings.db === "lichess"; theme: app; compact: true; label: openings.ratingOptions[openings.ratingAt][0] + " ▾"; hint: "r"; onClicked: openings.cycleRating() }
    }

    // Current position: board, name, totals and results.
    Rectangle {
        objectName: "openingsCurrent"
        Layout.fillWidth: true; implicitHeight: currentRow.implicitHeight + 24; radius: 12
        color: app.panel; border.width: 1; border.color: app.line
        GridLayout {
            id: currentRow
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            columns: openings.narrow ? 1 : 2; columnSpacing: 16; rowSpacing: 10
            MiniBoard {
                Layout.preferredWidth: 150; Layout.preferredHeight: 150
                app: openings.app; fen: openings.result ? openings.result.fen : "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
                lastMove: openings.line.length ? openings.line[openings.line.length - 1].uci : ""
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 6
                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: openings.name; color: app.fg; font { pixelSize: 22; weight: Font.DemiBold } }
                Text { Layout.fillWidth: true; elide: Text.ElideRight; visible: openings.line.length > 0 || openings.eco !== ""
                    text: [openings.eco, openings.line.length ? openings.lineText() : ""].filter(x => x).join("  ·  "); color: app.muted; font { family: app.mono; pixelSize: 12 } }
                Text {
                    text: openings.book ? openings.count(openings.total) + " games" + (openings.total ? "" : " from this position") : openings.error || "Loading…"
                    color: openings.error && !openings.book ? app.danger : app.muted; font.pixelSize: 12
                }
                ResultBar { Layout.fillWidth: true; Layout.preferredHeight: 18; visible: openings.total > 0; stats: openings.book; theme: app }
                Flow {
                    Layout.fillWidth: true; spacing: 6
                    ActionButton { objectName: "openingsUndo"; theme: app; compact: true; icon: "‹"; label: "Back"; hint: "⌫"; enabled: openings.line.length > 0; opacity: enabled ? 1 : 0.4; onClicked: app.navigateBack() }
                    ActionButton { theme: app; compact: true; label: "Start"; hint: "Home"; enabled: openings.line.length > 0; opacity: enabled ? 1 : 0.4; onClicked: openings.toStart() }
                    ActionButton { objectName: "openingsAnalyse"; theme: app; compact: true; icon: "⤢"; label: "Analyse"; hint: "a"; onClicked: openings.analyse() }
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true; spacing: 6
        ActionButton { objectName: "openingsTabMoves"; theme: app; compact: true; label: "Popular continuations"; hint: "1"; kind: openings.tab === "continuations" ? "primary" : "normal"; onClicked: { openings.tab = "continuations"; openings.index = 0; } }
        ActionButton { objectName: "openingsTabGames"; theme: app; compact: true; label: "Example games"; hint: "2"; kind: openings.tab === "examples" ? "primary" : "normal"; onClicked: { openings.tab = "examples"; openings.index = 0; } }
    }

    GridView {
        id: grid
        objectName: "openingsGrid"
        visible: openings.tab === "continuations"
        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
        readonly property int columns: Math.max(1, Math.floor(width / 240))
        // Square boards: card = header (44) + board (cellWidth - 48) + bottom margin, inside 6 px cell margins.
        // Never zero: a hidden GridView gets no width from the layout, and zero-size cells crash it.
        cellWidth: Math.max(160, Math.floor(width / columns)); cellHeight: cellWidth + 16
        model: openings.continuations
        currentIndex: openings.index
        ScrollBar.vertical: ScrollBar { }
        delegate: Item {
            id: cell
            required property var modelData
            required property int index
            width: grid.cellWidth; height: grid.cellHeight
            readonly property bool selected: index === openings.index
            Rectangle {
                objectName: "continuation" + cell.index
                anchors { fill: parent; margins: 6 } radius: 10
                color: cellMouse.containsMouse || cell.selected ? app.raised : app.panel
                border.width: 1; border.color: cell.selected ? app.mix(app.line, app.fg, 0.35) : app.line
                // Popularity strip across the top, like Lichess.
                Rectangle {
                    anchors { left: parent.left; top: parent.top; margins: 1 }
                    width: Math.max(26, (parent.width - 2) * cell.modelData.games / Math.max(1, openings.total)); height: 16; radius: 9
                    color: app.mix(app.panel, app.accent, 0.55)
                    Text { anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter } text: openings.percent(cell.modelData.games, openings.total) + "%"; color: app.fg; font { family: app.mono; pixelSize: 10 } }
                }
                RowLayout {
                    anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 10; rightMargin: 10; topMargin: 18 }
                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: cell.modelData.opening ? cell.modelData.opening.name : openings.name; color: app.fg; font.pixelSize: 13 }
                    Text { text: cell.modelData.san; color: app.fg; font { family: app.mono; pixelSize: 18; weight: Font.DemiBold } }
                }
                RowLayout {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; top: parent.top; margins: 8; topMargin: 44 } spacing: 6
                    // Vertical results: black on top, white at the bottom.
                    ResultBar { Layout.preferredWidth: 14; Layout.fillHeight: true; vertical: true; stats: cell.modelData; theme: app }
                    MiniBoard {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        app: openings.app; fen: cell.modelData.fen || ""; lastMove: cell.modelData.uci
                    }
                }
                MouseArea { id: cellMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(cellMouse, mouse)) openings.index = cell.index; } onClicked: openings.play(cell.index) }
            }
        }
        Text { anchors.centerIn: parent; visible: grid.count === 0 && !!openings.book; text: "No continuations in this database"; color: app.muted; font.pixelSize: 13 }
    }

    ListView {
        id: games
        objectName: "openingsGames"
        visible: openings.tab === "examples"
        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
        model: openings.examples
        currentIndex: openings.index
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        ScrollBar.vertical: ScrollBar { }
        delegate: Rectangle {
            id: gameRow
            required property var modelData
            required property int index
            width: games.width; height: 46; radius: 9
            color: index === openings.index ? app.raised : "transparent"; border.width: index === openings.index ? 1 : 0; border.color: app.line
            MouseArea { id: exampleMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(exampleMouse, mouse)) openings.index = gameRow.index; } onClicked: openings.openExample(gameRow.index) }
            RowLayout {
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 } spacing: 12
                Text {
                    Layout.preferredWidth: 34; horizontalAlignment: Text.AlignHCenter
                    text: gameRow.modelData.winner === "white" ? "1-0" : gameRow.modelData.winner === "black" ? "0-1" : "½-½"
                    color: app.fg; font { family: app.mono; pixelSize: 12; weight: Font.DemiBold }
                }
                Text {
                    Layout.fillWidth: true; elide: Text.ElideRight; color: app.fg; font.pixelSize: 13
                    text: gameRow.modelData.white.name + " (" + gameRow.modelData.white.rating + ")  –  " + gameRow.modelData.black.name + " (" + gameRow.modelData.black.rating + ")"
                }
                Text { text: [gameRow.modelData.year, gameRow.modelData.speed].filter(x => x).join(" · "); color: app.muted; font.pixelSize: 11 }
            }
        }
        Text { anchors.centerIn: parent; visible: games.count === 0 && !!openings.book; text: "No example games for this position"; color: app.muted; font.pixelSize: 13 }
    }
}
