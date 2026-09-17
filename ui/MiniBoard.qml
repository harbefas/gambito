import QtQuick

// Compact board for the lobby, TV and openings: light background, 32 dark squares, pieces only on
// occupied squares, one shared font metrics and one click area. The openings page shows a dozen of
// these, so this stays at ~70 objects instead of four per square.
Rectangle {
    id: mini
    required property var app
    property string fen: ""
    property bool flipped: false
    property string lastMove: ""
    property bool interactive: false
    property int selected: -1          // canonical index (a8 = 0)
    signal squareClicked(int index)
    readonly property var board: fen ? app.decodeFen(fen) : []
    readonly property real cell: (width - 6) / 8
    // Occupied squares only: [canonical index, piece].
    readonly property var pieces: {
        const list = [];
        for (let i = 0; i < board.length; i++) if (board[i]) list.push([i, board[i]]);
        return list;
    }
    // Last move and selection, drawn over their squares: [canonical index, overlay color].
    readonly property var marks: {
        const list = [];
        const index = sq => (8 - Number(sq[1])) * 8 + sq.charCodeAt(0) - 97;
        if (lastMove.length >= 4) for (const sq of [lastMove.slice(0, 2), lastMove.slice(2, 4)]) list.push([index(sq), app.highlight, 0.4]);
        if (selected >= 0) list.push([selected, app.selection, 0.55]);
        return list;
    }
    function squareX(sq) { return 3 + (flipped ? 7 - sq % 8 : sq % 8) * cell; }
    function squareY(sq) { return 3 + (flipped ? 7 - Math.floor(sq / 8) : Math.floor(sq / 8)) * cell; }
    function light(sq) { return (Math.floor(sq / 8) + sq % 8) % 2 === 0; }
    radius: 5; color: app.line

    Rectangle { x: 3; y: 3; width: mini.cell * 8; height: width; color: mini.app.squareLight }
    Repeater {
        model: 32
        Rectangle {
            required property int index
            // Dark squares: odd (row + column) in display coordinates, the same on both orientations.
            readonly property int row: Math.floor(index / 4)
            x: 3 + (index % 4 * 2 + (row % 2 ? 0 : 1)) * mini.cell; y: 3 + row * mini.cell
            width: mini.cell; height: mini.cell; color: mini.app.squareDark
        }
    }
    Repeater {
        model: mini.marks
        Rectangle {
            required property var modelData
            x: mini.squareX(modelData[0]); y: mini.squareY(modelData[0]); width: mini.cell; height: mini.cell
            color: mini.app.mix(mini.light(modelData[0]) ? mini.app.squareLight : mini.app.squareDark, modelData[1], modelData[2])
        }
    }
    // Center each glyph's ink, not its font line box, like the main board.
    FontMetrics { id: metrics; font { family: "DejaVu Sans"; pixelSize: mini.cell * 0.8 } }
    Repeater {
        model: mini.pieces
        Text {
            required property var modelData
            readonly property string piece: modelData[1]
            readonly property rect ink: {
                // The invokable does not expose its font dependency to QML bindings.
                // Recompute after layout/resizing changes the shared font size.
                metrics.font.pixelSize;
                return metrics.tightBoundingRect(text);
            }
            x: mini.squareX(modelData[0]) + (mini.cell - ink.width) / 2 - ink.x
            y: mini.squareY(modelData[0]) + (mini.cell - ink.height) / 2 - ink.y - baselineOffset
            text: mini.app.glyph(piece)
            color: piece === piece.toUpperCase() ? "#fbf8ee" : "#1f2629"
            style: Text.Outline; styleColor: piece === piece.toUpperCase() ? "#2b3533" : "#55615c"
            font: metrics.font
        }
    }
    MouseArea {
        anchors { fill: parent; margins: 3 }
        enabled: mini.interactive; cursorShape: mini.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: mouse => {
            const column = Math.min(7, Math.floor(mouse.x / mini.cell));
            const row = Math.min(7, Math.floor(mouse.y / mini.cell));
            mini.squareClicked(mini.flipped ? 63 - (row * 8 + column) : row * 8 + column);
        }
    }
}
