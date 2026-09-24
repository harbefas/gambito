import QtQuick
import Gambito.Host

Item {
    id: socket
    property string path: ""
    property bool connected: bridge.connected
    property var parser: null
    signal connectionStateChanged()
    GambitoSocket {
        id: bridge
        socketPath: socket.path
        onLineReceived: line => { if (socket.parser) socket.parser.read(line); }
        onConnectedChanged: socket.connectionStateChanged()
    }
    function write(data) { bridge.write(data); }
    function flush() { }
    Component.onCompleted: bridge.connectNow()
}
