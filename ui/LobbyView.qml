import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Lobby: play tiles and games in progress (history lives in ProfileView). Loaded only while no game is selected.
Flickable {
    id: lobby
    objectName: "lobbyView"
    required property var app
    // Window key-handling scope; board clicks give it focus back.
    required property Item focusScope

    // Daily puzzle: step indexes puzzle.fens; the solver plays even steps.
    property var puzzle: null
    property bool puzzleError: false
    property int step: 0
    property int pick: -1
    property string puzzleState: ""   // "" | "wrong" | "solved"
    property var blog: null
    property bool blogError: false
    readonly property string solverColor: puzzle && puzzle.fens[0].split(" ")[1] === "b" ? "black" : "white"
    readonly property bool puzzleTurn: !!puzzle && step < puzzle.solution.length && step % 2 === 0 && puzzleState !== "solved"
    readonly property string puzzleStatus: !puzzle ? "" : puzzleState === "solved" ? "Solved ✓" : puzzleState === "wrong" ? "Not the move. Try again." : step % 2 ? "Best move! Opponent replies…" : step > 0 ? "Best move! Keep going." : "Find the best move for " + (solverColor === "white" ? "White" : "Black") + "."

    function squareIndex(square) { return (8 - Number(square[1])) * 8 + square.charCodeAt(0) - 97; }
    function resetPuzzle() { step = 0; pick = -1; puzzleState = ""; }
    function puzzleClick(sq) {
        const piece = app.decodeFen(puzzle.fens[step])[sq] || "";
        const own = piece !== "" && (piece === piece.toUpperCase()) === (solverColor === "white");
        if (pick < 0 || own) { pick = own ? sq : -1; return; }
        const uci = app.square(pick) + app.square(sq);
        pick = -1;
        // Promotions: the solution's piece is played (no picker on the mini board).
        if (!puzzle.solution[step].startsWith(uci)) { puzzleState = "wrong"; return; }
        puzzleState = "";
        step++;
        if (step >= puzzle.solution.length) puzzleState = "solved";
        else reply.restart();
    }
    Timer { id: reply; interval: 450; onTriggered: { lobby.step++; if (lobby.step >= lobby.puzzle.solution.length) lobby.puzzleState = "solved"; } }

    Connections {
        target: lobby.app
        function onLobbyPuzzleKey(key) {
            if (!lobby.puzzle) return;
            if (key === "y" && lobby.step > 0) lobby.resetPuzzle();
            else if (key === "v" && lobby.puzzleTurn) lobby.pick = lobby.squareIndex(lobby.puzzle.solution[lobby.step].slice(0, 2));
            else if (key === "u") lobby.app.send("puzzle_open");
        }
        // The keyboard cursor scrolls the page too when the lists sit below the boards.
        function onListIndexChanged() { Qt.callLater(lobby.revealCursor); }
        function onOpenNews(index) { const item = news.model[index]; if (item) Qt.openUrlExternally(item.url); }
        function onReplied(cmd, data, error) {
            if (cmd === "puzzle") { if (data) lobby.puzzle = data.puzzle; else lobby.puzzleError = true; }
            else if (cmd === "blog") { if (data) lobby.blog = data.blog; else lobby.blogError = true; }
        }
    }
    function revealCursor() {
        const item = gameList.currentItem || news.currentItem;
        if (!item) return;
        const y = item.mapToItem(page, 0, 0).y;
        if (y < contentY) contentY = y;
        else if (y + item.height > contentY + height) contentY = Math.min(contentHeight - height, y + item.height - height);
    }
    Component.onCompleted: { app.send("puzzle"); app.send("blog"); }
    // Tiling window managers give any pane size: the page scrolls when it can't fit, and its sections reflow.
    // Everything sized here reads only the pane (width, height), never content heights: see the layout loop fix.
    clip: true; contentWidth: width; contentHeight: page.height
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { }

    readonly property bool iconTiles: width < 440
    readonly property bool compactTiles: !iconTiles && (width < 560 || height < 560)
    readonly property int tileColumns: iconTiles || width >= 860 || (compactTiles && width >= 640) ? 4 : 2
    readonly property int tileHeight: iconTiles || compactTiles ? 44 : 64
    readonly property real tilesHeight: Math.ceil(4 / tileColumns) * (tileHeight + 12) - 12
    readonly property real bannerHeight: !app.account && app.daemonConnected ? 72 + page.spacing : 0
    readonly property real gap: page.spacing
    // row: TV, puzzle and a side column; split: both boards, lists below; stack: one column.
    readonly property real sideWidth: Math.max(240, Math.min(320, width * 0.28))
    // Height left for a board beside the side column: the puzzle card needs 158 px around its board, or 196
    // when a board narrower than its three buttons wraps them onto a second row.
    readonly property real rowHeight: height - tilesHeight - bannerHeight - gap
    readonly property real rowBoard: Math.min(rowWidthBoard, rowHeight - 158 >= 350 ? rowHeight - 158 : rowHeight - 196)
    readonly property real rowWidthBoard: (width - sideWidth - 2 * 12 - 2 * 24) / 2
    // Wide but short panes keep the side column beside the boards and scroll, instead of leaving it empty.
    readonly property string mode: width >= 720 && (rowBoard >= 140 || rowWidthBoard >= 200) ? "row" : width >= 480 ? "split" : "stack"
    readonly property real boardSize: Math.floor(mode === "row" ? Math.min(rowWidthBoard, Math.max(rowBoard, 200))
                                               : mode === "split" ? Math.min(360, (width - 12) / 2 - 24) : Math.min(360, width - 24))

    ColumnLayout {
        id: page
        width: lobby.width
        // Fills the pane when the content fits, so the news list takes the remaining height.
        height: Math.max(lobby.height, implicitHeight)
        spacing: lobby.width < 560 || lobby.height < 560 ? 12 : 22

        GridLayout {
            id: tiles
            Layout.fillWidth: true
            columns: lobby.tileColumns; columnSpacing: 12; rowSpacing: 12
            Repeater {
                model: [
                    {id: "local", icon: "♟", title: "New local game", detail: "Two players, one board", hint: "n", enabled: true},
                    {id: "seek", icon: "⚡", title: "Find opponent", detail: !app.account ? "Connect Lichess to play" : "Real time or correspondence", hint: "s", enabled: !!app.account},
                    {id: "ai", icon: "⚙", title: "Play computer", detail: app.account ? "Stockfish, levels 1–8" : "Connect Lichess to play", hint: "c", enabled: !!app.account},
                    {id: "open", icon: "↗", title: "Open game", detail: "Paste a Lichess game ID", hint: ":open", enabled: true}
                ]
                Rectangle {
                    id: tile
                    required property var modelData
                    objectName: "tile_" + modelData.id
                    // Compact: vertical room goes to the TV and puzzle boards below.
                    Layout.fillWidth: true; Layout.preferredHeight: lobby.tileHeight; radius: 12
                    opacity: modelData.enabled ? 1 : 0.5
                    color: tileMouse.containsMouse && modelData.enabled ? app.raised : app.panel
                    border.width: 1; border.color: tileMouse.containsMouse && modelData.enabled ? app.mix(app.line, app.fg, 0.3) : app.line
                    scale: tileMouse.pressed && modelData.enabled ? 0.98 : 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 90 } }
                    Rectangle {
                        id: tileIcon
                        anchors { left: parent.left; leftMargin: lobby.iconTiles ? 6 : lobby.compactTiles ? 8 : 14; verticalCenter: parent.verticalCenter }
                        width: lobby.tileHeight === 64 ? 36 : 30; height: width; radius: 9; color: app.bg; border.width: 1; border.color: app.line
                        Text { anchors.centerIn: parent; text: tile.modelData.icon; color: app.fg; font { family: "DejaVu Sans"; pixelSize: 18 } }
                    }
                    Rectangle {
                        // Icon-only tiles have room for single-key hints; :open stays in the help.
                        visible: tile.modelData.hint !== "" && !(lobby.iconTiles && tile.modelData.hint.length > 1)
                        anchors { right: parent.right; rightMargin: lobby.iconTiles ? 6 : lobby.compactTiles ? 8 : 14; verticalCenter: parent.verticalCenter }
                        width: tileHint.implicitWidth + 12; height: 20; radius: 5; color: app.bg; border.width: 1; border.color: app.line
                        Text { id: tileHint; anchors.centerIn: parent; text: tile.modelData.hint; color: app.muted; font { pixelSize: 11; weight: Font.Medium } }
                    }
                    Column {
                        visible: !lobby.iconTiles
                        anchors { left: tileIcon.right; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: lobby.compactTiles ? 8 : 12; rightMargin: (lobby.compactTiles ? 8 : 14) + (tile.modelData.hint !== "" ? tile.modelData.hint.length * 7 + 18 : 0) }
                        spacing: 2
                        Text { width: parent.width; elide: Text.ElideRight; text: tile.modelData.title; color: app.fg; font { pixelSize: 14; weight: Font.DemiBold } }
                        Text { visible: !lobby.compactTiles; width: parent.width; elide: Text.ElideRight; text: tile.modelData.detail; color: app.muted; font.pixelSize: 12 }
                    }
                    MouseArea { id: tileMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.tileAction(tile.modelData.id) }
                }
            }
        }



        Rectangle {
            objectName: "lichessCard"
            visible: !app.account && app.daemonConnected
            Layout.fillWidth: true; implicitHeight: 72; radius: 12
            color: app.panel; border.width: 1; border.color: app.line
            RowLayout {
                anchors { fill: parent; leftMargin: 16; rightMargin: 16 } spacing: 14
                Rectangle {
                    width: 36; height: 36; radius: 9; color: app.bg; border.width: 1; border.color: app.line
                    Text { anchors.centerIn: parent; text: app.loggingIn ? "…" : "♞"; color: app.fg; font { family: "DejaVu Sans"; pixelSize: 18 } }
                }
                Column {
                    Layout.fillWidth: true; spacing: 3
                    Text { width: parent.width; elide: Text.ElideRight; text: app.loggingIn ? "Waiting for Lichess…" : "Play online"; color: app.fg; font { pixelSize: 14; weight: Font.DemiBold } }
                    Text { width: parent.width; elide: Text.ElideRight; text: app.loggingIn ? "Approve Gambito in the browser tab that just opened." : "Connect your Lichess account to seek opponents and play the computer."; color: app.muted; font.pixelSize: 12 }
                }
                ActionButton { visible: app.loggingIn && app.loginUrl !== ""; theme: app; label: "Open browser again"; hint: "b"; onClicked: Qt.openUrlExternally(app.loginUrl) }
                ActionButton { objectName: "cancelLoginButton"; visible: app.loggingIn; theme: app; label: "Cancel"; hint: "Esc"; onClicked: app.send("cancel_login") }
                ActionButton { objectName: "connectButton"; visible: !app.loggingIn; theme: app; kind: "primary"; icon: "↗"; label: "Connect Lichess"; hint: "l"; onClicked: app.send("login") }
            }
        }


        GridLayout {
            id: content
            Layout.fillWidth: true; Layout.fillHeight: lobby.mode === "row"
            columns: lobby.mode === "row" ? 3 : lobby.mode === "split" ? 2 : 1
            columnSpacing: 12; rowSpacing: 12

            // Lichess TV: streamed only while the lobby is loaded.
            Rectangle {
                objectName: "tvCard"
                // Fits its content instead of stretching to the row height.
                Layout.preferredWidth: lobby.boardSize + 24; Layout.alignment: Qt.AlignTop | Qt.AlignHCenter;
                Layout.row: lobby.mode === "stack" ? 2 : 0; Layout.column: 0; Layout.rowSpan: lobby.mode === "row" ? 2 : 1; implicitHeight: tvColumn.implicitHeight + 24; radius: 12
                color: app.panel; border.width: 1; border.color: app.line
                ColumnLayout {
                    id: tvColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 } spacing: 6
                    RowLayout {
                        Layout.preferredWidth: lobby.boardSize
                        Text { Layout.fillWidth: true; elide: Text.ElideRight; text: "Lichess TV"; color: app.fg; font { pixelSize: 13; weight: Font.DemiBold } }
                        // Key hint only when the card has room for it.
                        ActionButton { objectName: "tvChannelsButton"; theme: app; compact: true; label: "Channels"; hint: lobby.boardSize >= 220 ? "t" : ""; onClicked: lobby.app.view = "tv" }
                    }
                    // Streams the featured game while the lobby is loaded; click for the TV page.
                    TvBoard {
                        id: lobbyTv
                        objectName: "lobbyTv"
                        app: lobby.app; boardSize: lobby.boardSize
                        onActivated: lobby.app.view = "tv"
                    }
                }
            }


            // Daily puzzle, solved on the board: moves are checked against the Lichess solution.
            Rectangle {
                objectName: "puzzleCard"
                // Fits its content instead of stretching to the row height.
                Layout.preferredWidth: lobby.boardSize + 24; Layout.alignment: Qt.AlignTop | Qt.AlignHCenter;
                Layout.row: lobby.mode === "stack" ? 1 : 0; Layout.column: lobby.mode === "stack" ? 0 : 1; Layout.rowSpan: lobby.mode === "row" ? 2 : 1; implicitHeight: puzzleCardColumn.implicitHeight + 24; radius: 12
                color: app.panel; border.width: 1; border.color: app.line
                ColumnLayout {
                    id: puzzleCardColumn
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 } spacing: 6
                    RowLayout {
                        // Pinned to the card width so the rating can't end up outside a narrow card.
                        Layout.preferredWidth: lobby.boardSize
                        Text { Layout.fillWidth: true; elide: Text.ElideRight; text: "Puzzle of the day"; color: app.fg; font { pixelSize: 13; weight: Font.DemiBold } }
                        Text { visible: !!lobby.puzzle; text: lobby.puzzle ? lobby.puzzle.rating : ""; color: app.muted; font { family: app.mono; pixelSize: 12 } }
                    }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: lobby.puzzle ? lobby.puzzle.themes.slice(0, 3).map(t => t.replace(/([A-Z])/g, " $1").toLowerCase()).join(" · ") : ""
                        color: app.muted; font.pixelSize: 11
                    }
                    MiniBoard {
                        objectName: "puzzleBoard"
                        Layout.preferredWidth: lobby.boardSize; Layout.preferredHeight: lobby.boardSize
                        app: lobby.app; interactive: lobby.puzzleTurn
                        fen: lobby.puzzle ? lobby.puzzle.fens[lobby.step] : ""
                        flipped: lobby.solverColor === "black"
                        lastMove: !lobby.puzzle ? "" : lobby.step === 0 ? lobby.puzzle.last_move || "" : lobby.puzzle.solution[lobby.step - 1]
                        selected: lobby.pick
                        onSquareClicked: index => lobby.puzzleClick(index)
                        EmptyState {
                            anchors.fill: parent
                            visible: !lobby.puzzle
                            theme: lobby.app
                            title: lobby.puzzleError ? "Puzzle unavailable" : "Loading…"
                            detail: lobby.puzzleError ? "Try again later." : "Fetching today’s position…"
                        }
                    }
                    Text {
                        objectName: "puzzleStatus"
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: lobby.puzzleStatus
                        color: lobby.puzzleState === "wrong" ? app.danger : app.fg; font.pixelSize: 12
                    }
                    // Wraps onto a second line when the card is narrow (small tiled windows).
                    Flow {
                        Layout.preferredWidth: lobby.boardSize; spacing: 6; visible: !!lobby.puzzle
                        ActionButton { theme: app; compact: true; label: "Retry"; hint: "y"; visible: lobby.step > 0; onClicked: lobby.resetPuzzle() }
                        ActionButton { objectName: "puzzleHint"; theme: app; compact: true; label: "Show move"; hint: "v"; visible: lobby.puzzleTurn; onClicked: lobby.pick = lobby.squareIndex(lobby.puzzle.solution[lobby.step].slice(0, 2)) }
                        ActionButton { objectName: "puzzleThemesButton"; theme: app; compact: true; label: "Themes"; hint: "z"; onClicked: lobby.app.view = "puzzles" }
                        ActionButton { objectName: "puzzleOpenBoard"; theme: app; compact: true; icon: "⤢"; label: "Board"; hint: "u"; onClicked: lobby.app.send("puzzle_open") }
                    }
                }
            }


            ColumnLayout {
                objectName: "progressSection"
                Layout.row: lobby.mode === "row" ? 0 : lobby.mode === "split" ? 1 : 0
                Layout.column: lobby.mode === "row" ? 2 : 0
                Layout.columnSpan: lobby.mode === "split" ? 2 : 1
                Layout.preferredWidth: lobby.mode === "row" ? lobby.sideWidth : -1
                Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; spacing: 10
                RowLayout {
                    spacing: 8
                    Text { text: "In progress"; color: app.fg; font { pixelSize: 14; weight: Font.DemiBold } }
                    Text { text: gameList.count; color: app.muted; font { family: app.mono; pixelSize: 12 } }
                }
                ListView {
                    id: gameList
                    Layout.fillWidth: true; Layout.preferredHeight: Math.max(40, Math.min(count, 3) * 62); clip: true; spacing: 4
                    model: app.orderedGames; currentIndex: app.listIndex < count ? app.listIndex : -1
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    delegate: GameRow {
                        required property var modelData
                        width: gameList.width; app: lobby.app; game: modelData
                        selected: index === lobby.app.listIndex
                        onHovered: lobby.app.listIndex = index
                    }
                    EmptyState {
                        anchors.fill: parent
                        visible: gameList.count === 0
                        theme: lobby.app
                        title: "No games in progress"
                        detail: "History and analysis boards are in your profile."
                    }
                }
            }

            ColumnLayout {
                objectName: "newsSection"
                Layout.row: lobby.mode === "row" ? 1 : lobby.mode === "split" ? 2 : 3
                Layout.column: lobby.mode === "row" ? 2 : 0
                Layout.columnSpan: lobby.mode === "split" ? 2 : 1
                Layout.preferredWidth: lobby.mode === "row" ? lobby.sideWidth : -1
                Layout.fillWidth: true; Layout.fillHeight: lobby.mode === "row"; spacing: 10
                Text { text: "News"; color: app.fg; font { pixelSize: 14; weight: Font.DemiBold } }
                ListView {
                    id: news
                    objectName: "newsList"
                    Layout.fillWidth: true; Layout.fillHeight: lobby.mode === "row"; clip: true; spacing: 2
                    // Beside the boards it fills the column; stacked below them it shows a few posts and the page scrolls.
                    Layout.preferredHeight: lobby.mode === "row" ? -1 : Math.max(46, Math.min(count, 6) * 46)
                    model: lobby.blog ? lobby.blog.official.map(e => Object.assign({official: true}, e)).concat(lobby.blog.community) : []
                    // The keyboard cursor continues here after the games in progress.
                    currentIndex: Math.max(-1, app.listIndex - app.orderedGames.length)
                    onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                    onCountChanged: app.newsCount = count
                    Component.onDestruction: app.newsCount = 0
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        id: newsRow
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === news.currentIndex
                        width: news.width; height: 44; radius: 8
                        color: selected ? app.raised : "transparent"; border.width: selected ? 1 : 0; border.color: app.line
                        MouseArea { id: newsMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(newsMouse, mouse)) app.listIndex = app.orderedGames.length + newsRow.index; }; onClicked: Qt.openUrlExternally(parent.modelData.url) }
                        Column {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 8 } spacing: 2
                            Text { width: parent.width; elide: Text.ElideRight; text: modelData.title; color: app.fg; font { pixelSize: 13; weight: modelData.official ? Font.DemiBold : Font.Normal } }
                            Text {
                                width: parent.width; elide: Text.ElideRight; color: app.muted; font.pixelSize: 11
                                text: [modelData.official ? "Lichess" : modelData.author, modelData.published ? new Date(modelData.published).toLocaleDateString(Qt.locale(), "d MMM") : ""].filter(x => x).join(" · ")
                            }
                        }
                    }
                    EmptyState {
                        anchors.fill: parent
                        visible: news.count === 0
                        theme: lobby.app
                        title: lobby.blogError ? "News unavailable" : "Loading…"
                        detail: lobby.blogError ? "The news feed could not be reached." : "Fetching the latest chess news…"
                    }
                }
            }
        }
    }
}
