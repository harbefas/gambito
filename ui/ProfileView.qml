import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

// Profile: ratings with history chart, per-speed stats, game history, boards and activity.
// Loaded only while shown; everything it fetches is freed when it unloads.
Flickable {
    id: profile
    objectName: "profileView"
    required property var app
    required property Item focusScope
    // Tiling panes can be short or narrow: the page scrolls, and its rows stack when there's no width.
    clip: true; contentWidth: width; contentHeight: page.height
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { }
    readonly property bool narrow: width < 820
    anchors.fill: parent

    readonly property var speeds: [["bullet", "Bullet"], ["blitz", "Blitz"], ["rapid", "Rapid"], ["classical", "Classical"], ["correspondence", "Correspondence"], ["ultraBullet", "UltraBullet"], ["puzzle", "Puzzles"]]
    // Lichess `profile` reply: account, rating history, activity. (`data` is taken by Item.)
    property var info: null
    property string perfKey: ""
    property var perfStats: null
    property string tab: app.account ? "games" : "boards"
    // Games tab: loaded pages, cursor for the next page, filters.
    property var rows: []
    property var nextUntil: null
    property bool loading: false
    property string speedFilter: ""
    property string ratedFilter: ""     // "" | "rated" | "casual"
    property string resultFilter: ""    // "" | "win" | "loss" | "draw"
    property int index: 0

    function label(key) { const s = speeds.find(x => x[0] === key); return s ? s[1] : key; }
    function outcome(g) { return !g.winner ? "draw" : g.winner === g.color ? "win" : "loss"; }
    readonly property var visibleRows: resultFilter ? rows.filter(g => outcome(g) === resultFilter) : rows
    // Puzzles tab: /api/puzzle/dashboard/30 and recent puzzle activity (needs the puzzle:read scope).
    property var puzzleStats: null
    property string puzzleError: ""
    // Weakest themes first, like Lichess's "areas to improve".
    readonly property var puzzleThemes: {
        const themes = puzzleStats && puzzleStats.dashboard && puzzleStats.dashboard.themes ? puzzleStats.dashboard.themes : {};
        return Object.keys(themes).map(key => Object.assign({key: key, name: themes[key].theme}, themes[key].results)).sort((a, b) => a.performance - b.performance);
    }
    readonly property var currentList: tab === "games" ? visibleRows : tab === "boards" ? app.boardGames : tab === "puzzles" ? puzzleThemes : activity
    readonly property var activity: info && info.activity ? info.activity : []
    readonly property var perfs: {
        const p = info && info.account && info.account.perfs ? info.account.perfs : {};
        return speeds.filter(s => p[s[0]] && (p[s[0]].games || p[s[0]].runs)).map(s => Object.assign({key: s[0], name: s[1]}, p[s[0]]));
    }
    readonly property var points: {
        if (!info || !info.ratings || !perfKey) return [];
        const series = info.ratings.find(r => r.name === label(perfKey));
        return series ? series.points.map(p => ({t: new Date(p[0], p[1], p[2]).getTime(), r: p[3]})) : [];
    }

    function loadHistory(reset) {
        if (!app.account || loading || (!reset && nextUntil === null)) return;
        if (reset) { rows = []; nextUntil = null; index = 0; }
        const request = {max: 30};
        if (!reset) request.until = nextUntil;
        if (speedFilter) request.perf = speedFilter;
        if (ratedFilter) request.rated = ratedFilter === "rated";
        loading = true;
        app.send("history", request);
    }
    function selectPerf(key) { perfKey = key; perfStats = null; app.send("perf", {perf: key}); }
    function setTab(name) {
        if (name !== "boards" && !app.account) return;
        tab = name; index = 0;
        if (name === "puzzles" && !puzzleStats) { puzzleError = ""; app.send("puzzle_dashboard"); }
    }
    function activate(i) {
        const item = currentList[i];
        if (!item) return;
        if (tab === "games") app.send("open", {game: item.id});
        else if (tab === "puzzles") app.send("puzzle_next", {angle: item.key, difficulty: app.puzzleDifficulty});
        else if (tab === "boards") app.choose(item.id);
    }
    // Cycles a history filter; speed and rated refetch, result filters loaded rows.
    function cycleFilter(kind) {
        const options = kind === "speed" ? [""].concat(speeds.filter(s => s[0] !== "puzzle").map(s => s[0])) : kind === "rated" ? ["", "rated", "casual"] : ["", "win", "loss", "draw"];
        const value = kind === "speed" ? speedFilter : kind === "rated" ? ratedFilter : resultFilter;
        const next = options[(Math.max(0, options.indexOf(value)) + 1) % options.length];
        if (kind === "result") resultFilter = next;
        else { if (kind === "speed") speedFilter = next; else ratedFilter = next; loadHistory(true); }
    }
    // Keyboard selection scrolls the page, not just the list.
    function revealCursor() {
        const item = list.currentItem;
        if (!item) return;
        const y = item.mapToItem(page, 0, 0).y;
        if (y < contentY) contentY = y;
        else if (y + item.height > contentY + height) contentY = Math.min(contentHeight - height, y + item.height - height);
    }
    onIndexChanged: Qt.callLater(revealCursor)
    function date(ms) { return new Date(ms).toLocaleDateString(Qt.locale(), "d MMM yyyy"); }
    function duration(seconds) { const h = Math.floor(seconds / 3600); return h >= 1 ? h + " h" : Math.round(seconds / 60) + " min"; }

    Connections {
        target: profile.app
        function onReplied(cmd, data, error) {
            if (cmd === "profile" && data) {
                profile.info = data.profile;
                if (!profile.perfKey && profile.perfs.length) {
                    const main = profile.perfs.filter(p => p.key !== "puzzle").sort((a, b) => b.games - a.games)[0] || profile.perfs[0];
                    profile.selectPerf(main.key);
                }
            } else if (cmd === "perf" && data) profile.perfStats = data.perf;
            else if (cmd === "puzzle_dashboard") { profile.puzzleStats = data ? data.puzzle_dashboard : null; profile.puzzleError = data ? "" : error; }
            else if (cmd === "history") {
                profile.loading = false;
                if (data) { profile.rows = profile.rows.concat(data.history.games); profile.nextUntil = data.history.next_until; }
            }
        }
    }
    Component.onCompleted: {
        app.viewKeys = (key, event) => {
            if (key === "1") profile.setTab("games");
            else if (key === "2") profile.setTab("boards");
            else if (key === "3") profile.setTab("activity");
            else if (key === "4") profile.setTab("puzzles");
            else if (key === "l" && app.account) app.runCommand(":logout");
            else if (profile.tab === "games" && ["s", "r", "o"].includes(key)) profile.cycleFilter({"s": "speed", "r": "rated", "o": "result"}[key]);
            else if (key === "j" || event.key === Qt.Key_Down) profile.index = Math.min(profile.currentList.length - 1, profile.index + 1);
            else if (key === "k" || event.key === Qt.Key_Up) profile.index = Math.max(0, profile.index - 1);
            else if (event.key === Qt.Key_Return) profile.activate(profile.index);
            else if (key === "x" && profile.tab === "boards" && profile.currentList[profile.index]) profile.app.confirmDelete(profile.currentList[profile.index].id);
            else return false;
            return true;
        };
        if (app.account) { app.send("profile"); loadHistory(true); }
    }
    Component.onDestruction: if (app.viewKeys) app.viewKeys = null

    ColumnLayout {
        id: page
        width: profile.width
        // Fills the pane when the content fits, so the list takes the rest.
        height: Math.max(profile.height, implicitHeight)
        spacing: profile.width < 560 ? 10 : 14

        // Header: identity and lifetime totals.
        RowLayout {
            Layout.fillWidth: true; spacing: 14
            ActionButton { objectName: "profileBack"; theme: app; compact: true; icon: "←"; label: "Lobby"; hint: "g"; onClicked: app.view = "" }
            Column {
                // Elides instead of pushing the buttons and totals out of the window.
                Layout.fillWidth: true; Layout.minimumWidth: 80; Layout.preferredWidth: 0; spacing: 2
                Text { width: parent.width; elide: Text.ElideRight; text: app.account ? app.account.username : "Local profile"; color: app.fg; font { pixelSize: 20; weight: Font.DemiBold } }
                Text {
                    width: parent.width; elide: Text.ElideRight
                    text: !app.account ? "Connect Lichess for ratings, history and activity." : !profile.info ? "Loading…"
                        : "Member since " + profile.date(profile.info.account.createdAt) + " · " + profile.duration(profile.info.account.playTime.total) + " played"
                    color: app.muted; font.pixelSize: 12
                }
            }
            ActionButton { objectName: "challengesButton"; theme: app; label: "Challenges" + (app.challenges.length ? " (" + app.challenges.length + ")" : ""); hint: "C"; onClicked: app.runCommand(":challenges") }
            ActionButton { objectName: "profileSignOut"; visible: !!app.account; theme: app; compact: true; label: "Sign out"; hint: "l"; onClicked: app.runCommand(":logout") }
            Row {
                // Lifetime totals are extra: narrow panes keep the header to identity and actions.
                visible: !!profile.info && profile.width >= 900; spacing: 18
                Repeater {
                    model: profile.info ? [["Games", profile.info.account.count.all], ["Wins", profile.info.account.count.win], ["Draws", profile.info.account.count.draw], ["Losses", profile.info.account.count.loss]] : []
                    Column {
                        required property var modelData
                        Text { text: modelData[1]; color: app.fg; font { family: app.mono; pixelSize: 16; weight: Font.DemiBold } }
                        Text { text: modelData[0]; color: app.muted; font.pixelSize: 11 }
                    }
                }
            }
        }

        // Ratings per speed; selecting one drives the chart and the stats card.
        Flow {
            Layout.fillWidth: true; spacing: 8; visible: profile.perfs.length > 0
            Repeater {
                model: profile.perfs
                Rectangle {
                    required property var modelData
                    readonly property bool active: modelData.key === profile.perfKey
                    objectName: "perf_" + modelData.key
                    width: chip.implicitWidth + 24; height: 44; radius: 9
                    color: active ? app.raised : chipMouse.containsMouse ? app.panel : "transparent"
                    border.width: 1; border.color: active ? app.mix(app.line, app.fg, 0.35) : app.line
                    Column {
                        id: chip
                        anchors.centerIn: parent; spacing: 1
                        Row {
                            spacing: 6
                            Text { text: modelData.name; color: app.muted; font.pixelSize: 11 }
                            Text { visible: !!modelData.prog; text: (modelData.prog > 0 ? "+" : "") + modelData.prog; color: app.muted; font { family: app.mono; pixelSize: 11 } }
                        }
                        Text { text: modelData.rating + (modelData.prov ? "?" : ""); color: app.fg; font { family: app.mono; pixelSize: 15; weight: Font.DemiBold } }
                    }
                    MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: profile.selectPerf(modelData.key) }
                }
            }
        }

        GridLayout {
            // Fixed height: children fill it, and a filling child would otherwise make this row fill the page.
            Layout.fillWidth: true; Layout.fillHeight: false; Layout.preferredHeight: profile.narrow ? 400 : 210; Layout.maximumHeight: profile.narrow ? 400 : 210
            columns: profile.narrow ? 1 : 2; columnSpacing: 12; rowSpacing: 12
        // A short pane is better spent on the list than on the chart.
        visible: !!profile.perfKey && profile.height >= 420

            // Rating history: one series, so the title names it and no legend is needed.
            Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true; radius: 10
                color: app.panel; border.width: 1; border.color: app.line
                Text { id: chartTitle; anchors { left: parent.left; top: parent.top; margins: 12 } text: profile.label(profile.perfKey) + " rating"; color: app.fg; font { pixelSize: 13; weight: Font.DemiBold } }
                Item {
                    id: chart
                    objectName: "ratingChart"
                    anchors { left: parent.left; right: parent.right; top: chartTitle.bottom; bottom: parent.bottom; leftMargin: 44; rightMargin: 14; topMargin: 10; bottomMargin: 24 }
                    readonly property var pts: profile.points
                    readonly property real t0: pts.length ? pts[0].t : 0
                    readonly property real t1: pts.length > 1 ? pts[pts.length - 1].t : t0 + 1
                    readonly property real lo: pts.length ? Math.floor((Math.min(...pts.map(p => p.r)) - 20) / 50) * 50 : 0
                    readonly property real hi: pts.length ? Math.ceil((Math.max(...pts.map(p => p.r)) + 20) / 50) * 50 : 1
                    function px(t) { return (t - t0) / Math.max(1, t1 - t0) * width; }
                    function py(r) { return height - (r - lo) / Math.max(1, hi - lo) * height; }
                    property int hover: -1

                    // Recessive axis: min/max gridlines and labels only.
                    Repeater {
                        model: chart.pts.length ? [chart.lo, chart.hi] : []
                        Item {
                            required property real modelData
                            y: chart.py(modelData); width: chart.width
                            Rectangle { width: parent.width; height: 1; color: app.line }
                            Text { anchors { right: parent.left; rightMargin: 8; verticalCenter: parent.verticalCenter } text: modelData; color: app.muted; font { family: app.mono; pixelSize: 10 } }
                        }
                    }
                    Text { visible: chart.pts.length > 0; anchors { left: parent.left; top: parent.bottom; topMargin: 6 } text: chart.pts.length ? profile.date(chart.t0) : ""; color: app.muted; font.pixelSize: 10 }
                    Text { visible: chart.pts.length > 1; anchors { right: parent.right; top: parent.bottom; topMargin: 6 } text: chart.pts.length ? profile.date(chart.t1) : ""; color: app.muted; font.pixelSize: 10 }
                    Shape {
                        anchors.fill: parent; visible: chart.pts.length > 1
                        ShapePath {
                            strokeColor: app.accent; strokeWidth: 2; fillColor: "transparent"; joinStyle: ShapePath.RoundJoin
                            PathPolyline { path: chart.pts.map(p => Qt.point(chart.px(p.t), chart.py(p.r))) }
                        }
                    }
                    Text { anchors.centerIn: parent; visible: chart.pts.length === 0; text: profile.info ? "No rated games at this speed yet" : "Loading…"; color: app.muted; font.pixelSize: 12 }

                    // Hover: crosshair, marker and tooltip on the nearest point.
                    Rectangle { visible: chart.hover >= 0; x: chart.hover >= 0 ? chart.px(chart.pts[chart.hover].t) : 0; width: 1; height: chart.height; color: app.mix(app.line, app.fg, 0.3) }
                    Rectangle {
                        visible: chart.hover >= 0; width: 9; height: 9; radius: 4.5; color: app.accent; border.width: 2; border.color: app.panel
                        x: chart.hover >= 0 ? chart.px(chart.pts[chart.hover].t) - 4.5 : 0; y: chart.hover >= 0 ? chart.py(chart.pts[chart.hover].r) - 4.5 : 0
                    }
                    Rectangle {
                        visible: chart.hover >= 0; z: 2
                        width: tip.implicitWidth + 16; height: tip.implicitHeight + 10; radius: 6; color: app.raised; border.width: 1; border.color: app.line
                        x: chart.hover >= 0 ? Math.min(chart.width - width, Math.max(0, chart.px(chart.pts[chart.hover].t) - width / 2)) : 0; y: -height - 4
                        Text { id: tip; anchors.centerIn: parent; text: chart.hover >= 0 ? chart.pts[chart.hover].r + " · " + profile.date(chart.pts[chart.hover].t) : ""; color: app.fg; font { family: app.mono; pixelSize: 11 } }
                    }
                    MouseArea {
                        anchors { fill: parent; margins: -8 } hoverEnabled: true; enabled: chart.pts.length > 0
                        onExited: chart.hover = -1
                        onPositionChanged: mouse => {
                            let best = 0;
                            for (let i = 1; i < chart.pts.length; i++)
                                if (Math.abs(chart.px(chart.pts[i].t) - mouse.x + 8) < Math.abs(chart.px(chart.pts[best].t) - mouse.x + 8)) best = i;
                            chart.hover = best;
                        }
                    }
                }
            }

            // Per-speed statistics from /api/user/{name}/perf/{speed}.
            Rectangle {
                id: statsCard
                objectName: "perfStats"
                Layout.preferredWidth: profile.narrow ? -1 : 300; Layout.fillWidth: profile.narrow; Layout.fillHeight: true; radius: 10
                color: app.panel; border.width: 1; border.color: app.line
                readonly property var st: profile.perfStats ? profile.perfStats.stat : null
                GridLayout {
                    anchors { fill: parent; margins: 12 } columns: 2; rowSpacing: 6; columnSpacing: 10
                    visible: !!statsCard.st
                    Repeater {
                        model: {
                            const st = statsCard.st;
                            if (!st) return [];
                            const c = st.count;
                            const best = st.bestWins && st.bestWins.results[0];
                            const worst = st.worstLosses && st.worstLosses.results[0];
                            return [
                                ["Games", c.all + " · " + c.win + "W " + c.draw + "D " + c.loss + "L"],
                                ["Peak", st.highest ? st.highest.int + " · " + profile.date(Date.parse(st.highest.at)) : "–"],
                                ["Lowest", st.lowest ? st.lowest.int : "–"],
                                ["Best win", best ? best.opId.name + " (" + best.opRating + ")" : "–"],
                                ["Worst loss", worst ? worst.opId.name + " (" + worst.opRating + ")" : "–"],
                                ["Win streak", st.resultStreak ? "best " + st.resultStreak.win.max.v + " · now " + st.resultStreak.win.cur.v : "–"],
                                ["Time played", profile.duration(c.seconds)]
                            ];
                        }
                        Item {
                            required property var modelData
                            required property int index
                            Layout.columnSpan: 2; Layout.fillWidth: true; implicitHeight: 16
                            Text { text: modelData[0]; color: app.muted; font.pixelSize: 11 }
                            Text { anchors.right: parent.right; width: parent.width - 80; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight; text: modelData[1]; color: app.fg; font { family: app.mono; pixelSize: 11 } }
                        }
                    }
                }
                Text { anchors.centerIn: parent; visible: !statsCard.st; text: "Loading…"; color: app.muted; font.pixelSize: 12 }
            }
        }

        // Tabs, plus filters for the history; they wrap onto a second row in narrow panes.
        Flow {
            Layout.fillWidth: true; spacing: 6
            Repeater {
                model: [["games", "Games", "1"], ["boards", "Boards · " + app.boardGames.length, "2"], ["activity", "Activity", "3"], ["puzzles", "Puzzles", "4"]]
                ActionButton {
                    required property var modelData
                    objectName: "tab_" + modelData[0]
                    visible: modelData[0] === "boards" || !!app.account
                    theme: app; compact: true; label: modelData[1]; hint: modelData[2]
                    kind: profile.tab === modelData[0] ? "primary" : "normal"
                    onClicked: profile.setTab(modelData[0])
                }
            }
            Item { width: profile.narrow ? 0 : Math.max(0, profile.width - 780); height: 1 }
            Repeater {
                model: profile.tab !== "games" ? [] : [
                    ["speed", [["", "All speeds"]].concat(profile.speeds.filter(s => s[0] !== "puzzle"))],
                    ["rated", [["", "Rated & casual"], ["rated", "Rated"], ["casual", "Casual"]]],
                    ["result", [["", "All results"], ["win", "Wins"], ["loss", "Losses"], ["draw", "Draws"]]]
                ]
                ActionButton {
                    required property var modelData
                    readonly property var options: modelData[1]
                    readonly property string value: modelData[0] === "speed" ? profile.speedFilter : modelData[0] === "rated" ? profile.ratedFilter : profile.resultFilter
                    readonly property int at: Math.max(0, options.findIndex(o => o[0] === value))
                    objectName: "filter_" + modelData[0]
                    theme: app; compact: true; label: options[at][1] + " ▾"; hint: ({"speed": "s", "rated": "r", "result": "o"})[modelData[0]]
                    onClicked: profile.cycleFilter(modelData[0])
                }
            }
        }

        ListView {
            id: list
            objectName: "profileList"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 220; clip: true; spacing: 4
            model: profile.currentList
            currentIndex: profile.index
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            onAtYEndChanged: if (atYEnd && profile.tab === "games" && count > 0) profile.loadHistory(false)
            ScrollBar.vertical: ScrollBar { }
            delegate: Loader {
                required property var modelData
                required property int index
                width: list.width
                sourceComponent: profile.tab === "games" ? historyRow : profile.tab === "boards" ? boardRow : profile.tab === "puzzles" ? puzzleThemeRow : activityRow
            }
            // Puzzle summary above the theme list: rating, last 30 days, recent results.
            header: Loader {
                width: list.width
                active: profile.tab === "puzzles"
                height: active && item ? item.implicitHeight + 8 : 0
                sourceComponent: puzzleSummary
            }
            footer: Item {
                width: list.width; height: profile.loading ? 36 : 0
                Text { anchors.centerIn: parent; visible: profile.loading; text: "Loading…"; color: app.muted; font.pixelSize: 12 }
            }
            Text {
                anchors.centerIn: parent; visible: list.count === 0 && !profile.loading && profile.tab !== "puzzles"
                text: profile.tab === "games" ? (profile.resultFilter && profile.rows.length ? "No matching games loaded" : "No games") : profile.tab === "boards" ? "No analysis boards or finished local games" : "No recent activity"
                color: app.muted; font.pixelSize: 13
            }
        }

        Component {
            id: historyRow
            Rectangle {
                id: hrow
                readonly property var g: parent.modelData
                readonly property int i: parent.index
                readonly property string result: profile.outcome(g)
                readonly property var opponentRating: g.color === "black" ? g.white_rating : g.black_rating
                readonly property var myAccuracy: g.color && g.accuracy ? g.accuracy[g.color] : null
                readonly property bool hasAccuracy: myAccuracy !== null && myAccuracy !== undefined
                objectName: "historyRow" + i
                height: 50; radius: 9
                color: i === profile.index ? app.raised : "transparent"; border.width: i === profile.index ? 1 : 0; border.color: app.line
                MouseArea { id: historyMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(historyMouse, mouse)) profile.index = hrow.i; } onClicked: profile.activate(hrow.i) }
                RowLayout {
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 } spacing: 12
                    Rectangle {
                        implicitWidth: 26; implicitHeight: 26; radius: 6; color: "transparent"; border.width: 1; border.color: app.line
                        // Result letter in text ink; losses also get the danger tint, never color alone.
                        Text { anchors.centerIn: parent; text: ({win: "W", loss: "L", draw: "½"})[hrow.result]; color: hrow.result === "loss" ? app.danger : app.fg; font { family: app.mono; pixelSize: 12; weight: Font.DemiBold } }
                    }
                    Column {
                        Layout.fillWidth: true; spacing: 2
                        Text { width: parent.width; elide: Text.ElideRight; text: "vs " + (hrow.g.color === "black" ? hrow.g.white : hrow.g.black) + (hrow.opponentRating ? " (" + hrow.opponentRating + ")" : ""); color: app.fg; font { pixelSize: 13; weight: Font.Medium } }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: [hrow.g.speed ? profile.label(hrow.g.speed) : "", hrow.g.time_control, hrow.g.rated ? "rated" : "casual", Math.ceil(hrow.g.plies / 2) + " moves", profile.date(hrow.g.updated_ms)].filter(x => x).join(" · ")
                            color: app.muted; font.pixelSize: 11
                        }
                    }
                    Column {
                        visible: hrow.hasAccuracy
                        Text { text: hrow.hasAccuracy ? hrow.myAccuracy + "%" : ""; color: app.fg; font { family: app.mono; pixelSize: 13; weight: Font.DemiBold } }
                        Text { text: "accuracy"; color: app.muted; font.pixelSize: 10 }
                    }
                }
            }
        }
        Component {
            id: boardRow
            GameRow {
                app: profile.app; game: parent.modelData; index: parent.index
                selected: parent.index === profile.index
                onHovered: profile.index = parent.index
            }
        }
        Component {
            id: puzzleSummary
            ColumnLayout {
                id: summary
                spacing: 8
                readonly property var global: profile.puzzleStats && profile.puzzleStats.dashboard ? profile.puzzleStats.dashboard.global : null
                readonly property var rating: profile.info && profile.info.account.perfs.puzzle ? profile.info.account.perfs.puzzle : null
                Text {
                    visible: !summary.global; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13
                    text: profile.puzzleError || (profile.puzzleStats ? "No puzzles played in the last year." + (summary.rating ? " Puzzle rating " + summary.rating.rating + "." : "") : "Loading…"); color: profile.puzzleError ? app.danger : app.muted
                }
                Row {
                    visible: !!summary.global; spacing: 26
                    Repeater {
                        model: summary.global ? [
                            ["Puzzle rating", summary.rating ? summary.rating.rating + (summary.rating.prov ? "?" : "") : "–"],
                            ["Played (" + profile.puzzleStats.dashboard.days + " days)", summary.global.nb],
                            ["First try", Math.round(100 * summary.global.firstWins / Math.max(1, summary.global.nb)) + "%"],
                            ["Performance", summary.global.performance],
                            ["Avg puzzle", summary.global.puzzleRatingAvg]
                        ] : []
                        Column {
                            required property var modelData
                            Text { text: modelData[1]; color: app.fg; font { family: app.mono; pixelSize: 18; weight: Font.DemiBold } }
                            Text { text: modelData[0]; color: app.muted; font.pixelSize: 11 }
                        }
                    }
                }
                // Recent results, newest first: mark in text ink, misses also tinted.
                Flow {
                    Layout.fillWidth: true; spacing: 4; visible: !!profile.puzzleStats && profile.puzzleStats.activity.length > 0
                    Repeater {
                        model: profile.puzzleStats ? profile.puzzleStats.activity.slice(0, 40) : []
                        Rectangle {
                            required property var modelData
                            width: 22; height: 22; radius: 5; color: "transparent"; border.width: 1; border.color: app.line
                            Text { anchors.centerIn: parent; text: modelData.win ? "✓" : "✗"; color: modelData.win ? app.fg : app.danger; font.pixelSize: 11 }
                        }
                    }
                }
                Text { visible: profile.puzzleThemes.length > 0; text: "Themes, weakest first · Enter to practise"; color: app.muted; font.pixelSize: 11 }
            }
        }
        Component {
            id: puzzleThemeRow
            Rectangle {
                id: trow
                readonly property var t: parent.modelData
                readonly property int i: parent.index
                height: 44; radius: 9
                color: i === profile.index ? app.raised : "transparent"; border.width: i === profile.index ? 1 : 0; border.color: app.line
                MouseArea { id: themeMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onPositionChanged: mouse => { if (app.pointerMoved(themeMouse, mouse)) profile.index = trow.i; } onClicked: profile.activate(trow.i) }
                RowLayout {
                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 } spacing: 14
                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: trow.t.name; color: app.fg; font { pixelSize: 13; weight: Font.Medium } }
                    Text { text: trow.t.nb + " played"; color: app.muted; font.pixelSize: 11 }
                    Text { text: Math.round(100 * trow.t.firstWins / Math.max(1, trow.t.nb)) + "% first try"; color: app.muted; font.pixelSize: 11 }
                    Text { Layout.preferredWidth: 70; horizontalAlignment: Text.AlignRight; text: trow.t.performance; color: app.fg; font { family: app.mono; pixelSize: 13; weight: Font.DemiBold } }
                }
            }
        }
        Component {
            id: activityRow
            Rectangle {
                id: arow
                readonly property var entry: parent.modelData
                height: activityText.implicitHeight + 16; radius: 9; color: "transparent"; border.width: 1; border.color: app.line
                Text {
                    id: activityText
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 12 }
                    wrapMode: Text.WordWrap; color: app.fg; font.pixelSize: 12
                    text: {
                        const e = arow.entry; const parts = [];
                        for (const key in (e.games || {})) {
                            const s = e.games[key];
                            parts.push(profile.label(key) + ": " + s.win + "W " + s.draw + "D " + s.loss + "L" + (s.rp ? " · " + s.rp.before + " → " + s.rp.after : ""));
                        }
                        if (e.puzzles && e.puzzles.score) parts.push("Puzzles: " + e.puzzles.score.win + " solved, " + e.puzzles.score.loss + " failed");
                        if (e.correspondenceMoves) parts.push(e.correspondenceMoves.nb + " correspondence moves");
                        if (e.follows && e.follows.in) parts.push(e.follows.in.ids.length + " new followers");
                        for (const key of ["tournaments", "studies", "teams", "posts", "practice", "simuls"])
                            if (e[key]) parts.push(key[0].toUpperCase() + key.slice(1) + ": " + (e[key].nb !== undefined ? e[key].nb : (e[key].length || "yes")));
                        return profile.date(e.interval.start) + "   " + (parts.join(" · ") || "Active");
                    }
                }
            }
        }
    }
}
