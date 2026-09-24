import QtQuick
import QtQuick.Window

Window {
    id: floating
    property alias implicitWidth: floating.width
    property alias implicitHeight: floating.height
    property size minimumSize: Qt.size(0, 0)
    minimumWidth: minimumSize.width
    minimumHeight: minimumSize.height
    Component.onCompleted: floating.show()
    signal closed()
    onClosing: floating.closed()
}
