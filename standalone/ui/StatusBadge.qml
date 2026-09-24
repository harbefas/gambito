import QtQuick

Rectangle {
    id: badge
    required property var theme
    property string label: ""
    property string tone: "muted"
    readonly property color ink: tone === "live" ? theme.winColor : tone === "danger" ? theme.danger : theme.muted
    implicitWidth: badgeText.implicitWidth + 16
    implicitHeight: 24
    radius: 7
    color: theme.alpha(ink, 0.1)
    border.width: 1
    border.color: theme.alpha(ink, 0.32)
    Text {
        id: badgeText
        anchors.centerIn: parent
        text: badge.label
        color: badge.ink
        font { pixelSize: 11; weight: Font.Medium }
    }
}

