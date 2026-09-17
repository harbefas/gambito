import QtQuick

// Button with optional icon and keyboard hint. kind: normal | primary | destructive | danger
Rectangle {
    id: button
    required property var theme
    property string label: ""
    property string icon: ""
    property string hint: ""
    property string kind: "normal"
    property bool compact: false
    signal clicked()

    readonly property bool hovered: mouse.containsMouse
    readonly property bool filled: kind === "primary" || kind === "destructive"
    readonly property color fill: kind === "destructive" ? theme.danger : theme.fg
    readonly property color ink: filled ? theme.bg : kind === "danger" ? theme.danger : theme.fg

    implicitHeight: compact ? 32 : 38
    implicitWidth: content.implicitWidth + (compact ? 20 : 28) + (hint !== "" ? hintBox.width + 12 : 0)
    radius: 8
    color: filled ? (hovered ? Qt.darker(fill, 1.12) : fill)
         : kind === "danger" && hovered ? theme.alpha(theme.danger, 0.1)
         : hovered ? theme.raised : theme.panel
    border.width: filled ? 0 : 1
    border.color: kind === "danger" && hovered ? theme.alpha(theme.danger, 0.45) : hovered ? theme.mix(theme.line, theme.fg, 0.25) : theme.line
    scale: mouse.pressed ? 0.97 : 1
    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

    Row {
        id: content
        anchors { left: parent.left; leftMargin: button.compact ? 10 : 14; verticalCenter: parent.verticalCenter }
        spacing: 8
        Text { visible: button.icon !== ""; anchors.verticalCenter: parent.verticalCenter; text: button.icon; color: button.ink; font { family: "DejaVu Sans"; pixelSize: button.compact ? 13 : 15 } }
        Text { visible: button.label !== ""; anchors.verticalCenter: parent.verticalCenter; text: button.label; color: button.ink; font { pixelSize: 13; weight: Font.Medium } }
    }
    Rectangle {
        id: hintBox
        visible: button.hint !== ""
        anchors { right: parent.right; rightMargin: button.compact ? 6 : 8; verticalCenter: parent.verticalCenter }
        width: Math.max(20, hintText.implicitWidth + 10); height: 20; radius: 5
        color: button.filled ? button.theme.alpha(button.theme.bg, 0.15) : button.theme.bg
        border.width: button.filled ? 0 : 1; border.color: button.theme.line
        Text { id: hintText; anchors.centerIn: parent; text: button.hint; color: button.filled ? button.ink : button.theme.muted; font { family: button.theme.mono; pixelSize: 11 } }
    }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: button.clicked() }
}
