import QtQuick
import QtQuick.Layouts

// Online play options: opponent seek or Lichess computer, real-time or correspondence.
Rectangle {
    id: screen
    required property var app
    property string mode: "opponent"   // opponent | computer
    property bool rated: false
    property int level: 3
    property string side: "random"
    property bool customOpen: false
    property int customMinutes: 10
    property int customIncrement: 5

    readonly property var controls: [
        [1, 0, "Bullet"], [2, 1, "Bullet"], [3, 0, "Blitz"], [3, 2, "Blitz"],
        [5, 0, "Blitz"], [5, 3, "Blitz"], [10, 0, "Rapid"], [10, 5, "Rapid"],
        [15, 10, "Rapid"], [30, 0, "Classical"], [30, 20, "Classical"]
    ]
    // Lichess only pairs third-party boards in Rapid or slower (estimated time ≥ 8 min).
    function allowed(minutes, increment) { return mode === "computer" || minutes * 60 + 40 * increment >= 480; }
    // Only what can actually be played: seeks hide Bullet and Blitz (a note explains why).
    readonly property var shown: controls.filter(c => allowed(c[0], c[1]))
    onModeChanged: cursor = 0
    // Keyboard focus over the playable options: real-time controls, custom, then correspondence days.
    readonly property var days: [1, 2, 3, 5, 7, 10, 14]
    property int cursor: 0
    readonly property int columns: grid.columns
    readonly property int customIndex: shown.length
    function move(dx, dy) {
        const tiles = shown.length + 1;
        if (cursor < tiles) {
            let next = cursor + dx + dy * columns;
            if (dy > 0 && next >= tiles) next = tiles + Math.min(days.length - 1, cursor % columns);
            cursor = Math.max(0, Math.min(tiles + days.length - 1, next));
        } else {
            const day = cursor - tiles;
            if (dy < 0) cursor = Math.min(tiles - 1, (Math.ceil(tiles / columns) - 1) * columns + Math.min(day, columns - 1));
            else cursor = tiles + Math.max(0, Math.min(days.length - 1, day + dx));
        }
    }
    function activate() {
        const tiles = shown.length + 1;
        if (cursor < shown.length) {
            const c = shown[cursor];
            play({minutes: c[0], increment: c[1]});
        } else if (cursor === customIndex) {
            if (!customOpen) customOpen = true;
            else if (allowed(customMinutes, customIncrement)) play({minutes: customMinutes, increment: customIncrement});
        } else play({days: days[cursor - tiles]});
    }
    // Keys while the play screen is open; returns true when handled.
    function handleKey(key, event) {
        if (key === "m") mode = mode === "opponent" ? "computer" : "opponent";
        else if (key === "r" && mode === "opponent") rated = !rated;
        else if (key === "s" && mode === "computer") side = side === "white" ? "random" : side === "random" ? "black" : "white";
        else if (mode === "computer" && key >= "1" && key <= "8") level = Number(key);
        else if (key === "c") { customOpen = !customOpen; cursor = customIndex; }
        else if (customOpen && (key === "-" || key === "+" || key === "=")) customMinutes = Math.max(1, Math.min(180, customMinutes + (key === "-" ? -1 : 1)));
        else if (customOpen && (key === "[" || key === "]")) customIncrement = Math.max(0, Math.min(180, customIncrement + (key === "[" ? -1 : 1)));
        else if (key === "h" || event.key === Qt.Key_Left) move(-1, 0);
        else if (key === "l" || event.key === Qt.Key_Right) move(1, 0);
        else if (key === "k" || event.key === Qt.Key_Up) move(0, -1);
        else if (key === "j" || event.key === Qt.Key_Down) move(0, 1);
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) activate();
        else return false;
        return true;
    }
    function play(options) {
        if (mode === "computer") app.send("ai", Object.assign({level: level, color: side}, options));
        else app.send("seek", Object.assign({rated: rated}, options));
    }

    color: app.bg

    component Segmented: Rectangle {
        id: segmented
        required property var theme
        required property var options      // [[value, label], …]
        required property string value
        property string hint: ""
        signal picked(string value)
        implicitWidth: segmentRow.implicitWidth + 8 + (hint ? hintBox.width + 6 : 0); implicitHeight: 36; radius: 10
        color: theme.panel; border.width: 1; border.color: theme.line
        Rectangle {
            id: hintBox
            visible: segmented.hint !== ""
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            width: hintText.implicitWidth + 10; height: 18; radius: 4; color: segmented.theme.bg; border.width: 1; border.color: segmented.theme.line
            Text { id: hintText; anchors.centerIn: parent; text: segmented.hint; color: segmented.theme.muted; font { pixelSize: 10; weight: Font.Medium } }
        }
        Row {
            id: segmentRow
            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter } spacing: 2
            Repeater {
                model: segmented.options
                Rectangle {
                    id: segment
                    required property var modelData
                    readonly property bool selected: modelData[0] === segmented.value
                    width: segmentLabel.implicitWidth + 28; height: 28; radius: 7
                    color: selected ? segmented.theme.fg : segmentMouse.containsMouse ? segmented.theme.raised : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text { id: segmentLabel; anchors.centerIn: parent; text: segment.modelData[1]; color: segment.selected ? segmented.theme.bg : segmented.theme.fg; font { pixelSize: 13; weight: Font.Medium } }
                    MouseArea { id: segmentMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: segmented.picked(segment.modelData[0]) }
                }
            }
        }
    }

    RowLayout {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: 12
        // The title gives way first: the mode switch and Close must stay reachable in narrow panes.
        Text { Layout.fillWidth: true; Layout.preferredWidth: 0; elide: Text.ElideRight; text: "Play online"; color: screen.app.fg; font { pixelSize: 18; weight: Font.DemiBold } }
        Segmented {
            objectName: "modeSwitch"
            hint: "m"
            theme: screen.app; value: screen.mode
            options: [["opponent", "Opponent"], ["computer", "Computer"]]
            onPicked: v => screen.mode = v
        }
        ActionButton { objectName: "closePlayButton"; theme: screen.app; compact: true; label: "Close"; hint: "esc"; onClicked: screen.app.playVisible = false }
    }

    Flickable {
        anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom; topMargin: 20 }
        clip: true; contentHeight: body.implicitHeight
        ColumnLayout {
            id: body
            width: parent.width; spacing: 18

            RowLayout {
                spacing: 12
                Segmented {
                    visible: screen.mode === "opponent"
                    hint: "r"
                    theme: screen.app; value: screen.rated ? "rated" : "casual"
                    options: [["casual", "Casual"], ["rated", "Rated"]]
                    onPicked: v => screen.rated = v === "rated"
                }
                Segmented {
                    visible: screen.mode === "computer"
                    hint: "s"
                    theme: screen.app; value: screen.side
                    options: [["white", "♔ White"], ["random", "Random"], ["black", "♚ Black"]]
                    onPicked: v => screen.side = v
                }
                Segmented {
                    visible: screen.mode === "computer"
                    hint: "1–8"
                    theme: screen.app; value: String(screen.level)
                    options: [1, 2, 3, 4, 5, 6, 7, 8].map(n => [String(n), n === 1 ? "Level 1" : String(n)])
                    onPicked: v => screen.level = Number(v)
                }
            }

            Text { text: "Real time · arrows or hjkl to pick, enter to play"; color: screen.app.muted; font { pixelSize: 12; weight: Font.Medium } }
            GridLayout {
                id: grid
                Layout.fillWidth: true
                columns: width >= 700 ? 4 : width >= 470 ? 3 : 2; columnSpacing: 10; rowSpacing: 10
                Repeater {
                    model: screen.shown
                    Rectangle {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property bool focused: screen.cursor === index
                        objectName: "control_" + modelData[0] + "_" + modelData[1]
                        Layout.fillWidth: true; Layout.preferredHeight: 84; radius: 12
                        color: tileMouse.containsMouse ? screen.app.raised : screen.app.panel
                        border.width: focused ? 2 : 1; border.color: focused ? screen.app.accent : tileMouse.containsMouse ? screen.app.mix(screen.app.line, screen.app.fg, 0.3) : screen.app.line
                        scale: tileMouse.pressed ? 0.97 : 1
                        Behavior on color { ColorAnimation { duration: 120 } }
                        Behavior on scale { NumberAnimation { duration: 90 } }
                        Column {
                            anchors.centerIn: parent; spacing: 2
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.modelData[0] + "+" + tile.modelData[1]; color: screen.app.fg; font { family: screen.app.mono; pixelSize: 24; weight: Font.Medium } }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.modelData[2]; color: screen.app.muted; font.pixelSize: 12 }
                        }
                        MouseArea {
                            id: tileMouse; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onEntered: screen.cursor = tile.index
                            onClicked: screen.play({minutes: tile.modelData[0], increment: tile.modelData[1]})
                        }
                    }
                }
                Rectangle {
                    objectName: "customTile"
                    Layout.fillWidth: true; Layout.preferredHeight: 84; radius: 12
                    color: customMouse.containsMouse || screen.customOpen ? screen.app.raised : screen.app.panel
                    border.width: screen.cursor === screen.customIndex ? 2 : 1
                    border.color: screen.cursor === screen.customIndex ? screen.app.accent : screen.customOpen ? screen.app.fg : screen.app.line
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Column {
                        anchors.centerIn: parent; spacing: 2
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Custom"; color: screen.app.fg; font { pixelSize: 18; weight: Font.Medium } }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "your own clock · c"; color: screen.app.muted; font.pixelSize: 12 }
                    }
                    MouseArea { id: customMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: screen.customOpen = !screen.customOpen }
                }
            }

            Text {
                objectName: "seekNote"
                visible: screen.mode === "opponent"
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: "Bullet and Blitz aren't listed: Lichess only pairs apps like Gambito in Rapid or slower. Play them against the computer, or on lichess.org."
                color: screen.app.muted; font.pixelSize: 12
            }
            Rectangle {
                visible: screen.customOpen
                Layout.fillWidth: true; implicitHeight: 64; radius: 12
                color: screen.app.panel; border.width: 1; border.color: screen.app.line
                RowLayout {
                    anchors { fill: parent; leftMargin: 16; rightMargin: 12 } spacing: 10
                    Repeater {
                        model: [["Minutes", "customMinutes", 1, 180], ["Increment", "customIncrement", 0, 180]]
                        RowLayout {
                            id: stepper
                            required property var modelData
                            spacing: 6
                            Text { text: stepper.modelData[0]; color: screen.app.muted; font.pixelSize: 13 }
                            ActionButton { theme: screen.app; compact: true; label: "−"; hint: stepper.modelData[1] === "customMinutes" ? "-" : "["; onClicked: screen[stepper.modelData[1]] = Math.max(stepper.modelData[2], screen[stepper.modelData[1]] - 1) }
                            Text { Layout.preferredWidth: 36; horizontalAlignment: Text.AlignHCenter; text: screen[stepper.modelData[1]]; color: screen.app.fg; font { family: screen.app.mono; pixelSize: 18; weight: Font.Medium } }
                            ActionButton { theme: screen.app; compact: true; label: "+"; hint: stepper.modelData[1] === "customMinutes" ? "+" : "]"; onClicked: screen[stepper.modelData[1]] = Math.min(stepper.modelData[3], screen[stepper.modelData[1]] + 1) }
                            Item { width: 12 }
                        }
                    }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        visible: !screen.allowed(screen.customMinutes, screen.customIncrement)
                        text: "Too fast for a Lichess seek"; color: screen.app.danger; font.pixelSize: 12
                    }
                    Item { Layout.fillWidth: true; visible: screen.allowed(screen.customMinutes, screen.customIncrement) }
                    ActionButton {
                        objectName: "playCustomButton"
                        theme: screen.app; kind: "primary"; label: "Play " + screen.customMinutes + "+" + screen.customIncrement; hint: "↵"
                        opacity: screen.allowed(screen.customMinutes, screen.customIncrement) ? 1 : 0.4
                        onClicked: if (screen.allowed(screen.customMinutes, screen.customIncrement)) screen.play({minutes: screen.customMinutes, increment: screen.customIncrement})
                    }
                }
            }

            Text { Layout.topMargin: 6; text: "Correspondence · days per move"; color: screen.app.muted; font { pixelSize: 12; weight: Font.Medium } }
            Flow {
                Layout.fillWidth: true; spacing: 8
                Repeater {
                    model: [1, 2, 3, 5, 7, 10, 14]
                    ActionButton {
                        required property int modelData
                        required property int index
                        objectName: "days_" + modelData
                        border.width: screen.cursor === screen.customIndex + 1 + index ? 2 : 1
                        border.color: screen.cursor === screen.customIndex + 1 + index ? screen.app.accent : screen.app.line
                        theme: screen.app; label: modelData + (modelData === 1 ? " day" : " days")
                        onClicked: screen.play({days: modelData})
                    }
                }
            }
        }
    }

    // Waiting for a real-time pairing.
    Rectangle {
        anchors.fill: parent; visible: screen.app.seeking; color: screen.app.alpha(screen.app.bg, 0.92)
        MouseArea { anchors.fill: parent }
        Column {
            anchors.centerIn: parent; spacing: 16
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 14; height: 14; radius: 7; color: screen.app.fg
                SequentialAnimation on opacity {
                    running: screen.visible && screen.app.seeking; loops: Animation.Infinite
                    NumberAnimation { to: 0.2; duration: 700; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
                }
            }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Looking for an opponent…"; color: screen.app.fg; font { pixelSize: 17; weight: Font.DemiBold } }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "The game opens here as soon as someone joins."; color: screen.app.muted; font.pixelSize: 13 }
            ActionButton { objectName: "cancelSeekButton"; anchors.horizontalCenter: parent.horizontalCenter; theme: screen.app; label: "Cancel"; hint: "esc"; onClicked: screen.app.send("cancel") }
        }
    }
}
