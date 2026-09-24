import QtQuick

QtObject {
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    property string text: ""
    signal loaded()
    signal loadFailed()
    signal fileChanged()
    function reload() { loadFailed(); }
}
