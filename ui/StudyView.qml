import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Flickable {
    id: root
    objectName: "studyView"
    required property var app
    required property Item focusScope
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: page.height
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { }
    property var library: null
    property var chapter: null
    property int node: 0
    property string error: ""
    property string input: ""
    property string exportText: ""
    property string mode: "library"
    property var session: null
    property int sessionIndex: 0
    property var engineData: null
    property int studyOrigin: -1
    readonly property bool narrow: width < 820
    onNodeChanged: studyOrigin = -1

    function send(cmd, data) { error = ""; return app.send(cmd, data || {}); }
    function load() { send("study_list"); }
    function openChapter(id) { mode = "chapter"; send("study_get", {chapter: id}); }
    function startSession() { mode = "session"; send("study_session_start", {minutes: 20}); }
    function nodeData() { return chapter && chapter.nodes ? chapter.nodes[node] || chapter.nodes[0] : null; }
    function nodeDepth() {
        let n = nodeData(), depth = 0, guard = 0;
        while (n && n.parent !== null && n.parent !== undefined && guard++ < 128) { depth++; n = chapter.nodes[n.parent]; }
        return depth;
    }
    function insightTitle() {
        const n = nodeData();
        if (!n) return "";
        if (n.card) return "Prioridade de revisão";
        if (n.children && n.children.length > 1) return "Ponto de decisão";
        if (n.comment && n.comment.trim()) return "Checkpoint anotado";
        if (node === 0) return "Posição inicial";
        if (!n.children || n.children.length === 0) return "Fim da linha";
        return "Checkpoint da linha";
    }
    function insightText() {
        const n = nodeData();
        if (!n) return "";
        const depth = nodeDepth();
        if (n.card) return "Esta posição foi transformada em cartão. O objetivo é recuperar a próxima decisão, não apenas reconhecer a posição.";
        if (n.children && n.children.length > 1) return "Há " + n.children.length + " continuações salvas. Compare os planos aqui: este é um lugar melhor para estudar do que repetir uma sequência única.";
        if (n.comment && n.comment.trim()) return "Ela tem uma anotação associada. Leia a pergunta ou ideia antes de olhar a continuação.";
        if (node === 0) return "Use esta posição para entender o plano inicial e o que a linha pretende ensinar.";
        if (!n.children || n.children.length === 0) return "A linha termina aqui. Tente encontrar uma continuação antes de consultar a análise.";
        return "Este é um checkpoint depois de " + depth + " decisão" + (depth === 1 ? "" : "ões") + ". Tente explicar o plano antes de avançar.";
    }
    // The window delegates Backspace to this view first. Set the view directly
    // on the library screen to avoid routing back through navigateBack again.
    function back() { if (mode !== "library") { mode = "library"; chapter = null; session = null; load(); } else app.view = ""; }
    function addMove() { if (!chapter || !input.trim()) return; send("study_move", {chapter: chapter.id, node: node, notation: input.trim(), revision: chapter.revision}); input = ""; }
    function review(grade) { const n = nodeData(); if (n && n.card) send("study_grade", {chapter: chapter.id, node: node, grade: grade, due: n.card.due, revision: chapter.revision}); }
    function tryMove() { if (!chapter || !input.trim()) return; send("study_try", {chapter: chapter.id, node: node, notation: input.trim(), mode: nodeData().card ? "review" : "guess"}); input = ""; }
    function squareName(index) { return "abcdefgh"[index % 8] + (8 - Math.floor(index / 8)); }
    function targetSquares() {
        const n = nodeData(), from = studyOrigin >= 0 ? squareName(studyOrigin) : "";
        if (!n || !from || !n.children) return [];
        return n.children.map(id => chapter.nodes[id].uci).filter(uci => uci && uci.slice(0, 2) === from).map(uci => (8 - Number(uci[3])) * 8 + uci.charCodeAt(2) - 97);
    }
    function selectStudySquare(index) {
        const n = nodeData(), board = n ? app.decodeFen(n.fen) : [];
        if (!n || index < 0 || index >= board.length) return;
        if (studyOrigin < 0) {
            const side = n.fen.split(" ")[1] || "w", piece = board[index] || "";
            if (!piece || (side === "w" && piece !== piece.toUpperCase()) || (side === "b" && piece !== piece.toLowerCase())) return;
            studyOrigin = index;
            return;
        }
        if (studyOrigin === index) { studyOrigin = -1; return; }
        const notation = squareName(studyOrigin) + squareName(index);
        studyOrigin = -1;
        if (mode === "review") tryMoveNotation(notation); else if (mode === "chapter") send("study_move", {chapter: chapter.id, node: node, notation: notation, revision: chapter.revision});
    }
    function tryMoveNotation(notation) { if (!chapter) return; send("study_try", {chapter: chapter.id, node: node, notation: notation, mode: nodeData().card ? "review" : "guess"}); }
    function evaluatePosition() { if (chapter) { engineData = null; send("study_eval", {chapter: chapter.id, node: node}); } }
    function score(e) { if (!e) return null; if (e.mate !== undefined && e.mate !== null) return e.mate > 0 ? 10000 : -10000; return e.cp !== undefined && e.cp !== null ? Number(e.cp) : null; }
    function scoreLabel(e) { if (!e) return ""; if (e.mate !== undefined && e.mate !== null) return "Mate in " + Math.abs(e.mate); const cp = score(e); return cp === null ? "" : (cp >= 0 ? "+" : "") + (cp / 100).toFixed(2); }
    function engineInsight() {
        if (!engineData || !engineData.evaluation) return "";
        const now = score(engineData.evaluation), before = score(engineData.previous_evaluation);
        if (before === null || now === null) return "Engine evaluation: " + scoreLabel(engineData.evaluation) + ".";
        const swing = Math.abs(now - before);
        if (swing >= 100) return "Evaluation swing: " + scoreLabel(engineData.previous_evaluation) + " → " + scoreLabel(engineData.evaluation) + ". This is a strong candidate for deeper study.";
        if (swing >= 35) return "Small evaluation shift: " + scoreLabel(engineData.previous_evaluation) + " → " + scoreLabel(engineData.evaluation) + ". Compare the plans before and after this move.";
        return "Stable evaluation: " + scoreLabel(engineData.evaluation) + ". The value here is understanding the plan, not finding a tactical refutation.";
    }

    Connections {
        target: app
        function onReplied(cmd, data, failure) {
            if (!cmd.startsWith("study_")) return;
            if (failure) { root.error = failure; return; }
            if (data.library) root.library = data.library;
            if (data.pgn) root.exportText = data.pgn;
            if (data.chapter) { root.chapter = data.chapter; root.node = data.chapter.bookmark || 0; }
            if (cmd === "study_eval") root.engineData = data;
            if (cmd === "study_session_start") { root.session = data.library.session; root.sessionIndex = 0; }
            if (cmd === "study_session_next") root.sessionIndex++;
            if (cmd === "study_session_end") { root.session = null; root.mode = "library"; }
            if (cmd === "study_try" || cmd === "study_grade") root.error = data.message || (cmd === "study_grade" ? "Review saved." : (data.correct ? "Good line." : "Try another move."));
        }
    }
    Component.onCompleted: {
        app.viewKeys = handleKey;
        load();
        Qt.callLater(function() { root.focusScope.forceActiveFocus(); });
    }
    Component.onDestruction: if (app.viewKeys) app.viewKeys = null
    function handleKey(key, event) {
        if (event.key === Qt.Key_Backspace) { back(); return true; }
        if (mode === "library") {
            if (key === "j" || event.key === Qt.Key_Down) { chapterList.currentIndex = Math.min(chapterList.count - 1, chapterList.currentIndex + 1); return true; }
            if (key === "k" || event.key === Qt.Key_Up) { chapterList.currentIndex = Math.max(0, chapterList.currentIndex - 1); return true; }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { const c = root.library && root.library.chapters[chapterList.currentIndex]; if (c) openChapter(c.id); return true; }
            if (key === "s") { startSession(); return true; }
            if (key === "e") { send("study_examples"); return true; }
        } else if (mode === "chapter" || mode === "review") {
            if (key === "j" || event.key === Qt.Key_Down) { node = Math.min(chapter.nodes.length - 1, node + 1); return true; }
            if (key === "k" || event.key === Qt.Key_Up) { node = Math.max(0, node - 1); return true; }
            if (key === "m") { inputField.forceActiveFocus(); return true; }
            if (key === "r" && nodeData().card) { mode = "review"; return true; }
        }
        return false;
    }

    ColumnLayout {
        id: page
        width: root.width
        height: Math.max(root.height, root.narrow ? 760 : 620)
        spacing: 14

    RowLayout {
        Layout.topMargin: 4
        Layout.fillWidth: true
        spacing: 10
        ActionButton { objectName: "studyBack"; theme: app; compact: true; label: "Back"; hint: "⌫"; onClicked: root.back() }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 1
            Text { text: mode === "library" ? "Study" : mode === "session" ? "Review session" : chapter ? chapter.title : "Study"; color: app.fg; font { pixelSize: 23; weight: Font.DemiBold } }
            Text { text: mode === "library" ? "Build lines, annotate ideas and review them over time." : mode === "session" ? "A focused queue from your saved positions." : chapter ? chapter.tags : ""; color: app.muted; font.pixelSize: 12; elide: Text.ElideRight }
        }
        ActionButton { visible: mode === "library"; theme: app; compact: true; label: "Examples"; hint: root.narrow ? "" : "e"; onClicked: send("study_examples") }
        ActionButton { visible: mode === "library" && library && library.due.length > 0; theme: app; compact: true; label: "Start review"; hint: root.narrow ? "" : "s"; onClicked: startSession() }
    }

    Text { Layout.fillWidth: true; visible: !!error; text: error; color: error.includes("Good") || error.includes("saved") ? app.winColor : app.danger; wrapMode: Text.Wrap }

    ColumnLayout {
        visible: mode === "library"; Layout.fillWidth: true; Layout.fillHeight: true; spacing: 12
        Flow {
            Layout.fillWidth: true; spacing: 8
            Repeater {
                model: [
                    {label: "Due", value: root.library ? root.library.due.length : "—", detail: "positions ready"},
                    {label: "Today", value: root.library ? root.library.stats.today : "—", detail: "reviews completed"},
                    {label: "Library", value: root.library ? root.library.chapters.length : "—", detail: "chapters saved"}
                ]
                delegate: StatCard {
                    required property var modelData
                    theme: root.app; width: root.narrow ? (root.width - 8) / 2 : 170
                    label: modelData.label; value: modelData.value; detail: modelData.detail
                }
            }
        }
        GridLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; columns: root.narrow ? 1 : 2; columnSpacing: 12; rowSpacing: 12
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: root.narrow ? 0 : 410; radius: 14; color: app.panel; border.color: app.line
                ColumnLayout { anchors.fill: parent; anchors.margins: 14; spacing: 10
                    RowLayout { Layout.fillWidth: true
                        ColumnLayout { Layout.fillWidth: true; spacing: 1
                            Text { text: "Your chapters"; color: app.fg; font { pixelSize: 16; weight: Font.DemiBold } }
                            Text { text: root.library ? root.library.chapters.length + " saved lines" : "Loading…"; color: app.muted; font.pixelSize: 11 }
                        }
                        Text { text: "j / k"; color: app.muted; font.family: app.mono; font.pixelSize: 11; Layout.alignment: Qt.AlignTop }
                    }
                    ListView {
                        id: chapterList; objectName: "studyChapterList"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                        model: root.library ? root.library.chapters : []
                        delegate: Rectangle {
                            required property var modelData; required property int index
                            width: chapterList.width; height: 68; radius: 10; color: index === chapterList.currentIndex ? app.raised : "transparent"; border.color: index === chapterList.currentIndex ? app.accent : app.line
                            Column { anchors.fill: parent; anchors.margins: 10; spacing: 4
                                Text { text: modelData.title; color: app.fg; elide: Text.ElideRight; width: parent.width; font.weight: Font.DemiBold }
                                Text { text: (modelData.positions - 1) + " positions · " + modelData.cards + " cards" + (modelData.due ? " · " + modelData.due + " due" : ""); color: app.muted; font.pixelSize: 11 }
                            }
                            MouseArea { anchors.fill: parent; onClicked: { chapterList.currentIndex = index; root.openChapter(modelData.id); } }
                        }
                        EmptyState {
                            anchors.centerIn: parent
                            visible: !root.library || root.library.chapters.length === 0
                            theme: root.app
                            title: "No chapters yet"
                            detail: "Create a line or load the starter examples to begin studying."
                            action: "Load examples"
                            onActivated: root.send("study_examples")
                        }
                    }
                }
            }
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: root.narrow ? 0 : 340; radius: 14; color: app.panel; border.color: app.line
                ColumnLayout { anchors.fill: parent; anchors.margins: 14; spacing: 10
                    Text { text: "Import and export"; color: app.fg; font { pixelSize: 16; weight: Font.DemiBold } }
                    Text { Layout.fillWidth: true; text: "Bring in a PGN or save one of your chapters for use elsewhere."; color: app.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
                    ThemedTextField { id: pgnPath; Layout.fillWidth: true; theme: app; placeholderText: "Path to a .pgn file" }
                    RowLayout { Layout.fillWidth: true; spacing: 8
                        ActionButton { Layout.fillWidth: true; theme: app; label: "Import PGN"; onClicked: { const book = root.library && root.library.books.length ? root.library.books[0].id : ""; if (book) root.send("study_import", {book: book, path: pgnPath.text}); } }
                        ActionButton { Layout.fillWidth: true; theme: app; label: "Export PGN"; onClicked: { const book = root.library && root.library.books.length ? root.library.books[0].id : ""; if (book) root.send("study_export", {book: book}); } }
                    }
                    TextArea { visible: !!root.exportText; Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 90; readOnly: true; text: root.exportText; wrapMode: TextArea.Wrap; color: app.fg; placeholderText: "Exported PGN"; placeholderTextColor: app.muted; background: Rectangle { radius: 8; color: app.bg; border.width: 1; border.color: parent.activeFocus ? app.accent : app.line } }
                    Item { visible: !root.exportText; Layout.fillHeight: true }
                    Rectangle { visible: !root.narrow; Layout.fillWidth: true; height: 1; color: app.line }
                    Text { visible: !root.narrow; Layout.fillWidth: true; text: "Shortcuts"; color: app.muted; font.pixelSize: 11 }
                    Text { visible: !root.narrow; Layout.fillWidth: true; text: "Enter opens a chapter · s starts review · e loads examples · ⌫ returns"; color: app.muted; wrapMode: Text.Wrap; font.pixelSize: 11 }
                }
            }
        }
    }

    ColumnLayout {
        visible: mode === "chapter" || mode === "review"; Layout.fillWidth: true; Layout.fillHeight: true; spacing: 10
        RowLayout { Layout.fillWidth: true
            ColumnLayout { Layout.fillWidth: true; spacing: 2
                Text { text: mode === "review" ? "Recall this line" : "Explore the line"; color: app.fg; font { pixelSize: 18; weight: Font.DemiBold } }
                Text { text: chapter ? (chapter.nodes.length - 1) + " positions · j/k navigate" : ""; color: app.muted; font.pixelSize: 12 }
            }
            Text { text: chapter && nodeData() ? (node + 1) + " / " + chapter.nodes.length : ""; color: app.muted; font.family: app.mono; font.pixelSize: 12 }
        }
        GridLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; columns: root.narrow ? 1 : 2; columnSpacing: 12; rowSpacing: 12
            Rectangle { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: root.narrow ? 0 : 500; radius: 14; color: app.panel; border.color: app.line
                StudyBoard {
                    id: studyBoard
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 28, parent.height - 28); height: width
                    app: root.app; fen: root.nodeData() ? root.nodeData().fen : ""
                    flipped: chapter && chapter.side === "black"; selected: root.studyOrigin; targets: root.targetSquares()
                    onSquareClicked: square => { root.focusScope.forceActiveFocus(); root.selectStudySquare(square); }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: root.narrow ? 0 : 360; radius: 14; color: app.panel; border.color: app.line
                ColumnLayout { anchors.fill: parent; anchors.margins: 16; spacing: 10
                    Text { Layout.fillWidth: true; text: root.nodeData() ? (root.nodeData().san ? "After " + root.nodeData().san : "Starting position") : ""; color: app.fg; font.pixelSize: 16; font.weight: Font.DemiBold }
                    Text { Layout.fillWidth: true; text: root.nodeData() ? root.nodeData().comment || "No note yet." : ""; color: app.muted; wrapMode: Text.Wrap }
                    Rectangle { Layout.fillWidth: true; implicitHeight: insightColumn.implicitHeight + 20; radius: 10; color: app.mix(app.panel, app.accent, 0.08); border.color: app.mix(app.line, app.accent, 0.35)
                        ColumnLayout { id: insightColumn; anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 } spacing: 4
                            Text { text: "Why this position?"; color: app.accent; font.pixelSize: 11; font.weight: Font.DemiBold }
                            Text { Layout.fillWidth: true; text: root.insightTitle(); color: app.fg; font.pixelSize: 13; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                            Text { Layout.fillWidth: true; text: root.insightText(); color: app.muted; font.pixelSize: 11; wrapMode: Text.Wrap }
                            Text { visible: !!root.engineData; Layout.fillWidth: true; text: root.engineInsight(); color: app.fg; font.pixelSize: 11; wrapMode: Text.Wrap }
                            RowLayout { Layout.fillWidth: true; spacing: 8
                                ActionButton { compact: true; theme: app; label: root.engineData ? "Re-evaluate" : "Evaluate with engine"; hint: root.narrow ? "" : "e"; onClicked: root.evaluatePosition() }
                                Text { visible: !root.engineData; Layout.fillWidth: true; text: "Uses local Stockfish or cloud evaluation."; color: app.muted; font.pixelSize: 10; wrapMode: Text.Wrap }
                            }
                        }
                    }
                    Text { Layout.fillWidth: true; text: mode === "review" ? "Play the stored answer, then grade your recall." : "Play the next move or add an alternative to this line."; color: app.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
                    Item { Layout.fillHeight: true }
                    ThemedTextField {
                        id: inputField
                        Layout.fillWidth: true; theme: app; focus: false
                        placeholderText: mode === "review" ? "Your move (SAN or UCI)" : "Move, e.g. Nf3"
                        text: root.input; onTextChanged: root.input = text
                        onAccepted: mode === "review" ? root.tryMove() : root.addMove()
                        Keys.onEscapePressed: { inputField.focus = false; root.focusScope.forceActiveFocus(); event.accepted = true; }
                    }
                    RowLayout { Layout.fillWidth: true; spacing: 7
                        ActionButton { Layout.fillWidth: true; theme: app; label: mode === "review" ? "Try" : "Add move"; hint: "↵"; onClicked: mode === "review" ? root.tryMove() : root.addMove() }
                        ActionButton { visible: mode === "chapter" && !!root.nodeData() && !root.nodeData().card; theme: app; label: "Make card"; hint: "r"; onClicked: root.send("study_card", {chapter: root.chapter.id, node: root.node, enabled: true, revision: root.chapter.revision}) }
                        ActionButton { visible: mode === "review" && !!root.nodeData().card; theme: app; label: "Again"; hint: "1"; onClicked: root.review("again") }
                        ActionButton { visible: mode === "review" && !!root.nodeData().card; theme: app; label: "Good"; hint: "3"; onClicked: root.review("good") }
                    }
                    ActionButton { visible: mode === "chapter"; Layout.fillWidth: true; theme: app; label: "Analyse this position"; hint: "a"; onClicked: root.send("study_analyse", {chapter: root.chapter.id, node: root.node}) }
                }
            }
        }
    }

    Rectangle { visible: mode === "session"; Layout.fillWidth: true; Layout.preferredHeight: 300; Layout.minimumHeight: 260; radius: 14; color: app.panel; border.color: app.line
        ColumnLayout { anchors.centerIn: parent; width: Math.min(parent.width - 36, 460); spacing: 12
            Text { Layout.fillWidth: true; text: "Review session"; color: app.fg; font { pixelSize: 22; weight: Font.DemiBold } horizontalAlignment: Text.AlignHCenter }
            Text { Layout.fillWidth: true; text: session ? "Position " + Math.min(sessionIndex + 1, session.items.length) + " / " + session.items.length : "Preparing your queue…"; color: app.muted; horizontalAlignment: Text.AlignHCenter }
            Text { Layout.fillWidth: true; text: session && session.items[sessionIndex] ? session.items[sessionIndex].title : ""; color: app.fg; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
            RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 8
                ActionButton { visible: !!session; theme: app; label: "Open position"; hint: "↵"; onClicked: session && root.openChapter(session.items[sessionIndex].chapter) }
                ActionButton { visible: !!session; theme: app; label: "Finish session"; hint: "⌫"; onClicked: root.send("study_session_end") }
            }
        }
    }

    Item { Layout.fillHeight: true; implicitHeight: 1 }
    }
}
