import QtQuick

// White wins / draws / black wins as proportional segments in board piece colors. Vertical puts
// black on top and white at the bottom, like the evaluation bar.
Item {
    id: bar
    required property var theme
    property var stats: null            // {white, draws, black}
    property bool vertical: false
    readonly property real total: stats ? stats.white + stats.draws + stats.black : 0
    readonly property var segments: vertical
        ? [["black", "#20282b", "#f4f0e4"], ["draws", "#8b938f", "#121719"], ["white", "#f4f0e4", "#20282b"]]
        : [["white", "#f4f0e4", "#20282b"], ["draws", "#8b938f", "#121719"], ["black", "#20282b", "#f4f0e4"]]

    Rectangle { anchors.fill: parent; radius: 3; color: bar.theme.line }
    Grid {
        anchors.fill: parent
        columns: bar.vertical ? 1 : 3
        Repeater {
            model: bar.total ? bar.segments : []
            Rectangle {
                required property var modelData
                readonly property real share: bar.stats[modelData[0]] / bar.total
                width: bar.vertical ? bar.width : bar.width * share
                height: bar.vertical ? bar.height * share : bar.height
                color: modelData[1]
                Text {
                    anchors.centerIn: parent
                    visible: !bar.vertical && parent.width > 30
                    text: Math.round(parent.share * 100) + "%"; color: modelData[2]; font { family: bar.theme.mono; pixelSize: 9 }
                }
            }
        }
    }
}
