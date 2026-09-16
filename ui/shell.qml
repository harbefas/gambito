import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property var games: []
    property var account: null
    property string connection: "offline"
    property bool seeking: false
    property string selectedId: Quickshell.env("GAMBITO_GAME") || ""
    property var game: games.find(g => g.id === selectedId) || null
    property string message: ""
    property bool messageError: false
    property bool flipped: false
    property bool manualFlip: false
    property bool helpVisible: false
    property int cursor: 52
    property int origin: -1
    property int listIndex: 0
    property int serial: 0
    property var pending: ({})
    property string confirmation: ""
    property double clockNow: Date.now()
    property var board: decodeFen(game ? game.fen : "")
    readonly property color bg: "#121719"
    readonly property color panel: "#1b2225"
    readonly property color fg: "#e6e3db"
    readonly property color muted: "#96a4a5"
    readonly property color accent: "#c5dc9c"

    function decodeFen(fen) {
        let result = [];
        for (const c of fen.split(" ")[0]) {
            if (c === "/") continue;
            if (c >= "1" && c <= "8") for (let n = 0; n < Number(c); n++) result.push("");
            else result.push(c);
        }
        return result;
    }
    function square(index) { return "abcdefgh"[index % 8] + (8 - Math.floor(index / 8)); }
    function canonical(index) { return flipped ? 63 - index : index; }
    function glyph(piece) {
        const set = { k:"♚", q:"♛", r:"♜", b:"♝", n:"♞", p:"♟" };
        return set[(piece || "").toLowerCase()] || "";
    }
    function tell(text, error) { message = text; messageError = !!error; }
    function send(cmd, data) {
        if (!socket.connected) { tell("Daemon desconectado; tentando reconectar…", true); return; }
        const id = String(++serial);
        const request = Object.assign({cmd:cmd, game:selectedId, request_id:id}, data || {});
        pending[id] = cmd;
        socket.write(JSON.stringify(request) + "\n"); socket.flush();
    }
    function choose(id) {
        selectedId = id; origin = -1; confirmation = ""; manualFlip = false;
        const g = games.find(g => g.id === id);
        flipped = !!g && g.color === "black";
        cursor = flipped ? 11 : 52;
        boardFocus.forceActiveFocus();
    }
    function receive(line) {
        try {
            const e = JSON.parse(line);
            if (e.type === "state") {
                games = e.games; account = e.account; connection = e.connection; seeking = e.seeking;
                if (game && !manualFlip) flipped = game.color === "black";
                if (origin >= 0 && !board[origin]) origin = -1;
            } else if (e.type === "notice") tell(e.message, true);
            else if (e.type === "reply") {
                const cmd = pending[e.request_id]; delete pending[e.request_id];
                if (!e.ok) { tell(e.error, true); return; }
                if (e.data && e.data.game) choose(e.data.game);
                if (typeof e.data === "string") tell(e.data, false);
                else if (cmd === "local") tell("Partida local criada. Pressione i para digitar um lance.", false);
            }
        } catch (err) { tell("Resposta inválida do daemon: " + err, true); }
    }
    function selectSquare(displayIndex) {
        if (!game) return;
        const index = canonical(displayIndex);
        cursor = displayIndex;
        if (origin < 0) {
            const p = board[index];
            if (!p) return;
            const side = p === p.toUpperCase() ? "white" : "black";
            if (side !== game.turn) { tell("Selecione uma peça de quem está na vez.", true); return; }
            origin = index;
        } else if (origin === index) origin = -1;
        else {
            const uci = square(origin) + square(index);
            const choices = (game.legal || []).filter(m => m.startsWith(uci));
            if (choices.length > 1) {
                command.text = uci; command.forceActiveFocus(); command.cursorPosition = command.text.length;
                tell("Promoção: acrescente q, r, b ou n e pressione Enter.", false);
            } else send("move", {notation:uci});
            origin = -1;
        }
    }
    function runCommand(text) {
        text = text.trim(); if (!text) return;
        if (!text.startsWith(":")) { send("move", {notation:text}); return; }
        const words = text.slice(1).split(/\s+/); const cmd = words.shift();
        switch (cmd) {
        case "local": send("local"); break;
        case "games": selectedId = ""; break;
        case "open": send("open", {game:words[0] || ""}); break;
        case "seek":
            if (!/^\d+$/.test(words[0] || "") || (words[1] && !/^\d+$/.test(words[1])) || (words[2] && !["rated", "casual"].includes(words[2]))) { tell("Use :seek 10 5 casual (ou rated)", true); break; }
            send("seek", {minutes:Number(words[0]), increment:Number(words[1] || 0), rated:words[2] === "rated"}); break;
        case "cancel": send("cancel"); break;
        case "ai": send("ai", {level:Number(words[0] || 1)}); break;
        case "resign": case "draw":
            if (!game) { tell("Abra uma partida primeiro.", true); break; }
            confirmation = cmd; tell(cmd === "resign" ? "Desistir desta partida? Digite :confirm ou pressione Esc." : "Oferecer/aceitar empate? Digite :confirm ou pressione Esc.", false); break;
        case "confirm": if (confirmation) { send(confirmation); confirmation = ""; } break;
        case "flip": flipped = !flipped; manualFlip = true; break;
        case "window": newWindow(); break;
        case "help": helpVisible = !helpVisible; break;
        case "quit": Qt.quit(); break;
        default: tell("Comando desconhecido. Use :help.", true);
        }
    }
    function newWindow() {
        if (launcher.running) return;
        launcher.command = [Quickshell.env("GAMBITO_BIN") || "gambito", "open"].concat(selectedId ? [selectedId] : []);
        launcher.running = true;
    }
    function clock(side) {
        if (!game) return "—";
        let ms = side === "white" ? game.white_ms : game.black_ms;
        if (ms === null || ms === undefined) return "sem relógio";
        // Server values remain authoritative. Never extrapolate a disconnected clock.
        if (game.status === "started" && game.moves.length >= 2 && game.turn === side && game.connected)
            ms = Math.max(0, ms - Math.max(0, clockNow - game.updated_ms));
        const secs = Math.ceil(ms / 1000);
        return Math.floor(secs / 60) + ":" + String(secs % 60).padStart(2, "0");
    }
    function statusText() {
        if (!game) return "";
        if (game.status !== "started" && game.status !== "created") {
            const labels = {mate:"Xeque-mate", resign:"Desistência", draw:"Empate", stalemate:"Afogamento", outoftime:"Tempo esgotado", timeout:"Tempo esgotado", aborted:"Partida abortada", cheat:"Partida encerrada", noStart:"Partida não iniciada"};
            return (labels[game.status] || game.status) + (game.winner ? " · " + (game.winner === "white" ? "brancas" : "pretas") + " vencem" : "");
        }
        if (game.online && !game.connected) return "Reconectando · relógios pausados na tela";
        if (game.pending) return "Aguardando confirmação do Lichess…";
        const turn = game.turn === "white" ? "Brancas" : "Pretas";
        return turn + " jogam" + (game.check ? " · xeque" : "") + (game.color === game.turn ? " · sua vez" : "") + (game.draw_offer ? " · oferta de empate" : "");
    }

    Socket {
        id: socket
        path: Quickshell.env("GAMBITO_SOCKET") || (Quickshell.env("XDG_RUNTIME_DIR") + "/gambito/socket")
        connected: true
        parser: SplitParser { onRead: data => root.receive(data) }
        onConnectionStateChanged: { if (connected) root.tell("", false); }
    }
    Timer { interval: 1500; repeat: true; running: !socket.connected; onTriggered: socket.connected = true }
    Timer { interval: 200; repeat: true; running: true; onTriggered: root.clockNow = Date.now() }
    Process { id: launcher }

    FloatingWindow {
        id: window
        title: "Gambito" + (root.game ? " · " + root.game.white + " × " + root.game.black : "")
        visible: true
        implicitWidth: 1040
        implicitHeight: 780
        minimumSize: Qt.size(720, 570)
        color: root.bg

        ColumnLayout {
            id: pageLayout
            anchors.fill: parent; anchors.margins: 28; spacing: 18
            RowLayout {
                Layout.fillWidth: true
                Text { text: "gambito"; color: root.fg; font { family: "monospace"; pixelSize: 24; weight: Font.DemiBold; letterSpacing: -1 } }
                Text { text: " / " + (root.game ? (root.game.online ? "lichess" : "local") : "partidas"); color: root.muted; font.pixelSize: 15 }
                Item { Layout.fillWidth: true }
                Rectangle { width: 7; height: 7; radius: 4; color: !socket.connected ? "#df8f83" : root.connection === "online" ? root.accent : root.muted }
                Text { text: !socket.connected ? "daemon desconectado" : root.account ? root.account.username + " · " + root.connection : "modo local"; color: root.muted; font { family: "monospace"; pixelSize: 12 } }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: "#30393b" }

            FocusScope {
                id: boardFocus
                Layout.fillWidth: true; Layout.fillHeight: true
                focus: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { root.origin = -1; root.confirmation = ""; root.helpVisible = false; root.tell("", false); event.accepted = true; return; }
                    if (root.helpVisible) { event.accepted = true; return; }
                    const key = event.text;
                    if (key === "i" || key === ":") { command.text = key === ":" ? ":" : ""; command.forceActiveFocus(); command.cursorPosition = command.text.length; }
                    else if (key === "?") root.helpVisible = true;
                    else if (key === "g") root.selectedId = "";
                    else if (key === "n") root.send("local");
                    else if (key === "w") root.newWindow();
                    else if (key === "f") { root.flipped = !root.flipped; root.manualFlip = true; }
                    else if (key === "q") Qt.quit();
                    else if (!root.game) {
                        if (key === "j" || event.key === Qt.Key_Down) root.listIndex = Math.min(root.games.length - 1, root.listIndex + 1);
                        else if (key === "k" || event.key === Qt.Key_Up) root.listIndex = Math.max(0, root.listIndex - 1);
                        else if (event.key === Qt.Key_Return && root.games.length) root.choose(root.games[Math.max(0,root.listIndex)].id);
                        else return;
                    } else if (key === "h" || event.key === Qt.Key_Left) root.cursor = Math.max(0, root.cursor - 1);
                    else if (key === "l" || event.key === Qt.Key_Right) root.cursor = Math.min(63, root.cursor + 1);
                    else if (key === "k" || event.key === Qt.Key_Up) root.cursor = Math.max(0, root.cursor - 8);
                    else if (key === "j" || event.key === Qt.Key_Down) root.cursor = Math.min(63, root.cursor + 8);
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) root.selectSquare(root.cursor);
                    else return;
                    event.accepted = true;
                }

                ColumnLayout {
                    anchors.fill: parent; spacing: 20
                    visible: !root.game
                    RowLayout {
                        Text { text: "Suas partidas"; color: root.fg; font.pixelSize: 26 }
                        Item { Layout.fillWidth: true }
                        Text { text: "n  nova local     :seek 10 5 casual"; color: root.accent; font { family: "monospace"; pixelSize: 12 } }
                    }
                    Text { visible: root.seeking; text: "Buscando adversário…  :cancel para cancelar"; color: root.accent; font.pixelSize: 15 }
                    ListView {
                        id: gameList
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                        model: root.games; currentIndex: root.listIndex
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            width: gameList.width; height: 76; radius: 5
                            color: index === root.listIndex ? "#263136" : root.panel
                            border.width: index === root.listIndex ? 1 : 0; border.color: "#718365"
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 16; spacing: 18
                                Text { text: modelData.online ? "↗" : "○"; color: root.accent; font.pixelSize: 24 }
                                ColumnLayout { spacing: 5
                                    Text { text: modelData.white + "  ×  " + modelData.black; color: root.fg; font.pixelSize: 16 }
                                    Text { text: modelData.id + " · " + modelData.status; color: root.muted; font { family: "monospace"; pixelSize: 11 } }
                                }
                                Item { Layout.fillWidth: true }
                                Text { text: modelData.status === "started" && modelData.color === modelData.turn ? "SUA VEZ" : "↵"; color: root.accent; font { family: "monospace"; pixelSize: 12 } }
                            }
                            MouseArea { anchors.fill: parent; onClicked: root.choose(modelData.id) }
                        }
                        Text { anchors.centerIn: parent; visible: root.games.length === 0; text: "Um tabuleiro, sem distrações.\n\nPressione n para começar uma partida local.\nPara conectar ao Lichess: gambito auth no terminal."; color: root.muted; horizontalAlignment: Text.AlignHCenter; lineHeight: 1.5; font.pixelSize: 16 }
                    }
                }

                RowLayout {
                    anchors.fill: parent; spacing: 26; visible: !!root.game
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 12
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.game ? (root.flipped ? root.game.white : root.game.black) : ""; color: root.fg; font.pixelSize: 16 }
                            Text { text: root.clock(root.flipped ? "white" : "black"); color: root.accent; font { family: "monospace"; pixelSize: 25 } }
                        }
                        Item {
                            id: boardArea
                            Layout.fillWidth: true; Layout.fillHeight: true
                            Grid {
                                id: grid
                                anchors.centerIn: parent
                                width: Math.floor(Math.min(parent.width, parent.height) / 8) * 8
                                height: width; columns: 8
                                Repeater {
                                    model: 64
                                    Rectangle {
                                        id: cell
                                        required property int index
                                        property int sq: root.canonical(index)
                                        property string piece: root.board[sq] || ""
                                        property bool light: (Math.floor(index / 8) + index % 8) % 2 === 0
                                        property bool lastMove: !!root.game && root.game.moves.length > 0 && (root.game.moves[root.game.moves.length-1].slice(0,2) === root.square(sq) || root.game.moves[root.game.moves.length-1].slice(2,4) === root.square(sq))
                                        width: grid.width / 8; height: width
                                        color: root.origin === sq ? "#bdcb79" : lastMove ? (light ? "#c6c99d" : "#8b9b70") : light ? "#ddd6c3" : "#778a80"
                                        Text { anchors.centerIn: parent; anchors.verticalCenterOffset: -1; text: root.glyph(cell.piece); color: cell.piece === cell.piece.toUpperCase() ? "#fffcf0" : "#20282b"; style: Text.Outline; styleColor: "#33413d"; font { family: "DejaVu Sans"; pixelSize: cell.width * 0.76 } }
                                        Text { anchors { left: parent.left; top: parent.top; margins: 4 } visible: cell.index % 8 === 0; text: root.square(cell.sq)[1]; color: "#384a42"; font { pixelSize: 10; bold: true } }
                                        Text { anchors { right: parent.right; bottom: parent.bottom; margins: 4 } visible: cell.index >= 56; text: root.square(cell.sq)[0]; color: "#384a42"; font { pixelSize: 10; bold: true } }
                                        Rectangle { anchors.fill: parent; anchors.margins: 2; color: "transparent"; border.width: 3; border.color: "#f5cc79"; visible: root.cursor === cell.index && boardFocus.activeFocus }
                                        Rectangle { anchors.centerIn: parent; width: 12; height: 12; radius: 6; color: "#99425746"; visible: root.origin >= 0 && !!root.game && root.game.legal.some(m => m.startsWith(root.square(root.origin) + root.square(cell.sq))) }
                                        MouseArea { anchors.fill: parent; onClicked: { boardFocus.forceActiveFocus(); root.selectSquare(cell.index); } }
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: root.game ? (root.flipped ? root.game.black : root.game.white) : ""; color: root.fg; font.pixelSize: 16 }
                            Text { text: root.clock(root.flipped ? "black" : "white"); color: root.accent; font { family: "monospace"; pixelSize: 25 } }
                        }
                    }
                    ColumnLayout {
                        Layout.preferredWidth: 225; Layout.maximumWidth: 250; Layout.fillHeight: true; spacing: 16
                        Text { text: "PARTIDA"; color: root.muted; font { family: "monospace"; pixelSize: 11; letterSpacing: 2 } }
                        Text { Layout.fillWidth: true; text: root.statusText(); color: root.accent; wrapMode: Text.WordWrap; font.pixelSize: 17 }
                        Rectangle { Layout.fillWidth: true; height: 1; color: "#30393b" }
                        ListView {
                            id: moveList
                            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                            model: root.game ? Math.ceil(root.game.san.length / 2) : 0
                            onCountChanged: positionViewAtEnd()
                            delegate: Row {
                                required property int index
                                width: moveList.width; height: 31; spacing: 6
                                Text { width: 32; text: (parent.index + 1) + "."; color: root.muted; font { family: "monospace"; pixelSize: 14 } }
                                Text { width: 81; text: root.game ? root.game.san[parent.index * 2] || "" : ""; color: root.fg; font { family: "monospace"; pixelSize: 14 } }
                                Text { text: root.game ? root.game.san[parent.index * 2 + 1] || "" : ""; color: root.fg; font { family: "monospace"; pixelSize: 14 } }
                            }
                            ScrollBar.vertical: ScrollBar { }
                        }
                        Text { Layout.fillWidth: true; wrapMode: Text.WrapAnywhere; text: root.selectedId; color: root.muted; font { family: "monospace"; pixelSize: 11 } }
                        Text { text: "i  digitar lance\nf  inverter tabuleiro\ng  suas partidas\nw  outra janela\n?  todos os comandos"; color: root.muted; lineHeight: 1.5; font { family: "monospace"; pixelSize: 12 } }
                    }
                }
                Rectangle {
                    anchors.fill: parent; visible: root.helpVisible; color: root.panel; radius: 6; z: 5
                    Column {
                        anchors { fill: parent; margins: 28 } spacing: 18
                        Text { text: "Teclado primeiro"; color: root.fg; font.pixelSize: 26 }
                        Text { width: parent.width; wrapMode: Text.WordWrap; text: "hjkl / setas  mover foco    Enter / Espaço  selecionar\ni  escrever SAN/UCI    Esc  voltar ao tabuleiro\ng  partidas    n  nova local    w  outra janela\nf  inverter    q  fechar esta janela\n\n:local                 nova partida local\n:open ABCDef12         abrir partida do Lichess\n:seek 10 5 casual      buscar adversário (ou rated)\n:cancel                cancelar busca\n:ai 1                  jogar contra IA do Lichess (1–8)\n:resign / :draw         desistir / oferecer empate\n:confirm               confirmar ação\n:window / :games       nova janela / lista\n\nLances: e4, Nf3, O-O, e2e4. Promoção: e7e8q.\n\nPressione Esc para fechar a ajuda."; color: root.fg; lineHeight: 1.45; font { family: "monospace"; pixelSize: 13 } }
                    }
                }
            }

            Text { Layout.fillWidth: true; visible: text.length > 0; text: root.message; color: root.messageError ? "#efa899" : root.accent; wrapMode: Text.WordWrap; font.pixelSize: 13 }
            Rectangle {
                Layout.fillWidth: true; height: 46; radius: 5
                color: root.panel; border.width: 1; border.color: command.activeFocus ? root.accent : "#30393b"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                    Text { text: command.activeFocus ? "INS" : "NAV"; color: root.accent; font { family: "monospace"; pixelSize: 11; bold: true } }
                    TextField {
                        id: command
                        Layout.fillWidth: true; color: root.fg; selectionColor: "#53664d"; selectedTextColor: root.fg
                        placeholderText: root.game ? "i → e4, Nf3…    : → comandos" : ":local   ·   :seek 10 5 casual   ·   :help"
                        placeholderTextColor: root.muted; font { family: "monospace"; pixelSize: 14 }
                        background: Item {}
                        onAccepted: { root.runCommand(text); text = ""; boardFocus.forceActiveFocus(); }
                        Keys.onEscapePressed: { text = ""; root.confirmation = ""; root.helpVisible = false; boardFocus.forceActiveFocus(); }
                    }
                    Text { text: "↵"; color: root.muted; font.pixelSize: 17 }
                }
            }
        }
    }
}
