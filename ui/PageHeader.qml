import QtQuick
import QtQuick.Layouts

RowLayout {
    id: header
    required property var theme
    property string title: ""
    property string subtitle: ""
    property string backLabel: "Back"
    property string backHint: "⌫"
    property string backObjectName: "pageBack"
    property string secondaryLabel: ""
    property string secondaryHint: ""
    property string primaryLabel: ""
    property string primaryHint: ""
    property Component trailingContent: null
    signal backRequested()
    signal secondaryRequested()
    signal primaryRequested()
    Layout.fillWidth: true
    spacing: 10

    ActionButton {
        objectName: header.backObjectName
        theme: header.theme
        compact: true
        label: header.backLabel
        hint: header.backHint
        onClicked: header.backRequested()
    }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 1
        Text {
            Layout.fillWidth: true
            text: header.title
            color: header.theme.fg
            font { pixelSize: 23; weight: Font.DemiBold }
            elide: Text.ElideRight
        }
        Text {
            visible: header.subtitle !== ""
            Layout.fillWidth: true
            text: header.subtitle
            color: header.theme.muted
            font.pixelSize: 12
            elide: Text.ElideRight
        }
    }
    Loader {
        visible: header.trailingContent !== null
        active: visible
        sourceComponent: header.trailingContent
        Layout.preferredWidth: item ? item.implicitWidth : 0
        Layout.preferredHeight: item ? item.implicitHeight : 0
    }
    ActionButton {
        visible: header.secondaryLabel !== ""
        theme: header.theme
        compact: true
        label: header.secondaryLabel
        hint: header.secondaryHint
        onClicked: header.secondaryRequested()
    }
    ActionButton {
        visible: header.primaryLabel !== ""
        theme: header.theme
        compact: true
        label: header.primaryLabel
        hint: header.primaryHint
        kind: "primary"
        onClicked: header.primaryRequested()
    }
}
