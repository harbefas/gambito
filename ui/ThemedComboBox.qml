import QtQuick
import QtQuick.Controls.Basic

ComboBox {
    id: control
    required property var theme
    implicitHeight: 38
    leftPadding: 10; rightPadding: 32
    font.pixelSize: 13
    opacity: enabled ? 1 : 0.5
    contentItem: Text {
        text: control.displayText; color: control.theme.fg
        font: control.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
    }
    indicator: Text {
        x: control.width - width - 12; anchors.verticalCenter: parent.verticalCenter
        text: "▾"; color: control.theme.muted; font.pixelSize: 14
    }
    background: Rectangle {
        radius: 8; color: control.hovered ? control.theme.raised : control.theme.panel
        border.width: 1; border.color: control.activeFocus ? control.theme.accent : control.theme.line
    }
    delegate: ItemDelegate {
        required property var modelData
        required property int index
        width: control.width - 8; implicitHeight: 34
        highlighted: control.highlightedIndex === index
        contentItem: Text { text: modelData; color: control.theme.fg; font: control.font; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { radius: 6; color: parent.highlighted ? control.theme.raised : "transparent" }
    }
    popup: Popup {
        y: control.height + 4; width: control.width; padding: 4
        implicitHeight: Math.min(contentItem.implicitHeight + 8, 320)
        contentItem: ListView {
            clip: true; implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle { radius: 8; color: control.theme.panel; border.width: 1; border.color: control.theme.line }
    }
}
