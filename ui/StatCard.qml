import QtQuick

Rectangle {
    id: card
    required property var theme
    property string label: ""
    property string value: ""
    property string detail: ""
    implicitWidth: 170
    implicitHeight: 72
    radius: 12
    color: theme.panel
    border.width: 1
    border.color: theme.line

    Column {
        anchors.fill: parent
        anchors.margins: 11
        spacing: 2
        Text { text: card.label; color: card.theme.muted; font.pixelSize: 11 }
        Text { text: card.value; color: card.theme.fg; font { pixelSize: 21; weight: Font.DemiBold } }
        Text { text: card.detail; color: card.theme.muted; font.pixelSize: 10 }
    }
}

