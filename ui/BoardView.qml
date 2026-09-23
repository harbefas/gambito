import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

// Board, evaluation bar, arrows and the side panel. Loaded only while a game is selected.
Flickable {
    id: boardView
    required property var app
    // Window key-handling scope; board clicks give it focus back.
    required property Item focusScope
    anchors.fill: parent
    // Narrow panes stack the panel under the board and scroll, instead of shrinking the board.
    readonly property bool narrow: width < 760 && !app.zen
    clip: true; contentWidth: width; contentHeight: page.height
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { }

    Component {
        id: playerBar
        Rectangle {
        id: bar
        readonly property string side: parent ? parent.side : "white"
        readonly property bool active: !!app.game && app.game.status === "started" && app.game.turn === side
        readonly property string clockText: app.clock(side)
        color: "transparent"
        RowLayout {
            anchors { fill: parent; leftMargin: 2; rightMargin: 2 } spacing: 8
            Text {
                objectName: bar.side + "PlayerIcon"
                text: app.glyph("k")
                color: bar.side === "white" ? "#fbf8ee" : "#1f2629"
                style: Text.Outline
                styleColor: bar.side === "white" ? "#2b3533" : "#55615c"
                font { family: "DejaVu Sans"; pixelSize: 18 }
            }
            Text { Layout.maximumWidth: implicitWidth; Layout.minimumWidth: Math.min(implicitWidth, app.review ? 80 : 140); Layout.fillWidth: true; elide: Text.ElideRight; text: app.game ? app.game[bar.side] : ""; color: bar.active ? app.fg : app.muted; font { pixelSize: 14; weight: bar.active ? Font.DemiBold : Font.Normal } }
            Text { visible: !!app.game && !!app.game[bar.side + "_rating"]; text: app.game ? app.game[bar.side + "_rating"] || "" : ""; color: app.muted; font { family: app.mono; pixelSize: 12 } }
            Rectangle {
                // Puzzles keep the source game's players; the color only orients the board.
                visible: !!app.game && app.game.color === bar.side && !app.game.puzzle
                implicitWidth: youLabel.implicitWidth + 12; height: 18; radius: 9; color: app.fg
                Text { id: youLabel; anchors.centerIn: parent; text: "you"; color: app.bg; font { pixelSize: 11; weight: Font.DemiBold } }
            }
            Text {
                objectName: bar.side + "Material"
                readonly property int lead: bar.side === "white" ? app.materialBalance : -app.materialBalance
                visible: lead > 0; text: "+" + lead; color: app.muted; font { family: app.mono; pixelSize: 12 }
            }
            Item { Layout.fillWidth: true }
            // Lichess analysis for this side: accuracy and ?! / ? / ?? counts.
            Row {
                visible: !!app.review; spacing: 8
                readonly property var stats: app.review ? app.review[bar.side] || {} : {}
                Text { text: parent.stats.accuracy !== undefined ? parent.stats.accuracy + "%" : "–"; color: app.fg; font { family: app.mono; pixelSize: 13; weight: Font.DemiBold } }
                Repeater {
                    model: ["inaccuracy", "mistake", "blunder"]
                    Text {
                        required property string modelData
                        text: (parent.stats[modelData] || 0) + app.judgementGlyph(modelData)
                        color: app.judgementColor(modelData); font { family: app.mono; pixelSize: 12 }
                    }
                }
            }
            Text { visible: bar.clockText !== ""; text: bar.clockText; color: bar.active ? app.fg : app.muted; font { family: app.mono; pixelSize: 17; weight: bar.active ? Font.DemiBold : Font.Normal } }
        }
        }
    }

    GridLayout {
        id: page
        width: boardView.width
        height: Math.max(boardView.height, implicitHeight)
        columns: boardView.narrow ? 1 : 2
        columnSpacing: app.zen ? 0 : 20; rowSpacing: app.zen ? 0 : 12

        Item {
            id: boardArea
            Layout.fillWidth: true; Layout.fillHeight: !boardView.narrow
            Layout.preferredHeight: boardView.narrow ? Math.min(boardView.width, boardView.height * 0.62) : -1
            // Leaves zen mode; the only control on screen while the panel is hidden.
            ActionButton { objectName: "zenExit"; visible: app.zen; z: 3; anchors { right: parent.right; top: parent.top } theme: app; compact: true; icon: "⤡"; hint: "z"; onClicked: app.zen = false }
            MouseArea {
                anchors.fill: parent; acceptedButtons: Qt.NoButton
                onWheel: wheel => app.rewind(app.shownPly() + (wheel.angleDelta.y > 0 ? -1 : 1))
            }
            Column {
                anchors.centerIn: parent; spacing: 10
                Rectangle {
                    width: grid.width + 8; height: width; radius: 7; color: app.line
                    Rectangle {
                        id: evalBar
                        objectName: "evalBar"
                        visible: app.engineOn && app.engineAllowed
                        anchors { right: parent.left; rightMargin: 10; top: parent.top; bottom: parent.bottom }
                        width: 16; radius: 5; color: "#20282b"; clip: true
                        Rectangle {
                            width: parent.width; color: "#f4f0e4"
                            height: parent.height * app.whiteShare()
                            y: app.flipped ? 0 : parent.height - height
                            Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                        }
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 1; color: Qt.rgba(0.5, 0.5, 0.5, 0.7) }
                    }
                    Grid {
                        id: grid
                        anchors.centerIn: parent
                        width: Math.max(160, Math.floor((Math.min(boardArea.width - (app.engineOn ? 52 : 0), boardArea.height) - 8) / 8) * 8)
                        height: width; columns: 8
                        Repeater {
                            model: 64
                            Rectangle {
                                id: cell
                                required property int index
                                property int sq: app.canonical(index)
                                property string piece: app.board[sq] || ""
                                property bool light: (Math.floor(index / 8) + index % 8) % 2 === 0
                                property string last: !!app.game && app.shownPly() > 0 ? app.game.moves[app.shownPly() - 1] || "" : ""
                                property bool lastMove: last !== "" && (last.slice(0,2) === app.square(sq) || last.slice(2,4) === app.square(sq))
                                property bool inCheck: !!app.game && !app.rewound && app.game.check && piece === (app.game.turn === "white" ? "K" : "k")
                                property bool target: app.origin >= 0 && !!app.game && app.game.legal.some(m => m.startsWith(app.square(app.origin) + app.square(sq)))
                                readonly property color base: light ? app.squareLight : app.squareDark
                                readonly property color coordColor: light ? app.squareDark : app.squareLight
                                width: grid.width / 8; height: width
                                color: app.origin === sq ? app.mix(base, app.selection, 0.55) : lastMove ? app.mix(base, app.highlight, 0.4) : base
                                Rectangle {
                                    anchors.fill: parent; visible: cell.inCheck
                                    gradient: Gradient { orientation: Gradient.Vertical
                                        GradientStop { position: 0; color: app.alpha(app.danger, 0) }
                                        GradientStop { position: 0.5; color: app.alpha(app.danger, 0.7) }
                                        GradientStop { position: 1; color: app.alpha(app.danger, 0) } }
                                }
                                // Center the glyph's ink, not its font line box (ascent/descent skew it).
                                TextMetrics { id: ink; font: pieceText.font; text: pieceText.text }
                                Text {
                                    id: pieceText
                                    x: (cell.width - ink.tightBoundingRect.width) / 2 - ink.tightBoundingRect.x
                                    y: (cell.height - ink.tightBoundingRect.height) / 2 - ink.tightBoundingRect.y - baselineOffset
                                    text: app.glyph(cell.piece); color: cell.piece === cell.piece.toUpperCase() ? "#fbf8ee" : "#1f2629"; style: Text.Outline; styleColor: cell.piece === cell.piece.toUpperCase() ? "#2b3533" : "#55615c"; font { family: "DejaVu Sans"; pixelSize: cell.width * 0.8 }
                                }
                                Text { anchors { left: parent.left; top: parent.top; leftMargin: 3; topMargin: 1 } visible: cell.index % 8 === 0; text: app.square(cell.sq)[1]; color: cell.coordColor; font { pixelSize: Math.max(9, cell.width * 0.18); weight: Font.DemiBold } }
                                Text { anchors { right: parent.right; bottom: parent.bottom; rightMargin: 3; bottomMargin: 0 } visible: cell.index >= 56; text: app.square(cell.sq)[0]; color: cell.coordColor; font { pixelSize: Math.max(9, cell.width * 0.18); weight: Font.DemiBold } }
                                Rectangle { anchors.centerIn: parent; visible: cell.target && !cell.piece; width: cell.width * 0.3; height: width; radius: width / 2; color: "#50202820" }
                                Rectangle { anchors { fill: parent; margins: 1 } visible: cell.target && !!cell.piece; radius: width / 2; color: "transparent"; border.width: cell.width * 0.08; border.color: "#60202820" }
                                Rectangle { anchors { fill: parent; margins: 2 } radius: 3; color: "transparent"; border.width: 3; border.color: app.accent; visible: app.cursor === cell.index && focusScope.activeFocus }
                                MouseArea { anchors.fill: parent; onClicked: { focusScope.forceActiveFocus(); app.selectSquare(cell.index); } }
                            }
                        }
                    }
                    // Arrows as vector shapes: a Canvas kept a full-board pixel buffer (~23 MB) even with no arrows.
                    Item {
                        id: arrowLayer
                        objectName: "arrowLayer"
                        anchors.fill: grid
                        readonly property real size: width / 8
                        function center(sq) {
                            let i = (8 - Number(sq[1])) * 8 + sq.charCodeAt(0) - 97;
                            if (app.flipped) i = 63 - i;
                            return Qt.point((i % 8 + 0.5) * size, (Math.floor(i / 8) + 0.5) * size);
                        }
                        Repeater {
                            model: app.arrows
                            Shape {
                                required property var modelData
                                readonly property point from: arrowLayer.center(modelData.uci.slice(0, 2))
                                readonly property point to: arrowLayer.center(modelData.uci.slice(2, 4))
                                readonly property real angle: Math.atan2(to.y - from.y, to.x - from.x)
                                readonly property real head: arrowLayer.size * 0.42
                                readonly property point base: Qt.point(to.x - Math.cos(angle) * head, to.y - Math.sin(angle) * head)
                                anchors.fill: parent
                                ShapePath {
                                    strokeColor: modelData.color; strokeWidth: arrowLayer.size * 0.16; fillColor: "transparent"; capStyle: ShapePath.FlatCap
                                    startX: from.x; startY: from.y
                                    PathLine { x: base.x; y: base.y }
                                }
                                ShapePath {
                                    strokeWidth: -1; fillColor: modelData.color
                                    startX: to.x; startY: to.y
                                    PathLine { x: base.x + Math.sin(angle) * head * 0.6; y: base.y - Math.cos(angle) * head * 0.6 }
                                    PathLine { x: base.x - Math.sin(angle) * head * 0.6; y: base.y + Math.cos(angle) * head * 0.6 }
                                    PathLine { x: to.x; y: to.y }
                                }
                            }
                        }
                    }
                    Rectangle {
                        objectName: "promotionPicker"
                        anchors.fill: grid; visible: app.promotion !== ""; color: app.alpha(app.bg, 0.8)
                        MouseArea { anchors.fill: parent }
                        Column {
                            anchors.centerIn: parent; spacing: 16
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Promote to"; color: app.fg; font { pixelSize: 16; weight: Font.DemiBold } }
                            Row {
                                spacing: 10
                                Repeater {
                                    model: ["q", "r", "b", "n"]
                                    Rectangle {
                                        id: choice
                                        required property string modelData
                                        readonly property bool white: !!app.game && app.game.turn === "white"
                                        objectName: "promote_" + modelData
                                        width: Math.max(56, grid.width / 8 * 1.2); height: width; radius: 12
                                        color: choiceMouse.containsMouse ? app.raised : app.panel
                                        border.width: 1; border.color: choiceMouse.containsMouse ? app.fg : app.line
                                        scale: choiceMouse.pressed ? 0.95 : choiceMouse.containsMouse ? 1.04 : 1
                                        Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        Text { anchors.centerIn: parent; text: app.glyph(choice.modelData); color: choice.white ? "#fbf8ee" : "#1f2629"; style: Text.Outline; styleColor: choice.white ? "#2b3533" : "#55615c"; font { family: "DejaVu Sans"; pixelSize: choice.width * 0.62 } }
                                        Text { anchors { right: parent.right; bottom: parent.bottom; margins: 6 } text: choice.modelData; color: app.muted; font { family: app.mono; pixelSize: 11 } }
                                        MouseArea { id: choiceMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.promote(choice.modelData) }
                                    }
                                }
                            }
                            ActionButton { objectName: "promotionCancel"; anchors.horizontalCenter: parent.horizontalCenter; theme: app; compact: true; label: "Cancel"; hint: "esc"; onClicked: app.clearPending() }
                        }
                    }
                }
            }
        }

        Rectangle {
            objectName: "sidePanel"
            visible: !app.zen
            Layout.preferredWidth: boardView.narrow ? -1 : 390; Layout.fillWidth: boardView.narrow
            Layout.fillHeight: !boardView.narrow; Layout.preferredHeight: boardView.narrow ? panelColumn.implicitHeight + 28 : -1; radius: 14
            color: app.panel; border.width: 1; border.color: app.line
            ColumnLayout {
                id: panelColumn
                anchors { fill: parent; margins: 14 } spacing: 10
                PageHeader {
                    theme: boardView.app
                    title: app.statusText()
                    subtitle: app.gameInfo()
                    backLabel: app.game && app.game.analysis_source ? "Source" : "Back"
                    backObjectName: app.game && app.game.analysis_source ? "sourceButton" : "gamesButton"
                    onBackRequested: app.navigateBack()
                    trailingContent: Component {
                        RowLayout {
                            spacing: 6
                            ActionButton { objectName: "deleteBoardButton"; visible: !!app.game && app.game.analysis; theme: app; compact: true; kind: "danger"; icon: "✕"; hint: "x"; onClicked: app.confirmDelete(app.selectedId) }
                            ActionButton { objectName: "studyCaptureButton"; visible: !!app.game && !app.isActive(app.game); theme: app; compact: true; label: "Study"; hint: "S"; onClicked: app.send("study_capture", {ply: app.shownPly()}) }
                            ActionButton { objectName: "zenButton"; theme: app; compact: true; icon: "⤢"; hint: "z"; onClicked: app.zen = true }
                            ActionButton { objectName: "helpButton"; theme: app; compact: true; icon: "?"; hint: ""; onClicked: app.helpVisible = true }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !!app.game && app.game.online && !!app.game.color
                    ActionButton { objectName: "chatButton"; theme: app; compact: true; label: app.chatVisible ? "Moves" : "Chat"; hint: "c"; onClicked: app.runCommand(":chat") }
                    ActionButton { objectName: "takebackButton"; theme: app; compact: true; visible: app.isActive(app.game); enabled: app.game.takeback_offer !== app.game.color; opacity: enabled ? 1 : 0.5; label: app.game.takeback_offer && app.game.takeback_offer !== app.game.color ? "Accept" : "Takeback"; hint: "T"; onClicked: app.runCommand(":takeback") }
                    ActionButton { objectName: "declineTakebackButton"; theme: app; compact: true; visible: app.isActive(app.game) && !!app.game.takeback_offer && app.game.takeback_offer !== app.game.color; label: "Decline"; hint: "Y"; onClicked: app.runCommand(":takeback no") }
                }
                Text { Layout.fillWidth: true; visible: !!app.game && !!app.game.takeback_offer && app.isActive(app.game); text: app.game && app.game.takeback_offer === app.game.color ? "Takeback requested · waiting for opponent" : "Opponent requests a takeback"; color: app.accent; font.pixelSize: 12 }
                // Board-top player first, matching the orientation.
                Item { Layout.fillWidth: true; Layout.preferredHeight: 26; Loader { anchors.fill: parent; sourceComponent: playerBar; property string side: app.flipped ? "white" : "black" } }
                Item { Layout.fillWidth: true; Layout.preferredHeight: 26; Loader { anchors.fill: parent; sourceComponent: playerBar; property string side: app.flipped ? "black" : "white" } }
                Rectangle {
                    objectName: "reviewCard"
                    Layout.fillWidth: true; visible: app.reviewable && !app.review; implicitHeight: reviewColumn.implicitHeight + 16; radius: 10
                    color: app.bg; border.width: 1; border.color: app.line
                    ColumnLayout {
                        id: reviewColumn
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 } spacing: 2
                        // Once loaded, analysis shows in the player rows; r / :lichess reloads it.
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            Text { Layout.fillWidth: true; elide: Text.ElideRight; text: "No Lichess analysis"; color: app.muted; font.pixelSize: 12 }
                            ActionButton { objectName: "reviewButton"; theme: app; compact: true; label: "Load"; hint: "r"; onClicked: app.loadReview() }
                            ActionButton { objectName: "reviewSiteButton"; theme: app; compact: true; label: "lichess.org ↗"; hint: "L"; onClicked: Qt.openUrlExternally("https://lichess.org/" + app.selectedId) }
                        }
                    }
                }
                // Puzzle of the day on the main board: Lichess-style status, hint and solution.
                Rectangle {
                    objectName: "puzzlePanel"
                    Layout.fillWidth: true; visible: !!app.game && !!app.game.puzzle; implicitHeight: puzzleColumn.implicitHeight + 16; radius: 10
                    color: app.bg; border.width: 1; border.color: app.line
                    readonly property var pz: app.game && app.game.puzzle ? app.game.puzzle : null
                    ColumnLayout {
                        id: puzzleColumn
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 } spacing: 6
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            Text {
                                text: app.glyph("k"); style: Text.Outline; font { family: "DejaVu Sans"; pixelSize: 30 }
                                color: app.game && app.game.color === "black" ? "#1f2629" : "#fbf8ee"; styleColor: app.game && app.game.color === "black" ? "#55615c" : "#2b3533"
                            }
                            Column {
                                Layout.fillWidth: true; spacing: 1
                                Text { readonly property var pz: app.game ? app.game.puzzle : null
                                text: app.puzzleUnsolved || !pz ? "Your turn" : (pz.failed ? "Solved, not on the first try" : "Solved ✓") + (pz.rating_diff !== undefined && pz.rating_diff !== null ? "  " + (pz.rating_diff > 0 ? "+" : "") + pz.rating_diff : ""); color: app.fg; font { pixelSize: 15; weight: Font.DemiBold } }
                                Text { width: parent.width; elide: Text.ElideRight; text: app.puzzleUnsolved ? "Find the best move for " + (app.game.color === "black" ? "Black" : "White") + "." : "Engine and analysis are available."; color: app.muted; font.pixelSize: 12 }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            ActionButton { objectName: "puzzleHintButton"; visible: app.puzzleUnsolved; theme: app; compact: true; label: "Hint"; hint: "v"; onClicked: app.puzzleHint() }
                            ActionButton { objectName: "puzzleSolutionButton"; visible: app.puzzleUnsolved; theme: app; compact: true; label: "Solution"; hint: "u"; onClicked: app.send("puzzle_solution") }
                            ActionButton { objectName: "puzzleNextButton"; visible: !app.puzzleUnsolved && !!app.game && !!app.game.puzzle && !!app.game.puzzle.angle; theme: app; compact: true; kind: "primary"; label: "Next puzzle"; hint: "n"; onClicked: app.runCommand(":next") }
                            ActionButton { objectName: "puzzleRetryButton"; visible: !!parent.parent.parent.pz && app.game.moves.length > parent.parent.parent.pz.start; theme: app; compact: true; label: "Retry"; hint: "y"; onClicked: app.send("puzzle_retry") }
                            Item { Layout.fillWidth: true }
                        }
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; color: app.muted; font.pixelSize: 11
                            readonly property var pz: parent.parent.pz
                            text: !pz ? "" : "Puzzle #" + pz.id + " · " + (app.puzzleUnsolved ? "rating hidden" : "rating " + pz.rating) + (pz.plays ? " · played " + Number(pz.plays).toLocaleString(Qt.locale(), "f", 0) + " times" : "")
                                  + (pz.source && pz.source.clock ? "\nFrom a " + pz.source.clock + " " + (pz.source.perf || "") + " game" : "")
                                  + (!app.puzzleUnsolved && pz.themes ? "\n" + pz.themes.map(t => t.replace(/([A-Z])/g, " $1").toLowerCase()).join(" · ") : "")
                        }
                    }
                }
                Rectangle {
                    objectName: "engineCard"
                    Layout.fillWidth: true; implicitHeight: engineColumn.implicitHeight + 16; radius: 10
                    color: app.bg; border.width: 1; border.color: app.line
                    ColumnLayout {
                        id: engineColumn
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 } spacing: 4
                        Rectangle {
                            objectName: "engineProgress"
                            Layout.fillWidth: true; height: 3; radius: 1.5
                            visible: app.engineOn && app.engineAllowed
                            color: app.line
                            Rectangle {
                                objectName: "engineProgressFill"
                                width: parent.width * app.evalProgress; height: parent.height; radius: parent.radius
                                color: "#629924"
                                Behavior on width { NumberAnimation { duration: 120 } }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            ActionButton { objectName: "engineButton"; theme: app; compact: true; kind: app.engineOn && app.engineAllowed ? "primary" : "normal"; icon: "⚙"; label: app.engineOn ? "Engine on" : "Engine"; hint: "e"; onClicked: app.engineOn = !app.engineOn }
                            ActionButton { objectName: "explorerButton"; theme: app; compact: true; kind: app.explorerOn && app.engineAllowed ? "primary" : "normal"; label: "Book"; hint: "m"; onClicked: app.explorerOn = !app.explorerOn }
                            Text {
                                visible: app.engineOn && app.engineAllowed && !!app.evalData && !app.evalData.error
                                text: app.formatScore(app.evalData)
                                color: app.fg; font { family: app.mono; pixelSize: 20; weight: Font.DemiBold }
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight
                                text: app.evalPending && !app.evalData ? "thinking…" : app.evalData && !app.evalData.error ? app.evalData.source + (app.evalData.depth ? " · " + app.evalData.depth + "/" + app.engineDepth : "") : ""
                                color: app.faint; font.pixelSize: 11
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            visible: app.engineOn && app.engineAllowed
                            ActionButton { objectName: "depthDecrease"; theme: app; compact: true; label: "−"; hint: "-"; onClicked: app.adjustDepth(-1) }
                            ActionButton { objectName: "depthInput"; theme: app; compact: true; label: String(app.engineDepth); hint: "d"; onClicked: app.prefill(":depth " + app.engineDepth) }
                            ActionButton { objectName: "depthIncrease"; theme: app; compact: true; label: "+"; hint: "+"; onClicked: app.adjustDepth(1) }
                            Slider {
                                id: depthSlider
                                objectName: "depthSlider"
                                Layout.fillWidth: true; implicitHeight: 22
                                visible: app.engineOn && app.engineAllowed
                                from: 1; to: 245; stepSize: 1; value: app.engineDepth; live: false
                                Accessible.name: "Target analysis depth"
                                onMoved: app.engineDepth = Math.round(value)
                                background: Rectangle {
                                    x: depthSlider.leftPadding; y: (depthSlider.height - height) / 2
                                    width: depthSlider.availableWidth; height: 3; radius: 1.5
                                    color: app.line
                                    Rectangle { width: depthSlider.visualPosition * parent.width; height: parent.height; radius: parent.radius; color: app.muted }
                                }
                                handle: Rectangle {
                                    x: depthSlider.leftPadding + depthSlider.visualPosition * (depthSlider.availableWidth - width)
                                    y: (depthSlider.height - height) / 2
                                    width: 12; height: 12; radius: 6
                                    color: depthSlider.pressed ? app.fg : app.muted
                                    border.width: depthSlider.activeFocus ? 2 : 1
                                    border.color: depthSlider.activeFocus ? app.fg : app.bg
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true; visible: app.engineOn && text !== ""; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                            text: app.puzzleUnsolved ? "Solve the puzzle to use the engine." : !app.engineAllowed ? "Off while you play a live Lichess game (fair play)." : app.evalData && app.evalData.error ? app.evalData.error : app.formatPv(app.evalData)
                            color: app.muted; font { family: app.evalData && app.evalData.pv ? app.mono : "sans-serif"; pixelSize: 12 }
                        }
                    }
                }
                // Opening explorer: moves played from this position in the Masters or Lichess database.
                Rectangle {
                    id: explorerCard
                    objectName: "explorerCard"
                    Layout.fillWidth: true; visible: app.explorerOn && app.engineAllowed; implicitHeight: explorerColumn.implicitHeight + 16; radius: 10
                    color: app.bg; border.width: 1; border.color: app.line
                    readonly property var book: app.explorerData && !app.explorerData.error ? app.explorerData.explorer : null
                    readonly property real total: book ? book.white + book.draws + book.black : 0
                    ColumnLayout {
                        id: explorerColumn
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 } spacing: 4
                        RowLayout {
                            Layout.fillWidth: true; spacing: 6
                            Repeater {
                                model: [["masters", "Masters"], ["lichess", "Lichess"]]
                                ActionButton {
                                    required property var modelData
                                    objectName: "explorer_" + modelData[0]
                                    theme: app; compact: true; label: modelData[1]
                                    kind: app.explorerDb === modelData[0] ? "primary" : "normal"
                                    onClicked: app.explorerDb = modelData[0]
                                }
                            }
                            Text {
                                Layout.fillWidth: true; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight; color: app.muted; font.pixelSize: 11
                                text: explorerCard.book && explorerCard.book.opening ? explorerCard.book.opening.eco + " " + explorerCard.book.opening.name : ""
                            }
                        }
                        EmptyState {
                            Layout.fillWidth: true
                            visible: !explorerCard.book
                            theme: boardView.app
                            title: app.explorerData && app.explorerData.error ? "Explorer unavailable" : "Loading explorer…"
                            detail: app.explorerData && app.explorerData.error ? app.explorerData.error : "Fetching opening statistics for this position."
                        }
                        EmptyState {
                            Layout.fillWidth: true
                            visible: !!explorerCard.book && explorerCard.total === 0
                            theme: boardView.app
                            title: "No games from this position"
                            detail: "Try an earlier position or switch databases."
                        }
                        ListView {
                            id: explorerList
                            objectName: "explorerList"
                            Layout.fillWidth: true; implicitHeight: Math.min(count, 5) * 26; clip: true; interactive: count > 5
                            visible: count > 0
                            // The total row closes the list, like Lichess's Σ.
                            model: {
                                const d = explorerCard.book;
                                if (!d || !d.moves.length) return [];
                                return d.moves.map(m => Object.assign({played: m.white + m.draws + m.black}, m)).concat([{san: "Σ", uci: "", white: d.white, draws: d.draws, black: d.black, played: explorerCard.total}]);
                            }
                            ScrollBar.vertical: ScrollBar { }
                            delegate: Rectangle {
                                id: explorerRow
                                required property var modelData
                                readonly property real games: modelData.played
                                width: explorerList.width; height: 26; radius: 5
                                color: rowMouse.containsMouse && modelData.uci ? app.raised : "transparent"
                                MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; enabled: !!parent.modelData.uci; cursorShape: Qt.PointingHandCursor; onClicked: app.playExplorerMove(parent.modelData.uci) }
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 6; rightMargin: 6 } spacing: 6
                                    Text { Layout.preferredWidth: 44; text: modelData.san; color: app.fg; font { family: app.mono; pixelSize: 12; weight: modelData.uci ? Font.Normal : Font.DemiBold } }
                                    Text { Layout.preferredWidth: 32; horizontalAlignment: Text.AlignRight; text: explorerCard.total ? Math.round(100 * games / explorerCard.total) + "%" : ""; color: app.muted; font { family: app.mono; pixelSize: 10 } }
                                    Text { Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight; text: games >= 1e6 ? (games / 1e6).toFixed(1) + "M" : games >= 1e3 ? Math.round(games / 1e3) + "k" : games; color: app.muted; font { family: app.mono; pixelSize: 10 } }
                                    ResultBar { Layout.fillWidth: true; Layout.preferredHeight: 16; stats: explorerRow.modelData; theme: app }
                                }
                            }
                        }
                    }
                }
                Loader { id: chatLoader; Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 150
                    Layout.preferredHeight: boardView.narrow ? 260 : -1; visible: active; active: app.chatVisible && !!app.game && app.game.online && !!app.game.color; sourceComponent: Component { ChatPanel { app: boardView.app; focusScope: boardView.focusScope } } }
                Rectangle {
                    visible: !chatLoader.active
                    Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 150
                    Layout.preferredHeight: boardView.narrow ? 260 : -1; radius: 10; color: app.bg; border.width: 1; border.color: app.line
                    ListView {
                        id: moveList
                        anchors { fill: parent; margins: 6 } clip: true
                        model: app.game ? Math.ceil((app.game.san.length + app.initialPlyOffset) / 2) : 0
                        onCountChanged: positionViewAtEnd()
                        delegate: Column {
                            id: moveRow
                            required property int index
                            readonly property int lastPly: app.shownPly() - 1
                            width: moveList.width
                            Rectangle {
                                width: parent.width; height: 28; radius: 6
                                color: moveRow.index % 2 ? "transparent" : app.alpha(app.fg, 0.035)
                                Row {
                                    anchors { fill: parent; leftMargin: 8 } spacing: 4
                                    Text { width: 30; anchors.verticalCenter: parent.verticalCenter; text: (moveRow.index + app.initialMoveNumber) + "."; color: app.faint; font { family: app.mono; pixelSize: 12 } }
                                    Repeater {
                                        model: 2
                                        Rectangle {
                                            required property int index
                                            readonly property int ply: moveRow.index * 2 + index - app.initialPlyOffset
                                            readonly property bool current: ply === moveRow.lastPly
                                            readonly property string judgement: app.judgement(ply)
                                            width: (moveRow.width - 50) / 2; height: 22; radius: 5; anchors.verticalCenter: parent.verticalCenter
                                            color: current ? app.fg : "transparent"
                                            Text {
                                                anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                                                text: app.game ? (app.game.san[parent.ply] || "") + app.judgementGlyph(parent.judgement) : ""
                                                color: parent.current ? app.bg : parent.judgement ? app.judgementColor(parent.judgement) : app.fg
                                                font { family: app.mono; pixelSize: 13; weight: parent.current || parent.judgement ? Font.DemiBold : Font.Normal }
                                            }
                                            Text {
                                                anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                                text: app.game && parent.ply >= 0 && parent.ply < app.game.san.length ? app.reviewScore(parent.ply) : ""
                                                color: parent.current ? app.bg : app.faint; font { family: app.mono; pixelSize: 10 }
                                            }
                                            MouseArea { anchors.fill: parent; enabled: !!app.game && parent.ply >= 0 && parent.ply < app.game.san.length; cursorShape: Qt.PointingHandCursor; onClicked: app.rewind(parent.ply + 1) }
                                        }
                                    }
                                }
                            }
                            Repeater {
                                model: 2
                                Rectangle {
                                    required property int index
                                    readonly property int ply: moveRow.index * 2 + index - app.initialPlyOffset
                                    readonly property string judgement: app.judgement(ply)
                                    readonly property var entry: judgement ? app.review.moves[ply] : null
                                    objectName: "judgement_" + ply
                                    visible: judgement !== ""
                                    width: moveRow.width; height: visible ? comment.implicitHeight + 12 : 0
                                    color: app.alpha(app.judgementColor(judgement), 0.08)
                                    Rectangle { width: 2; height: parent.height; color: app.judgementColor(parent.judgement) }
                                    Column {
                                        id: comment
                                        x: 12; y: 6; width: parent.width - 20; spacing: 3
                                        Text { width: parent.width; wrapMode: Text.WordWrap; text: parent.parent.entry ? parent.parent.entry.judgment.comment : ""; color: app.judgementColor(parent.parent.judgement); font.pixelSize: 12 }
                                        Text {
                                            width: parent.width; wrapMode: Text.WordWrap
                                            text: parent.parent.entry && parent.parent.entry.variation ? app.formatPv({ply: parent.parent.ply, pv: parent.parent.entry.variation.split(" ")}) : ""
                                            color: app.muted; font { family: app.mono; pixelSize: 11 }
                                        }
                                    }
                                }
                            }
                        }
                        // Variations scroll with the moves, so the panel never overflows.
                        footer: Column {
                            readonly property var variations: app.games.filter(g => g.analysis_source === app.selectedId)
                            width: moveList.width; spacing: 2; topPadding: variations.length ? 8 : 0
                            Text { visible: parent.variations.length > 0; leftPadding: 8; bottomPadding: 2; text: "Saved variations"; color: app.muted; font.pixelSize: 11 }
                            Repeater {
                                id: variationList
                                objectName: "variationList"
                                model: parent.variations
                                RowLayout {
                                    required property var modelData
                                    required property int index
                                    width: moveList.width; spacing: 4
                                    ActionButton {
                                        Layout.fillWidth: true; implicitHeight: 26; compact: true; theme: app
                                        label: "Variation " + (parent.index + 1) + " · ply " + parent.modelData.analysis_ply + (parent.modelData.san.length > parent.modelData.analysis_ply ? " · " + parent.modelData.san.slice(parent.modelData.analysis_ply, parent.modelData.analysis_ply + 3).join(" ") : "")
                                        onClicked: app.choose(parent.modelData.id)
                                    }
                                    ActionButton { objectName: "deleteVariation" + parent.index; implicitHeight: 26; compact: true; theme: app; kind: "danger"; icon: "✕"; onClicked: app.confirmDelete(parent.modelData.id) }
                                }
                            }
                        }
                        ScrollBar.vertical: ScrollBar { }
                        Text { anchors.centerIn: parent; visible: moveList.count === 0; text: "No moves yet"; color: app.faint; font.pixelSize: 13 }
                    }
                }
                RowLayout {
                    objectName: "playedVsBest"
                    readonly property int ply: app.shownPly()
                    readonly property string judgement: app.judgement(ply)
                    readonly property var entry: judgement ? app.review.moves[ply] : null
                    Layout.fillWidth: true; spacing: 6; visible: !!entry
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredWidth: 1; height: 30; radius: 8
                        color: app.alpha(app.judgementColor(parent.judgement), 0.16)
                        Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter } text: parent.parent.entry ? app.moveLabel(parent.parent.ply, app.game.san[parent.parent.ply] + app.judgementGlyph(parent.parent.judgement)) : ""; color: app.judgementColor(parent.parent.judgement); font { family: app.mono; pixelSize: 12; weight: Font.DemiBold } }
                        Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter } text: app.reviewScore(parent.parent.ply); color: app.muted; font { family: app.mono; pixelSize: 11 } }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: app.rewind(parent.parent.ply + 1) }
                    }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredWidth: 1; height: 30; radius: 8
                        color: app.alpha(app.fg, 0.06); border.width: 1; border.color: app.line
                        Text { anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter } text: parent.parent.entry && parent.parent.entry.variation ? app.moveLabel(parent.parent.ply, parent.parent.entry.variation.split(" ")[0]) : ""; color: app.fg; font { family: app.mono; pixelSize: 12; weight: Font.DemiBold } }
                        Text { anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter } text: app.reviewScore(parent.parent.ply - 1); color: app.muted; font { family: app.mono; pixelSize: 11 } }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    ActionButton { objectName: "rewindStart"; theme: app; compact: true; label: "«"; hint: "Home"; onClicked: app.rewind(0) }
                    ActionButton { objectName: "rewindBack"; theme: app; compact: true; label: "‹"; hint: "["; onClicked: app.rewind(app.shownPly() - 1) }
                    Text {
                        Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                        text: app.game ? (app.viewPly >= 0 ? "move " + Math.ceil(app.viewPly / 2) + " of " + Math.ceil(app.game.moves.length / 2) : "live") : ""
                        color: app.viewPly >= 0 ? app.fg : app.faint; font { family: app.mono; pixelSize: 12; weight: app.viewPly >= 0 ? Font.DemiBold : Font.Normal }
                    }
                    ActionButton { objectName: "rewindForward"; theme: app; compact: true; label: "›"; hint: "]"; onClicked: app.rewind(app.shownPly() + 1) }
                    ActionButton { objectName: "rewindLive"; theme: app; compact: true; label: "»"; hint: "End"; kind: app.viewPly >= 0 ? "primary" : "normal"; onClicked: app.rewind(Infinity) }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6; visible: !app.confirmation
                    ActionButton { objectName: "analyseButton"; theme: app; Layout.fillWidth: true; Layout.minimumWidth: implicitWidth; compact: true; label: app.game && app.game.analysis ? "Branch" : "Analyse"; hint: "a"; enabled: app.engineAllowed; opacity: enabled ? 1 : 0.4; onClicked: app.analyse() }
                    ActionButton { objectName: "fenButton"; theme: app; compact: true; label: "FEN"; onClicked: app.prefill(":fen ") }
                    ActionButton { objectName: "flipButton"; theme: app; compact: true; icon: "⇅"; onClicked: app.runCommand(":flip") }
                    ActionButton { theme: app; compact: true; icon: "+"; onClicked: app.newWindow() }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: !app.confirmation && !!app.game && !app.game.analysis && !app.game.puzzle && app.isActive(app.game) && (!app.game.online || !!app.game.color)
                    ActionButton { objectName: "drawButton"; theme: app; Layout.fillWidth: true; compact: true; icon: "½"; label: "Draw"; hint: "D"; onClicked: app.runCommand(":draw") }
                    ActionButton { objectName: "resignButton"; theme: app; Layout.fillWidth: true; compact: true; kind: "danger"; icon: "⚑"; label: "Resign"; hint: "R"; onClicked: app.runCommand(":resign") }
                }
                Rectangle {
                    Layout.fillWidth: true; visible: !!app.confirmation
                    implicitHeight: confirmBox.implicitHeight + 28; radius: 10
                    color: app.bg; border.width: 1; border.color: app.confirmation === "resign" || app.confirmation === "delete" ? app.alpha(app.danger, 0.45) : app.line
                    ColumnLayout {
                        id: confirmBox
                        anchors { fill: parent; margins: 14 } spacing: 6
                        Text { text: app.confirmation === "delete" ? (app.game && app.game.puzzle ? "Delete this puzzle?" : "Delete this variation?") : app.confirmation === "resign" ? "Resign this game?" : "Offer or accept a draw?"; color: app.fg; font { pixelSize: 14; weight: Font.DemiBold } }
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: app.confirmation === "delete" ? "Branches made from it are deleted too. This can't be undone." : app.confirmation === "resign" ? "Your opponent wins. This can't be undone." : "The game ends if both sides agree."; color: app.muted; font.pixelSize: 12 }
                        RowLayout {
                            Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
                            ActionButton { objectName: "cancelConfirmButton"; theme: app; Layout.fillWidth: true; label: "Cancel"; hint: "esc"; onClicked: app.clearPending() }
                            ActionButton { objectName: "confirmButton"; theme: app; Layout.fillWidth: true; kind: app.confirmation === "resign" || app.confirmation === "delete" ? "destructive" : "primary"; label: app.confirmation === "delete" ? "Delete" : app.confirmation === "resign" ? "Resign" : "Draw"; hint: "↵"; onClicked: app.runCommand(":confirm") }
                        }
                    }
                }
            }
        }
    }
}
