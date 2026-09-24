import QtQuick
import QtQuick.Layouts

// One game in a list: lobby games in progress, profile boards. Analysis rows can be deleted.
Rectangle {
    id: row
    required property var app
    required property var game
    required property int index
    property bool selected: false
    signal hovered()
    readonly property bool yourTurn: game.status === "started" && game.color === game.turn
    readonly property bool finished: !app.isActive(game) && !game.analysis
    readonly property bool confirming: app.confirmation === "delete" && app.deleteTarget === game.id
    height: 58; radius: 10
    opacity: finished && !selected ? 0.7 : 1
    color: selected ? app.raised : "transparent"
    border.width: selected ? 1 : 0; border.color: app.line
    Behavior on color { ColorAnimation { duration: 100 } }

    // Below the row content so its buttons stay clickable.
    MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (row.app.pointerMoved(rowMouse, mouse)) row.hovered(); } onClicked: row.app.choose(row.game.id) }
    RowLayout {
        anchors { fill: parent; leftMargin: 14; rightMargin: 14 } spacing: 14
        Rectangle {
            width: 34; height: 34; radius: 8; color: row.app.bg; border.width: 1; border.color: row.app.line
            Text { anchors.centerIn: parent; text: row.game.online ? "↗" : "♟"; color: row.app.fg; font { family: "DejaVu Sans"; pixelSize: 16 } }
        }
        Column {
            Layout.fillWidth: true; spacing: 3
            Text { width: parent.width; elide: Text.ElideRight; text: row.game.white + "  vs  " + row.game.black; color: row.app.fg; font { pixelSize: 14; weight: Font.Medium } }
            Text { width: parent.width; elide: Text.ElideRight; text: row.app.rowInfo(row.game); color: row.app.muted; font.pixelSize: 12 }
        }
        Rectangle {
            visible: row.yourTurn || row.finished
            implicitWidth: pill.implicitWidth + 18; height: 22; radius: 11
            color: row.yourTurn ? row.app.fg : row.app.bg; border.width: row.yourTurn ? 0 : 1; border.color: row.app.line
            Text {
                id: pill
                anchors.centerIn: parent
                text: row.yourTurn ? "your turn" : row.app.result(row.game) || (({started: "in progress", created: "waiting", mate: "checkmate", resign: "resigned", draw: "draw", stalemate: "stalemate", outoftime: "time out", timeout: "time out", aborted: "aborted"})[row.game.status] || row.game.status) + (row.game.winner ? " · " + row.game.winner + " won" : "")
                color: row.yourTurn ? row.app.bg : row.app.muted; font { family: row.app.mono; pixelSize: 11 }
            }
        }
        Text { visible: row.confirming; text: row.game.puzzle ? "Delete this puzzle?" : "Delete this variation and its branches?"; color: row.app.danger; font.pixelSize: 12 }
        ActionButton { objectName: "listConfirmDelete" + row.index; visible: row.confirming; theme: row.app; compact: true; kind: "destructive"; label: "Delete"; hint: "↵"; onClicked: row.app.runCommand(":confirm") }
        ActionButton { visible: row.confirming; theme: row.app; compact: true; label: "Cancel"; hint: "esc"; onClicked: row.app.clearPending() }
        ActionButton {
            objectName: "listDelete" + row.index
            visible: (row.game.analysis || !!row.game.puzzle) && !row.confirming && row.selected
            theme: row.app; compact: true; kind: "danger"; icon: "✕"; hint: "x"
            onClicked: row.app.confirmDelete(row.game.id)
        }
    }
}
