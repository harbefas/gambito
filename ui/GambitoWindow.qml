import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// One Gambito window with its own daemon connection and view state.
// shell.qml hosts any number of these in a single Quickshell process.
Scope {
    id: root
    property string initialGame: ""
    // Ask the host for another window (game id or "" for the lobby).
    signal requestWindow(string game)
    // This window is gone; the host drops it and quits after the last one.
    signal finished()
    property var games: []
    property var account: null
    property var challenges: []
    property bool chatVisible: false
    signal chatLine(string gameId, var line)
    signal socialReply(string request, string cmd, var data, string error)
    property string connection: "offline"
    property bool seeking: false
    property bool loggingIn: false
    property string loginUrl: ""
    property string selectedId: initialGame
    readonly property bool daemonConnected: socket.connected
    property var game: games.find(g => g.id === selectedId) || null
    readonly property int initialPlyOffset: game && game.initial_fen !== "startpos" && game.initial_fen.split(" ")[1] === "b" ? 1 : 0
    readonly property int initialMoveNumber: game && game.initial_fen !== "startpos" ? Number(game.initial_fen.split(" ")[5]) || 1 : 1
    property string message: ""
    property bool messageError: false
    property bool flipped: false
    property bool manualFlip: false
    property bool helpVisible: false
    property bool playVisible: false
    property int cursor: 52
    property int origin: -1
    property int listIndex: 0
    // Lobby list: games in progress, then news. listIndex indexes orderedGames, and continues into the news.
    property int newsCount: 0
    // Game list order: in progress, analysis boards (like Lichess, not games being played), finished.
    readonly property var activeGames: games.filter(g => isActive(g) && !g.analysis && !isWatched(g))
    readonly property var analysisGames: games.filter(g => g.analysis).sort((a, b) => b.updated_ms - a.updated_ms)
    readonly property var finishedGames: games.filter(g => !isActive(g) && !g.analysis).sort((a, b) => b.updated_ms - a.updated_ms)
    readonly property var orderedGames: activeGames
    // Profile "Boards" tab: analysis boards and finished local games. Finished Lichess games live in its history.
    readonly property var boardGames: analysisGames.concat(finishedGames.filter(g => !g.online))
    // "" = lobby, "profile" = ProfileView, "tv" = TvView, "openings" = OpeningsView, "puzzles" = PuzzlesView;
    // each shows only while no game is selected.
    property string view: ""
    // Zen mode (z on the board, like Lichess): only the board; the command bar returns while typing.
    property bool zen: false
    // Difficulty for themed puzzles; kept in the window so "Next puzzle" on the board reuses it.
    property string puzzleDifficulty: "normal"
    // Key handler registered by the loaded ProfileView: (key, event) => handled.
    property var viewKeys: null
    // Replies for view-owned requests (profile, perf, history, puzzle, blog), so their data is freed with the view.
    signal replied(string cmd, var data, string error)
    // Broadcast replies include request IDs so views can discard responses after navigation.
    signal broadcastEvent(var event)
    signal broadcastReply(string request, string cmd, var payload, string error)
    // Lichess TV events for the lobby (streamed only between tv_watch and tv_stop).
    signal tvEvent(var event, string error)
    // The TvBoard that started this connection's single TV feed. When switching views the old board is
    // destroyed after the new one starts watching, so only the current owner may stop the feed.
    property var tvOwner: null
    property int serial: 0
    property var pending: ({})
    property string confirmation: ""
    property string deleteTarget: ""
    property string promotion: ""
    property double clockNow: Date.now()
    // Rewind: viewPly = plies shown (-1 = live). positions caches the FENs of the selected game.
    property int viewPly: -1
    property int wantedPly: -1
    property var positions: ({})
    readonly property bool rewound: viewPly >= 0 && !!game && positions.game === selectedId && positions.plies === game.moves.length
    // Engine: evaluation of the shown position; never during your own live online games.
    property bool engineOn: false
    property int engineDepth: 30
    property var evalData: null
    // Opening explorer (Masters / Lichess databases) for the shown position; same fair-play gate as the engine.
    property bool explorerOn: false
    property string explorerDb: "masters"
    property var explorerData: null
    property string pendingExplorerMove: ""
    property string explorerRequest: ""
    readonly property string explorerKey: explorerOn && engineAllowed ? selectedId + ":" + shownPly() + ":" + game.moves.length + ":" + explorerDb : ""
    onExplorerKeyChanged: { explorerData = null; explorerTimer.restart(); }
    function playExplorerMove(uci) {
        // Playable here (local game or analysis board at its live position): play it. Otherwise branch first.
        if (game && !game.online && viewPly < 0 && game.status === "started") { send("move", {notation: uci}); return; }
        pendingExplorerMove = uci;
        analyse();
    }
    property bool evalPending: false
    property string evalRequest: ""
    readonly property real evalProgress: !evalData || evalData.error ? 0 : Math.min(1, (evalData.depth || 0) / root.engineDepth)
    // Fair play restricts only your own live games (by color, or by name for games opened via TV).
    readonly property bool engineAllowed: !!game && !puzzleUnsolved && !(game.online && isActive(game) && (!!game.color || isMe(game.white) || isMe(game.black)))
    // Like Lichess: engine, analysis boards, rating and themes stay hidden until the puzzle is solved.
    readonly property bool puzzleUnsolved: !!game && !!game.puzzle && game.status === "started"
    function puzzleHint() {
        if (!puzzleUnsolved) return;
        rewind(Infinity);
        const next = game.puzzle.solution[game.moves.length - game.puzzle.start];
        origin = (8 - Number(next[1])) * 8 + next.charCodeAt(0) - 97;
        tell("Hint: move the highlighted piece.", false);
    }
    // Someone else's Lichess game opened from TV: not yours, so never "in progress" in the lobby.
    function isWatched(g) { return !!g && g.online && !g.color; }
    // Leaving a watched game stops its stream, unless you branched an analysis board from it.
    // (The branch reply arrives before the state containing the branch, so remember the source here.)
    property string lastSelected: ""
    property string branchingFrom: ""
    onSelectedIdChanged: {
        const previous = games.find(g => g.id === lastSelected);
        if (isWatched(previous) && previous.id !== branchingFrom) send("unwatch", {game: previous.id});
        branchingFrom = "";
        lastSelected = selectedId;
    }
    onFinished: if (isWatched(game) && socket.connected) send("unwatch", {game: game.id})
    function isMe(name) { return !!account && !!name && name.toLowerCase() === account.username.toLowerCase(); }
    readonly property string evalKey: engineOn && engineAllowed ? selectedId + ":" + shownPly() + ":" + game.moves.length + ":" + engineDepth : ""
    onEvalKeyChanged: { if (evalRequest && socket.connected) send("cancel_eval"); evalRequest = ""; evalData = null; evalPending = evalKey !== ""; evalTimer.stop(); if (evalKey) evalTimer.restart(); }
    // Lichess server analysis of finished Lichess games: moves[i] judges move i (eval after it, best instead of it).
    readonly property var review: game && game.lichess_analysis ? game.lichess_analysis : null
    readonly property bool reviewable: !!game && game.online && !isActive(game)
    readonly property color inaccuracyColor: tc("blue", "#56b4e9")
    readonly property color mistakeColor: tc("yellow", "#e69f00")
    // Board arrows at the shown position: the move played next and the better move.
    readonly property var arrows: {
        if (!game) return [];
        const ply = shownPly(); const judged = review ? review.moves[ply] : null; const out = [];
        if (judged && judged.best && game.moves[ply]) out.push({uci: game.moves[ply], color: "#801e2426"});
        const best = judged && judged.best ? judged.best : engineOn && engineAllowed && evalData && evalData.best && evalData.ply === ply ? evalData.best : "";
        if (best && !out.some(a => a.uci === best)) out.push({uci: best, color: "#cc15781b"});
        return out;
    }
    property var board: decodeFen(game ? (rewound ? positions.fens[viewPly] : game.fen) : "")
    readonly property var helpSections: [
        {title: "board", rows: [["c", "player chat"], ["T / Y", "request or accept / decline takeback"], ["h j k l / arrows", "move cursor"], ["enter / space", "select square"], ["[  ]", "previous / next move"], ["Home / End", "start / live position"], ["e", "engine on / off"], ["m", "opening explorer on / off"], ["a", "analyse / branch here"], ["S", "save game position for study"], ["Backspace", "back to source / previous page"], ["v u y", "puzzle hint / solution / retry"], ["F", "FEN"], ["L", "open on lichess.org"], ["D R", "draw / resign"], ["z", "zen mode: board only"], ["r", "load Lichess analysis"], ["x", "delete analysis board"], ["- / +", "decrease / increase depth"], ["d", "set analysis depth"], ["i", "type a move"], [":", "command"], ["f", "flip board"], ["esc", "cancel"]]},
        {title: "window", rows: [["C", "challenges (u player, t time, c color, v rated, s send)"], ["Backspace", "back one level"], ["p", "profile (1–4 tabs, s r o history filters, l sign out)"], ["s c d", "find opponent / computer / study"], ["l", "sign in / out (Enter confirms)"], ["t", "Lichess TV (b tournaments, j/k select, Enter open, Backspace back, a analyse, r refresh, 1–4 filters)"], ["o", "openings (arrows pick, enter play, Backspace back, Home start, a analyse, s r filters)"], ["z", "puzzle themes ([ ] category, d difficulty)"], ["j k / enter", "lobby: games in progress, then news"], ["n", "new local game"], ["w", "new window"], ["?", "help"], ["q", "close"]]},
        {title: "commands", rows: [[":challenges", "send and respond to invitations"], [":challenge USER [MIN INC rated]", "challenge a player"], [":accept / :decline / :cancelchallenge ID", "respond to an invitation"], [":chat [MESSAGE]", "toggle chat or send message"], [":takeback [no]", "request / accept / decline takeback"], [":analyse", "branch from viewed position"], [":fen FEN", "analyse a FEN position"], [":source", "return to source game"], [":lichess", "load Lichess analysis"], [":explorer", "opening explorer on / off"], [":puzzle", "daily puzzle on the board"], [":hint", "puzzle hint"], [":retry", "restart puzzle"], [":solution", "show puzzle solution"], [":delete", "delete analysis board"], [":depth N", "set analysis depth (1–245)"], [":local", "new local game"], [":open ID", "open Lichess game"], [":seek 10 5 [rated]", "seek opponent"], [":cancel", "cancel seek"], [":ai 1-8", "play Lichess AI"], [":play", "online play options"], [":login", "connect Lichess"], [":logout", "sign out of Lichess"], [":resign", "resign"], [":draw", "offer or accept draw"], [":confirm", "confirm action"], [":games", "lobby"], [":profile", "profile: ratings, history, boards"], [":tv", "Lichess TV"], [":zen", "board only (z on the board)"], [":openings", "opening explorer page"], [":puzzles", "puzzle themes"], [":next", "next puzzle of this theme"], [":window", "new window"], [":quit", "close"]]},
        {title: "moves", rows: [["e4  Nf3  O-O", "SAN"], ["e2e4", "UCI"], ["e7e8q", "promotion"]]}
    ]
    // Palette, first found wins, all followed live. Every source uses Omarchy's colors.toml keys
    // (background, foreground, accent, muted, red, green, ...), so any setup can write one:
    // 1. $XDG_CONFIG_HOME/gambito/colors.toml  2. Omarchy 4's current theme  3. Omarchy 3's current theme
    // 4. ~/.config/desktop/theme-<mode>.toml, mode from ~/.local/state/desktop/theme  5. built-in palette.
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
    property string themeMode: "dark"
    property var themeSources: [({}), ({}), ({}), ({})]
    readonly property var theme: themeSources.find(t => !!t.background) || ({})
    function setThemeSource(i, text) { const next = themeSources.slice(); next[i] = text ? parseToml(text) : ({}); themeSources = next; }
    readonly property bool themed: !!theme.background
    readonly property color bg: tc("background", "#121719")
    readonly property color fg: tc("foreground", "#e6e3db")
    readonly property color accent: tc("accent", "#c5dc9c")
    readonly property color danger: tc(["error", "red"], "#df8f83")
    readonly property color panel: mix(bg, fg, 0.05)
    readonly property color raised: mix(bg, fg, 0.09)
    readonly property color line: mix(bg, fg, 0.15)
    readonly property color muted: mix(fg, bg, 0.4)
    readonly property color faint: mix(fg, bg, 0.62)
    readonly property string mono: theme.font || "monospace"
    readonly property color squareLight: themed ? mix(tc("bright_white", "#f4f1e8"), tc("bright_yellow", "#d8b878"), 0.22) : "#ddd6c3"
    readonly property color squareDark: themed ? mix(tc("green", "#8f9f52"), tc(["bright_black", "muted"], "#4f5b4a"), 0.5) : "#778a80"
    readonly property color highlight: tc("yellow", "#c9c46a")
    readonly property color selection: tc(["bright_green", "green"], "#b0bd68")
    // Score coloring (leading / trailing), from the terminal theme like the rest of the palette.
    readonly property color winColor: tc("green", "#629924")

    // Keys may list alternatives; values may be written with or without "#".
    function tc(keys, fallback) {
        const value = [].concat(keys).map(k => theme[k]).find(v => !!v);
        return Qt.color(value ? (value.startsWith("#") ? value : "#" + value) : fallback);
    }
    function mix(a, b, t) { return Qt.tint(a, Qt.rgba(b.r, b.g, b.b, t)); }
    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    function parseToml(text) {
        const out = {};
        for (const l of text.split("\n")) {
            const m = l.match(/^\s*(\w+)\s*=\s*"([^"]*)"/);
            if (m) out[m[1]] = m[2];
        }
        return out;
    }

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
    function analyse() {
        if (puzzleUnsolved) { tell("Solve the puzzle first, or view the solution.", true); return; }
        if (!game || !engineAllowed) { tell("Analysis is off while you play a live Lichess game (fair play).", true); return; }
        branchingFrom = selectedId;
        send("analyse", {ply: shownPly()});
    }
    // Hover selects a row only when the pointer really moves: keyboard scrolling slides rows under a resting pointer.
    property point pointer
    function pointerMoved(area, mouse) {
        const p = area.mapToItem(null, mouse.x, mouse.y);
        const moved = p.x !== pointer.x || p.y !== pointer.y;
        pointer = p;
        return moved;
    }
    function confirmDelete(id) {
        const g = games.find(g => g.id === id);
        if (!g || !(g.analysis || g.puzzle)) { tell("Only analysis boards and puzzles can be deleted.", true); return; }
        deleteTarget = id; confirmation = "delete";
        tell("Delete this variation and its branches? Type :confirm or press Esc.", false);
    }
    // Your color in your games; for watched games, the side Lichess TV showed at the bottom.
    property var watchOrientation: ({})
    function orientation(g) { return !g ? "white" : g.color || watchOrientation[g.id] || "white"; }
    // Material balance from the shown board, Lichess-style: positive favors White.
    // Pieces each side has captured, from a FEN's board: {white: "♟♞", black: "♙", lead: +N for white}.
    // Promotions can make a side "capture" more than the opponent lost; counts are clamped at zero.
    function captures(fen) {
        const start = {p: 8, n: 2, b: 2, r: 2, q: 1};
        const values = {p: 1, n: 3, b: 3, r: 5, q: 9};
        const left = {w: {p: 0, n: 0, b: 0, r: 0, q: 0}, b: {p: 0, n: 0, b: 0, r: 0, q: 0}};
        for (const c of fen.split(" ")[0]) if ("pnbrq".includes(c.toLowerCase())) left[c === c.toUpperCase() ? "w" : "b"][c.toLowerCase()]++;
        const taken = side => ["q", "r", "b", "n", "p"].map(k => glyph(side === "w" ? k : k.toUpperCase()).repeat(Math.max(0, start[k] - left[side][k]))).join("");
        const material = side => Object.keys(values).reduce((sum, k) => sum + values[k] * left[side][k], 0);
        // White has captured black's missing pieces, drawn in black glyphs, and vice versa.
        return {white: taken("b"), black: taken("w"), lead: material("w") - material("b")};
    }
    readonly property int materialBalance: {
        const values = {p: 1, n: 3, b: 3, r: 5, q: 9};
        let total = 0;
        for (const piece of board) if (piece) total += (values[piece.toLowerCase()] || 0) * (piece === piece.toUpperCase() ? 1 : -1);
        return total;
    }
    // One navigation action for buttons and keys; a page may consume it for a child level.
    function navigateBack() {
        if (helpVisible || confirmation || promotion) return;
        if (playVisible) { if (!seeking) playVisible = false; return; }
        if (selectedId) {
            if (game && game.analysis_source) returnToSource();
            else selectedId = "";
        } else if (view !== "") {
            if (!(viewKeys && viewKeys("", {key: Qt.Key_Backspace}))) view = "";
        }
    }
    function returnToSource() {
        if (!game || !game.analysis_source) return;
        const source = game.analysis_source; const ply = game.analysis_ply;
        if (!games.some(g => g.id === source)) { send("open", {game: source}); return; }
        choose(source); rewind(ply);
    }
    function analysisOrigin(g) {
        const source = games.find(x => x.id === g.analysis_source);
        return source ? " of " + source.white + " vs " + source.black : g.analysis_source ? "" : " from FEN";
    }
    function rowInfo(g) {
        const speed = g.speed ? g.speed[0].toUpperCase() + g.speed.slice(1) : "";
        const parts = g.online ? ["Lichess", [speed, g.time_control].filter(x => x).join(" "), g.rated ? "rated" : ""] : [g.puzzle ? "Puzzle of the day" + (g.status === "solved" ? " · solved" : "") : g.analysis ? "Analysis" + analysisOrigin(g) : "Local"];
        parts.push(Math.ceil(g.san.length / 2) + " moves");
        if (!isActive(g) && g.updated_ms) parts.push(new Date(g.updated_ms).toLocaleDateString(Qt.locale(), "d MMM yyyy"));
        return parts.filter(x => x).join(" · ");
    }
    // Finished result from the player's side, when they played in it.
    function result(g) {
        if (isActive(g) || !g.color) return "";
        const how = ({mate: "checkmate", resign: "resignation", outoftime: "time", timeout: "timeout", stalemate: "stalemate", draw: "agreement"})[g.status] || g.status;
        return (g.winner ? (g.winner === g.color ? "won" : "lost") : "draw") + " · " + how;
    }
    function formatScore(e) {
        if (!e || e.error) return "…";
        if (e.mate !== null && e.mate !== undefined) return e.mate === 0 ? "#" : "#" + e.mate;
        return (e.cp > 0 ? "+" : "") + (e.cp / 100).toFixed(1);
    }
    // Share of the bar that is White's, Lichess winning-chances curve.
    function whiteShare() {
        const e = evalData;
        if (!e || e.error) return 0.5;
        if (e.mate !== null && e.mate !== undefined) return e.mate > 0 ? 1 : e.mate < 0 ? 0 : (e.ply + initialPlyOffset) % 2 === 0 ? 0 : 1;
        return 1 / (1 + Math.exp(-0.00368208 * e.cp));
    }
    function judgement(ply) { const a = review ? review.moves[ply] : null; return a && a.judgment ? a.judgment.name.toLowerCase() : ""; }
    function judgementGlyph(name) { return ({inaccuracy: "?!", mistake: "?", blunder: "??"})[name] || ""; }
    function judgementColor(name) { return name === "blunder" ? danger : name === "mistake" ? mistakeColor : inaccuracyColor; }
    function reviewScore(ply) { const a = review && ply >= 0 ? review.moves[ply] : null; return a ? formatScore({cp: a.eval, mate: a.mate}) : ""; }
    // "6… b4" style label for the move at ply.
    function moveLabel(ply, san) {
        const abs = ply + initialPlyOffset + 2 * (initialMoveNumber - 1);
        return Math.floor(abs / 2) + 1 + (abs % 2 ? "… " : ". ") + san;
    }
    function loadReview() {
        if (!reviewable) { tell("Lichess analysis is only available for finished Lichess games.", true); return; }
        send("lichess_analysis");
    }
    function formatPv(e) {
        if (!e || !e.pv) return "";
        return e.pv.map((san, i) => {
            const ply = e.ply + i + initialPlyOffset + 2 * (initialMoveNumber - 1);
            return ply % 2 === 0 ? (ply / 2 + 1) + ". " + san : (i === 0 ? Math.ceil(ply / 2) + "… " : "") + san;
        }).join(" ");
    }
    function shownPly() { return viewPly >= 0 ? viewPly : game ? game.moves.length : 0; }
    function rewind(target) {
        if (!game) return;
        const plies = game.moves.length;
        target = Math.max(0, Math.min(plies, target));
        origin = -1;
        if (target >= plies) { viewPly = -1; wantedPly = -1; return; }
        if (positions.game === selectedId && positions.plies === plies) viewPly = target;
        else { wantedPly = target; send("positions"); }
    }
    function isActive(g) { return g.status === "started" || g.status === "created"; }
    // Lobby puzzle card keys, handled by the loaded LobbyView (y retry, v show move, u open on board).
    signal lobbyPuzzleKey(string key)
    signal openNews(int index)
    function tileAction(id) {
        if ((id === "seek" || id === "ai") && !account) { send("login"); return; }
        if (id === "local") send("local");
        else if (id === "seek" || id === "ai") { playScreen.mode = id === "ai" ? "computer" : "opponent"; playVisible = true; }
        else if (id === "open") prefill(":open ");
    }
    function prefill(text) { command.text = text; command.forceActiveFocus(); command.cursorPosition = text.length; }
    function promote(piece) { const uci = promotion; clearPending(); send("move", {notation: uci + piece}); }
    function clearPending() { promotion = ""; confirmation = ""; origin = -1; command.text = ""; tell("", false); boardFocus.forceActiveFocus(); }
    function tell(text, error) { message = text; messageError = !!error; }
    function send(cmd, data) {
        if (!socket.connected) { tell("Daemon disconnected; reconnecting…", true); return; }
        const id = String(++serial);
        const request = Object.assign({cmd:cmd, game:selectedId, request_id:id}, data || {});
        // Quiet requests (a view's background work) skip the generic reply handling, e.g. selecting a game.
        pending[id] = data && data.quiet ? "quiet" : cmd;
        if (cmd === "eval") evalRequest = id;
        // The board panel asks by game position; the openings page asks by line (its reply goes to `replied`).
        if (cmd === "explorer" && !(data && data.line)) explorerRequest = id;
        socket.write(JSON.stringify(request) + "\n"); socket.flush();
        return id;
    }
    function choose(id) {
        selectedId = id; origin = -1; confirmation = ""; tell("", false); missingGame.restart(); manualFlip = false; playVisible = false; viewPly = -1; wantedPly = -1;
        const g = games.find(g => g.id === id);
        flipped = orientation(g) === "black";
        cursor = flipped ? 11 : 52;
        boardFocus.forceActiveFocus();
    }
    function receive(line) {
        try {
            const e = JSON.parse(line);
            if (e.type === "state") {
                const known = games.map(g => g.id); const wasSeeking = seeking;
                challenges = e.challenges || [];
                games = e.games; account = e.account; connection = e.connection; seeking = e.seeking; loggingIn = !!e.logging_in;
                // A game that appears while seeking or on the play screen is the one just paired.
                const fresh = games.find(g => g.online && isActive(g) && !known.includes(g.id));
                if (fresh && (known.length || view === "challenges") && (wasSeeking || playVisible || view === "challenges")) choose(fresh.id);
                // The selected game vanished from the state (deleted elsewhere): back to the list.
                if (selectedId && known.includes(selectedId) && !games.some(g => g.id === selectedId)) selectedId = "";
                if (game && !manualFlip) flipped = orientation(game) === "black";
                if (origin >= 0 && !board[origin]) origin = -1;
                // New moves while rewound: refresh the cached positions, keep the viewed ply.
                if (viewPly >= 0 && game && positions.plies !== game.moves.length && wantedPly < 0) { wantedPly = viewPly; send("positions"); }
            } else if (e.type === "notice") tell(e.message, true);
            else if (e.type === "chat") chatLine(e.game, e.line);
            else if (e.type === "broadcast") broadcastEvent(e);
            else if (e.type === "tv") tvEvent(e.event || null, e.error || "");
            else if (e.type === "eval") {
                if (engineOn && engineAllowed && evalPending && e.request_id === evalRequest && e.eval.for === selectedId && e.eval.ply === shownPly()) evalData = e.eval;
            }
            else if (e.type === "reply") {
                const cmd = pending[e.request_id]; delete pending[e.request_id];
                if (cmd === "quiet") return;
                if (cmd === "chat" || cmd === "chat_history") { socialReply(e.request_id, cmd, e.data || null, e.ok ? "" : e.error); if (!e.ok) tell(e.error, true); return; }
                if (cmd === "eval" && (e.request_id !== evalRequest || !engineOn || !engineAllowed)) return;
                if (!e.ok && cmd === "eval") { evalData = {error: e.error}; evalPending = false; return; }
                if (["broadcasts", "broadcast_tournament", "broadcast_round", "broadcast_game"].includes(cmd)) { broadcastReply(e.request_id, cmd, e.ok ? e.data : null, e.ok ? "" : e.error); return; }
                if (["profile", "perf", "history", "puzzle", "blog", "tv_channels", "crosstable", "puzzle_themes", "puzzle_dashboard"].includes(cmd) || cmd.startsWith("study_")) { replied(cmd, e.ok ? e.data : null, e.ok ? "" : e.error); if (!e.ok && ["profile", "perf", "history"].includes(cmd)) tell(e.error, true); return; }
                if (cmd === "tv_watch" || cmd === "tv_stop") return;
                // Only the latest request counts: replies for positions already left are dropped.
                if (cmd === "explorer") {
                    if (e.request_id === explorerRequest) explorerData = e.ok ? e.data : {error: e.error};
                    else replied("explorer:" + e.request_id, e.ok ? e.data : null, e.ok ? "" : e.error);
                    return;
                }
                if (!e.ok) { if (cmd === "analyse") pendingExplorerMove = ""; tell(e.error, true); return; }
                if (e.data && e.data.eval) {
                    if (e.data.eval.for === selectedId && e.data.eval.ply === shownPly()) { evalData = e.data.eval; evalPending = false; }
                    return;
                }
                if (e.data && e.data.game) {
                    choose(e.data.game);
                    if (cmd === "analyse") tell("Analysis board. Play moves freely; press a at any earlier position to branch again.", false);
                    if (cmd === "analyse" && pendingExplorerMove) { send("move", {notation: pendingExplorerMove}); pendingExplorerMove = ""; }
                }
                if (e.data && e.data.positions) {
                    positions = {game: e.data.for, plies: e.data.plies, fens: e.data.positions};
                    if (wantedPly >= 0 && e.data.for === selectedId) { viewPly = Math.min(wantedPly, e.data.plies); wantedPly = -1; if (viewPly >= e.data.plies) viewPly = -1; }
                }
                if (e.data && e.data.url) { loginUrl = e.data.url; Qt.openUrlExternally(e.data.url); }
                if (typeof e.data === "string") tell(e.data, false);
                else if (cmd === "local") tell("Local game created. Press i to type a move.", false);
            }
        } catch (err) { tell("Invalid daemon response: " + err, true); }
    }
    function selectSquare(displayIndex) {
        if (!game) return;
        if (game.online && !game.color) { tell("Watching: moves are disabled.", false); return; }
        if (viewPly >= 0) { tell(game.analysis ? "Press a or Branch here to explore this position." : "Press a or Analyse to explore this position.", true); return; }
        const index = canonical(displayIndex);
        cursor = displayIndex;
        if (origin < 0) {
            const p = board[index];
            if (!p) return;
            const side = p === p.toUpperCase() ? "white" : "black";
            if (side !== game.turn) { tell("Select a piece of the side to move.", true); return; }
            origin = index;
        } else if (origin === index) origin = -1;
        else {
            const uci = square(origin) + square(index);
            const choices = (game.legal || []).filter(m => m.startsWith(uci));
            if (choices.length > 1) {
                prefill(uci); promotion = uci;
                tell("Promotion: pick a piece above, or append q, r, b or n and press Enter.", false);
            } else send("move", {notation:uci});
            origin = -1;
        }
    }
    function adjustDepth(delta) { engineDepth = Math.max(1, Math.min(245, engineDepth + delta)); }
    function runCommand(text) {
        promotion = "";
        text = text.trim(); if (!text) return;
        if (!text.startsWith(":")) { if (viewPly >= 0) { tell("Press a to branch from this position before playing a move.", true); return; } send("move", {notation:text}); return; }
        const words = text.slice(1).split(/\s+/); const cmd = words.shift();
        switch (cmd) {
        case "challenges": selectedId = ""; view = "challenges"; break;
        case "challenge":
            if (!words.length) { selectedId = ""; view = "challenges"; break; }
            send("challenge", {username: words[0], minutes: Number(words[1] || 10), increment: Number(words[2] || 5), rated: words[3] === "rated"}); break;
        case "accept": case "decline": case "cancelchallenge": send("challenge_" + (cmd === "cancelchallenge" ? "cancel" : cmd), {challenge: words[0] || ""}); break;
        case "chat":
            if (!game || !game.online || !game.color) { tell("Chat requires your own Lichess game", true); break; }
            if (words.length) send("chat", {text: words.join(" ")}); else { chatVisible = !chatVisible; zen = false; } break;
        case "takeback": send("takeback", {accept: words[0] !== "no"}); break;
        case "analyse": analyse(); break;
        case "fen": send("analyse", {fen: words.join(" ")}); break;
        case "source": returnToSource(); break;
        case "puzzle": send("puzzle_open"); break;
        case "explorer": explorerOn = !explorerOn; break;
        case "hint": puzzleHint(); break;
        case "retry": if (game && game.puzzle) send("puzzle_retry"); break;
        case "solution": if (game && game.puzzle) send("puzzle_solution"); break;
        case "lichess": loadReview(); break;
        case "local": send("local"); break;
        case "games": selectedId = ""; view = ""; break;
        case "profile": selectedId = ""; view = "profile"; break;
        case "tv": selectedId = ""; view = "tv"; break;
        case "zen": zen = !zen; break;
        case "openings": selectedId = ""; view = "openings"; break;
        case "study": selectedId = ""; view = "study"; break;
        case "puzzles": selectedId = ""; view = "puzzles"; break;
        case "next": if (game && game.puzzle && game.puzzle.angle) send("puzzle_next", {angle: game.puzzle.angle, difficulty: puzzleDifficulty}); break;
        case "open": send("open", {game:words[0] || ""}); break;
        case "seek":
            if (!/^\d+$/.test(words[0] || "") || (words[1] && !/^\d+$/.test(words[1])) || (words[2] && !["rated", "casual"].includes(words[2]))) { tell("Use :seek 10 5 casual (or rated)", true); break; }
            send("seek", {minutes:Number(words[0]), increment:Number(words[1] || 0), rated:words[2] === "rated"}); break;
        case "cancel": send(loggingIn ? "cancel_login" : "cancel"); break;
        case "login": send("login"); break;
        case "logout": confirmation = "logout"; tell("Sign out of Lichess? Press Enter to confirm or Esc.", false); break;
        case "ai": send("ai", {level:Number(words[0] || 1)}); break;
        case "resign": case "draw":
            if (!game) { tell("Open a game first.", true); break; }
            confirmation = cmd; tell(cmd === "resign" ? "Resign this game? Type :confirm or press Esc." : "Offer/accept a draw? Type :confirm or press Esc.", false); break;
        case "delete": if (game) confirmDelete(selectedId); break;
        case "confirm":
            if (confirmation === "delete") { const target = deleteTarget; if (target === selectedId) returnToSource(); send("delete", {game: target}); }
            else if (confirmation) send(confirmation);
            confirmation = ""; break;
        case "depth":
            if (words.length !== 1 || !/^\d+$/.test(words[0]) || Number(words[0]) < 1 || Number(words[0]) > 245) { tell("Use :depth 1–245", true); return; }
            engineDepth = Number(words[0]); break;
        case "flip": flipped = !flipped; manualFlip = true; break;
        case "window": newWindow(); break;
        case "play": if (!account) send("login"); else playVisible = !playVisible; break;
        case "help": helpVisible = !helpVisible; break;
        case "quit": finished(); break;
        default: tell("Unknown command. See :help.", true);
        }
    }
    function newWindow() {
        requestWindow(selectedId);
    }
    function clock(side) {
        if (!game) return "";
        let ms = side === "white" ? game.white_ms : game.black_ms;
        if (ms === null || ms === undefined) return "";
        // Server values remain authoritative. Never extrapolate a disconnected clock.
        if (game.status === "started" && game.moves.length >= 2 && game.turn === side && game.connected)
            ms = Math.max(0, ms - Math.max(0, clockNow - game.updated_ms));
        const secs = Math.ceil(ms / 1000);
        const pad = n => String(n).padStart(2, "0");
        // Correspondence clocks read in days and hours, never as a wall clock: a day left is "1d 0h", not 24:00:00.
        if (game.speed === "correspondence") {
            if (secs >= 86400) return Math.floor(secs / 86400) + "d " + Math.floor(secs % 86400 / 3600) + "h";
            if (secs >= 3600) return Math.floor(secs / 3600) + "h " + Math.floor(secs % 3600 / 60) + "m";
            return Math.max(1, Math.floor(secs / 60)) + "m";
        }
        if (secs >= 86400) return Math.floor(secs / 86400) + "d " + Math.floor(secs % 86400 / 3600) + "h";
        if (secs >= 3600) return Math.floor(secs / 3600) + ":" + pad(Math.floor(secs % 3600 / 60)) + ":" + pad(secs % 60);
        return Math.floor(secs / 60) + ":" + pad(secs % 60);
    }
    function gameInfo() {
        if (!game) return "";
        const parts = [];
        if (game.online) {
            parts.push(game.rated ? "Rated" : "Casual");
            const speed = game.speed ? game.speed[0].toUpperCase() + game.speed.slice(1) : "";
            parts.push([speed, game.speed === "correspondence" ? "" : game.time_control, game.speed === "correspondence" ? game.time_control : ""].filter(x => x).join(" "));
            parts.push(game.color ? "you play " + game.color : "watching");
        } else parts.push(game.puzzle ? "Puzzle of the day" : game.analysis ? "Analysis · local variation" : "Local");
        parts.push("move " + (Math.floor(game.san.length / 2) + 1));
        return parts.filter(x => x).join(" · ");
    }
    function statusText() {
        if (!game) return "";
        if (viewPly === 0) return "Start position";
        if (viewPly > 0) return ((viewPly + initialPlyOffset) % 2 ? "White" : "Black") + " played " + game.san[viewPly - 1];
        if (game.puzzle) return game.status === "solved" ? "Puzzle solved ✓" : "Puzzle · your turn";
        if (game.status !== "started" && game.status !== "created") {
            const labels = {mate:"Checkmate", resign:"Resigned", draw:"Draw", stalemate:"Stalemate", outoftime:"Time out", timeout:"Time out", aborted:"Aborted", cheat:"Game over", noStart:"Not started"};
            return (labels[game.status] || game.status) + (game.winner ? " · " + game.winner + " wins" : "");
        }
        if (game.online && !game.connected) return "Reconnecting · clocks paused";
        if (game.pending) return "Waiting for Lichess…";
        const turn = game.turn === "white" ? "White" : "Black";
        return turn + " to move" + (game.check ? " · check" : "") + (game.color === game.turn ? " · your turn" : "") + (game.draw_offer ? " · draw offered" : "");
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
    // A selected game that never reaches the state (bad ID, failed stream) must not leave a blank window.
    Timer { id: missingGame; interval: 10000; onTriggered: if (root.selectedId && !root.game) { root.selectedId = ""; root.tell("Game not available.", true); } }
    Timer { id: explorerTimer; interval: 150; onTriggered: if (root.explorerKey) root.send("explorer", {ply: root.shownPly(), db: root.explorerDb}) }
    Timer { id: evalTimer; interval: 120; onTriggered: if (root.evalKey) root.send("eval", {ply: root.shownPly(), stream: true, depth: root.engineDepth}) }
    Instantiator {
        model: [root.configHome + "/gambito/colors.toml", root.stateHome + "/omarchy/current/theme/colors.toml",
                root.configHome + "/omarchy/current/theme/colors.toml", root.configHome + "/desktop/theme-" + root.themeMode + ".toml"]
        delegate: FileView {
            id: source
            required property string modelData
            required property int index
            path: modelData
            watchChanges: true; printErrors: false
            onFileChanged: reload()
            onLoaded: root.setThemeSource(index, text())
            onLoadFailed: root.setThemeSource(index, "")
            // omarchy-theme-set swaps the whole theme directory, which a file watch can miss; theme.name is rewritten after it.
            readonly property Connections omarchySwitch: Connections { target: omarchyName; function onLoaded() { source.reload(); } }
        }
    }
    FileView {
        id: omarchyName
        path: root.stateHome + "/omarchy/current/theme.name"
        watchChanges: true; printErrors: false
        onFileChanged: reload()
    }
    FileView {
        path: root.stateHome + "/desktop/theme"
        watchChanges: true; printErrors: false
        onFileChanged: reload()
        onLoaded: root.themeMode = text().trim() || "dark"
    }

    FloatingWindow {
        id: window
        title: "Gambito" + (root.game ? " · " + root.game.white + " × " + root.game.black : "")
        visible: true
        implicitWidth: 1040
        implicitHeight: 780
        minimumSize: Qt.size(720, 570)
        color: root.bg
        onClosed: root.finished()

        ColumnLayout {
            id: pageLayout
            // Tiled panes can be small: less chrome around the page.
            anchors.fill: parent; anchors.margins: window.width < 700 || window.height < 500 ? 10 : 28; spacing: window.width < 700 || window.height < 500 ? 10 : 18
            FocusScope {
                id: boardFocus
                Layout.fillWidth: true; Layout.fillHeight: true
                // Views never draw under the command bar, whatever the pane size.
                clip: true
                focus: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape && root.playVisible) { if (root.seeking) root.send("cancel"); event.accepted = true; return; }
                    if (root.playVisible) {
                        if (event.key === Qt.Key_Backspace) root.navigateBack();
                        else if (event.text === ":") { command.text = ":"; command.forceActiveFocus(); command.cursorPosition = 1; }
                        else if (!root.seeking) playScreen.handleKey(event.text, event);
                        event.accepted = true; return;
                    }
                    if (event.key === Qt.Key_Escape && root.loggingIn && !root.confirmation && !root.helpVisible) { root.send("cancel_login"); event.accepted = true; return; }
                    if (event.key === Qt.Key_Escape) { root.origin = -1; root.confirmation = ""; root.promotion = ""; root.helpVisible = false; root.tell("", false); event.accepted = true; return; }
                    if (root.helpVisible) { event.accepted = true; return; }
                    if (root.confirmation && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.runCommand(":confirm"); event.accepted = true; return; }
                    if (event.key === Qt.Key_Backspace) { root.navigateBack(); event.accepted = true; return; }
                    const key = event.text;
                    if (key === "i" || key === ":") { command.text = key === ":" ? ":" : ""; command.forceActiveFocus(); command.cursorPosition = command.text.length; }
                    else if (key === "?") root.helpVisible = true;
                    else if (key === "C") root.runCommand(":challenges");
                    else if (key === "T" && root.game) root.runCommand(":takeback");
                    else if (key === "Y" && root.game) root.runCommand(":takeback no");
                    else if (key === "c" && root.game) root.runCommand(":chat");
                    else if (key === "n" && root.game && root.game.puzzle && root.game.puzzle.angle && !root.puzzleUnsolved) root.runCommand(":next");
                    else if (key === "n") root.send("local");
                    else if (key === "w") root.newWindow();
                    else if (key === "f") { root.flipped = !root.flipped; root.manualFlip = true; }
                    else if (key === "q") root.finished();
                    else if (!root.game && root.view !== "") {
                        if (!(root.viewKeys && root.viewKeys(key, event))) return;
                    } else if (!root.game) {
                        if (key === "p") root.view = "profile";
                        else if (key === "t") root.view = "tv";
                        else if (key === "s") root.tileAction("seek");
                        else if (key === "c") root.tileAction("ai");
                        else if (key === "l") { if (root.account) root.runCommand(":logout"); else root.send("login"); }
                        else if (key === "y" || key === "v" || key === "u") root.lobbyPuzzleKey(key);
                        else if (key === "b" && root.loggingIn && root.loginUrl) Qt.openUrlExternally(root.loginUrl);
                        else if (key === "o") root.view = "openings";
                        else if (key === "d") root.view = "study";
                        else if (key === "z") root.view = "puzzles";
                        else if (key === "j" || event.key === Qt.Key_Down) root.listIndex = Math.min(root.orderedGames.length + root.newsCount - 1, root.listIndex + 1);
                        else if (key === "k" || event.key === Qt.Key_Up) root.listIndex = Math.max(0, root.listIndex - 1);
                        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.listIndex >= root.orderedGames.length) root.openNews(root.listIndex - root.orderedGames.length);
                        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.orderedGames.length) root.choose(root.orderedGames[Math.max(0,root.listIndex)].id);
                        else if (key === "x" && root.orderedGames[root.listIndex]) root.confirmDelete(root.orderedGames[root.listIndex].id);
                        else return;
                    } else if (key === "e") root.engineOn = !root.engineOn;
                    else if (key === "m") root.explorerOn = !root.explorerOn;
                    else if (key === "+" || key === "=") root.adjustDepth(1);
                    else if (key === "-") root.adjustDepth(-1);
                    else if (key === "d") root.prefill(":depth " + root.engineDepth);
                    else if (key === "a") root.analyse();
                    else if (key === "z") root.zen = !root.zen;
                    else if (key === "r") root.loadReview();
                    else if (key === "v" && root.puzzleUnsolved) root.puzzleHint();
                    else if (key === "u" && root.puzzleUnsolved) root.send("puzzle_solution");
                    else if (key === "y" && root.game.puzzle) root.send("puzzle_retry");
                    else if (key === "L" && root.game.online) Qt.openUrlExternally("https://lichess.org/" + root.selectedId);
                    else if (key === "F") root.prefill(":fen ");
                    else if (key === "D" && root.game.color && root.isActive(root.game)) root.runCommand(":draw");
                    else if (key === "R" && root.game.color && root.isActive(root.game)) root.runCommand(":resign");
                    else if (key === "S" && root.game) root.send("study_capture", {ply: root.shownPly()});
                    else if (key === "x") root.runCommand(":delete");
                    else if (key === "[") root.rewind(root.shownPly() - 1);
                    else if (key === "]") root.rewind(root.shownPly() + 1);
                    else if (event.key === Qt.Key_Home) root.rewind(0);
                    else if (event.key === Qt.Key_End) root.rewind(Infinity);
                    else if (key === "h" || event.key === Qt.Key_Left) root.cursor = Math.max(0, root.cursor - 1);
                    else if (key === "l" || event.key === Qt.Key_Right) root.cursor = Math.min(63, root.cursor + 1);
                    else if (key === "k" || event.key === Qt.Key_Up) root.cursor = Math.max(0, root.cursor - 8);
                    else if (key === "j" || event.key === Qt.Key_Down) root.cursor = Math.min(63, root.cursor + 8);
                    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) || event.key === Qt.Key_Space) root.selectSquare(root.cursor);
                    else return;
                    event.accepted = true;
                }

                // Views load only while shown, so the hidden one costs nothing.
                // Keyed on selectedId, not game: a reply selecting a new game arrives before the state
                // that contains it, and keying on `game` briefly rebuilt the lobby (and its TV stream).
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === ""; sourceComponent: Component { LobbyView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "challenges"; sourceComponent: Component { ChallengesView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "profile"; sourceComponent: Component { ProfileView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "tv"; sourceComponent: Component { TvView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "puzzles"; sourceComponent: Component { PuzzlesView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "openings"; sourceComponent: Component { OpeningsView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !root.selectedId && root.view === "study"; sourceComponent: Component { StudyView { app: root; focusScope: boardFocus } } }
                Loader { anchors.fill: parent; active: !!root.game; sourceComponent: Component { BoardView { app: root; focusScope: boardFocus } } }
                PlayScreen { id: playScreen; objectName: "playScreen"; anchors.fill: parent; app: root; visible: root.playVisible; z: 5 }
                Rectangle {
                    anchors.fill: parent; visible: root.helpVisible; color: root.bg; z: 6
                    RowLayout {
                        id: helpHeader
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        Text { text: "Keyboard & commands"; color: root.fg; font { pixelSize: 18; weight: Font.DemiBold } }
                        Item { Layout.fillWidth: true }
                        ActionButton { objectName: "closeHelpButton"; theme: root; compact: true; label: "Close"; hint: "esc"; onClicked: root.helpVisible = false }
                    }
                    Flickable {
                        anchors { left: parent.left; right: parent.right; top: helpHeader.bottom; bottom: parent.bottom; topMargin: 24 }
                        clip: true; contentHeight: helpColumn.height
                        Column {
                            id: helpColumn
                            readonly property int sectionWidth: Math.min(440, parent.width)
                            x: (parent.width - width) / 2; spacing: 28; topPadding: 8; bottomPadding: 8
                            Grid {
                            columns: parent.parent.width >= 2 * helpColumn.sectionWidth + 64 ? 2 : 1; columnSpacing: 64; rowSpacing: 28
                            Repeater {
                                model: root.helpSections
                                Column {
                                    required property var modelData
                                    width: helpColumn.sectionWidth; spacing: 10
                                    Text { text: modelData.title; color: root.muted; font { family: root.mono; pixelSize: 12 } }
                                    Rectangle { width: parent.width; height: 1; color: root.line }
                                    Grid {
                                        columns: 2; columnSpacing: 24; rowSpacing: 7
                                        Repeater {
                                            model: modelData.rows.reduce((all, row) => all.concat(row), [])
                                            Text {
                                                required property var modelData
                                                required property int index
                                                width: index % 2 ? implicitWidth : 180
                                                text: modelData; color: index % 2 ? root.muted : root.fg
                                                font { family: root.mono; pixelSize: 13 }
                                            }
                                        }
                                    }
                                }
                            }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: commandBar
                objectName: "commandBar"
                visible: !(root.zen && (root.game || root.view === "tv")) || command.activeFocus || !!root.confirmation
                Layout.fillWidth: true; height: 46; radius: 5
                // Narrow panes keep each button's icon and key, dropping labels, then secondary buttons.
                readonly property bool narrow: width < 860
                readonly property bool tiny: width < 520
                color: root.panel; border.width: 1; border.color: command.activeFocus ? root.accent : root.line
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                    Text { text: !socket.connected ? "OFF" : command.activeFocus ? "INS" : "NAV"; color: !socket.connected ? root.danger : root.muted; font { family: root.mono; pixelSize: 11; bold: true } }
                    TextField {
                        id: command
                        Layout.fillWidth: true; color: root.fg; selectionColor: root.mix(root.bg, root.accent, 0.4); selectedTextColor: root.fg
                        placeholderText: commandBar.narrow && !root.game ? "" : root.game ? "i move   : command   ? help" : "n new game   : command   ? help"
                        placeholderTextColor: root.muted; font { family: root.mono; pixelSize: 14 }
                        background: Item {}
                        onAccepted: { root.runCommand(text); text = ""; boardFocus.forceActiveFocus(); }
                        Keys.onEscapePressed: { text = ""; root.confirmation = ""; root.promotion = ""; root.helpVisible = false; boardFocus.forceActiveFocus(); }
                    }
                    // Messages live in the fixed-height bar so they never resize the board.
                    Text {
                        objectName: "messageText"
                        Layout.maximumWidth: parent.width * 0.6; visible: text.length > 0; elide: Text.ElideRight
                        text: root.message; color: root.messageError ? root.danger : root.muted; font.pixelSize: 13
                    }
                    ActionButton { objectName: "puzzlesButton"; visible: !root.game && root.view === ""; theme: root; compact: true; icon: "◎"; label: commandBar.narrow ? "" : "Puzzles"; hint: "z"; onClicked: root.view = "puzzles" }
                    ActionButton { objectName: "openingsButton"; visible: !root.game && root.view === ""; theme: root; compact: true; icon: "♞"; label: commandBar.narrow ? "" : "Openings"; hint: "o"; onClicked: root.view = "openings" }
                    ActionButton { objectName: "studyButton"; visible: !root.game && root.view === ""; theme: root; compact: true; icon: "◈"; label: commandBar.narrow ? "" : "Study"; hint: "d"; onClicked: root.view = "study" }
                    ActionButton { objectName: "profileButton"; visible: !root.game && root.view === ""; theme: root; compact: true; icon: "♔"; label: commandBar.narrow ? "" : root.account ? root.account.username : "Profile"; hint: "p"; onClicked: root.view = "profile" }
                    ActionButton { visible: !root.game && !commandBar.tiny; theme: root; compact: true; icon: "+"; label: commandBar.narrow ? "" : "New window"; hint: "w"; onClicked: root.newWindow() }
                    ActionButton { visible: !root.game && !commandBar.narrow; theme: root; objectName: "lobbyHelpButton"; compact: true; icon: "?"; label: "Help"; onClicked: root.helpVisible = true }
                }
            }
        }
    }
}
