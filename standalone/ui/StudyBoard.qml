import QtQuick
import QtQuick.Layouts

Item {
    id: root
    required property var app
    property string fen: ""
    property bool flipped: false
    property int selected: -1
    property var targets: []
    signal squareClicked(int square)

    readonly property var board: fen ? app.decodeFen(fen) : []
    readonly property real cell: Math.min(width, height) / 8
    function displaySquare(index) { return flipped ? 63 - index : index; }
    function squareName(index) { return "abcdefgh"[index % 8] + (8 - Math.floor(index / 8)); }

    Grid {
        id: grid
        anchors.centerIn: parent
        width: root.cell * 8
        height: width
        columns: 8
        Repeater {
            model: 64
            Rectangle {
                required property int index
                readonly property int square: root.displaySquare(index)
                readonly property bool light: (Math.floor(index / 8) + index % 8) % 2 === 0
                readonly property string piece: root.board[square] || ""
                readonly property bool target: root.targets.indexOf(square) >= 0
                width: grid.width / 8; height: width
                color: square === root.selected ? root.app.mix(light ? root.app.squareLight : root.app.squareDark, root.app.selection, 0.55) : light ? root.app.squareLight : root.app.squareDark
                Text {
                    anchors.centerIn: parent
                    text: root.app.glyph(parent.piece)
                    color: parent.piece === parent.piece.toUpperCase() ? "#fbf8ee" : "#1f2629"
                    style: Text.Outline
                    styleColor: parent.piece === parent.piece.toUpperCase() ? "#2b3533" : "#55615c"
                    font { family: "DejaVu Sans"; pixelSize: parent.width * 0.8 }
                }
                Rectangle { visible: parent.target && !parent.piece; anchors.centerIn: parent; width: parent.width * 0.28; height: width; radius: width / 2; color: "#50202820" }
                Rectangle { visible: parent.target && !!parent.piece; anchors.fill: parent; anchors.margins: 2; radius: width / 2; color: "transparent"; border.width: 3; border.color: "#60202820" }
                Text { visible: index % 8 === 0; anchors { left: parent.left; top: parent.top; leftMargin: 3; topMargin: 1 } text: root.squareName(square)[1]; color: light ? root.app.squareDark : root.app.squareLight; font.pixelSize: Math.max(9, parent.width * 0.18) }
                Text { visible: index >= 56; anchors { right: parent.right; bottom: parent.bottom; rightMargin: 3 } text: root.squareName(square)[0]; color: light ? root.app.squareDark : root.app.squareLight; font.pixelSize: Math.max(9, parent.width * 0.18) }
                MouseArea { anchors.fill: parent; onClicked: root.squareClicked(parent.square) }
            }
        }
    }
}
