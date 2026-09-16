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
            keyClick(Qt.Key_G);
            verify(!root.game);
            root.listIndex = root.games.findIndex(g => g.id === first);
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
            keyClick(Qt.Key_Escape); compare(root.confirmation, "");
            compare(root.game.status, "started");
            // Captures the actual rendered window, including pieces and move list.
            pageLayout.grabToImage(result => {
                result.saveToFile(Quickshell.env("GAMBITO_SCREENSHOT"));
            });
            wait(500);
            console.log("GAMBITO_UI_PASS");
        }
        function cleanupTestCase() { Qt.quit(); }
    }
'''

with tempfile.TemporaryDirectory(prefix="gambito-ui-") as folder:
    folder = Path(folder)
    env = dict(os.environ, XDG_CONFIG_HOME=str(folder / "config"), XDG_DATA_HOME=str(folder / "data"),
               GAMBITO_SOCKET=str(folder / "socket"), QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
               GAMBITO_SCREENSHOT=str(ROOT / "screenshot.png"), GAMBITO_GAME="")
    env.pop("WAYLAND_DISPLAY", None)
    source = (ROOT / "ui/shell.qml").read_text()
    source = "import QtTest\n" + source[:source.rfind("}")] + TEST + "\n}\n"
    (folder / "shell.qml").write_text(source)
    log = (folder / "daemon.log").open("w+")
    daemon = subprocess.Popen([str(BIN), "daemon"], env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if (folder / "socket").exists(): break
            time.sleep(.05)
        result = subprocess.run(["quickshell", "--path", str(folder)], env=env, text=True, capture_output=True, timeout=30)
        output = result.stdout + result.stderr
        print(output)
        assert "GAMBITO_UI_PASS" in output and "FAIL!" not in output and "Failed to load" not in output
        assert "TypeError" not in output and "ReferenceError" not in output
        p = subprocess.run([str(BIN), "--json", "list"], env=env, text=True, capture_output=True, check=True)
        games = json.loads(p.stdout)
        assert len(games) == 2
        assert sorted(len(g["moves"]) for g in games) == [0, 3]
        print("PASS UI: teclado SAN/UCI, navegação espacial, partidas independentes, inversão, erro e confirmação")
        # Two actual Quickshell processes, each retaining its own selected game.
        multi = []
        for index, game in enumerate(games):
            extra = folder / ("window" + str(index))
            extra.mkdir()
            check = """
    Timer {
        interval: 50; repeat: true; running: true
        onTriggered: {
            if (root.game && root.game.san.length === Number(Quickshell.env("EXPECTED_MOVES"))) {
                console.log("WINDOW_SYNC_OK " + root.selectedId);
                Qt.quit();
            }
        }
    }
"""
            original = (ROOT / "ui/shell.qml").read_text()
            (extra / "shell.qml").write_text(original[:original.rfind("}")] + check + "\n}\n")
            child_env = dict(env, GAMBITO_GAME=game["id"], EXPECTED_MOVES=str(len(game["moves"]) + 1))
            process = subprocess.Popen(["quickshell", "--path", str(extra)], env=child_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            multi.append((process, game))
        try:
            for process, game in multi:
                move = "Nc6" if len(game["moves"]) == 3 else "d4"
                subprocess.run([str(BIN), "move", game["id"], move], env=env, capture_output=True, check=True)
            for process, game in multi:
                output, _ = process.communicate(timeout=15)
                assert "WINDOW_SYNC_OK " + game["id"] in output, output
            print("PASS múltiplas janelas: dois processos Quickshell, partidas distintas e atualização pelo daemon")
        finally:
            for process, _ in multi:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
    finally:
        daemon.terminate(); daemon.wait(timeout=5)
