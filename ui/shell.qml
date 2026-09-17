import QtQuick
import Quickshell
import Quickshell.Io

// A single UI process hosts every Gambito window (~250 MB per process, a few MB per window).
// `gambito open` reaches a running instance through the "gambito" IPC target.
ShellRoot {
    id: shell
    // An app, not a live-edited config: no hot reload, so no "Config reloaded" popup.
    settings.watchFiles: false
    property int nextKey: 1

    function open(game) { windows.append({windowKey: nextKey++, startGame: game}); }
    function close(key) {
        for (let i = 0; i < windows.count; i++)
            if (windows.get(i).windowKey === key) { windows.remove(i); break; }
        if (windows.count === 0) Qt.quit();
    }

    // A ListModel (not a reassigned array) so opening or closing one window keeps the others alive.
    ListModel { id: windows }
    Component.onCompleted: open(Quickshell.env("GAMBITO_GAME") || "")

    Instantiator {
        model: windows
        delegate: GambitoWindow {
            required property int windowKey
            required property string startGame
            initialGame: startGame
            onRequestWindow: game => shell.open(game)
            // Deferred: the window must not be destroyed inside its own signal handler. A fresh closure per
            // call: Qt.callLater merges calls to the same function, which dropped simultaneous closes.
            onFinished: Qt.callLater(() => shell.close(windowKey))
        }
    }

    IpcHandler {
        target: "gambito"
        function open(game: string): void { shell.open(game); }
        function lobby(): void { shell.open(""); }
    }
}
