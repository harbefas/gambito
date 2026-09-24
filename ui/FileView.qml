import QtQuick
import Gambito.Host

Item {
    id: view
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    readonly property string contents: bridge.text
    signal loaded()
    signal loadFailed()
    signal fileChanged()
    GambitoFile {
        id: bridge
        path: view.path
        watchChanges: view.watchChanges
        onLoaded: view.loaded()
        onLoadFailed: view.loadFailed()
        onFileChanged: view.fileChanged()
    }
    function text() { return bridge.text; }
    function reload() { bridge.load(); }
}
