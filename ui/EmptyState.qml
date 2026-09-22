import QtQuick
import QtQuick.Layouts

Item {
    id: empty
    required property var theme
    property string title: ""
    property string detail: ""
    property string action: ""
    signal activated()
    implicitHeight: 112
    implicitWidth: 260

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 28, 360)
        spacing: 6
        Text {
            Layout.fillWidth: true
            text: empty.title
            color: empty.theme.fg
            font { pixelSize: 14; weight: Font.DemiBold }
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
        Text {
            visible: empty.detail !== ""
            Layout.fillWidth: true
            text: empty.detail
            color: empty.theme.muted
            font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
        ActionButton {
            visible: empty.action !== ""
            Layout.alignment: Qt.AlignHCenter
            theme: empty.theme
            compact: true
            label: empty.action
            onClicked: empty.activated()
        }
    }
}

