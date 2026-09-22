#!/usr/bin/env python3
"""Offscreen Quickshell test with QtTest keyboard events and a real daemon."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("GAMBITO_TEST_BIN", ROOT / "target/debug/gambito"))

TEST = r'''
    property var testRequests: []
    TestCase {
        name: "GambitoKeyboard"
        when: socket.connected && window.visible
        function test_play() {
            boardFocus.forceActiveFocus();
            keyClick(Qt.Key_N);
            tryVerify(() => !!root.game, 5000);
            const first = root.selectedId;
            keyClick(Qt.Key_I);
            verify(command.activeFocus);
            keyClick(Qt.Key_E); keyClick(Qt.Key_4); keyClick(Qt.Key_Return);
            tryVerify(() => root.game.san.length === 1, 5000);
            compare(root.game.san[0], "e4");
            keyClick(Qt.Key_I); keyClick(Qt.Key_E); keyClick(Qt.Key_5); keyClick(Qt.Key_Return);
            tryVerify(() => root.game.san.length === 2, 5000);
            compare(root.game.san[1], "e5");
            keyClick(Qt.Key_N);
            tryVerify(() => root.selectedId !== first, 5000);
            compare(root.game.san.length, 0);
            keyClick(Qt.Key_Backspace);
            verify(!root.game);
            root.listIndex = root.orderedGames.findIndex(g => g.id === first);
            keyClick(Qt.Key_Return);
            compare(root.game.san.length, 2);
            keyClick(Qt.Key_F); verify(root.flipped);
            keyClick(Qt.Key_F); verify(!root.flipped);
            root.cursor = 62; // g1 knight
            keyClick(Qt.Key_Return);
            compare(root.origin, 62);
            keyClick(Qt.Key_Up); keyClick(Qt.Key_Up); keyClick(Qt.Key_Left); keyClick(Qt.Key_Return);
            tryVerify(() => root.game.san.length === 3, 5000);
            compare(root.game.san[2], "Nf3");
            keyClick(Qt.Key_I); keyClick(Qt.Key_E); keyClick(Qt.Key_5); keyClick(Qt.Key_Return);
            tryVerify(() => root.messageError, 5000);
            compare(root.game.san.length, 3);
            keyClick(Qt.Key_Escape);
            root.runCommand(":resign"); compare(root.confirmation, "resign");
            const confirmedGame = root.selectedId;
            keyClick(Qt.Key_Backspace); compare(root.selectedId, confirmedGame); compare(root.confirmation, "resign");
            keyClick(Qt.Key_Escape); compare(root.confirmation, "");
            keyClick(Qt.Key_I); command.text = "Nf3"; command.cursorPosition = 3;
            keyClick(Qt.Key_Backspace); compare(command.text, "Nf"); compare(root.selectedId, confirmedGame);
            keyClick(Qt.Key_Escape);
            keyClick(Qt.Key_G); compare(root.selectedId, confirmedGame);
            compare(root.game.status, "started");
            // Every keyboard action has an on-screen button.
            const click = name => { const item = findChild(pageLayout, name); verify(item && item.visible, name); mouseClick(item); };
            click("flipButton"); verify(root.flipped); click("flipButton"); verify(!root.flipped);
            click("resignButton"); compare(root.confirmation, "resign");
            click("cancelConfirmButton"); compare(root.confirmation, "");
            click("helpButton"); verify(root.helpVisible); click("closeHelpButton"); verify(!root.helpVisible);
            root.promotion = "a7a8";
            verify(findChild(pageLayout, "promotionPicker").visible);
            click("promotionCancel"); compare(root.promotion, "");
            // Rewind: [ ] step, « » ends, board locked while viewing the past.
            boardFocus.forceActiveFocus(); root.tell("", false);
            compare(root.game.moves.length, 3);
            keyClick("["); tryVerify(() => root.viewPly === 2, 5000);
            compare(root.board[62], "N");
            root.selectSquare(52); verify(root.messageError); compare(root.origin, -1);
            keyClick(Qt.Key_Home); compare(root.viewPly, 0); compare(findChild(pageLayout, "rewindStart").hint, "Home"); compare(root.board[52], "P");
            click("rewindForward"); compare(root.viewPly, 1);
            keyClick(Qt.Key_End); compare(root.viewPly, -1); compare(root.board[62], "");
            // Engine: fake UCI engine, score from White's side (black to move, cp 35 -> -35).
            keyClick("e"); verify(root.engineOn);
            tryVerify(() => root.evalData && root.evalData.source === "FakeFish", 5000);
            compare(root.evalData.depth, 4); compare(root.evalData.cp, -10);
            verify(root.evalPending); verify(root.evalProgress > 0 && root.evalProgress < 1);
            verify(findChild(pageLayout, "engineProgress").visible);
            tryVerify(() => !root.evalPending, 5000);
            compare(root.evalProgress, 1);
            compare(root.evalData.cp, -35); verify(root.whiteShare() < 0.5); verify(findChild(pageLayout, "evalBar").visible);
            const depthInput = findChild(pageLayout, "depthInput");
            verify(depthInput && depthInput.visible);
            compare(root.engineDepth, 30);
            boardFocus.forceActiveFocus(); keyClick("=");
            compare(root.engineDepth, 31);
            tryVerify(() => root.evalData && root.evalData.target_depth === 31 && !root.evalPending, 5000);
            compare(root.evalData.depth, 31);
            keyClick("-"); compare(root.engineDepth, 30);
            keyClick("d"); verify(command.activeFocus); compare(command.text, ":depth 30");
            command.text = ":depth 32"; keyClick(Qt.Key_Return); compare(root.engineDepth, 32);
            root.runCommand(":depth 0"); compare(root.engineDepth, 32);
            root.runCommand(":depth 246"); compare(root.engineDepth, 32);
            click("depthDecrease"); compare(root.engineDepth, 31);
            click("depthIncrease"); compare(root.engineDepth, 32);
            root.engineDepth = 31;
            const slider = findChild(pageLayout, "depthSlider");
            verify(slider && slider.visible);
            slider.forceActiveFocus(); keyClick(Qt.Key_Left);
            compare(root.engineDepth, 30);
            tryVerify(() => root.evalData && root.evalData.target_depth === 30 && !root.evalPending, 5000);
            boardFocus.forceActiveFocus();
            keyClick("e"); verify(!root.engineOn);
            root.receive(JSON.stringify({type: "eval", request_id: "stale", eval: {for: root.selectedId, ply: root.shownPly(), cp: 900}}));
            compare(root.evalData, null);
            root.playVisible = true;
            verify(findChild(pageLayout, "playScreen").visible);
            click("customTile"); verify(findChild(pageLayout, "playCustomButton").visible);
            // Play screen by keyboard: mode, rated, side, level, custom clock, grid focus.
            const ps = findChild(pageLayout, "playScreen");
            boardFocus.forceActiveFocus();
            ps.mode = "opponent"; ps.customOpen = false; ps.cursor = 0;
            compare(ps.shown.length, 5); verify(findChild(pageLayout, "seekNote").visible); // Rapid and Classical only
            keyClick(Qt.Key_M); compare(ps.mode, "computer"); keyClick(Qt.Key_M); compare(ps.mode, "opponent");
            keyClick(Qt.Key_R); verify(ps.rated); keyClick(Qt.Key_R); verify(!ps.rated);
            keyClick(Qt.Key_M); keyClick(Qt.Key_S); compare(ps.side, "black"); keyClick(Qt.Key_5); compare(ps.level, 5); keyClick(Qt.Key_M);
            keyClick(Qt.Key_L); compare(ps.cursor, 1); keyClick(Qt.Key_J); compare(ps.cursor, 5); // custom tile, below 10+5
            keyClick(Qt.Key_J); compare(ps.cursor, 7); // down from the grid lands on correspondence days
            keyClick(Qt.Key_K); verify(ps.cursor < 6);
            keyClick(Qt.Key_C); verify(ps.customOpen); compare(ps.cursor, 5);
            keyClick(Qt.Key_Plus); compare(ps.customMinutes, 11); keyClick(Qt.Key_BracketLeft); compare(ps.customIncrement, 4);
            keyClick(Qt.Key_C); verify(!ps.customOpen);
            ps.mode = "computer"; compare(ps.shown.length, 11); verify(!findChild(pageLayout, "seekNote").visible); ps.mode = "opponent";
            keyClick(Qt.Key_Escape); verify(root.playVisible);
            keyClick(Qt.Key_Backspace); verify(!root.playVisible);
            root.playVisible = true; click("closePlayButton"); verify(!root.playVisible);
            root.engineOn = false;
            root.rewind(1); tryVerify(() => root.viewPly === 1, 5000);
            boardFocus.forceActiveFocus(); keyClick("a");
            tryVerify(() => root.game && root.game.analysis, 5000);
            const branch = root.selectedId;
            compare(root.game.analysis_source, first); compare(root.game.moves.length, 1);
            root.runCommand("c5"); tryVerify(() => root.game.san.length === 2, 5000);
            compare(root.game.san[1], "c5");
            compare(root.games.find(g => g.id === first).san.join(" "), "e4 e5 Nf3");
            root.rewind(1); tryVerify(() => root.viewPly === 1, 5000);
            click("analyseButton"); tryVerify(() => root.selectedId !== branch, 5000);
            const alternate = root.selectedId;
            root.runCommand("e5"); tryVerify(() => root.game.san.length === 2, 5000);
            boardFocus.forceActiveFocus(); keyClick(Qt.Key_Backspace);
            tryVerify(() => root.selectedId === branch && root.viewPly === 1, 5000);
            compare(root.game.san[1], "c5");
            verify(findChild(pageLayout, "variationList").count === 1);
            click("deleteVariation0"); compare(root.confirmation, "delete"); compare(root.deleteTarget, alternate);
            keyClick(Qt.Key_Escape); compare(root.confirmation, "");
            root.choose(alternate); click("deleteBoardButton"); compare(root.confirmation, "delete");
            keyClick(Qt.Key_Escape); compare(root.confirmation, "");
            keyClick(Qt.Key_X); compare(root.confirmation, "delete");
            keyClick(Qt.Key_Return);
            tryVerify(() => root.selectedId === branch && !root.games.some(g => g.id === alternate), 5000);
            tryVerify(() => findChild(pageLayout, "variationList").count === 0, 5000);
            click("sourceButton");
            tryVerify(() => root.selectedId === first && root.viewPly === 1, 5000);
            compare(root.game.san.length, 3);
            root.choose(branch);
            root.tell("", false); root.engineOn = true;
            tryVerify(() => root.evalData && !root.evalPending, 5000);
            verify(root.evalData.best === "e7e5" || root.evalData.best === null);
            // Lobby: TV, daily puzzle and news (injected; the daemon's Lichess is unreachable here).
            root.engineOn = false; keyClick(Qt.Key_Backspace); tryVerify(() => root.selectedId === first, 5000); keyClick(Qt.Key_Backspace); verify(!root.game);
            tryVerify(() => !!findChild(pageLayout, "lobbyView"), 5000);
            const lobby = findChild(pageLayout, "lobbyView");
            tryVerify(() => lobby.puzzleError && lobby.blogError, 10000);
            const f0 = "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4";
            const f1 = "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4";
            lobby.puzzle = {id: "Pz001", rating: 1609, themes: ["mateIn1", "backRankMate"], solution: ["h5f7", "a7a6", "c4b5"], fens: [f0, f1, f0, f1], last_move: "g8f6"};
            compare(lobby.solverColor, "white"); verify(lobby.puzzleTurn);
            // Lobby keys: s/c need an account (they start sign-in), v shows the move, u opens the board.
            boardFocus.forceActiveFocus();
            let before = root.serial; keyClick(Qt.Key_S); compare(root.pending[String(before + 1)], "login");
            before = root.serial; keyClick(Qt.Key_V); compare(lobby.pick, lobby.squareIndex("h5")); lobby.pick = -1;
            before = root.serial; keyClick(Qt.Key_U); compare(root.pending[String(before + 1)], "puzzle_open");
            tryVerify(() => root.messageError, 5000); root.tell("", false);
            lobby.puzzleClick(lobby.squareIndex("h5")); compare(lobby.pick, lobby.squareIndex("h5"));
            lobby.puzzleClick(lobby.squareIndex("h6")); compare(lobby.puzzleState, "wrong"); compare(lobby.step, 0);
            lobby.puzzleClick(lobby.squareIndex("h5")); lobby.puzzleClick(lobby.squareIndex("f7"));
            compare(lobby.step, 1); verify(!lobby.puzzleTurn);
            tryVerify(() => lobby.step === 2 && lobby.puzzleTurn, 3000); // opponent's reply is played automatically
            lobby.puzzleClick(lobby.squareIndex("c4")); lobby.puzzleClick(lobby.squareIndex("b5"));
            compare(lobby.puzzleState, "solved"); compare(lobby.step, 3);
            lobby.resetPuzzle(); compare(lobby.step, 0);
            root.tvEvent({t: "featured", d: {id: "tv000001", orientation: "white", fen: f0, players: [{color: "white", user: {name: "jjosujjosu", title: "GM"}, rating: 2975, seconds: 45}, {color: "black", user: {name: "JiAnGHaOcHeN"}, rating: 3116, seconds: 37}]}}, "");
            root.tvEvent({t: "fen", d: {fen: f1, lm: "h5f7", wc: 44, bc: 37}}, "");
            const lobbyTv = findChild(pageLayout, "lobbyTv");
            compare(lobbyTv.tv.lm, "h5f7"); compare(lobbyTv.tv.wc, 44);
            lobby.blog = {official: [{title: "46th FIDE Chess Olympiad starts tomorrow", author: "Lichess", published: "2026-09-15T07:00:00Z", url: "https://lichess.org/@/Lichess/blog/x"}],
                          community: [{title: "Rounding up the first week of the GCL", author: "MEGALODON777hs", published: "2026-09-11T10:00:00Z", url: "https://lichess.org/@/a/blog/y"}]};
            compare(findChild(pageLayout, "newsList").count, 2);
            // The lobby cursor continues from the games in progress into the news.
            root.listIndex = root.orderedGames.length - 1; keyClick(Qt.Key_J); keyClick(Qt.Key_J);
            compare(findChild(pageLayout, "newsList").currentIndex, 1);
            keyClick(Qt.Key_J); compare(findChild(pageLayout, "newsList").currentIndex, 1); // stops at the last post
            root.listIndex = 0;
            root.tell("", false); wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-lobby.png"))); wait(300);
            // TV page: separate from the play board; moves of the shown game in its side panel.
            const featured = {t: "featured", d: {id: "tv000001", orientation: "black", fen: f1, players: [{color: "white", user: {name: "Frogkiller", title: "FM"}, rating: 2735, seconds: 39}, {color: "black", user: {name: "McBeast", title: "NM"}, rating: 2704, seconds: 37}]}};
            mouseClick(findChild(pageLayout, "tvOpen"));
            tryVerify(() => !!findChild(pageLayout, "tvView"), 5000); compare(root.view, "tv"); compare(root.selectedId, "");
            // The destroyed lobby board must not stop the TV page's new feed.
            tryVerify(() => root.tvOwner === findChild(pageLayout, "tvMainBoard"), 5000);
            const tvv = findChild(pageLayout, "tvView");
            root.tvEvent(featured, "");
            compare(tvv.watchedId, "tv000001"); compare(root.selectedId, ""); // streamed for the panel, not selected
            // The stream never connects here; inject the watched game so its moves show.
            root.games = root.games.concat([Object.assign({}, root.games.find(g => g.id === first), {id: "tv000001", online: true, color: null, status: "started"})]);
            tryVerify(() => findChild(pageLayout, "tvMoves").count === 2, 5000);
            verify(!root.orderedGames.some(g => g.id === "tv000001")); // never listed as a game in progress
            tvv.channels = {best: {user: {name: "Mlchael", title: "IM"}, rating: 2902}, bullet: {user: {name: "Frogkiller", title: "FM"}, rating: 2735}};
            tvv.crosstable = {users: {frogkiller: 15.5, mcbeast: 26.5}, nbGames: 42};
            verify(tvv.showScore);
            compare(String(findChild(pageLayout, "tvScore0").color), String(root.danger)); // Frogkiller 15½ trails
            compare(String(findChild(pageLayout, "tvScore1").color), String(root.winColor)); // McBeast 26½ leads
            // Captures: after 1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6 4.Qxf7# white has taken a pawn.
            const cap = root.captures("r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4");
            compare(cap.lead, 1); compare(cap.white, root.glyph("p")); compare(cap.black, "");
            keyClick(Qt.Key_J); compare(tvv.channel, "bullet");
            root.tvEvent(featured, "");
            root.tell("", false); wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-tv.png"))); wait(300);
            keyClick(Qt.Key_Z); verify(root.zen); verify(!findChild(pageLayout, "tvSidebar").visible); verify(!commandBar.visible);
            keyClick(Qt.Key_J); compare(tvv.channel, "blitz"); keyClick(Qt.Key_K); compare(tvv.channel, "bullet");
            keyClick(Qt.Key_Z); verify(!root.zen); verify(findChild(pageLayout, "tvSidebar").visible);
            root.tvEvent(featured, "");
            // A new featured game is followed: the old one is unwatched.
            const beforeFollow = root.serial;
            root.tvEvent({t: "featured", d: Object.assign({}, featured.d, {id: "tv000002"})}, "");
            compare(tvv.watchedId, "tv000002");
            verify(root.serial >= beforeFollow + 2); compare(root.selectedId, ""); // unwatch, watch (+ score)
            root.tvEvent(featured, ""); compare(tvv.watchedId, "tv000001");
            // Enter opens the board, Backspace returns to its page. The old alias does nothing.
            keyClick(Qt.Key_O); compare(root.selectedId, "");
            keyClick(Qt.Key_Enter);
            tryVerify(() => root.selectedId === "tv000001", 5000);
            compare(root.orientation({id: "tv000001", color: null}), "black");
            root.watchOrientation["tv000002"] = "black"; compare(root.orientation({id: "tv000002", color: null}), "black");
            compare(root.orientation({id: "x", color: "black"}), "black");
            keyClick(Qt.Key_Backspace); tryVerify(() => !!findChild(pageLayout, "tvView"), 5000);
            keyClick(Qt.Key_Escape); verify(root.view !== "");
            keyClick(Qt.Key_Backspace); tryVerify(() => !!findChild(pageLayout, "lobbyView"), 5000);
            root.games = root.games.filter(g => g.id !== "tv000001");
            // Broadcast browsing stays in TV; stale replies cannot replace the selected game.
            keyClick(Qt.Key_T);
            tryVerify(() => !!findChild(pageLayout, "tvView"), 5000);
            keyClick(Qt.Key_B);
            tryVerify(() => !!findChild(pageLayout, "broadcastView"), 5000);
            const bv = findChild(pageLayout, "broadcastView");
            tryVerify(() => !bv.busy, 5000); // Settle real replies before injecting fixtures.
            bv.retryAt = 0;
            bv.request = "broadcast-fixture";
            root.broadcastReply("broadcast-fixture", "broadcasts", {broadcast: {active: [{tour: {id: "tour0001", name: "Invitational"}, round: {name: "Round 1", ongoing: true}}]}}, "");
            compare(bv.rows.length, 1); compare(root.selectedId, "");
            keyClick(Qt.Key_Return); tryVerify(() => !bv.busy, 5000);
            bv.request = "tour-fixture";
            root.broadcastReply("tour-fixture", "broadcast_tournament", {broadcast: {tour: {id: "tour0001", name: "Invitational"}, rounds: [{id: "round001", name: "Round 1"}]}}, "");
            compare(bv.title, "Invitational");
            keyClick(Qt.Key_Return); tryVerify(() => !bv.busy, 5000);
            bv.request = "round-fixture";
            const bg = {id: "chapter1", name: "Alpha – Beta", fen: f1, lastMove: "h5f7", status: "*", players: [{name: "Alpha", clock: 12345}, {name: "Beta"}]};
            root.broadcastReply("round-fixture", "broadcast_round", {broadcast: {round: {id: "round001", name: "Round 1"}, games: [bg, Object.assign({}, bg, {id: "chapter2", name: "Gamma – Delta"})]}}, "");
            keyClick(Qt.Key_Return); tryVerify(() => !bv.historyRequest, 5000);
            compare(bv.selected.id, "chapter1"); compare(bv.clock(bg.players[0]), "2:03"); compare(bv.clock(bg.players[1]), "—");
            keyClick(Qt.Key_O); verify(!Object.values(root.pending).includes("broadcast_open"));
            compare(findChild(pageLayout, "broadcastAnalyse").hint, "a");
            bv.historyRequest = "moves-fixture";
            root.broadcastReply("old-request", "broadcast_game", {round: "round001", chapter: "chapter1", broadcast_game: {san: ["d4"]}}, "");
            verify(!bv.history);
            root.broadcastReply("moves-fixture", "broadcast_game", {round: "round001", chapter: "chapter1", broadcast_game: {san: ["e4", "e5"]}}, "");
            compare(bv.history.san.length, 2); compare(root.selectedId, "");
            verify(findChild(pageLayout, "broadcastAnalyse").enabled);
            const broadcastTv = findChild(pageLayout, "tvView");
            broadcastTv.contentY = Math.max(0, broadcastTv.contentHeight - broadcastTv.height);
            waitForRendering(findChild(pageLayout, "broadcastAnalyse"));
            keyClick(Qt.Key_A);
            const analysisRequest = root.testRequests.filter(r => r.cmd === "broadcast_open").pop();
            compare(analysisRequest.round, "round001"); compare(analysisRequest.chapter, "chapter1");
            tryVerify(() => !Object.values(root.pending).includes("broadcast_open"), 5000);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-broadcast.png"))); wait(100);
            keyClick(Qt.Key_J); keyClick(Qt.Key_Return); tryVerify(() => !bv.historyRequest, 5000);
            compare(bv.selected.id, "chapter2"); verify(!bv.history);
            // Live events replace the board/history, results update filters, old subscriptions cannot win.
            const subscription = bv.subscription;
            const updated = Object.assign({}, bg, {id: "chapter2", lastMove: "e7e5", state: "playing", history: {san: ["e4", "e5"]}});
            root.broadcastEvent({round: "round001", subscription: "old", game: updated});
            verify(!bv.history);
            root.broadcastEvent({round: "round001", subscription: subscription, game: updated});
            compare(bv.history.san.length, 2); compare(bv.selected.lastMove, "e7e5");
            keyClick(Qt.Key_2); compare(bv.gameFilter, "playing"); compare(bv.rows.length, 2);
            root.broadcastEvent({round: "round001", subscription: subscription, game: Object.assign({}, updated, {state: "finished", status: "1-0"})});
            compare(bv.rows.length, 1); compare(bv.selected.status, "1-0");
            keyClick(Qt.Key_3); compare(bv.rows.length, 1); compare(bv.rows[0].id, "chapter2");
            keyClick(Qt.Key_4); compare(bv.rows.length, 0);
            root.broadcastEvent({round: "round001", subscription: subscription, game: Object.assign({}, bg, {id: "chapter3", lastMove: "", state: "waiting"})});
            compare(bv.rows.length, 1); compare(bv.count("waiting"), 1);
            root.broadcastEvent({round: "round001", subscription: subscription, connected: false, error: "Connection lost"});
            verify(!bv.liveConnected); compare(bv.liveError, "Connection lost"); compare(bv.selected.status, "1-0");
            keyClick(Qt.Key_1); compare(bv.rows.length, 3);
            keyClick(Qt.Key_Backspace); verify(!bv.round); verify(!!bv.tournament);
            compare(bv.subscription, "");
            keyClick(Qt.Key_Backspace); verify(!bv.tournament);
            bv.request = "error-fixture";
            root.broadcastReply("error-fixture", "broadcasts", null, "Lichess rate limited requests (429); wait a minute");
            verify(bv.error.includes("429")); verify(bv.retryAt > Date.now());
            keyClick(Qt.Key_B); verify(!!findChild(pageLayout, "broadcastView"));
            keyClick(Qt.Key_Backspace);
            tryVerify(() => !findChild(pageLayout, "broadcastView"), 5000);
            verify(!!root.tvOwner);
            keyClick(Qt.Key_Backspace);
            // Openings page: tree walking, tabs, database switch and opening examples/analysis.
            keyClick(Qt.Key_O); tryVerify(() => !!findChild(pageLayout, "openingsView"), 5000);
            const op = findChild(pageLayout, "openingsView");
            keyClick("?"); verify(root.helpVisible);
            keyClick(Qt.Key_Backspace); verify(root.helpVisible); compare(root.view, "openings");
            keyClick(Qt.Key_Escape); verify(!root.helpVisible); compare(root.view, "openings");
            // Each load() gets an error reply here (no Lichess account); inject data only after it, or it would be cleared.
            const settle = () => tryVerify(() => op.error !== "", 5000);
            settle();
            const start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
            const afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1";
            const tree = {fen: start, explorer: {white: 933863, draws: 1271743, black: 673981, opening: null, topGames: [{id: "mstr0001", white: {name: "Carlsen, M.", rating: 2882}, black: {name: "Caruana, F.", rating: 2818}, winner: null, year: 2019}], moves: [
                {san: "e4", uci: "e2e4", white: 419328, draws: 573290, black: 316848, fen: afterE4, opening: {eco: "B00", name: "King's Pawn Game"}},
                {san: "d4", uci: "d2d4", white: 334470, draws: 461840, black: 233568, fen: "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1", opening: {eco: "A40", name: "Queen's Pawn Game"}},
                {san: "Nf3", uci: "g1f3", white: 97528, draws: 130393, black: 65036, fen: "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1", opening: {eco: "A04", name: "Zukertort Opening"}},
                {san: "c4", uci: "c2c4", white: 67094, draws: 87549, black: 44799, fen: "rnbqkbnr/pppppppp/8/8/2P5/8/PP1PPPPP/RNBQKBNR b KQkq - 0 1", opening: {eco: "A10", name: "English Opening"}}]}};
            op.result = tree;
            compare(findChild(pageLayout, "openingsGrid").count, 4);
            keyClick(Qt.Key_L); compare(op.index, 1);
            keyClick(Qt.Key_H); keyClick(Qt.Key_Return);
            compare(op.line.length, 1); compare(op.line[0].uci, "e2e4"); compare(op.name, "King's Pawn Game");
            keyClick(Qt.Key_U); keyClick(Qt.Key_B); keyClick(Qt.Key_G); compare(op.line.length, 1); compare(root.view, "openings");
            verify(op.request !== "");
            settle();
            op.result = {fen: afterE4, explorer: {white: 10, draws: 5, black: 5, opening: {eco: "B00", name: "King's Pawn Game"}, moves: [{san: "c5", uci: "c7c5", white: 5, draws: 2, black: 3, fen: afterE4, opening: {eco: "B20", name: "Sicilian Defense"}}], topGames: []}};
            compare(op.lineText(), "1. e4");
            keyClick(Qt.Key_Backspace); compare(op.line.length, 0);
            op.line = [{uci: "e2e4", san: "e4", name: "King's Pawn Game"}];
            keyClick(Qt.Key_Home); compare(op.line.length, 0);
            settle(); op.result = tree; wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-openings.png"))); wait(300);
            keyClick(Qt.Key_2); compare(op.tab, "examples"); compare(findChild(pageLayout, "openingsGames").count, 1);
            keyClick(Qt.Key_M); compare(op.db, "lichess"); verify(findChild(pageLayout, "openingsSpeed").visible);
            keyClick(Qt.Key_S); compare(op.speedAt, 1); keyClick(Qt.Key_R); compare(op.ratingAt, 1);
            settle(); op.db = "masters"; settle(); op.result = tree;
            const beforeOpen = root.serial;
            op.openExample(0); compare(root.pending[String(beforeOpen + 1)], "analyse");
            tryVerify(() => root.messageError, 5000); // no Lichess here: the masters PGN can't be fetched
            keyClick(Qt.Key_Escape); verify(root.view !== "");
            keyClick(Qt.Key_Backspace); tryVerify(() => !!findChild(pageLayout, "lobbyView"), 5000);
            // Puzzle themes page: categories, difficulty, starting a themed puzzle.
            keyClick(Qt.Key_Z); tryVerify(() => !!findChild(pageLayout, "puzzlesView"), 5000);
            const pz = findChild(pageLayout, "puzzlesView");
            pz.catalog = {themes: {Recommended: [{key: "mix", name: "Healthy mix", desc: "A bit of everything. You don't know what to expect, so be ready for anything! Just like in real games.", count: 6404540}],
                                   Phases: [{key: "opening", name: "Opening", desc: "A tactic during the first phase of the game.", count: 321447}, {key: "middlegame", name: "Middlegame", desc: "A tactic during the second phase of the game.", count: 2917156}, {key: "endgame", name: "Endgame", desc: "A tactic during the last phase of the game.", count: 3165937}],
                                   Mates: [{key: "mateIn1", name: "Mate in 1", desc: "Deliver checkmate in one move.", count: 912293}]},
                          openings: [{family: {key: "Sicilian_Defense", name: "Sicilian Defense", count: 204576}, openings: [{name: "Old Sicilian"}, {name: "Alapin Variation"}]}]};
            compare(pz.categories.length, 4); compare(pz.categories[3].name, "By opening");
            keyClick(Qt.Key_BracketRight); compare(pz.category, 1); compare(findChild(pageLayout, "puzzleThemes").count, 3);
            compare(findChild(pageLayout, "puzzleCategories").currentIndex, 1);
            keyClick(Qt.Key_L); compare(pz.index, 1);
            keyClick(Qt.Key_D); compare(root.puzzleDifficulty, "harder");
            wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-puzzles.png"))); wait(300);
            const beforeTheme = root.serial;
            keyClick(Qt.Key_Return); compare(root.pending[String(beforeTheme + 1)], "puzzle_next");
            tryVerify(() => root.messageError, 5000); // no Lichess here
            root.puzzleDifficulty = "normal";
            keyClick(Qt.Key_Escape); verify(root.view !== "");
            keyClick(Qt.Key_Backspace); tryVerify(() => !!findChild(pageLayout, "lobbyView"), 5000);
            // Analysis boards live in Profile → Boards; delete one from there.
            verify(!root.orderedGames.some(g => g.analysis));
            keyClick(Qt.Key_P); tryVerify(() => !!findChild(pageLayout, "profileView"), 5000);
            const pv = findChild(pageLayout, "profileView");
            compare(pv.tab, "boards"); // no Lichess account in this test
            pv.index = root.boardGames.findIndex(g => g.id === branch);
            verify(pv.index >= 0); wait(100);
            click("listDelete" + pv.index); compare(root.confirmation, "delete");
            keyClick(Qt.Key_Escape); compare(root.confirmation, "");
            verify(!!findChild(pageLayout, "profileView")); // Esc cancelled the confirmation, not the view
            keyClick(Qt.Key_X); compare(root.deleteTarget, branch); wait(100);
            click("listConfirmDelete" + pv.index);
            tryVerify(() => !root.games.some(g => g.id === branch), 5000);
            keyClick(Qt.Key_Backspace); tryVerify(() => !findChild(pageLayout, "profileView"), 5000); compare(root.view, "");
            keyClick(Qt.Key_P); tryVerify(() => !!findChild(pageLayout, "profileView"), 5000);
            // Injected Lichess data: chart, stats, history rows and result filter.
            const pv2 = findChild(pageLayout, "profileView");
            root.account = {username: "Tester"};
            pv2.info = {account: {username: "Tester", createdAt: 1605761265990, playTime: {total: 186584}, count: {all: 366, win: 158, draw: 8, loss: 200},
                                  perfs: {rapid: {games: 314, rating: 858, prog: -4, prov: true}, blitz: {games: 20, rating: 627, prog: 0}}},
                        ratings: [{name: "Rapid", points: [[2021, 0, 5, 1000], [2022, 3, 1, 1059], [2024, 6, 1, 810], [2026, 8, 16, 858]]}], activity: [{interval: {start: 1789516800000, end: 1789603200000}, games: {rapid: {win: 2, loss: 2, draw: 0, rp: {before: 759, after: 858}}}}]};
            pv2.perfKey = "rapid";
            pv2.perfStats = {stat: {count: {all: 315, win: 145, draw: 8, loss: 162, seconds: 175878}, highest: {int: 1059, at: "2021-02-03T17:55:10.78Z"}, lowest: {int: 810},
                             bestWins: {results: [{opRating: 1147, opId: {name: "AlvinBolt"}}]}, worstLosses: {results: [{opRating: 742, opId: {name: "mviv00"}}]}, resultStreak: {win: {cur: {v: 0}, max: {v: 9}}}}};
            pv2.tab = "games";
            pv2.rows = [{id: "aaaaaaaa", white: "Tester", black: "Rival", white_rating: 858, black_rating: 870, rated: true, speed: "rapid", time_control: "10+5", status: "resign", winner: "white", color: "white", updated_ms: 1789603200000, plies: 51, accuracy: {white: 85, black: 71}},
                        {id: "bbbbbbbb", white: "Other", black: "Tester", white_rating: 900, black_rating: 850, rated: true, speed: "rapid", time_control: "10+0", status: "mate", winner: "white", color: "black", updated_ms: 1789500000000, plies: 43, accuracy: {white: null, black: null}}];
            compare(pv2.points.length, 4);
            compare(pv2.currentList.length, 2);
            pv2.resultFilter = "loss"; compare(pv2.currentList.length, 1); pv2.resultFilter = "";
            verify(findChild(pageLayout, "ratingChart").visible); verify(findChild(pageLayout, "perfStats").visible);
            keyClick(Qt.Key_J); compare(pv2.index, 1);
            keyClick(Qt.Key_O); compare(pv2.resultFilter, "win"); pv2.resultFilter = "";
            // Hover moves the selection only when the pointer moves, not when rows scroll under it.
            verify(root.pointerMoved(pageLayout, {x: 7, y: 9})); verify(!root.pointerMoved(pageLayout, {x: 7, y: 9}));
            // Signing out asks first; Esc cancels without leaving the profile.
            keyClick(Qt.Key_L); compare(root.confirmation, "logout");
            keyClick(Qt.Key_Escape); compare(root.confirmation, ""); verify(!!findChild(pageLayout, "profileView"));
            // Puzzles tab: summary, recent results and themes weakest first; Enter practises one.
            keyClick(Qt.Key_4); compare(pv2.tab, "puzzles");
            tryVerify(() => pv2.puzzleError !== "", 5000); // the real request fails here; inject after its reply
            pv2.info.account.perfs.puzzle = {rating: 1066, prov: true, games: 63};
            pv2.puzzleStats = {dashboard: {days: 365, global: {nb: 63, firstWins: 40, replayWins: 3, puzzleRatingAvg: 1180, performance: 1120},
                                            themes: {fork: {theme: "Fork", results: {nb: 12, firstWins: 9, performance: 1250}}, backRankMate: {theme: "Back rank mate", results: {nb: 8, firstWins: 3, performance: 980}}}},
                               activity: [{win: true, puzzle: {id: "a"}}, {win: false, puzzle: {id: "b"}}, {win: true, puzzle: {id: "c"}}]};
            compare(pv2.currentList.length, 2); compare(pv2.currentList[0].key, "backRankMate");
            wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-profile-puzzles.png"))); wait(300);
            const beforePractice = root.serial;
            pv2.index = 0; keyClick(Qt.Key_Return);
            compare(root.pending[String(beforePractice + 1)], "puzzle_next");
            pv2.puzzleStats = null; keyClick(Qt.Key_1);
            wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-profile.png"))); wait(300);
            root.account = null; keyClick(Qt.Key_Backspace); tryVerify(() => !findChild(pageLayout, "profileView"), 5000);
            // Lichess server analysis of a finished online game (injected; no network in UI tests).
            root.engineOn = false;
            const analysed = Object.assign({}, root.games.find(g => g.id === first), {id: "hist0001", online: true, status: "mate", color: "white",
                lichess_analysis: {moves: [{eval: 20}, {eval: 25}, {eval: -80, best: "b1c3", variation: "Nc3 Nf6 Bc4", judgment: {name: "Mistake", comment: "Mistake. Nc3 was best."}}],
                                   white: {accuracy: 85, inaccuracy: 2, mistake: 1, blunder: 1}, black: {accuracy: 71, inaccuracy: 3, mistake: 1, blunder: 3}}});
            root.games = root.games.concat([analysed]); root.choose("hist0001");
            // Correspondence clocks read in days and hours, not as a wall clock.
            root.games = root.games.filter(g => g.id !== "hist0001").concat([Object.assign({}, analysed, {speed: "correspondence", status: "started", connected: false, white_ms: 86_400_000, black_ms: 3_600_000 * 23 + 59_000})]);
            compare(root.clock("white"), "1d 0h"); compare(root.clock("black"), "23h 0m");
            root.games = root.games.filter(g => g.id !== "hist0001").concat([Object.assign({}, analysed, {speed: "rapid", status: "started", connected: false, white_ms: 3_600_000 + 61_000})]);
            compare(root.clock("white"), "1:01:01");
            root.games = root.games.filter(g => g.id !== "hist0001").concat([analysed]);
            root.positions = {game: "hist0001", plies: 3, fens: ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
                "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"]};
            root.viewPly = 2;
            compare(root.judgement(2), "mistake");
            compare(JSON.stringify(root.arrows.map(a => a.uci)), JSON.stringify(["g1f3", "b1c3"]));
            verify(!findChild(pageLayout, "reviewCard").visible); // analysis shows in the player rows
            verify(findChild(pageLayout, "playedVsBest").visible);
            compare(root.moveLabel(2, "Nc3"), "2. Nc3");
            compare(root.materialBalance, 0); verify(!findChild(pageLayout, "whiteMaterial").visible);
            // Zen mode: only the board; the command bar comes back while typing.
            click("zenButton"); verify(root.zen);
            tryVerify(() => !findChild(pageLayout, "sidePanel").visible && !commandBar.visible, 3000);
            verify(findChild(pageLayout, "zenExit").visible);
            boardFocus.forceActiveFocus(); keyClick(Qt.Key_I); verify(commandBar.visible);
            keyClick(Qt.Key_Escape); verify(!commandBar.visible);
            keyClick(Qt.Key_Z); verify(!root.zen); verify(findChild(pageLayout, "sidePanel").visible);
            compare(root.formatPv({ply: 2, pv: ["Nc3", "Nf6"]}), "2. Nc3 Nf6");
            wait(200);
            // Captures the actual rendered window
            // Opening explorer on a finished game: rows, shares, and clicking a move branches an analysis board.
            // Re-inject: a daemon state update in the meantime replaces injected games.
            if (!root.game) { root.games = root.games.filter(g => g.id !== "hist0001").concat([analysed]); root.selectedId = "hist0001"; root.viewPly = 2; }
            tryVerify(() => !!findChild(pageLayout, "explorerCard"), 5000);
            root.explorerOn = true; verify(findChild(pageLayout, "explorerCard").visible);
            tryVerify(() => !!root.explorerData, 5000); // the daemon has no such game here: an error first
            root.explorerData = {db: "masters", explorer: {white: 933863, draws: 1271743, black: 673981, opening: {eco: "C20", name: "King's Pawn Game"},
                moves: [{san: "Nf3", uci: "g1f3", white: 97528, draws: 130393, black: 65036}, {san: "Bc4", uci: "f1c4", white: 5000, draws: 4000, black: 3000}]}};
            compare(findChild(pageLayout, "explorerList").count, 3);
            wait(200);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-explorer.png"))); wait(300);
            const beforeBranch = root.serial;
            root.playExplorerMove("g1f3");
            compare(root.pendingExplorerMove, "g1f3"); compare(root.pending[String(beforeBranch + 1)], "analyse");
            root.pendingExplorerMove = ""; root.explorerOn = false;
            // Captures the actual rendered window, including pieces and move list.
            pageLayout.grabToImage(result => {
                result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT"));
            });
            wait(500);
            // A watched Lichess game is not "in progress", and leaving it unwatches it.
            const watched = Object.assign({}, root.games.find(g => g.id === first), {id: "watched1", online: true, color: null, status: "started"});
            root.games = root.games.concat([watched]);
            verify(!root.orderedGames.some(g => g.id === "watched1"));
            root.choose("watched1"); compare(root.selectedId, "watched1");
            const unwatchFrom = root.serial;
            root.selectedId = "";
            compare(root.pending[String(unwatchFrom + 1)], "unwatch");
            // Daily puzzle on the main board (injected; Lichess is unreachable in tests).
            root.engineOn = false;
            const puzzleGame = Object.assign({}, root.games.find(g => g.id === first), {id: "puzzle-Pz001", color: "white", white: "Agadmater", black: "Gummyy", white_rating: 1526, black_rating: 1532,
                puzzle: {id: "Pz001", rating: 1698, plays: 58311, themes: ["mateIn1", "backRankMate"], solution: ["d1h5"], start: 3, source: {clock: "3+2", perf: "Blitz"}}});
            root.games = root.games.concat([puzzleGame]); root.choose("puzzle-Pz001");
            tryVerify(() => !!findChild(pageLayout, "puzzlePanel") && findChild(pageLayout, "puzzlePanel").visible, 5000);
            verify(root.puzzleUnsolved); verify(!root.engineAllowed);
            compare(root.statusText(), "Puzzle · your turn");
            verify(!findChild(pageLayout, "resignButton").visible);
            root.puzzleHint(); compare(root.origin, 59); // d1
            root.analyse(); verify(root.messageError);
            wait(300);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-puzzle.png"))); wait(300);
            root.origin = -1;
            // Re-inject: a real daemon state update during the waits above replaces injected games.
            root.games = root.games.filter(g => g.id !== "puzzle-Pz001").concat([Object.assign({}, puzzleGame, {status: "solved"})]);
            root.selectedId = "puzzle-Pz001";
            verify(!root.puzzleUnsolved); verify(root.engineAllowed); compare(root.statusText(), "Puzzle solved ✓");
            verify(!findChild(pageLayout, "puzzleNextButton").visible); // the daily puzzle has no theme
            root.games = root.games.filter(g => g.id !== "puzzle-Pz001").concat([Object.assign({}, puzzleGame, {status: "solved", puzzle: Object.assign({}, puzzleGame.puzzle, {angle: "fork"})})]);
            root.selectedId = "puzzle-Pz001";
            tryVerify(() => findChild(pageLayout, "puzzleNextButton").visible, 5000);
            const beforeNext = root.serial;
            keyClick(Qt.Key_N); compare(root.pending[String(beforeNext + 1)], "puzzle_next");
            // Social UI uses the same socket protocol; HTTP behavior is covered by integration.py.
            wait(300);
            root.engineOn = false; root.explorerOn = false; root.selectedId = ""; root.view = "";
            boardFocus.forceActiveFocus();
            keyClick("C");
            compare(root.view, "challenges");
            tryVerify(() => !!findChild(pageLayout, "challengesView"));
            root.account = {id: "tester", username: "Tester"};
            root.challenges = [{id:"invit001", direction:"in", challenger:{name:"Friend"}, destUser:{name:"Tester"}, variant:{key:"standard", name:"Standard"}, speed:"blitz", timeControl:{show:"3+2"}}];
            const invitations = findChild(pageLayout, "challengesView");
            keyClick(Qt.Key_U); verify(findChild(pageLayout, "challengeUsername").activeFocus);
            const usernameField = findChild(pageLayout, "challengeUsername");
            usernameField.text = "test"; usernameField.cursorPosition = 4;
            keyClick(Qt.Key_Backspace); compare(usernameField.text, "tes"); compare(root.view, "challenges");
            usernameField.text = "";
            keyClick(Qt.Key_Backspace); compare(root.view, "challenges");
            keyClick(Qt.Key_Escape); verify(!findChild(pageLayout, "challengeUsername").activeFocus);
            const beforeAccept = root.serial;
            keyClick(Qt.Key_A); compare(root.testRequests.find(r => r.request_id === String(beforeAccept + 1)).cmd, "challenge_accept");
            wait(100);
            mouseClick(findChild(pageLayout, "declineChallenge_invit001"));
            compare(root.testRequests[root.testRequests.length - 1].cmd, "challenge_decline");
            wait(100);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-challenges.png"))); wait(100);
            // Opponent's takeback is visible and both replies have clickable controls.
            const socialGame = Object.assign({}, root.games.find(g => g.id === first), {id:"social01", online:true, color:"white", status:"started", connected:true, takeback_offer:"black"});
            root.games = root.games.concat([socialGame]); root.choose("social01");
            tryVerify(() => !!findChild(pageLayout, "takebackButton"));
            verify(findChild(pageLayout, "declineTakebackButton").visible);
            const beforeTakeback = root.serial;
            keyClick("T"); compare(root.testRequests.find(r => r.request_id === String(beforeTakeback + 1)).cmd, "takeback");
            wait(100);
            mouseClick(findChild(pageLayout, "declineTakebackButton"));
            compare(root.testRequests[root.testRequests.length - 1].cmd, "takeback");
            wait(100);
            boardFocus.forceActiveFocus(); keyClick(Qt.Key_C);
            verify(root.chatVisible);
            tryVerify(() => !!findChild(pageLayout, "chatInput"));
            wait(100); // Let the unauthenticated history error settle before injecting messages.
            root.chatLine("other001", {user:"Other", text:"wrong board"});
            root.chatLine("social01", {user:"Friend", text:"<b>Olá!</b>"});
            compare(findChild(pageLayout, "chatMessages").count, 1);
            const chatInput = findChild(pageLayout, "chatInput");
            chatInput.forceActiveFocus(); chatInput.text = "Boa partida";
            keyClick(Qt.Key_Return);
            compare(root.testRequests[root.testRequests.length - 1].cmd, "chat");
            wait(100); compare(chatInput.text, "Boa partida"); // Failed sends preserve the draft.
            keyClick(Qt.Key_Escape); verify(!chatInput.activeFocus);
            pageLayout.grabToImage(result => result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT").replace(".png", "-chat.png"))); wait(100);
            keyClick(Qt.Key_C); verify(!root.chatVisible);
            console.log("GAMBITO_UI_PASS");
        }
        function cleanupTestCase() { Qt.quit(); }
    }
'''

with tempfile.TemporaryDirectory(prefix="gambito-ui-") as folder:
    folder = Path(folder)
    env = dict(os.environ, XDG_CONFIG_HOME=str(folder / "config"), XDG_DATA_HOME=str(folder / "data"),
               GAMBITO_SOCKET=str(folder / "socket"), QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
               GAMBITO_SCREENSHOT=str(ROOT / "screenshot.png"), GAMBITO_GAME="",
               GAMBITO_STOCKFISH=str(ROOT / "tests/fake-stockfish.sh"),
               # Lobby TV, puzzle and blog must not reach the real Lichess from tests.
               GAMBITO_API_URL="http://127.0.0.1:9")
    env.pop("WAYLAND_DISPLAY", None)
    def install_ui(target, extra, imports=""):
        """Copies the UI with `extra` appended inside the window component."""
        for component in (ROOT / "ui").glob("*.qml"):
            (target / component.name).write_text(component.read_text())
        window = (ROOT / "ui/GambitoWindow.qml").read_text()
        if extra == TEST:
            # Record dispatch before replies can clear `pending` during QtTest key events.
            window = window.replace('socket.write(JSON.stringify(request)', 'root.testRequests.push(request); socket.write(JSON.stringify(request)')
        (target / "GambitoWindow.qml").write_text(imports + window[:window.rfind("}")] + extra + "\n}\n")
    install_ui(folder, TEST, "import QtTest\n")
    log = (folder / "daemon.log").open("w+")
    daemon = subprocess.Popen([str(BIN), "daemon"], env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if (folder / "socket").exists(): break
            time.sleep(.05)
        try:
            result = subprocess.run(["quickshell", "--path", str(folder)], env=env, text=True, capture_output=True, timeout=90)
        except subprocess.TimeoutExpired as error:
            print(error.stdout or b"", error.stderr or b"")
            raise
        output = result.stdout + result.stderr
        print(output)
        assert result.returncode == 0 and "GAMBITO_UI_PASS" in output and "FAIL!" not in output and "Failed to load" not in output, output
        assert "TypeError" not in output and "ReferenceError" not in output, output
        p = subprocess.run([str(BIN), "--json", "list"], env=env, text=True, capture_output=True, check=True)
        games = json.loads(p.stdout)
        assert len(games) == 2
        assert sorted(len(g["moves"]) for g in games) == [0, 3]
        print("PASS UI: SAN/UCI keyboard, navigation, games, challenges, takeback controls, chat, focus and failed drafts")
        # One Quickshell process, two windows: the second opens over IPC through `gambito open`.
        extra = folder / "windows"
        extra.mkdir()
        expected = {g["id"]: len(g["moves"]) + 1 for g in games}
        check = """
    property bool synced: false
    Timer {
        interval: 50; repeat: true; running: !root.synced
        onTriggered: {
            const expected = JSON.parse(Quickshell.env("EXPECTED_MOVES"));
            if (root.game && root.game.san.length === expected[root.selectedId]) {
                root.synced = true;
                console.log("WINDOW_SYNC_OK " + root.selectedId);
                root.finished();
            }
        }
    }
"""
        install_ui(extra, check)
        ui_env = dict(env, GAMBITO_UI=str(extra), EXPECTED_MOVES=json.dumps(expected))
        process = subprocess.Popen(["quickshell", "--path", str(extra)], env=dict(ui_env, GAMBITO_GAME=games[0]["id"]),
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if subprocess.run(["quickshell", "ipc", "--path", str(extra), "show"], capture_output=True).returncode == 0: break
                time.sleep(.1)
            opened = subprocess.run([str(BIN), "open", games[1]["id"]], env=ui_env, text=True, capture_output=True, check=True)
            assert "running UI" in opened.stdout, opened.stdout
            time.sleep(1)
            for game in games:
                move = "Nc6" if len(game["moves"]) == 3 else "d4"
                subprocess.run([str(BIN), "move", game["id"], move], env=env, capture_output=True, check=True)
            # Each window closes itself once synced; the process must exit after the last one.
            try:
                output, _ = process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill(); output, _ = process.communicate()
                raise AssertionError("UI process did not exit after both windows synced:\n" + output)
            for game in games:
                assert "WINDOW_SYNC_OK " + game["id"] in output, output
            assert process.returncode == 0, output
            print("PASS multiple windows: one Quickshell process, IPC open, distinct games, daemon updates, exit after last close")
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
    finally:
        daemon.terminate(); daemon.wait(timeout=5)
