import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Puzzle themes: Lichess's theme categories and openings, each opening the next puzzle of that theme
// on the main board. Loaded only while shown.
GridLayout {
    id: puzzles
    objectName: "puzzlesView"
    required property var app
    required property Item focusScope
    anchors.fill: parent
    // Narrow panes put the categories in a row above the themes instead of a fixed side column.
    readonly property bool narrow: width < 620
    columns: narrow ? 1 : 2; columnSpacing: 18; rowSpacing: 12

    // Lichess reply: {themes: {category: [{key, name, desc, count}]}, openings: [{family, openings}]}
    property var catalog: null
    property int category: 0
    property int index: 0
    readonly property var difficulties: [["easiest", "Easiest"], ["easier", "Easier"], ["normal", "Normal"], ["harder", "Harder"], ["hardest", "Hardest"]]
    readonly property var categories: {
        if (!catalog) return [];
        // Lichess's order; the daemon's JSON map sorts keys alphabetically. Unknown categories go last.
        const order = ["Recommended", "Phases", "Motifs", "Advanced", "Mates", "Mate themes", "Special moves", "Goals", "Lengths", "Origin"];
        const rank = name => order.indexOf(name) < 0 ? order.length : order.indexOf(name);
        const list = Object.keys(catalog.themes).sort((a, b) => rank(a) - rank(b)).map(name => ({name: name, items: catalog.themes[name]}));
        list.push({name: "By opening", items: (catalog.openings || []).map(o => ({key: o.family.key, name: o.family.name, desc: o.openings.slice(0, 4).map(v => v.name).join(" · "), count: o.family.count}))});
        return list;
    }
    readonly property var items: categories.length ? categories[category].items : []

    function start(i) {
        const item = items[i];
        if (item) app.send("puzzle_next", {angle: item.key, difficulty: app.puzzleDifficulty});
    }
    function selectCategory(i) { category = Math.max(0, Math.min(categories.length - 1, i)); index = 0; }
    function count(n) { return Number(n).toLocaleString(Qt.locale(), "f", 0); }

    Connections {
        target: puzzles.app
        function onReplied(cmd, data, error) { if (cmd === "puzzle_themes" && data) puzzles.catalog = data.puzzle_themes; }
    }
    Component.onCompleted: {
        app.viewKeys = (key, event) => {
            const last = puzzles.items.length - 1;
            if (key === "[") puzzles.selectCategory(puzzles.category - 1);
            else if (key === "]") puzzles.selectCategory(puzzles.category + 1);
            else if (key === "d") { const i = puzzles.difficulties.findIndex(d => d[0] === puzzles.app.puzzleDifficulty); puzzles.app.puzzleDifficulty = puzzles.difficulties[(i + 1) % puzzles.difficulties.length][0]; }
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) puzzles.start(puzzles.index);
            else if (key === "l" || event.key === Qt.Key_Right) puzzles.index = Math.min(last, puzzles.index + 1);
            else if (key === "h" || event.key === Qt.Key_Left) puzzles.index = Math.max(0, puzzles.index - 1);
            else if (key === "j" || event.key === Qt.Key_Down) puzzles.index = Math.min(last, puzzles.index + grid.columns);
            else if (key === "k" || event.key === Qt.Key_Up) puzzles.index = Math.max(0, puzzles.index - grid.columns);
            else return false;
            return true;
        };
        app.send("puzzle_themes");
    }
    Component.onDestruction: if (app.viewKeys) app.viewKeys = null

    PageHeader {
        Layout.columnSpan: puzzles.narrow ? 1 : 2
        theme: puzzles.app
        title: "Puzzles"
        subtitle: "Practice tactical themes and build pattern recognition."
        onBackRequested: puzzles.app.navigateBack()
    }

    ColumnLayout {
        // Narrow and fixed beside the cards; a short row above them in a narrow pane.
        Layout.preferredWidth: puzzles.narrow ? -1 : 170; Layout.maximumWidth: puzzles.narrow ? 100000 : 170
        Layout.fillWidth: puzzles.narrow; Layout.fillHeight: !puzzles.narrow; spacing: 10
        ListView {
            id: categoryList
            objectName: "puzzleCategories"
            Layout.fillWidth: true; Layout.fillHeight: !puzzles.narrow; Layout.preferredHeight: puzzles.narrow ? 38 : -1
            orientation: puzzles.narrow ? ListView.Horizontal : ListView.Vertical
            clip: true; spacing: 2
            model: puzzles.categories
            currentIndex: puzzles.category
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool active: index === puzzles.category
                width: puzzles.narrow ? categoryText.implicitWidth + 24 : categoryList.width; height: 36; radius: 8
                color: active ? app.raised : categoryMouse.containsMouse ? app.panel : "transparent"
                border.width: active ? 1 : 0; border.color: app.line
                Text { id: categoryText; anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter } text: modelData.name; color: active ? app.fg : app.muted; font { pixelSize: 13; weight: active ? Font.DemiBold : Font.Normal } }
                MouseArea { id: categoryMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: puzzles.selectCategory(parent.index) }
            }
            Text { visible: categoryList.count === 0; text: "Loading…"; color: app.muted; font.pixelSize: 12 }
        }
        Text { visible: !puzzles.narrow; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: "[ ] category\nenter start\nd difficulty"; color: app.faint; font.pixelSize: 11 }
    }

    ColumnLayout {
        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 12
        Text {
            Layout.fillWidth: true; elide: Text.ElideRight
            text: puzzles.categories.length ? puzzles.categories[puzzles.category].name : ""; color: app.fg; font { pixelSize: 22; weight: Font.DemiBold }
        }
        // Wraps under the title when the pane is too narrow for one row.
        Flow {
            Layout.fillWidth: true; spacing: 6
            Text { visible: !puzzles.narrow; text: "Difficulty"; color: app.muted; font.pixelSize: 12; anchors.verticalCenter: undefined }
            Repeater {
                model: puzzles.difficulties
                ActionButton {
                    required property var modelData
                    objectName: "difficulty_" + modelData[0]
                    theme: app; compact: true; label: modelData[1]; hint: app.puzzleDifficulty === modelData[0] ? "d" : ""
                    kind: app.puzzleDifficulty === modelData[0] ? "primary" : "normal"
                    onClicked: app.puzzleDifficulty = modelData[0]
                }
            }
        }
        GridView {
            id: grid
            objectName: "puzzleThemes"
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            readonly property int columns: Math.max(1, Math.floor(width / 360))
            cellWidth: Math.max(200, Math.floor(width / columns)); cellHeight: 96
            model: puzzles.items
            currentIndex: puzzles.index
            ScrollBar.vertical: ScrollBar { }
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                width: grid.cellWidth; height: grid.cellHeight
                readonly property bool selected: index === puzzles.index
                Rectangle {
                    objectName: "theme_" + cell.modelData.key
                    anchors { fill: parent; margins: 5 } radius: 10
                    color: cellMouse.containsMouse || cell.selected ? app.raised : app.panel
                    border.width: 1; border.color: cell.selected ? app.mix(app.line, app.fg, 0.35) : app.line
                    Column {
                        anchors { fill: parent; margins: 12 } spacing: 4
                        Row {
                            spacing: 8
                            Text { text: cell.modelData.name; color: app.fg; font { pixelSize: 15; weight: Font.DemiBold } }
                            Text { anchors.baseline: parent.children[0].baseline; text: puzzles.count(cell.modelData.count); color: app.muted; font { family: app.mono; pixelSize: 11 } }
                        }
                        Text { width: parent.width; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; text: cell.modelData.desc || ""; color: app.muted; font.pixelSize: 12 }
                    }
                    MouseArea { id: cellMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(cellMouse, mouse)) puzzles.index = cell.index; } onClicked: puzzles.start(cell.index) }
                }
            }
        }
    }
}
