import QtQuick

Rectangle {
    id: panel
    required property var theme
    property int padding: 14
    default property alias content: body.data
    radius: 14
    color: theme.panel
    border.width: 1
    border.color: theme.line
    Item {
        id: body
        anchors.fill: parent
        anchors.margins: panel.padding
    }
}
