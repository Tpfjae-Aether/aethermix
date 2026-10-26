// lang: QML, file: BrowseRoom.qml
// The browse room: one window onto the web's music.
//
// This is not a general HTML engine - it doesn't pretend to be. It reads the
// pages this player can actually use (youtube videos, soundcloud tracks, sets,
// playlists, spotify links), draws them as pages with a sleeve and a real
// action row, and keeps a history and a shelf of marks the way a browser does.
// Every action lands in the same library as the rest of the app: PLAY streams
// the page, STREAM keeps it as a web row, SAVE downloads it once.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

Item {
    id: room
    anchors.fill: parent
    z: 96
    visible: slide > 0.002
    opacity: slide

    property real slide: 0
    property bool closing: false
    property bool opened: false

    // palette + typography, handed in by the shell so the room always wears
    // the world the listener is standing in
    property color ink: "#ffffff"
    property color dim: "#9fb3c8"
    property color accent: "#00ffa3"
    property color bar: "#0fd3c4"
    property color panel: "#0a1220"
    property bool light: false
    property string fontFamily: "Segoe UI"
    property real typeScale: 1.0
    property var typeFn: null

    signal closed()
    signal watchVideo(string url, string title)
    signal libraryChanged()

    // ------------------------------------------------------------------ state
    property var tabs: [ newTab() ]
    property int tab: 0
    property string addr: ""
    property var rows: []
    property var page: null
    property bool busy: false
    property string error: ""
    property var back: []
    property var fwd: []
    property var marks: []
    property var hist: []
    property var source: "all"
    property bool dictating: false

    function a(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
    function newTab() {
        return { url: "", title: "new page", view: "start", rows: [], page: null, busy: false, error: "" }
    }
    function cur() { return room.tabs[room.tab] || room.newTab() }
    function patchTab(fields) {
        var next = room.tabs.slice();
        var t = next[room.tab] || room.newTab();
        for (var k in fields) t[k] = fields[k];
        next[room.tab] = t;
        room.tabs = next;
        room.pull();
    }
    // the room keeps one copy of the active tab's fields for the view to bind
    // to; writing them back through patchTab is the only way they change
    function pull() {
        var t = room.cur();
        room.addr = t.url;
        room.rows = t.rows;
        room.page = t.page;
        room.busy = t.busy;
        room.error = t.error;
    }
    function push(fields) { room.patchTab(fields); }

    function api(path, cb) {
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== XMLHttpRequest.DONE) return;
            var d = {};
            try { d = JSON.parse(x.responseText); } catch (e) { d = { ok: false, error: "bad answer" } }
            cb(d);
        };
        x.open("GET", "http://127.0.0.1:3690" + path);
        x.send();
    }
    function loadStore() {
        api("/config?k=browse_hist", function(d) {
            try { room.hist = JSON.parse(d.value || "[]"); } catch (e) { room.hist = [] }
        });
        api("/config?k=browse_marks", function(d) {
            try { room.marks = JSON.parse(d.value || "[]"); } catch (e) { room.marks = [] }
        });
    }
    function saveStore() {
        api("/config?k=browse_hist&v=" + encodeURIComponent(JSON.stringify(room.hist.slice(0, 60))), function() {});
        api("/config?k=browse_marks&v=" + encodeURIComponent(JSON.stringify(room.marks)), function() {});
    }
    function remember(url, title) {
        if (!url) return;
        var h = room.hist.filter(function(r) { return r.url !== url });
        h.unshift({ url: url, title: title || url, at: Date.now() });
        room.hist = h.slice(0, 60);
        room.saveStore();
    }
    function marked() {
        for (var i = 0; i < room.marks.length; i++) if (room.marks[i].url === room.addr) return true;
        return false;
    }
    function toggleMark() {
        if (!room.addr) return;
        var m = room.marks.slice();
        var at = -1;
        for (var i = 0; i < m.length; i++) if (m[i].url === room.addr) at = i;
        if (at >= 0) m.splice(at, 1);
        else m.unshift({ url: room.addr, title: room.addrTitle() || room.addr });
        room.marks = m;
        room.saveStore();
        toast = at >= 0 ? "removed from marks" : "kept on the shelf";
        toastTimer.restart();
    }
    function addrTitle() { return room.page ? room.page.title : "" }

    // ------------------------------------------------------------------ doors
    function show() {
        opened = true;
        closing = false;
        room.loadStore();
        openAnim.to = 1;
        openAnim.restart();
        focusTimer.restart();
    }
    function hide() {
        closing = true;
        openAnim.to = 0;
        openAnim.restart();
    }
    function isLink(s) {
        var t = ("" + s).trim().toLowerCase();
        return t.indexOf("http://") === 0 || t.indexOf("https://") === 0
            || t.indexOf("youtu.be/") === 0 || t.indexOf("www.") === 0
            || (t.indexOf("youtube.com/") >= 0) || (t.indexOf("soundcloud.com/") >= 0)
            || (t.indexOf("spotify.com/") >= 0) || (t.indexOf("bandcamp.com/") >= 0);
    }
    function normalize(s) {
        var t = ("" + s).trim();
        if (t.indexOf("http") === 0) return t;
        return "https://" + t;
    }

    function go(text, keepHist) {
        var s = ("" + text).trim();
        if (s.length === 0) return;
        if (room.isLink(s)) room.resolve(room.normalize(s), keepHist);
        else room.search(s);
    }
    function resolve(url, keepHist) {
        room.push({ url: url, busy: true, error: "", view: "page", page: null, rows: [] });
        room.rows = [];
        room.api("/web/resolve?url=" + encodeURIComponent(url), function(d) {
            if (room.addr !== url) return;
            if (!d || !d.ok) {
                room.push({ busy: false, error: (d && d.error) ? d.error : "that page could not be read" });
                return;
            }
            room.push({ busy: false, page: d, title: d.title || url, error: "" });
            if (!keepHist) room.remember(url, d.title);
            room.pagePreview(d);
        });
    }
    // a playlist link also asks the importer what it would find
    function pagePreview(d) {
        if (!d || (d.kind !== "playlist")) return;
        if (("" + d.url).indexOf("spotify.com") >= 0) {
            room.api("/playlist/import/preview?url=" + encodeURIComponent(d.url), function(p) {
                if (room.addr !== d.url) return;
                var pg = room.page;
                if (!pg) return;
                var copy = {};
                for (var k in pg) copy[k] = pg[k];
                copy.preview = p;
                room.push({ page: copy });
            });
            return;
        }
        var copy = {}; for (var k in d) copy[k] = d[k];
        copy.preview = { total: d.count || 0, matched: d.count || 0, note: "" };
        room.push({ page: copy });
    }
    function search(q) {
        room.push({ url: q, busy: true, error: "", view: "results", rows: [], page: null, title: q });
        var srcs = room.source === "all" ? ["youtube", "soundcloud"] : [room.source];
        var pending = srcs.length;
        var got = [];
        for (var i = 0; i < srcs.length; i++) {
            (function(src) {
                room.api("/sources/search?src=" + src + "&q=" + encodeURIComponent(q), function(d) {
                    if (room.addr !== q) return;
                    var r = (d && d.results) ? d.results : [];
                    for (var j = 0; j < r.length; j++) if (!r[j].source) r[j].source = src;
                    got = got.concat(r);
                    pending--;
                    if (pending <= 0) {
                        room.push({ busy: false, rows: got, error: got.length ? "" : "nothing found - try another spelling" });
                        room.remember("search:" + q, "search: " + q);
                    }
                });
            })(srcs[i]);
        }
        if (srcs.length === 0) room.push({ busy: false });
    }
    function goBack() {
        if (room.back.length === 0) return;
        var prev = room.back[room.back.length - 1];
        var nb = room.back.slice(0, room.back.length - 1);
        var nf = room.fwd.slice();
        nf.unshift({ url: room.addr, title: room.addrTitle() });
        room.back = nb; room.fwd = nf;
        room.jump(prev);
    }
    function goFwd() {
        if (room.fwd.length === 0) return;
        var nxt = room.fwd[0];
        var nf = room.fwd.slice(1);
        var nb = room.back.slice();
        nb.push({ url: room.addr, title: room.addrTitle() });
        room.fwd = nf; room.back = nb;
        room.jump(nxt);
    }
    function jump(entry) {
        var u = entry.url || "";
        if (u.indexOf("search:") === 0) room.search(u.substring(7));
        else if (u.indexOf("http") === 0) { room.resolve(u, true); }
    }
    function revisit(row) {
        var u = row.url || "";
        if (u.indexOf("search:") === 0) room.search(u.substring(7));
        else if (u.indexOf("http") === 0) { room.resolve(u, true); }
        else room.go(u, true);
    }

    // ------------------------------------------------------------------ actions
    function playRow(r) {
        if (!r) return;
        if (r.source === "spotify") {
            room.api("/playlist/add_spotify?url=" + encodeURIComponent(r.uri || r.url), function(d) {
                if (d && d.ok) room.api("/play?id=" + d.id, function() {});
                else room.say((d && d.error) || "could not play that track");
            });
            return;
        }
        var u = r.url || r.web || "";
        if (u.length < 6) { room.say("that result has no playable link"); return; }
        room.say("tuning " + (r.title || "the page"));
        room.api("/youtube/add?url=" + encodeURIComponent(u) + "&mode=stream&play=1", function(d) {
            if (!d.ok) room.say(d.error || "could not start that stream");
            else { room.libraryChanged(); room.toastNow("streaming " + (r.title || "now")); }
        });
    }
    function addRow(r, mode) {
        var u = r.url || r.web || "";
        if (r.source === "spotify") { room.playRow(r); return; }
        if (u.length < 6) return;
        room.api("/youtube/add?url=" + encodeURIComponent(u) + "&mode=" + mode, function(d) {
            if (!d.ok) { room.say(d.error || "could not add that song"); return; }
            room.libraryChanged();
            room.toastNow(mode === "file" ? "saving for offline" : "kept as a stream");
        });
    }
    function importPage() {
        var p = room.page;
        if (!p) return;
        room.say("building the playlist - this can take a minute");
        room.api("/playlist/import/start?url=" + encodeURIComponent(p.url) + "&name=" + encodeURIComponent(p.title || ""), function(d) {
            if (!d || !d.ok) { room.say((d && d.error) || "the import did not start"); return; }
            room.toastNow("playlist import started");
            room.libraryChanged();
        });
    }
    function playMain() {
        var p = room.page;
        if (!p) return;
        if (p.kind === "playlist") { room.importPage(); return; }
        if (p.kind === "spotify") {
            room.api("/playlist/import/preview?url=" + encodeURIComponent(p.url), function(d) {
                if (d && d.ok) room.importPage();
                else room.say((d && d.error) || "that spotify link could not be read");
            });
            return;
        }
        room.playRow({ url: p.url, title: p.title, source: p.source });
    }
    function watchPage() {
        var p = room.page;
        if (!p) return;
        room.watchVideo(p.url, p.title);
    }
    function saveMain() {
        var p = room.page;
        if (!p) return;
        room.addRow({ url: p.url, title: p.title, source: p.source }, "file");
    }

    property string toast: ""
    Timer { id: toastTimer; interval: 2600; onTriggered: room.toast = "" }
    function toastNow(t) { room.toast = t || ""; toastTimer.restart(); }
    function say(t) { room.push({ error: t || "" }); room.toastNow(t); }

    // ------------------------------------------------------------------ motion
    NumberAnimation {
        id: openAnim
        target: room; property: "slide"
        duration: room.closing ? 220 : 420
        easing.type: room.closing ? Easing.InCubic : Easing.OutQuint
        onFinished: if (room.closing) { room.slide = 0; room.opened = false; room.closed(); }
    }
    Timer { id: focusTimer; interval: 120; onTriggered: addrField.forceActiveFocus() }

    // the world behind the pane: it does not go black, it goes quiet
    Rectangle {
        anchors.fill: parent
        color: room.light ? Qt.rgba(0.96, 0.97, 1, 0.42 * room.slide)
                          : Qt.rgba(0.01, 0.02, 0.04, 0.52 * room.slide)
        MouseArea { anchors.fill: parent; onClicked: {} }
    }

    Rectangle {
        id: shell
        anchors.fill: parent
        anchors.margins: Math.max(14, Math.min(30, room.width * 0.022))
        radius: 26
        color: room.light ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(0.04, 0.06, 0.10, 0.80)
        border.width: 0
        opacity: room.slide
        scale: 0.975 + 0.025 * room.slide
        transform: Translate { y: (1 - room.slide) * 26 }

        // the accent breathes in through the top of the pane instead of a rule
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0; color: room.a(room.accent, 0.10) }
                GradientStop { position: 0.42; color: room.a(room.accent, 0.0) }
                GradientStop { position: 1; color: room.a(room.bar, 0.05) }
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 18
            spacing: 10

            // ------------------------------------------------ title row
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: room.accent
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.35; duration: 1400; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1600; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    text: "BROWSE"
                    color: room.ink
                    font.family: room.fontFamily; font.pixelSize: (15) * room.typeScale
                    font.bold: true; font.letterSpacing: 3
                }
                Text {
                    text: "the web, without the noise"
                    color: room.a(room.dim, 0.65)
                    font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                    Layout.alignment: Qt.AlignVCenter
                }
                Item { Layout.fillWidth: true }

                Repeater {
                    model: [ { k: "all", l: "ALL" }, { k: "youtube", l: "YT" }, { k: "soundcloud", l: "SC" } ]
                    delegate: Rectangle {
                        width: lbl.width + 18; height: 22; radius: 11
                        color: room.source === modelData.k ? room.a(room.accent, 0.24)
                                                            : (srcMa.containsMouse ? room.a(room.ink, 0.10)
                                                                                   : room.a(room.ink, 0.05))
                        Behavior on color { ColorAnimation { duration: 140 } }
                        Text {
                            id: lbl
                            anchors.centerIn: parent
                            text: modelData.l
                            color: room.source === modelData.k ? room.accent : room.a(room.ink, 0.7)
                            font.family: room.fontFamily; font.pixelSize: (7) * room.typeScale
                            font.bold: true; font.letterSpacing: 1.2
                        }
                        MouseArea {
                            id: srcMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { room.source = modelData.k; if (room.addr) room.go(room.addr, true); }
                        }
                    }
                }

                Rectangle {
                    width: 30; height: 30; radius: 15
                    color: closeMa.containsMouse ? room.a(room.accent, 0.22) : room.a(room.ink, 0.06)
                    Behavior on color { ColorAnimation { duration: 140 } }
                    Text {
                        anchors.centerIn: parent; text: "\u00d7"
                        color: room.a(room.ink, 0.85); font.pixelSize: (17) * room.typeScale
                    }
                    MouseArea {
                        id: closeMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { room.hide() }
                    }
                }
            }

            // ------------------------------------------------ address row
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                component NavBtn : Rectangle {
                    id: nb
                    property string glyph: ""
                    property bool live: true
                    width: 30; height: 32; radius: 11
                    color: nb.live && nbMa.containsMouse ? room.a(room.accent, 0.18) : room.a(room.ink, 0.045)
                    opacity: nb.live ? 1 : 0.35
                    Behavior on color { ColorAnimation { duration: 130 } }
                    Text {
                        anchors.centerIn: parent; text: nb.glyph
                        color: room.a(room.ink, 0.78); font.pixelSize: (13) * room.typeScale
                    }
                    MouseArea {
                        id: nbMa
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: nb.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: nb.act()
                    }
                    property var act: function() {}
                }

                NavBtn { glyph: "\u2039"; live: room.back.length > 0; act: function() { room.goBack() } }
                NavBtn { glyph: "\u203a"; live: room.fwd.length > 0; act: function() { room.goFwd() } }

                Rectangle {
                    Layout.fillWidth: true
                    height: 32; radius: 16
                    color: room.light ? Qt.rgba(0, 0, 0, 0.06) : Qt.rgba(1, 1, 1, 0.07)
                    border.width: addrField.input.activeFocus ? 1 : 0
                    border.color: room.a(room.accent, 0.55)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12; anchors.rightMargin: 8
                        spacing: 6
                        Text {
                            text: "\u25cf"
                            color: room.addr ? room.a(room.accent, 0.8) : room.a(room.dim, 0.4)
                            font.pixelSize: (7) * room.typeScale
                        }
                        TextField {
                            id: addrField
                            Layout.fillWidth: true
                            placeholderText: "paste a link, or search every source"
                            text: room.addr
                            // typing must not be overwritten by the address
                            // binding: only a page change moves the caret
                            color: room.ink
                            placeholderTextColor: room.a(room.dim, 0.5)
                            font.family: room.fontFamily; font.pixelSize: (10) * room.typeScale
                            selectByMouse: true
                            background: Item { }
                            Keys.onPressed: function(ev) {
                                if (!ev.isAutoRepeat && room.typeFn
                                        && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                    room.typeFn();
                            }
                            onAccepted: { room.go(text); addrField.focus = false; }
                            Keys.onEscapePressed: room.hide()
                            Connections {
                                target: room
                                function onAddrChanged() {
                                    if (!addrField.activeFocus) addrField.text = room.addr;
                                }
                            }
                        }
                        Rectangle {
                            width: 50; height: 22; radius: 11
                            color: goMa.containsMouse ? room.a(room.accent, 0.34) : room.a(room.accent, 0.18)
                            Behavior on color { ColorAnimation { duration: 130 } }
                            Text {
                                anchors.centerIn: parent; text: "GO"
                                color: room.accent; font.family: room.fontFamily
                                font.pixelSize: (7) * room.typeScale; font.bold: true; font.letterSpacing: 1.4
                            }
                            MouseArea {
                                id: goMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { room.go(addrField.text); addrField.focus = false; }
                            }
                        }
                    }
                }

                Rectangle {
                    width: 32; height: 32; radius: 16
                    color: room.marked() ? room.a(room.accent, 0.85)
                                         : (markMa.containsMouse ? room.a(room.accent, 0.18) : room.a(room.ink, 0.045))
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text {
                        anchors.centerIn: parent
                        text: room.marked() ? "\u2605" : "\u2606"
                        color: room.marked() ? room.panel : room.a(room.ink, 0.8)
                        font.pixelSize: (13) * room.typeScale
                    }
                    MouseArea {
                        id: markMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: room.toggleMark()
                    }
                }
            }

            // ------------------------------------------------ tabs
            RowLayout {
                Layout.fillWidth: true
                spacing: 5

                Repeater {
                    model: room.tabs
                    delegate: Rectangle {
                        width: Math.min(190, Math.max(92, tabLbl.width + 40))
                        height: 25; radius: 12.5
                        color: room.tab === index ? room.a(room.accent, 0.14)
                                                  : (tabMa.containsMouse ? room.a(room.ink, 0.08) : room.a(room.ink, 0.035))
                        Behavior on color { ColorAnimation { duration: 140 } }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 6
                            spacing: 4
                            Text {
                                id: tabLbl
                                Layout.fillWidth: true
                                text: (modelData.title || "new page")
                                color: room.tab === index ? room.ink : room.a(room.dim, 0.8)
                                font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                elide: Text.ElideRight
                            }
                            Text {
                                visible: room.tabs.length > 1
                                text: "\u00d7"
                                color: room.a(room.dim, 0.7); font.pixelSize: (10) * room.typeScale
                                MouseArea {
                                    width: 14; height: 18
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var next = room.tabs.slice();
                                        next.splice(index, 1);
                                        room.tabs = next;
                                        if (room.tab >= next.length) room.tab = next.length - 1;
                                        room.pull();
                                    }
                                }
                            }
                        }
                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            z: -1
                            onClicked: { room.tab = index; room.pull(); }
                        }
                    }
                }

                Rectangle {
                    width: 25; height: 25; radius: 12.5
                    color: plusMa.containsMouse ? room.a(room.accent, 0.20) : room.a(room.ink, 0.04)
                    Text { anchors.centerIn: parent; text: "+"; color: room.a(room.ink, 0.7); font.pixelSize: (13) * room.typeScale }
                    MouseArea {
                        id: plusMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (room.tabs.length >= 6) { room.toastNow("six pages is the limit"); return; }
                            var next = room.tabs.slice();
                            next.push(room.newTab());
                            room.tabs = next;
                            room.tab = next.length - 1;
                            room.back = []; room.fwd = [];
                            room.pull();
                            focusTimer.restart();
                        }
                    }
                }

                Item { Layout.fillWidth: true }
                Text {
                    visible: room.busy
                    text: "READING..."
                    color: room.accent
                    font.family: room.fontFamily; font.pixelSize: (7) * room.typeScale
                    font.bold: true; font.letterSpacing: 1.6
                }
            }

            // ------------------------------------------------ body
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // ---------- start page
                Flickable {
                    id: startFlick
                    anchors.fill: parent
                    visible: room.cur().view === "start"
                    contentHeight: startCol.height + 18
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: startCol
                        width: parent.width
                        spacing: 14

                        Text {
                            text: "WHERE TO"
                            color: room.a(room.dim, 0.55)
                            font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                            font.bold: true; font.letterSpacing: 2
                            Layout.topMargin: 6
                        }

                        // a few doors that always work
                        Flow {
                            Layout.fillWidth: true
                            spacing: 7
                            Repeater {
                                model: [
                                    { l: "lofi radio", u: "lofi hip hop radio" },
                                    { l: "new releases", u: "new music this week" },
                                    { l: "jazz at night", u: "late night jazz" },
                                    { l: "soundcloud picks", u: "soundcloud trending" },
                                    { l: "live sessions", u: "live session" }
                                ]
                                delegate: Rectangle {
                                    width: doorLbl.width + 24; height: 28; radius: 14
                                    color: doorMa.containsMouse ? room.a(room.accent, 0.18) : room.a(room.ink, 0.045)
                                    Behavior on color { ColorAnimation { duration: 140 } }
                                    Text {
                                        id: doorLbl
                                        anchors.centerIn: parent
                                        text: modelData.l
                                        color: doorMa.containsMouse ? room.accent : room.a(room.ink, 0.8)
                                        font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                                    }
                                    MouseArea {
                                        id: doorMa
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: room.go(modelData.u)
                                    }
                                }
                            }
                        }

                        // ---------- marks
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "ON THE SHELF"
                                color: room.a(room.dim, 0.55)
                                font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                font.bold: true; font.letterSpacing: 2
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                visible: room.marks.length === 0
                                text: "the star in the address bar keeps a page here"
                                color: room.a(room.dim, 0.38)
                                font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Repeater {
                                model: room.marks
                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    height: 32; radius: 9
                                    color: markRow.containsMouse ? room.a(room.accent, 0.10) : "transparent"
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10; anchors.rightMargin: 10
                                        spacing: 8
                                        Text { text: "\u2605"; color: room.a(room.accent, 0.85); font.pixelSize: (9) * room.typeScale }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.title || modelData.url
                                            color: room.a(room.ink, 0.85)
                                            font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: modelData.url.replace(/^https?:\/\//, "").split("/")[0]
                                            color: room.a(room.dim, 0.5)
                                            font.family: room.fontFamily; font.pixelSize: (7.5) * room.typeScale
                                        }
                                    }
                                    MouseArea {
                                        id: markRow
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: room.revisit(modelData)
                                    }
                                }
                            }
                        }

                        // ---------- history
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "RECENT"
                                color: room.a(room.dim, 0.55)
                                font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                font.bold: true; font.letterSpacing: 2
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                visible: room.hist.length > 0
                                text: "clear"
                                color: clearMa.containsMouse ? room.accent : room.a(room.dim, 0.5)
                                font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                MouseArea {
                                    id: clearMa
                                    width: 40; height: 18; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { room.hist = []; room.saveStore(); }
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Repeater {
                                model: room.hist.slice(0, 10)
                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    height: 30; radius: 9
                                    color: histRow.containsMouse ? room.a(room.ink, 0.06) : "transparent"
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10; anchors.rightMargin: 10
                                        spacing: 8
                                        Text { text: "\u21ba"; color: room.a(room.dim, 0.55); font.pixelSize: (10) * room.typeScale }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.title || modelData.url
                                            color: room.a(room.ink, 0.78)
                                            font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                                            elide: Text.ElideRight
                                        }
                                    }
                                    MouseArea {
                                        id: histRow
                                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: room.revisit(modelData)
                                    }
                                }
                            }
                        }
                        Item { height: 10 }
                    }
                }

                // ---------- search results
                Flickable {
                    id: resFlick
                    anchors.fill: parent
                    visible: room.cur().view === "results"
                    contentHeight: resCol.height + 10
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: resCol
                        width: parent.width
                        spacing: 3

                        Text {
                            Layout.fillWidth: true
                            text: room.rows.length > 0
                                  ? (room.rows.length + " results for \"" + room.addr + "\"")
                                  : (room.busy ? "listening..." : (room.error || "nothing yet"))
                            color: room.busy ? room.accent : room.a(room.dim, 0.65)
                            font.family: room.fontFamily; font.pixelSize: (8.5) * room.typeScale
                            Layout.topMargin: 6
                            elide: Text.ElideRight
                        }

                        Repeater {
                            model: room.rows
                            delegate: Rectangle {
                                Layout.fillWidth: true
                                height: 56; radius: 12
                                color: rowMa.containsMouse ? room.a(room.accent, 0.08)
                                                           : (rowMa.pressed ? room.a(room.accent, 0.12) : "transparent")
                                Behavior on color { ColorAnimation { duration: 120 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 7; anchors.rightMargin: 7
                                    spacing: 10

                                    Rectangle {
                                        width: 42; height: 42; radius: 9
                                        color: room.a(room.accent, 0.12)
                                        clip: true
                                        Image {
                                            anchors.fill: parent
                                            source: modelData.thumb || ""
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            visible: status === Image.Ready
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            visible: rowImg.status !== Image.Ready
                                            text: ("" + (modelData.title || "?").charAt(0)).toUpperCase()
                                            color: room.a(room.accent, 0.7)
                                            font.pixelSize: (14) * room.typeScale; font.bold: true
                                        }
                                        Image { id: rowImg; source: modelData.thumb || ""; visible: false; asynchronous: true }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.title || ""
                                            color: room.ink
                                            font.family: room.fontFamily; font.pixelSize: (10.5) * room.typeScale
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: (modelData.artist || "") + (modelData.duration_ms > 0
                                                  ? ("  \u00b7  " + Math.floor(modelData.duration_ms / 60000) + ":"
                                                     + ("0" + Math.floor((modelData.duration_ms % 60000) / 1000)).slice(-2))
                                                  : "") + "  \u00b7  " + ("" + (modelData.source || "youtube")).toUpperCase()
                                            color: room.a(room.dim, 0.65)
                                            font.family: room.fontFamily; font.pixelSize: (8.5) * room.typeScale
                                            elide: Text.ElideRight
                                        }
                                    }

                                    RowLayout {
                                        spacing: 4
                                        component TinyBtn : Rectangle {
                                            id: tb
                                            property string label: ""
                                            property bool hot: false
                                            width: tbLbl.width + 16; height: 24; radius: 12
                                            color: tb.hot ? room.a(room.accent, 0.22)
                                                          : (tbMa.containsMouse ? room.a(room.ink, 0.12) : room.a(room.ink, 0.05))
                                            Behavior on color { ColorAnimation { duration: 120 } }
                                            Text {
                                                id: tbLbl
                                                anchors.centerIn: parent
                                                text: tb.label
                                                color: tb.hot ? room.accent : room.a(room.ink, 0.72)
                                                font.family: room.fontFamily
                                                font.pixelSize: (7) * room.typeScale
                                                font.bold: true; font.letterSpacing: 1
                                            }
                                            MouseArea {
                                                id: tbMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: tb.clicked()
                                            }
                                            signal clicked()
                                        }
                                        TinyBtn { label: "PLAY"; hot: true; onClicked: room.playRow(modelData) }
                                        TinyBtn { label: "+"; onClicked: room.addRow(modelData, "stream") }
                                        TinyBtn { label: "\u2193"; onClicked: room.addRow(modelData, "file") }
                                        TinyBtn {
                                            label: "\u25b6"
                                            onClicked: room.watchVideo(modelData.url, modelData.title)
                                        }
                                    }
                                }

                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    z: -1
                                    onClicked: {}
                                }
                            }
                        }
                        Item { height: 6 }
                    }
                }

                // ---------- a page
                Flickable {
                    id: pageFlick
                    anchors.fill: parent
                    visible: room.cur().view === "page"
                    contentHeight: pageCol.height + 10
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: pageCol
                        width: parent.width
                        spacing: 12
                        Layout.topMargin: 4

                        Rectangle {
                            Layout.fillWidth: true
                            height: 178; radius: 18
                            color: room.a(room.ink, 0.045)
                            clip: true

                            Rectangle {
                                id: pageArt
                                anchors.fill: parent
                                color: room.a(room.accent, 0.10)
                                Image {
                                    anchors.fill: parent
                                    source: room.page ? (room.page.thumb || "") : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    opacity: status === Image.Ready ? 0.55 : 0
                                    Behavior on opacity { NumberAnimation { duration: 380 } }
                                }
                                gradient: Gradient {
                                    orientation: Gradient.Vertical
                                    GradientStop { position: 0; color: room.a(room.panel, 0.10) }
                                    GradientStop { position: 0.55; color: room.a(room.panel, 0.55) }
                                    GradientStop { position: 1; color: room.a(room.panel, 0.94) }
                                }
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 4
                                Item { Layout.fillHeight: true }
                                Text {
                                    Layout.fillWidth: true
                                    text: room.page ? (room.page.title || "") : ""
                                    color: room.ink
                                    font.family: room.fontFamily; font.pixelSize: (20) * room.typeScale
                                    font.bold: true; font.letterSpacing: -0.3
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: {
                                        if (!room.page) return "";
                                        var bits = [];
                                        if (room.page.artist) bits.push(room.page.artist);
                                        if (room.page.kind === "playlist") bits.push((room.page.count || 0) + " songs");
                                        else if (room.page.duration_ms > 0) {
                                            var s = Math.floor(room.page.duration_ms / 1000);
                                            bits.push(Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2));
                                        }
                                        bits.push(("" + (room.page.source || "youtube")).toUpperCase());
                                        return bits.join("   \u00b7   ");
                                    }
                                    color: room.a(room.dim, 0.8)
                                    font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 7
                            component PageBtn : Rectangle {
                                id: pb
                                property string label: ""
                                property bool main: false
                                width: pbLbl.width + 30; height: 34; radius: 17
                                color: pb.main ? room.a(room.accent, 0.9)
                                               : (pbMa.containsMouse ? room.a(room.accent, 0.20) : room.a(room.ink, 0.06))
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Text {
                                    id: pbLbl
                                    anchors.centerIn: parent
                                    text: pb.label
                                    color: pb.main ? room.panel : room.a(room.ink, 0.85)
                                    font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                    font.bold: true; font.letterSpacing: 1.4
                                }
                                MouseArea {
                                    id: pbMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: pb.clicked()
                                }
                                signal clicked()
                            }
                            PageBtn {
                                visible: room.page && room.page.kind !== "spotify"
                                main: true
                                label: room.page && room.page.kind === "playlist" ? "IMPORT AS PLAYLIST" : "STREAM"
                                onClicked: room.playMain()
                            }
                            PageBtn {
                                visible: room.page && (room.page.kind === "video" || room.page.kind === "playlist")
                                label: "\u25b6  WATCH"
                                onClicked: room.watchPage()
                            }
                            PageBtn {
                                visible: room.page && room.page.kind !== "playlist" && room.page.kind !== "spotify"
                                label: "SAVE OFFLINE"
                                onClicked: room.saveMain()
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: ("" + (room.page ? room.page.url : "")).replace(/^https?:\/\//, "")
                                color: room.a(room.dim, 0.4)
                                font.family: room.fontFamily; font.pixelSize: (7.5) * room.typeScale
                                elide: Text.ElideMiddle
                                Layout.maximumWidth: 260
                            }
                        }

                        // playlist contents preview
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: room.page && room.page.kind === "playlist" && room.page.entries
                                     && room.page.entries.length > 0
                            spacing: 2
                            Text {
                                text: "WHAT IS BEHIND THE LINK"
                                color: room.a(room.dim, 0.5)
                                font.family: room.fontFamily; font.pixelSize: (7.5) * room.typeScale
                                font.bold: true; font.letterSpacing: 1.8
                                Layout.topMargin: 2
                            }
                            Repeater {
                                model: room.page && room.page.entries ? room.page.entries : []
                                delegate: RowLayout {
                                    Layout.fillWidth: true
                                    height: 26
                                    spacing: 8
                                    Text {
                                        text: "\u00b7"
                                        color: room.a(room.accent, 0.6)
                                        font.pixelSize: (12) * room.typeScale
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.title || ""
                                        color: room.a(room.ink, 0.75)
                                        font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        text: modelData.duration_ms > 0
                                              ? (Math.floor(modelData.duration_ms / 60000) + ":"
                                                 + ("0" + Math.floor((modelData.duration_ms % 60000) / 1000)).slice(-2))
                                              : ""
                                        color: room.a(room.dim, 0.5)
                                        font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                                    }
                                }
                            }
                        }

                        // spotify: tell the truth about what happens next
                        Rectangle {
                            Layout.fillWidth: true
                            visible: room.page && room.page.kind === "spotify"
                            height: 62; radius: 14
                            color: room.a("#1db954", 0.12)
                            Text {
                                anchors.fill: parent
                                anchors.margins: 14
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.WordWrap
                                text: "A spotify link is read through the linked account: the tracks that exist there are matched on youtube and soundcloud, and the sleeve comes across with them. Import the link to build the playlist."
                                color: room.a(room.ink, 0.78)
                                font.family: room.fontFamily; font.pixelSize: (9) * room.typeScale
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: room.error.length > 0
                            text: room.error
                            color: room.a("#ff9a9a", 0.95)
                            font.family: room.fontFamily; font.pixelSize: (9.5) * room.typeScale
                            wrapMode: Text.WordWrap
                        }
                        Item { height: 8 }
                    }
                }
            }

            // ------------------------------------------------ footer
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text {
                    Layout.fillWidth: true
                    text: room.toast.length > 0
                          ? room.toast
                          : (room.page && room.page.url ? ("page \u00b7 " + room.page.url) : "paste any youtube, soundcloud, spotify or bandcamp link - the room reads it")
                    color: room.toast.length > 0 ? room.accent : room.a(room.dim, 0.42)
                    font.family: room.fontFamily; font.pixelSize: (8) * room.typeScale
                    elide: Text.ElideRight
                }
                Text {
                    text: room.tabs.length + " / 6 pages"
                    color: room.a(room.dim, 0.35)
                    font.family: room.fontFamily; font.pixelSize: (7.5) * room.typeScale
                }
            }
        }
    }

    // closing when the app itself changes surface
    Shortcut {
        sequence: "Escape"
        enabled: room.slide > 0.4
        onActivated: room.hide()
    }
}
