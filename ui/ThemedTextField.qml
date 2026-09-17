import QtQuick
import QtQuick.Controls.Basic

TextField {
    id: field
    required property var theme
    implicitHeight: 38
    leftPadding: 10; rightPadding: 10; topPadding: 6; bottomPadding: 6
    color: theme.fg; placeholderTextColor: theme.muted
    selectionColor: theme.mix(theme.bg, theme.accent, 0.4); selectedTextColor: theme.fg
    font.pixelSize: 13
    opacity: enabled ? 1 : 0.5
    background: Rectangle {
        radius: 8; color: field.theme.bg
        border.width: 1; border.color: field.activeFocus ? field.theme.accent : field.theme.line
    }
}
