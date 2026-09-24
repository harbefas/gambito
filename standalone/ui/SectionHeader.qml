import QtQuick
import QtQuick.Layouts

RowLayout {
    id: section
    required property var theme
    required property string title
    property string detail: ""
    property string count: ""
    Layout.fillWidth: true
    spacing: 8

    Text {
        text: section.title
        color: section.theme.fg
        font { pixelSize: 14; weight: Font.DemiBold }
    }
    Text {
        visible: section.count !== ""
        text: section.count
        color: section.theme.muted
        font { family: section.theme.mono; pixelSize: 12 }
    }
    Item { Layout.fillWidth: true }
    Text {
        visible: section.detail !== ""
        text: section.detail
        color: section.theme.muted
        font.pixelSize: 11
        elide: Text.ElideRight
    }
}
