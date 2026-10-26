// lang: QML, file: Main.qml
// Aether Audio - sovereign player shell, Frutiger Metro per Visual Codex
import QtQuick
import QtQuick.Window 2.15
import QtQuick.Controls.Basic 2.15
import QtQuick.Layouts 1.15
import QtQuick.Effects
import QtQuick.Dialogs
import QtMultimedia

ApplicationWindow {
    id: root
    visible: true
    width: 1280
    height: 760
    title: "AetherMix"
    color: th.bg
    font.family: "Segoe UI"
    flags: Qt.Window | Qt.FramelessWindowHint
    minimumWidth: 1080
    minimumHeight: 640

    // ---------------- motion language ----------------
    // four clocks, one grammar: page (nav), interaction (pointer), event
    // (bursts) and world (slow drift). everything in the shell reads these.
    readonly property int eEnter: Easing.OutQuint      // arrivals settle late
    readonly property int eExit: Easing.InCubic        // departures leave quickly
    readonly property int ePop: Easing.OutBack         // touches overshoot once
    readonly property int dTap: 120
    readonly property int dResp: 220
    // window choreography: the shell itself is a scene, not a rectangle
    property real uiIn: 0
    property bool shuttingDown: false
    property bool fadingToTray: false
    NumberAnimation {
        id: uiInAnim
        target: root; property: "uiIn"
        from: 0; to: 1
        duration: 760
        easing.type: Easing.OutQuint
    }
    NumberAnimation {
        id: uiOutAnim
        target: root; property: "uiIn"
        from: 1; to: 0
        duration: 260
        easing.type: Easing.InCubic
        onFinished: {
            if (root.shuttingDown) { Qt.exit(0); }
            else if (root.fadingToTray) { root.fadingToTray = false; root.showMinimized(); }
        }
    }
    onClosing: function(close) {
        if (root.shuttingDown) return;
        close.accepted = false;
        root.shuttingDown = true;
        uiOutAnim.restart();
    }
    onVisibilityChanged: {
        if (root.visibility === Window.Minimized) {
            // the shell sinks into the taskbar, but the song keeps playing: a
            // small always-on-top bar takes over the transport down there
            root.fadingToTray = false;
            root.showMiniBar();
            return;
        }
        // the bar sinks away on its own clock while the room's curtain lifts:
        // the two windows overlap for a beat instead of swapping places
        if (root.miniBar) root.miniBar.dismiss();
        if (!root.shuttingDown && root.uiIn < 1) uiInAnim.restart();
    }
    // minimize is a gesture too: the room sinks before the taskbar takes it
    function minimizeWindow() {
        if (root.visibility === Window.Minimized) return;
        root.fadingToTray = true;
        uiOutAnim.restart();
    }

    // The desktop bar is a separate top-level window, created the first time the
    // window is minimized: a minimized QQuickWindow does not draw, so the
    // transport has to live in a window of its own. One instance, reused.
    property var miniBar: null
    function showMiniBar() {
        if (!root.miniBar) {
            var c = Qt.createComponent("MiniBar.qml");
            if (c.status !== Component.Ready) {
                // console.log never leaves the process on this build: the diag
                // channel is the only way a failed side window becomes visible
                console.log("minibar: " + c.errorString());
                root.hit("/frame?d=" + encodeURIComponent("minibar " + c.errorString()));
                return;
            }
            root.miniBar = c.createObject(null, { host: root });
        }
        // let the room sink first (uiOut is 260 ms), then let the bar rise into
        // the corner the window just vacated
        miniReveal.restart();
    }
    Timer {
        id: miniReveal
        interval: 130
        onTriggered: if (root.miniBar && root.visibility === Window.Minimized) root.miniBar.summon();
    }

    // ---------------- state ----------------
    property var s: ({
        status: "booting", title: "", artist: "", album: "", origin: "",
        track_id: null, playing: false, position_ms: 0, duration_ms: 0,
        volume: 70, viz_mode: 0, theme: "frutiger", levels: [], wave: [],
        library_version: 0, queue_len: 0, queue_pos: 0, shuffle: false, repeat: 0,
        streaming: false, cover_url: "", underruns: 0
    })
    // 1 = the world is background (content needs quiet air), 0 = the world is the page
    readonly property real worldVeil: themeWorldOpen ? 0.10 : (currentPage === 4 ? 0.46 : 1.0)
    // a photograph or a film replaces the atmosphere: the theme still tints the
    // interface, but its fog no longer sits on top of someone's wallpaper
    readonly property bool mediaLook: !!effLook && effLook.kind !== undefined && effLook.kind !== "theme"
    // The washes below read these two weights, never the targets above. A page
    // carries its own veil depth and can swap a wallpaper in the same frame it
    // becomes visible, so without an animated weight the whole background
    // changes opacity in one present - the "jumpscare". Both ease over ~0.7s,
    // which is the length of a page move, so the change travels with the page.
    property real veilK: worldVeil
    property real mediaK: mediaLook ? 1 : 0
    Behavior on veilK { NumberAnimation { duration: 680; easing.type: Easing.InOutCubic } }
    Behavior on mediaK { NumberAnimation { duration: 720; easing.type: Easing.InOutCubic } }
    property var tc: ({
        name: "Frutiger", bg: "#010814", panel: "#06203f", panel_alpha: 0.5,
        text: "#eaffff", dim: "#8fc7e8", accent: "#00ff7f", bar: "#00ffff",
        accent2: "#69e7ff", glow: "#7dffd0",
        light: false, anim: "aurora", signature: "bubbles",
        depth: { shadow: 0.6, rim: 0.32, grain: 0.12, vignette: 0.32, glass: 0.10, blur: 0.85 },
        mood: "weightless chrome optimism",
        transition: { type: "slide", dur: 300, from: 60 }
    })
    property var lib: ({ version: 0, playlist_name: "Library", playlist_owner: "", total: 0, playable: 0, stream_count: 0, local_count: 0, tracks: [] })
    property var filtered: []
    // how the playlist is ordered, and whether only liked songs are shown.
    // both are view state: the playlist file keeps its own order.
    property string sortBy: "added"
    property bool likedOnly: false
    property var trackInfo: null
    property bool infoOpen: false
    // a row's heart is a *view* override until the next library load: the
    // track objects come from JSON, so mutating them does not notify any
    // binding. reassigning this map does.
    property var likedOverrides: ({})
    property bool syncBusy: false
    property var localFiltered: []
    property string searchQ: ""
    property bool localOnly: false
    property var convertStatus: ({ running: false, done: 0, failed: 0, total: 0, current: "" })
    property var queueData: ({ current: null, up: [] })
    property var lyricsData: ({ lines: [], synced: false })
    property int lyricLine: -1
    // locally interpolated playback clock: lyrics and scrubbers move at 60fps
    // instead of stepping on the 100ms state poll
    property real posMs: 0
    property real lastServerPos: 0
    property int currentPage: 5   // HOME is the landing page
    property int navDir: 1
    property int lastServerPage: 5
    property real pageEnter: 1     // 0..1 entering-page progress
    property real pageExit: 0      // 1..0 leaving-page progress
    property real pageClock: 0     // seconds clock for cascades
    property real enterStamp: -10  // pageClock value at last page activation
    property real trKick: 0        // 3D camera impulse during transitions
    // ---- frame pacing -------------------------------------------------
    // the room is a 3D scene on an integrated GPU, so smoothness is entirely
    // a question of frame time. this is measured on frames the compositor
    // actually presented (FrameAnimation), never on a Timer - a 16ms Timer
    // happily reports 60fps while the render loop is struggling.
    property real fps: 60          // smoothed, presented frames per second
    property real q: 1.0           // world quality the room currently draws at
    property real qSteady: 0       // milliseconds the frame time has been healthy
    property real qSick: 0         // milliseconds the frame time has been poor
    property bool qDropped: false  // one-way: a room never spends its way back up
    // animated theme colors: every surface cross-fades when the theme changes
    QtObject {
        id: th
        property color bg: "#010814"
        property color panel: "#06203f"
        property color text: "#eaffff"
        property color dim: "#8fc7e8"
        property color accent: "#00ff7f"
        property color bar: "#00ffff"
        property color accent2: "#69e7ff"
        property color glow: "#7dffd0"
        Behavior on bg { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on panel { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on text { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on dim { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on accent { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on bar { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on accent2 { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
        Behavior on glow { ColorAnimation { duration: 560; easing.type: Easing.OutCubic } }
    }
    onTcChanged: {
        th.bg = tc.bg; th.panel = tc.panel; th.text = tc.text;
        th.dim = tc.dim; th.accent = tc.accent; th.bar = tc.bar;
        th.accent2 = tc.accent2 || tc.bar || tc.accent;
        th.glow = tc.glow || tc.accent;
        root.applyTypeColor();
        root.themeFlash = 1;
        themeFlashAnim.restart();
        applyBg3d();
    }
    // theme tokens with safe fallbacks for hand-made theme files
    function dep(k, d) {
        var o = root.tc.depth || {};
        return (o[k] !== undefined) ? o[k] : d;
    }
    function accent2() { return root.tc.accent2 || root.tc.bar || root.tc.accent; }
    function materialFor() {
        var s = (root.tc.signature || root.tc.anim || "").toLowerCase();
        var m = {
            ribbon: "silk light", shapes: "matte paper", motes: "deep glass",
            orbit: "liquid metal", grid: "etched copper", gear: "warm brass",
            embers: "night air", bubbles: "aerogel", rain: "dither glass",
            glass: "foil", ink: "washi", lowpoly: "raw facets",
            glyph: "terminal rain", vapor: "chrome sunset", rings: "warp glass"
        };
        return m[s] || "quiet matter";
    }
    function coverOf(t) {
        return (t && t.cover && ("" + t.cover).length > 4) ? t.cover : "";
    }
    function pageName() {
        var names = ["PLAYLIST", "LOCAL", "VIBE", "QUEUE", "THEMES", "HOME", "SETTINGS"];
        if (root.currentPage >= 7) {
            var e = root.exts[root.currentPage - 7];
            return e ? ("" + e.id).toUpperCase() : "EXTENSION";
        }
        return names[root.currentPage] || "";
    }
    function pageNameFor(p) {
        var n = ["PLAYLIST", "LOCAL", "VIBE", "QUEUE", "THEMES", "HOME", "SETTINGS"];
        return (p >= 0 && p < n.length) ? n[p] : "TAB";
    }
    // stylised unicode (mathematical bold/script letters) has no glyph in the
    // UI font on Windows and paints as tofu boxes. show the letters they stand
    // for; the stored playlist name itself is never rewritten.
    function readable(s) {
        var t = (s === undefined || s === null) ? "" : ("" + s);
        if (t.length === 0) return t;
        // [codepoint start, ascii start, count]
        var sets = [
            [0x1D400, 65, 26], [0x1D41A, 97, 26], [0x1D434, 65, 26], [0x1D44E, 97, 26],
            [0x1D468, 65, 26], [0x1D482, 97, 26], [0x1D49C, 65, 26], [0x1D4B6, 97, 26],
            [0x1D4D0, 65, 26], [0x1D4EA, 97, 26], [0x1D504, 65, 26], [0x1D51E, 97, 26],
            [0x1D538, 65, 26], [0x1D552, 97, 26], [0x1D56C, 65, 26], [0x1D586, 97, 26],
            [0x1D5A0, 65, 26], [0x1D5BA, 97, 26], [0x1D5D4, 65, 26], [0x1D5EE, 97, 26],
            [0x1D608, 65, 26], [0x1D622, 97, 26], [0x1D63C, 65, 26], [0x1D656, 97, 26],
            [0x1D670, 65, 26], [0x1D68A, 97, 26],
            [0x1D7CE, 48, 10], [0x1D7D8, 48, 10], [0x1D7E2, 48, 10],
            [0x1D7EC, 48, 10], [0x1D7F6, 48, 10]
        ];
        var out = "";
        for (var i = 0; i < t.length; i++) {
            var c = t.charCodeAt(i);
            if (c < 0xD800 || c > 0xDBFF) { out += t.charAt(i); continue; }
            var d = t.charCodeAt(i + 1);
            if (isNaN(d)) { out += t.charAt(i); continue; }
            var cp = (c - 0xD800) * 0x400 + (d - 0xDC00) + 0x10000;
            var mapped = -1;
            for (var k = 0; k < sets.length; k++) {
                var base = sets[k][0];
                if (cp >= base && cp < base + sets[k][2]) { mapped = sets[k][1] + (cp - base); break; }
            }
            if (mapped >= 0) { out += String.fromCharCode(mapped); i++; }
            else out += t.charAt(i);
        }
        return out;
    }
    function libCover() {
        if (root.lib && root.lib.playlist_cover && root.lib.playlist_cover.length > 4) return root.lib.playlist_cover;
        var trks = (root.lib && root.lib.tracks) ? root.lib.tracks : [];
        for (var i = 0; i < trks.length; i++) {
            if (trks[i].cover && trks[i].cover.length > 4) return trks[i].cover;
        }
        return "";
    }
    function nowCover() {
        if (root.s.cover_url && root.s.cover_url.length > 4) return root.s.cover_url;
        var trks = (root.lib && root.lib.tracks) ? root.lib.tracks : [];
        if (root.s.track_id !== null) {
            for (var i = 0; i < trks.length; i++) {
                if (trks[i].id === root.s.track_id && trks[i].cover && trks[i].cover.length > 4) return trks[i].cover;
            }
        }
        return root.libCover();
    }
    function trackById(id) {
        var trks = (root.lib && root.lib.tracks) ? root.lib.tracks : [];
        for (var i = 0; i < trks.length; i++) if (trks[i].id === id) return trks[i];
        return null;
    }
    function currentLyric() {
        if (!root.lyricsData.synced) return "";
        var i = root.lyricLine;
        if (i < 0 || i >= root.lyricsData.lines.length) return "";
        return root.lyricsData.lines[i].text || "";
    }
    function upNextCount() {
        return Math.max(0, (root.s.queue_len || 0) - (root.s.queue_pos || 0) - (root.s.playing ? 0 : 0));
    }
    function recentIds(n) {
        var ids = (root.playStats && root.playStats.recent) ? root.playStats.recent : [];
        if (ids.length > 0) return ids.slice(0, n);
        var out = [];
        var trks = (root.lib && root.lib.tracks) ? root.lib.tracks : [];
        for (var i = 0; i < trks.length && out.length < n; i++) {
            if (trks[i].playable) out.push(trks[i].id);
        }
        return out;
    }
    property real themeFlash: 0
    NumberAnimation { id: themeFlashAnim; target: root; property: "themeFlash"; from: 1; to: 0; duration: 900; easing.type: Easing.OutCubic }
    property bool railShown: false
    property var lyricStyle: ({ pattern: "accent", anim: "rise", emphasis: "glow" })
    property var engine: ({})
    property var searchResults: []
    property var playStats: ({ top: [], recent: [] })
    property var suggestResults: []
    property var eqState: ({ enabled: false, gains: [0, 0, 0, 0, 0] })
    property bool eqOn: false
    function pushEq() {
        hit("/eq/set?enabled=" + (root.eqOn ? "1" : "0")
            + "&g0=" + eq0.value + "&g1=" + eq1.value + "&g2=" + eq2.value
            + "&g3=" + eq3.value + "&g4=" + eq4.value);
    }
    property bool lyricStyleGlobal: false
    function applyLyricStyle() {
        var id = (s.track_id !== null && s.track_id !== undefined) ? s.track_id : 0;
        hit("/lyricstyle/set?id=" + id
            + "&pattern=" + root.lyricStyle.pattern
            + "&anim=" + root.lyricStyle.anim
            + "&emphasis=" + root.lyricStyle.emphasis
            + (root.lyricStyleGlobal ? "&global=1" : ""));
    }
    function fetchEq() {
        fetchJson("/eq", function(e) {
            root.eqOn = e.enabled === true;
            var g = e.gains || [0, 0, 0, 0, 0];
            eq0.value = g[0]; eq1.value = g[1]; eq2.value = g[2]; eq3.value = g[3]; eq4.value = g[4];
        });
    }
    property int leavingPage: -1
    property int lastLibVer: -1
    property int lastTrackId: -1
    property var themeCards: []
    // playlist library: saved playlists + the add-music sheet
    property var playlistRows: []
    property string activePlaylistFile: ""
    property bool newPlOpen: false
    property string newPlName: ""
    // the playlist room has two depths: the shelf of every saved list, and one
    // list opened. plOpen drives the transition between them.
    property bool plOpen: false
    property bool shelfCreating: false
    property int plIndex: 0
    // themes are rooms you can walk into, not swatches you pick
    property bool themeWorldOpen: false
    property var ytResults: []
    property int ytSeq: 0
    property string localFilter: ""
    property bool ytSearching: false
    property var ytAddState: ({ running: false, current: "", current_title: "", last_title: "", last_error: "", last_id: -1, queued: 0 })
    // url -> "queued" | "done": the sheet answers the press immediately
    property var ytPending: ({})
    function ytState(u) { return root.ytPending[u] || ""; }
    function setYtState(u, v) {
        var m = {};
        for (var k in root.ytPending) m[k] = root.ytPending[k];
        m[u] = v;
        root.ytPending = m;
    }
    function clearYtPending() { root.ytPending = ({}); }
    property int addTab: 0
    // right-click menu: a song, where the press happened, and which page of
    // the menu is showing (actions, or the playlist chooser)
    property var ctxTrack: null
    property real ctxX: 0
    property real ctxY: 0
    property bool ctxOpenState: false
    property int ctxMode: 0
    property bool ctxIsLocal: false
    property real cardPhase: 0
    // cardPhase is advanced by the frame clock (frameProbe), one step per
    // presented frame - a fixed 80ms timer made every accent pulse step on a
    // high-refresh panel instead of gliding.
    // the song clock is anchored to the wall clock between polls: a 16ms tick
    // used to under-count badly and lyrics drifted behind the voice
    property real anchorPos: 0
    property double anchorAt: 0
    property var exts: []
    property double brandPulse: 0
    property var smoothLevels: []
    property var smoothPeaks: []
    // the measured spectrum and the drawn one are two clocks: raw is smoothed
    // audio, shown is raw lifted by a slow auto-gain (see smoothLevelsTick)
    property var rawLevels: []
    property var rawPeaks: []
    property real eqGain: 1
    property real bassLevel: 0
    property real eqPhase: 0
    property string themeSlug: ""

    // ---------------- the look: type, wallpaper, per-tab worlds ----------------
    // stored server-side in appearance.json so the room opens the way it was
    // left, even after a crash. every field is live: no apply button.
    property var appearance: ({
        font: { family: "Segoe UI", scale: 1.0, color: "" },
        backdrop: { kind: "theme", source: "", opacity: 0.75, blur: 0.22,
                    tint: "#050f1c", tintAmt: 0.0, hue: 0, sat: 1.0,
                    bright: 1.0, zoom: 1.0, drift: 0.35 },
        tabs: {}
    })
    readonly property real ts: {
        var f = root.appearance.font || {};
        var v = (f.scale !== undefined) ? f.scale : 1.0;
        return Math.max(0.78, Math.min(1.45, v));
    }
    readonly property string tf: {
        var f = root.appearance.font || {};
        return (f.family && f.family.length > 0) ? f.family : "Segoe UI";
    }
    property var effLook: ({ kind: "theme" })
    // ---------------- the equaliser's colours ----------------
    // Two optional colours for the meters. Empty means "keep drawing with
    // this room's own palette": the big circular meter runs bar -> accent and
    // the little one in the bar runs accent -> accent2, so a colour left on
    // THEME shows each one exactly what it drew before this existed. They
    // live in the look document, so they are per tab like the rest of the
    // grading - one room can wear a different equaliser to the next.
    readonly property string eqA: "" + (((root.effLook || {}).eqA) || "")
    readonly property string eqB: "" + (((root.effLook || {}).eqB) || "")
    readonly property bool eqAOn: root.eqA.length >= 4
    readonly property bool eqBOn: root.eqB.length >= 4
    property string baseThemeId: ""      // the theme the app itself is set to
    property string lookThemeId: ""      // the theme currently shown (may be a tab's)
    property var studio: ({ page: -1 })
    property bool studioOpen: false
    property int studioTab: 0
    property string fontWheel: ""
    property var accountsData: ({ accounts: [], active: "", spotify: { granted: false } })
    // the phone gateway: whether this machine answers anything from the network
    property bool phoneOpen: true
    property string phoneURL: ""
    property bool accountsOpen: false
    property string newAccLabel: ""
    property string newAccCookies: "browser:chrome"
    property var ytBackdrop: ({ running: false, path: "", error: "", url: "" })
    // one search bar over every room
    property bool findOpen: false
    property string findQ: ""
    property string findSrc: "all"
    // how a song found on the web joins the room: "stream" plays it straight
    // from the page (nothing written to disk), "file" downloads it first.
    // saved as add_mode so the next press behaves the same way.
    property string addMode: "stream"
    property var findRows: []
    // ---- watch: the film, not the player around it ----
    property var watch: ({ running: false, path: "", error: "", url: "", title: "" })
    property string watchQuery: ""
    property bool watchBusy: false
    property int watchStale: 0    // polls answered by someone else's job
    property var watchRows: []
    function watchUrlLooksLikeLink() {
        return /^https?:\/\//i.test((root.watchQuery || "").trim());
    }
    function watchThis(u, title) {
        var x = (u || "").trim();
        if (x.length < 4) return;
        if (!/^https?:\/\//i.test(x)) {
            var id = x.replace(/[^A-Za-z0-9_-]/g, "");
            if (id.length < 6) { root.watch = { running: false, path: "", error: "need a link or a video id", url: "", title: "" }; return; }
            x = "https://www.youtube.com/watch?v=" + id;
        }
        root.watchQuery = x;
        root.watchStale = 0;
        root.watch = { running: true, path: "", error: "", url: x, title: title || "", pct: 0, note: "reading the link" };
        watchPanel.show();
        hit("/backdrop/prepare?url=" + encodeURIComponent(x));
        watchPoll.restart();
    }
    function pollWatch() {
        fetchJson("/backdrop/status", function(d) {
            if (!d) return;
            // the fetch slot is shared with the room's moving wallpaper, so a
            // status can belong to a different surface entirely. a film that
            // has its file must never have it swapped or cleared by someone
            // else's job - only this film's own url may write here.
            if (d.url && root.watch.url && d.url !== root.watch.url) {
                // someone else owns the shared slot right now. keep waiting,
                // but not forever - a slot that never comes back must say so
                // instead of spinning on "fetching"
                root.watchStale += 1;
                if (root.watchStale > 40) {
                    watchPoll.stop();
                    root.watch = { running: false, path: "", error: "that fetch was interrupted - try it again",
                                   url: root.watch.url, title: root.watch.title, pct: 0, note: "" };
                }
                return;
            }
            root.watchStale = 0;
            if (d.running) {
                // keep the live download readable: percent and stage, not a
                // frozen "FETCHING" label for ninety seconds
                root.watch = { running: true, path: "", error: "", url: root.watch.url,
                               title: root.watch.title, pct: d.pct || 0, note: d.note || "" };
                return;
            }
            watchPoll.stop();
            if ((d.path || "").length > 2) {
                root.watch = { running: false, path: d.path, error: "", url: root.watch.url, title: root.watch.title, pct: 100, note: "" };
            } else {
                root.watch = { running: false, path: "", error: (d.error || "that video could not be fetched"), url: root.watch.url, title: root.watch.title, pct: 0, note: "" };
            }
        });
    }
    // the way back out of a loaded film. the sheet has two states - the
    // browser (search field + results) and the film - and once a film is in
    // the slot the browser is hidden, so without this the sheet was a one-way
    // door: reopening it always landed on the last video with no way to look
    // for another one.
    function watchBrowse() {
        watchPoll.stop();
        root.watchStale = 0;
        root.watch = { running: false, path: "", error: "", url: "", title: "", pct: 0, note: "" };
        watchFocus.restart();
        // bring the last *text* query back, never the URL: watchQuery still
        // holds the link of the film that was just cleared, and searching it
        // would immediately start that same download again - the sheet looked
        // like BROWSE did nothing because the film came straight back
        var q = (root.watchQuery || "").trim();
        if (q.length > 1 && !/^https?:\/\//i.test(q) && root.watchRows.length === 0)
            root.searchWatch(q);
    }
    // the song on the deck, as a film: one press from the hero block
    function watchCurrent() {
        var t = (root.s.title || "").trim();
        if (t.length < 2) { syncToast.show("play something first, then watch it"); return; }
        // the film in the slot belongs to the previous song: clear it first or
        // the sheet opens on it and the search box never appears
        root.watchBrowse();
        watchPanel.show();
        root.watchQuery = t + (root.s.artist ? " " + root.s.artist : "");
        root.searchWatch(root.watchQuery);
    }
    function searchWatch(q) {
        var s = (q || "").trim();
        if (s.length < 2) return;
        if (/^https?:\/\//i.test(s)) { root.watchThis(s); return; }
        root.watchBusy = true;
        root.watchRows = [];
        fetchJson("/youtube/search?q=" + encodeURIComponent(s), function(d) {
            root.watchBusy = false;
            root.watchRows = (d && d.results) ? d.results : [];
        });
    }
    // ---- playlist link import ----
    property string importLink: ""
    property var importPreview: null
    property bool importBusy: false
    property string importError: ""
    property var importStatus: ({ running: false, done: 0, total: 0, failed: [], name: "" })
    function readImportLink() {
        var u = (importLink || "").trim();
        if (u.length < 8) { root.importError = "paste a playlist link first"; return; }
        root.importBusy = true;
        root.importError = "";
        fetchJson("/playlist/import/preview?url=" + encodeURIComponent(u), function(d) {
            root.importBusy = false;
            if (!d || !d.ok) {
                root.importPreview = null;
                root.importError = (d && d.error) ? d.error : "could not read that link";
                return;
            }
            root.importPreview = d;
        });
    }
    function startImport() {
        if (!root.importPreview) { root.readImportLink(); return; }
        root.importBusy = true;
        root.importError = "";
        var u = (root.importLink || "").trim();
        var nm = (root.importPreview.name || "").trim();
        fetchJson("/playlist/import/start?url=" + encodeURIComponent(u) + "&name=" + encodeURIComponent(nm), function(d) {
            root.importBusy = false;
            if (!d || !d.ok) { root.importError = (d && d.error) ? d.error : "import failed"; return; }
            root.importStatus = ({ running: true, done: 0, total: d.total || 0, failed: [], name: d.name || nm, file: d.file || "" });
            importPoll.restart();
            syncToast.show("building \"" + (d.name || nm) + "\" - " + (d.total || 0) + " songs");
        });
    }
    function pollImport() {
        fetchJson("/playlist/import/status", function(d) {
            if (!d) return;
            root.importStatus = d;
            if (!d.running) {
                importPoll.stop();
                root.loadPlaylists();
                root.lastLibVer = -1;
                var n = (d.failed || []).length;
                syncToast.show("import finished: " + (d.done - n) + " of " + d.total + (n > 0 ? ("  \u00b7  " + n + " not found") : ""));
            }
        });
    }
    function openImported() {
        var f = root.importStatus.file || "";
        if (f.length < 4) return;
        hit("/playlist/switch?id=" + encodeURIComponent(f));
        root.lastLibVer = -1;
        root.loadPlaylists();
        root.plOpen = true;
        syncToast.show("opening " + (root.importStatus.name || "the new room"));
    }
    property var findCounts: ({ youtube: 0, soundcloud: 0, spotify: 0 })
    property int findSeq: 0
    property bool findBusy: false
    property string findError: ""
    property var findSides: ([])
    // command palette + sleep fade
    property bool palOpen: false
    property string palQ: ""
    property int palSel: 0
    property var palRows: []
    property int sleepMins: 0
    property double sleepDeadline: 0
    property int sleepBaseVol: 70
    property int sleepLastVol: -1
    // air: a small HUD that appears only while the volume is being touched
    property bool volHudOn: false
    property int volShown: 70
    Timer { id: volHudTimer; interval: 2200; onTriggered: root.volHudOn = false }
    function setVolume(v) {
        var nv = Math.max(0, Math.min(100, Math.round(v)));
        root.volShown = nv;
        root.volHudOn = true;
        volHudTimer.restart();
        root.hit("/volume?v=" + nv);
    }

    function hexParts(h) {
        var x = ("" + h).replace("#", "");
        if (x.length === 6) {
            return [parseInt(x.substring(0, 2), 16) / 255, parseInt(x.substring(2, 4), 16) / 255,
                    parseInt(x.substring(4, 6), 16) / 255, 1];
        }
        if (x.length === 8) {
            // color objects stringify as #aarrggbb
            return [parseInt(x.substring(2, 4), 16) / 255, parseInt(x.substring(4, 6), 16) / 255,
                    parseInt(x.substring(6, 8), 16) / 255, parseInt(x.substring(0, 2), 16) / 255];
        }
        return [1, 1, 1, 1];
    }
    function mixColor(c1, c2, t) {
        var a = hexParts(c1), b = hexParts(c2);
        return Qt.rgba(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, 1);
    }
    function rgba(hex, a) {
        var h = ("" + hex).replace("#", "");
        if (h.length === 6) h += "ff";
        var r = parseInt(h.substring(0, 2), 16) / 255;
        var g = parseInt(h.substring(2, 4), 16) / 255;
        var b = parseInt(h.substring(4, 6), 16) / 255;
        return Qt.rgba(r, g, b, a);
    }

    // ---------------- helpers ----------------
    function hit(path) {
        var x = new XMLHttpRequest();
        x.open("GET", "http://127.0.0.1:3690" + path);
        x.send();
    }
    function fetchJson(path, cb) {
        var x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState === XMLHttpRequest.DONE && x.status === 200) {
                try { cb(JSON.parse(x.responseText)); } catch (e) {}
            }
        };
        x.open("GET", "http://127.0.0.1:3690" + path);
        x.send();
    }
    function fmt(ms) {
        var t = Math.max(0, Math.floor(ms / 1000));
        return Math.floor(t / 60) + ":" + ("0" + (t % 60)).slice(-2);
    }
    function isLight(hex) {
        var r = parseInt(hex.substring(1, 3), 16);
        var g = parseInt(hex.substring(3, 5), 16);
        var b = parseInt(hex.substring(5, 7), 16);
        return (r * 0.299 + g * 0.587 + b * 0.114) > 145;
    }
    function colorFor(id) {
        var h = (id * 137.508) % 360;
        return Qt.hsla(h / 360, 0.62, 0.55, 1);
    }
    function localAddRows() {
        var q = root.localFilter.toLowerCase();
        var out = [];
        var src = (root.lib && root.lib.tracks) ? root.lib.tracks : [];
        for (var i = 0; i < src.length; i++) {
            var t = src[i];
            if (!t.playable) continue;
            if (t.origin !== "local" && t.album !== "YouTube") continue;
            if (q.length > 0 && (t.title || "").toLowerCase().indexOf(q) < 0 && (t.artist || "").toLowerCase().indexOf(q) < 0) continue;
            out.push(t);
        }
        return out;
    }
    function applyFilter() {
        var q = searchQ.toLowerCase();
        var src = lib.tracks || [];
        var streamOut = [];
        var localOut = [];
        for (var i = 0; i < src.length; i++) {
            var t = src[i];
            var match = q.length === 0 ||
                (t.title || "").toLowerCase().indexOf(q) >= 0 ||
                (t.artist || "").toLowerCase().indexOf(q) >= 0;
            if (!match) continue;
            if (likedOnly && !t.liked) continue;
            if (t.origin === "playlist") streamOut.push(t);
            else localOut.push(t);
        }
        // sorting is a projection, never a rewrite: the playlist file keeps the
        // order the songs were added in, so "added" can always come back
        if (sortBy === "title") {
            streamOut.sort(function(a, b) { return (a.title || "").localeCompare(b.title || ""); });
        } else if (sortBy === "artist") {
            streamOut.sort(function(a, b) { return (a.artist || "").localeCompare(b.artist || ""); });
        } else if (sortBy === "plays") {
            streamOut.sort(function(a, b) { return (b.plays || 0) - (a.plays || 0); });
        } else if (sortBy === "length") {
            streamOut.sort(function(a, b) { return (b.duration_ms || 0) - (a.duration_ms || 0); });
        }
        // two rooms, two meanings: the playlist shows the songs that belong to
        // it; the local vault shows files that were never attached to a playlist
        filtered = streamOut;
        localFiltered = localOut;
    }
    function cycleSort() {
        var order = ["added", "title", "artist", "plays", "length"];
        var i = order.indexOf(root.sortBy);
        root.sortBy = order[(i + 1) % order.length];
        root.applyFilter();
        root.toastNow("sorted by " + root.sortLabel().toLowerCase());
    }
    function sortLabel() {
        return root.sortBy === "added" ? "ADDED"
             : root.sortBy === "title" ? "TITLE"
             : root.sortBy === "artist" ? "ARTIST"
             : root.sortBy === "plays" ? "PLAYS"
             : "LENGTH";
    }
    function toggleLikedView() {
        root.likedOnly = !root.likedOnly;
        root.applyFilter();
        root.toastNow(root.likedOnly ? "showing liked songs" : "showing every song");
    }
    // ---------------- liked songs ----------------
    function isLiked(trk) {
        if (!trk) return false;
        var o = root.likedOverrides;
        if (o[trk.id] !== undefined) return o[trk.id];
        return !!trk.liked;
    }
    function toggleLike(trk) {
        if (!trk) return;
        var want = !root.isLiked(trk);
        root.fetchJson("/favorite?id=" + trk.id + "&on=" + (want ? 1 : 0), function(r) {
            if (!r || !r.ok) { syncToast.show(r && r.error ? r.error : "could not update"); return; }
            var m = {};
            for (var k in root.likedOverrides) m[k] = root.likedOverrides[k];
            m[trk.id] = r.liked;
            root.likedOverrides = m;
            trk.liked = r.liked;
            // the counter and the liked-only filter read the library, and the
            // library is server-owned: ask for a fresh copy instead of guessing
            root.lastLibVer = -1;
            if (root.likedOnly) root.applyFilter();
            root.toastNow(r.liked ? ("liked " + trk.title) : ("removed " + trk.title + " from liked"));
        });
    }
    function filteredMs() {
        var n = 0;
        var rows = root.filtered || [];
        for (var i = 0; i < rows.length; i++) n += rows[i].duration_ms || 0;
        return n;
    }
    function fmtLong(ms) {
        var m = Math.round((ms || 0) / 60000);
        if (m < 60) return m + " min";
        return Math.floor(m / 60) + "h " + (m % 60) + "m";
    }
    function exportM3u() {
        root.fetchJson("/playlist/export", function(r) {
            if (r && r.ok) syncToast.show("exported " + r.rows + " songs to " + r.path);
            else syncToast.show((r && r.error) ? r.error : "export failed");
        });
    }
    function importM3u(path) {
        var p = (path || "").trim();
        if (p.length < 4) { syncToast.show("paste a .m3u8 path first"); return; }
        root.fetchJson("/playlist/import/m3u?path=" + encodeURIComponent(p), function(r) {
            if (r && r.ok) {
                root.lastLibVer = -1;
                syncToast.show("imported " + r.added + " songs" + (r.missing ? (" - " + r.missing + " missing") : ""));
            } else {
                syncToast.show((r && r.error) ? r.error : "import failed");
            }
        });
    }
    // ---------------- one song, in full ----------------
    function showTrackInfo(trk) {
        if (!trk) return;
        root.trackInfo = { id: trk.id, title: trk.title, artist: trk.artist, album: trk.album,
                           duration_ms: trk.duration_ms, path: trk.path, origin: trk.origin,
                           liked: trk.liked, plays: trk.plays };
        root.infoOpen = true;
        root.fetchJson("/track/info?id=" + trk.id, function(d) {
            if (d && d.id !== undefined) root.trackInfo = d;
        });
    }
    function closeInfo() { root.infoOpen = false; root.trackInfo = null; }
    function revealTrack() {
        if (!root.trackInfo) return;
        root.fetchJson("/track/reveal?id=" + root.trackInfo.id, function(r) {
            if (!r || !r.ok) syncToast.show("this row has no file to show");
        });
    }
    // ---------------- resume where the room was left ----------------
    function resumeTrack() {
        var r = root.s.resume;
        if (!r || !r.key) return null;
        var rows = root.lib.tracks || [];
        for (var i = 0; i < rows.length; i++)
            if (rows[i].key === r.key) return rows[i];
        return null;
    }
    // On a stopped deck the hero used to sit on "nothing playing" while the
    // resume chip offered a song whose cover was nowhere on screen. The idle
    // state now borrows the last song's identity, so the room looks like it
    // remembers where it was instead of looking empty.
    function idleTrack() {
        if (root.s.track_id !== null && root.s.track_id !== undefined) return null;
        return root.resumeTrack();
    }
    function resumePlay() {
        var t = root.resumeTrack();
        if (!t) { syncToast.show("that song is no longer in this playlist"); return; }
        var pos = root.s.resume ? (root.s.resume.pos_ms || 0) : 0;
        root.hit("/play?id=" + t.id + "&pos=" + Math.round(pos));
        root.toastNow("resuming " + t.title);
    }
    function trActive() {
        var tr = root.tc.transition;
        return tr && tr.type ? tr.type : "dolly";
    }
    function trDur() {
        var tr = root.tc.transition;
        var d = tr && tr.dur ? tr.dur : 300;
        // the page clock never snaps below 280ms and never drags past 520ms:
        // under that it reads as a flicker, over it the room feels laggy.
        // the motion preference scales the whole grammar, it does not break it.
        d = d / Math.max(0.4, root.motionSpeed);
        if (root.motionStyle === "snappy") d *= 0.72;
        if (root.motionStyle === "minimal" || !root.motionEnabled) d = 180;
        return Math.max(160, Math.min(620, d));
    }
    // enter transform for progress p (0..1): { x, y, s, ry, rz, o }
    // every branch keeps the same grammar: the new room arrives slightly
    // further away and *settles* into place. nothing flies in from nowhere.
    function trEnterOf(p) {
        var dir = root.navDir || 1;
        var settle = p * p * (3 - 2 * p); // smoothstep: no kick at either end
        switch (trActive()) {
        case "dolly":
            return { x: 0, y: 34 * (1 - settle), s: 0.925 + 0.075 * settle, ry: 0, rz: 0, o: Math.min(1, p * 1.45) };
        case "tilt":
            return { x: 0, y: 6 * (1 - p), s: 0.94 + 0.06 * settle, ry: 14 * (1 - settle) * dir, rz: 0.5 * (1 - settle) * dir, o: Math.min(1, p * 1.3) };
        case "parallax":
            // the incoming screen comes in from the side, a little small and
            // a little far, and settles - a home-screen page arriving
            return { x: 128 * (1 - settle) * dir, y: 0, s: 0.935 + 0.065 * settle, ry: -7 * (1 - settle) * dir, rz: 0, o: Math.min(1, p * 1.25) };
        case "warp":
            return { x: 0, y: 0, s: 1.14 - 0.14 * settle, ry: 0, rz: 0, o: Math.min(1, p * 1.5) };
        case "glitch": {
            var j = Math.sin(p * 61.8) * (1 - p) * 18;
            return { x: j, y: 0, s: 1, ry: 0, rz: 0, o: p > 0.05 ? 1 : p * 12 };
        }
        case "snap": {
            var q = Math.min(1, Math.floor(p * 5.999) / 5);
            return { x: 0, y: 40 * (1 - q), s: 0.952 + 0.048 * q, ry: 0, rz: 0, o: q };
        }
        case "ripple":
            return { x: 0, y: 0, s: 1 + 0.055 * (1 - settle), ry: 0, rz: 0, o: Math.min(1, p * 1.4) };
        case "veil":
            return { x: 0, y: 14 * (1 - p), s: 1 + 0.025 * (1 - settle), ry: 0, rz: 0, o: Math.pow(p, 1.6) };
        case "slide":
            return { x: 84 * (1 - settle) * dir, y: 0, s: 0.988 + 0.012 * settle, ry: 0, rz: 0, o: Math.min(1, p * 1.3) };
        default:
            return { x: 0, y: 24 * (1 - settle), s: 0.962 + 0.038 * settle, ry: 0, rz: 0, o: Math.min(1, p * 1.3) };
        }
    }
    // exit transform for progress p (1..0): the old room leaves faster than
    // the new one arrives, so the two never fight for the eye
    function trExitOf(p) {
        var dir = root.navDir || 1;
        var out = 1 - p;
        switch (trActive()) {
        case "dolly":
            return { x: 0, y: -28 * out, s: 1 - 0.055 * out, ry: 0, rz: 0, o: p * p };
        case "tilt":
            return { x: 0, y: 0, s: 1 - 0.045 * out, ry: -11 * out * dir, rz: 0, o: p * p };
        case "parallax":
            // the outgoing screen falls back and dims but stays in the room
            // until it is off the edge: fading it to nothing in 200ms is a cut
            return { x: -170 * out * dir, y: 0, s: 1 - 0.06 * out, ry: 5 * out * dir, rz: 0, o: Math.pow(1 - out, 1.35) };
        case "warp":
            return { x: 0, y: 0, s: 1 - 0.12 * out, ry: 0, rz: 0, o: p * p };
        case "glitch":
            return { x: Math.sin(out * 47) * out * 12, y: 0, s: 1, ry: 0, rz: 0, o: p };
        case "snap":
            return { x: 0, y: -32 * out, s: 1, ry: 0, rz: 0, o: p };
        case "ripple":
            return { x: 0, y: 0, s: 1 - 0.045 * out, ry: 0, rz: 0, o: p * p };
        case "veil":
            return { x: 0, y: -10 * out, s: 1, ry: 0, rz: 0, o: p * p };
        case "slide":
            return { x: -74 * out * dir, y: 0, s: 1, ry: 0, rz: 0, o: p * p };
        default:
            return { x: 0, y: -18 * out, s: 1, ry: 0, rz: 0, o: p };
        }
    }
    function trFor(pg) {
        if (pg === root.currentPage) return trEnterOf(root.pageEnter);
        if (pg === root.leavingPage) return trExitOf(root.pageExit);
        return { x: 0, y: 0, s: 1, ry: 0, rz: 0, o: 0 };
    }
    // row cascade progress for delegates
    function cascFor(idx, page) {
        if (page !== root.currentPage) return 1;
        var t = root.pageClock - root.enterStamp - idx * 0.035;
        return Math.max(0, Math.min(1, t / 0.28));
    }

    ParallelAnimation {
        id: pageTransition
        NumberAnimation {
            target: root; property: "pageEnter"; from: 0; to: 1
            duration: root.trDur()
            easing.type: ["snap", "glitch"].indexOf(root.trActive()) >= 0 ? Easing.Linear
                         : (root.trActive() === "dolly" ? Easing.OutBack : Easing.OutCubic)
        }
        NumberAnimation {
            target: root; property: "pageExit"; from: 1; to: 0
            duration: Math.round(root.trDur() * 0.8)
            easing.type: Easing.InCubic
        }
    }
    // a short luminous exhale under the navigation when the page changes
    property real navGlowAmt: 0
    // arrival light: the room is lit from the side you came in from
    property real trBloom: 0
    // dock magnification: where the hand is, in window coordinates
    property real railHoverY: -999
    property real pageNameShift: 0

    // ---------------- motion + sound preferences ----------------
    // the reference settings panel treats motion as a preference, not a fixed
    // personality: on/off, speed, feel, and a chosen tap sound.
    property bool motionEnabled: true
    property real motionSpeed: 1.0
    property string motionStyle: "smooth"   // smooth | snappy | minimal
    property string soundPack: "tap"        // off | tap | double
    property bool typingOn: true            // keyboard voice in every field
    property string miniBackdrop: "theme"   // theme | song - the minimized bar
    property real soundVolume: 0.35

    // the dye drop: a change of room is ink meeting water
    property real dyeAmt: 0
    property real dyeSeed: 0.37
    property vector2d dyeOrigin: Qt.vector2d(0.5, 0.45)
    property color dyeInkA: th.accent
    property color dyeInkB: th.bg
    NumberAnimation {
        id: dyeAnim
        target: root; property: "dyeAmt"
        from: 0; to: 1
        duration: Math.round(780 / Math.max(0.4, root.motionSpeed))
        easing.type: Easing.OutCubic
        onFinished: root.dyeAmt = 0
    }
    // a click, a chip, a room: the same tiny voice, chosen by the person.
    // Each pack is loaded once and kept warm: swapping a source on the fly
    // costs a load pause, and the first tap after a change would go silent.
    // Two taps, both real recordings rather than generated waves: a single
    // mouse click (0.37s) and a fast double click (0.46s). The old glass/drop/
    // wood voices are gone - they were synthesised and read as "app sounds"
    // next to these.
    SoundEffect { id: sndTap;    source: Qt.resolvedUrl("../assets/sounds/tap.wav");    volume: root.soundVolume }
    SoundEffect { id: sndDouble; source: Qt.resolvedUrl("../assets/sounds/double.wav"); volume: root.soundVolume }

    // The keyboard: ten separate key strikes cut out of the supplied typing
    // recording (onset-detected, 150ms each, peak-normalised). A sentence picks
    // them at random, so it never sounds like one clip on repeat - and a single
    // 20s file never has to be seeked while you type.
    SoundEffect { id: sndT1;  source: Qt.resolvedUrl("../assets/sounds/type1.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT2;  source: Qt.resolvedUrl("../assets/sounds/type2.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT3;  source: Qt.resolvedUrl("../assets/sounds/type3.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT4;  source: Qt.resolvedUrl("../assets/sounds/type4.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT5;  source: Qt.resolvedUrl("../assets/sounds/type5.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT6;  source: Qt.resolvedUrl("../assets/sounds/type6.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT7;  source: Qt.resolvedUrl("../assets/sounds/type7.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT8;  source: Qt.resolvedUrl("../assets/sounds/type8.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT9;  source: Qt.resolvedUrl("../assets/sounds/type9.wav");  volume: root.soundVolume }
    SoundEffect { id: sndT10; source: Qt.resolvedUrl("../assets/sounds/type10.wav"); volume: root.soundVolume }
    readonly property var typingVoices: [sndT1, sndT2, sndT3, sndT4, sndT5, sndT6, sndT7, sndT8, sndT9, sndT10]

    function playPack(pack) {
        var s = pack === "double" ? sndDouble
              : (pack === "tap" || pack === "click") ? sndTap : null;
        if (!s) return;
        s.volume = root.soundVolume;
        s.play();
    }
    // one strike per keystroke, a little quieter than a button so a sentence
    // does not shout over the music
    function typeKey() {
        if (!root.typingOn || root.soundPack === "off") return;
        var v = root.typingVoices[Math.floor(Math.random() * root.typingVoices.length)];
        if (!v) return;
        v.volume = root.soundVolume * 0.62;
        v.play();
    }
    function playTap() {
        // sound is a preference of its own: turning the room's motion down used
        // to silence every tap with it, which felt like broken audio
        if (root.soundPack === "off" || root.soundPack === "") return;
        root.playPack(root.soundPack);
    }
    function dyeAt(x, y, a, b) {
        if (!root.motionEnabled || root.motionStyle === "minimal") return;
        root.dyeOrigin = Qt.vector2d(Math.max(0.03, Math.min(0.97, x)), Math.max(0.03, Math.min(0.97, y)));
        root.dyeSeed = Math.random() * 12.0;
        root.dyeInkA = a || root.tc.accent;
        root.dyeInkB = b || root.tc.bg;
        dyeAnim.restart();
    }
    function applyMotion() {
        var m = (root.appearance || {}).motion || {};
        root.motionEnabled = m.enabled !== false;
        root.motionSpeed = Math.max(0.4, Math.min(2.0, (m.speed !== undefined ? m.speed : 1.0)));
        root.motionStyle = m.style || "smooth";
        root.soundPack = m.sound || "tap";
        // a store that still names a removed voice falls back to the single tap
        if (root.soundPack !== "double" && root.soundPack !== "off") root.soundPack = "tap";
        root.typingOn = m.typing !== false;
        root.soundVolume = (m.volume !== undefined) ? Math.max(0, Math.min(1, m.volume)) : 0.35;
        var mn = (root.appearance || {}).mini || {};
        root.miniBackdrop = mn.bg === "song" ? "song" : "theme";
    }

    NumberAnimation { id: bloomAnim; target: root; property: "trBloom"; from: 1; to: 0; duration: 820; easing.type: Easing.OutCubic }
    NumberAnimation { id: pageNameAnim; target: root; property: "pageNameShift"; from: 1; to: 0; duration: 460; easing.type: Easing.OutQuint }
    Connections { target: root; function onCurrentPageChanged() { pageNameAnim.restart(); } }
    NumberAnimation { id: navGlow; target: root; property: "navGlowAmt"; from: 1; to: 0; duration: 900; easing.type: Easing.OutCubic }

    // ---------------- change of world ----------------
    // A palette, a backdrop and a 3D scene cannot be interpolated: they are
    // different worlds. So the change is hidden in plain sight - the outgoing
    // room's colour washes over the window for a beat, the new scene rises
    // from the dark underneath it, and the two settle together.
    property real worldFade: 1
    property real curtainAmt: 0
    property color curtainCol: "#05060a"
    // Both legs are animated. Writing worldFade = 0 in one assignment left a
    // single frame with no room in it - on a bright palette that frame is a
    // flash, and it is the "jump" a world change used to have. The dip never
    // reaches nothing now: 0.18 always keeps the room's own colour under the
    // page, so the swap reads as a breath rather than a cut.
    SequentialAnimation {
        id: worldSwap
        NumberAnimation { id: worldDip; target: root; property: "worldFade"
                          to: 0.18; easing.type: Easing.InOutQuad }
        NumberAnimation { id: worldLift; target: root; property: "worldFade"
                          to: 1.0; easing.type: Easing.OutCubic }
    }
    // The old room's colour is laid over the page and lifted again - but it
    // rises over 150ms first. Snapping it to 0.62 was a dark slap across the
    // whole window on every theme change.
    SequentialAnimation {
        id: curtainBeat
        NumberAnimation { id: curtainIn; target: root; property: "curtainAmt"
                          to: 0.34; easing.type: Easing.OutQuad }
        NumberAnimation { id: curtainOut; target: root; property: "curtainAmt"
                          to: 0.0; easing.type: Easing.InOutCubic }
    }
    function dissolveWorld(oldBg) {
        // walking between pages already carries the eye: the world only dips
        // and comes back, with no wash laid over the page at all
        var pageMove = root.leavingPage !== -1;
        root.curtainCol = oldBg || "#05060a";
        worldDip.duration = pageMove ? 150 : 230;
        worldLift.duration = pageMove ? 520 : 760;
        if (pageMove) {
            curtainBeat.stop();
            root.curtainAmt = 0;
        } else {
            curtainIn.duration = 150;
            curtainOut.duration = 620;
            curtainBeat.restart();
        }
        worldSwap.restart();
    }

    // Every scrubber asks the room for one thing: move the song here, and move
    // the line here in the same breath. Writing only to the server left the
    // drawn line on the old anchor until the next poll arrived, so the bar sat
    // still for up to 200 ms after a seek and then jumped.
    function seekTo(ms) {
        var dur = root.s.duration_ms > 0 ? root.s.duration_ms : ms;
        var t = Math.max(0, Math.min(dur, ms));
        root.anchorPos = t;
        root.anchorAt = Date.now();
        root.posMs = t;
        root.hit("/seek?ms=" + Math.round(t));
    }
    function gotoPage(i) {
        if (i === currentPage) {
            // pressing the room you are already in takes you out one level:
            // the open playlist steps back to the shelf
            if (i === 0 && root.plOpen) root.closePlaylist();
            return;
        }
        root.navDir = i > currentPage ? 1 : -1;
        leavingPage = currentPage;
        currentPage = i;
        // the drop lands where the room lives in the rail, then spreads. The
        // ink is the accent pulled most of the way back to the room colour: a
        // full-strength accent here is a flood, not a drop.
        root.dyeAt(0.12 + i * 0.125, 0.90, root.mixColor(th.accent, th.bg, 0.5), th.bg);
        // each tab can wear its own world: swap the theme and wallpaper with
        // the page, so walking between rooms is a real change of place
        root.refreshLook();
        hit("/page?n=" + i);
        enterStamp = pageClock;
        pageExit = 1;
        hideTimer.interval = root.trDur() + 160;
        hideTimer.restart();
        // 3D depth lean: the world leans away as the page swings in. The
        // impulse has to be animated - writing 1 in a single frame moved the
        // camera 26 world units between two presents, which is what made the
        // background flinch. This lean is small and eases both ways.
        kickLean.restart();
        navGlow.restart();
        // accent sweep line for print/glitch style themes
        if (["glitch", "offset", "wipe", "ripple"].indexOf(trActive()) >= 0) {
            trSweep.x = -root.width;
            trSweep.visible = true;
            sweepAnim.restart();
        }
        pageTransition.restart();
        // one breadcrumb per room change: this used to throw before it got
        // here, and nothing in the app's own logs showed it
        hit("/frame?d=NAV" + i);
        root.trBloom = 1;
        bloomAnim.restart();
        if (i === 3) fetchJson("/queue", function(d) { queueData = d; });
        if (i === 4) loadThemeCards();
        if (i === 6) fetchEq();
        if (i === 5) { fetchJson("/engine", function(e) { root.engine = e; }); fetchJson("/stats", function(st) { root.playStats = st; }); }
        if (root.convertStatus.running || i === 0) fetchJson("/convert/status", function(c) { root.convertStatus = c; });
    }
    // one keystroke per room: the pointer can stay on the music
    Shortcut { sequence: "Ctrl+1"; onActivated: root.gotoPage(0) }
    Shortcut { sequence: "Ctrl+2"; onActivated: root.gotoPage(1) }
    Shortcut { sequence: "Ctrl+3"; onActivated: root.gotoPage(2) }
    Shortcut { sequence: "Ctrl+4"; onActivated: root.gotoPage(3) }
    Shortcut { sequence: "Ctrl+5"; onActivated: root.gotoPage(4) }
    Shortcut { sequence: "Ctrl+6"; onActivated: root.gotoPage(5) }
    Shortcut { sequence: "Ctrl+7"; onActivated: root.gotoPage(6) }
    Shortcut { sequence: "Ctrl+Tab"; onActivated: root.gotoPage((root.currentPage + 1) % 7) }
    Shortcut { sequence: "Ctrl+B"; onActivated: root.openBrowse() }

    function applyBg3d() {
        if (!bg3d.item) return;
        bg3d.item.pal = root.tc;
        var cfg = root.tc.bg3d || {};
        bg3d.item.cfg = cfg;
        bg3d.item.archetype = cfg.archetype ? cfg.archetype : "bubbles";
        bg3d.item.speed = cfg.speed ? cfg.speed : 1.0;
        bg3d.item.intensity = (cfg.intensity !== undefined) ? cfg.intensity : (root.tc.light ? 0.65 : 1.0);
        bg3d.item.flowDir = (cfg.dir !== undefined) ? cfg.dir : 1.0;
        bg3d.item.yaw = 0;
        bg3d.item.pitch = 0;
        bg3d.item.zoom = 1;
        bg3d.item.excite = 0;
    }
    // ---------- exploring a theme's 3D room ----------
    function orbitWorld(dx, dy) {
        if (!bg3d.item) return;
        bg3d.item.yaw = Math.max(-52, Math.min(52, bg3d.item.yaw + dx * 0.24));
        bg3d.item.pitch = Math.max(-15, Math.min(19, bg3d.item.pitch + dy * 0.12));
    }
    function zoomWorld(d) {
        if (!bg3d.item) return;
        bg3d.item.zoom = Math.max(0.68, Math.min(1.55, bg3d.item.zoom + d));
    }
    function resetWorld() {
        if (!bg3d.item) return;
        bg3d.item.yaw = 0;
        bg3d.item.pitch = 0;
        bg3d.item.zoom = 1;
    }
    function exciteWorld() {
        if (!bg3d.item) return;
        bg3d.item.excite = 1;
        worldPulse.restart();
    }
    NumberAnimation {
        id: worldPulse
        target: bg3d.item
        property: "excite"
        from: 1; to: 0
        duration: 1100
        easing.type: Easing.OutCubic
    }
    function enterThemeWorld() {
        root.themeWorldOpen = true;
        root.resetWorld();
        root.exciteWorld();
    }
    function leaveThemeWorld() {
        root.themeWorldOpen = false;
        root.resetWorld();
    }
    function toastNow(m) { syncToast.show(m); }
    function setTheme(id, label, quiet) {
        root.lookThemeId = id;
        if (!quiet) {
            root.themeSlug = id;
            root.baseThemeId = id;
        }
        // a tab's own theme is a preview: it must not rewrite the app's theme
        // every time you walk through a room, or the next launch forgets.
        var oldBg = (root.tc && root.tc.bg) ? root.tc.bg : "#05060a";
        fetchJson("/theme?name=" + id + (quiet ? "&preview=1" : ""), function(t) {
            if (!t || !t.bg) {
                // a tab can point at a theme file that was renamed or deleted;
                // fall back to the app theme instead of freezing in the old world
                if (quiet) {
                    var b = root.baseThemeId;
                    if (b && b !== id) { root.lookThemeId = b; root.setTheme(b, "", true); }
                }
                return;
            }
            var wasSame = root.tc && t.bg === root.tc.bg && t.accent === root.tc.accent;
            root.tc = t;
            root.applyBg3d();
            // ink follows the palette, including a tab's own world
            root.applyTypeColor();
            // a deliberate theme change dyes the room; a tab swap travels
            // with the page transition instead, so the two never double up
            if (!quiet && root.leavingPage === -1) root.dyeAt(0.5, 0.42, t.accent, t.bg);
            console.log("[ui-theme]", id, "page", root.currentPage, "base", root.baseThemeId,
                        "override", JSON.stringify(root.tabOverride(root.currentPage)));
            // same palette means a re-render, not a new room: no dissolve
            if (!wasSame) root.dissolveWorld(oldBg);
            if (!quiet) syncToast.show((label || t.name || id) + "  \u00b7  " + (t.scene || "new atmosphere"));
        });
    }

    // ---------------- appearance ----------------
    function lookFor(page) {
        var a = root.appearance || {};
        var g = a.backdrop || {};
        var t = (a.tabs || {})[("" + page)] || {};
        if (!t.enabled) return g;
        var out = {};
        for (var k in g) out[k] = g[k];
        for (var j in t) if (j !== "enabled" && j !== "theme") out[j] = t[j];
        return out;
    }
    function tabOverride(page) {
        return (root.appearance.tabs || {})[("" + page)] || ({ enabled: false, theme: "" });
    }
    function loadAppearance() {
        fetchJson("/appearance", function(a) {
            if (!a || typeof a !== "object") return;
            root.appearance = a;
            var lib = a.library || {};
            root.addMode = (lib.add_mode === "file") ? "file" : "stream";
            root.applyMotion();
            root.refreshLook();
        });
    }
    function patchAppearance(section, key, val) {
        var a = root.appearance || {};
        var next = {};
        for (var k in a) next[k] = a[k];
        var sec = {};
        var cur = a[section] || {};
        for (var j in cur) sec[j] = cur[j];
        sec[key] = val;
        next[section] = sec;
        root.appearance = next;
        // both sections are read by applyMotion (the sound preferences and the
        // collapsed window's floor), so both have to re-read the store at once
        if (section === "motion" || section === "mini") root.applyMotion();
        root.refreshLook();
        appearanceSave.restart();
    }
    function patchTab(page, key, val) {
        var a = root.appearance || {};
        var next = {};
        for (var k in a) next[k] = a[k];
        var tabs = {};
        for (var t in (a.tabs || {})) tabs[t] = a.tabs[t];
        var pageKey = "" + page;
        var cur = tabs[pageKey] || ({ enabled: false, theme: "" });
        var nt = {};
        for (var j in cur) nt[j] = cur[j];
        nt[key] = val;
        // touching any look control is the intent to wear it: turning the tab
        // on is implied, otherwise the picker looks broken until you hunt the
        // switch. an explicit `enabled` write is never overridden.
        if (key !== "enabled" && (key !== "theme" || ("" + val).length > 1)) nt.enabled = true;
        tabs[pageKey] = nt;
        next.tabs = tabs;
        root.appearance = next;
        root.refreshLook();
        appearanceSave.restart();
    }
    function patchLook(key, val, page) {
        if (page === undefined || page < 0) root.patchAppearance("backdrop", key, val);
        else root.patchTab(page, key, val);
    }
    function flushAppearance() {
        hit("/appearance/set?json=" + encodeURIComponent(JSON.stringify(root.appearance)));
    }
    Timer { id: appearanceSave; interval: 320; onTriggered: root.flushAppearance() }
    // the type colour rides the theme palette: a dark world gets a bright
    // chosen ink, and the dim tone is mixed towards it so both stay related
    function applyTypeColor() {
        var c = ((root.appearance.font || {}).color || "").trim();
        if (c.length >= 4) {
            th.text = c;
            th.dim = root.mixColor(root.tc.dim || c, c, 0.45);
        } else if (root.tc.text) {
            th.text = root.tc.text;
            // a room's secondary ink still has to be *read*: lift the dim tone
            // toward the primary ink instead of trusting the palette alone
            th.dim = root.mixColor(root.tc.dim || root.tc.text, root.tc.text, root.tc.light ? 0.10 : 0.38);
        }
    }
    function refreshLook() {
        root.effLook = root.lookFor(root.currentPage);
        root.applyTabTheme();
        root.applyTypeColor();
        if ((root.effLook.kind || "theme") === "youtube") {
            var u = root.effLook.source || "";
            if (u.length > 4 && (root.ytBackdrop.url !== u || (!root.ytBackdrop.running && !root.ytBackdrop.path)))
                root.prepareBackdrop(u);
        }
    }
    function applyTabTheme() {
        var t = root.tabOverride(root.currentPage);
        var want = (t.enabled && t.theme && t.theme.length > 2)
                   ? t.theme
                   : (root.baseThemeId || root.themeSlug);
        if (!want || want === root.lookThemeId) return;
        root.setTheme(want, "", true);
    }
    // remote art goes through the engine's disk cache: consistent, fast, and
    // independent of Qt's TLS plugins on this machine
    function art(u) {
        var x = "" + (u || "");
        if (x.indexOf("http://") === 0 || x.indexOf("https://") === 0)
            return "http://127.0.0.1:3690/thumb?u=" + encodeURIComponent(x);
        return x;
    }
    function backdropKind(look) {
        var k = (look && look.kind) ? look.kind : "theme";
        if (k === "youtube") return "video";
        if (k === "cover") return "cover";
        return k;
    }
    function backdropSource(look) {
        var k = (look && look.kind) ? look.kind : "theme";
        var src = ((look && look.source) ? look.source : "").trim();
        if (k === "cover") return root.nowCover();
        if (k === "youtube") {
            var p = (root.ytBackdrop.path || "").replace(/\\/g, "/");
            return p.length > 2 ? "file:///" + p : "";
        }
        if (k === "theme" || !src) return "";
        if (src.indexOf("file:") === 0) return src;
        if (src.charAt(1) === ":" || src.indexOf("\\\\\\\\") === 0) return "file:///" + src.replace(/\\/g, "/");
        if (src.indexOf("http") === 0) return root.art(src);
        return src;
    }
    function prepareBackdrop(url) {
        var u = (url || "").trim();
        if (u.length < 5) { syncToast.show("paste a link first"); return; }
        root.ytBackdrop = { running: true, path: "", error: "", url: u };
        hit("/backdrop/prepare?url=" + encodeURIComponent(u));
        backdropPoll.restart();
    }
    Timer {
        id: backdropPoll
        interval: 900; repeat: true
        running: root.ytBackdrop.running
        onTriggered: root.pollBackdrop()
    }
    function pollBackdrop() {
        fetchJson("/backdrop/status", function(d) {
            root.ytBackdrop = d;
            if (!d.running) {
                backdropPoll.stop();
                if ((d.path || "").length > 2) syncToast.show("backdrop ready");
                else if ((d.error || "").length > 1) syncToast.show("backdrop failed: " + d.error);
            }
        });
    }
    // ---------------- accounts ----------------
    function loadAccounts() {
        fetchJson("/accounts", function(d) { if (d && d.accounts) root.accountsData = d; });
    }
    function pushAccounts(next) {
        root.accountsData = next;
        hit("/accounts/save?json=" + encodeURIComponent(JSON.stringify({ accounts: next.accounts, next_id: 100 })));
    }
    function activateAccount(id) {
        var a = root.accountsData || {};
        var list = [];
        for (var i = 0; i < (a.accounts || []).length; i++) {
            var x = a.accounts[i];
            var copy = {};
            for (var k in x) copy[k] = x[k];
            copy.active = (copy.id === id);
            list.push(copy);
        }
        var next = {};
        for (var j in a) next[j] = a[j];
        next.accounts = list;
        next.active = id;
        root.pushAccounts(next);
        syncToast.show("listening as " + ((root.accountById(id) || {}).label || id));
    }
    function accountById(id) {
        var l = (root.accountsData || {}).accounts || [];
        for (var i = 0; i < l.length; i++) if (l[i].id === id) return l[i];
        return null;
    }
    function activeAccount() {
        var l = (root.accountsData || {}).accounts || [];
        for (var i = 0; i < l.length; i++) if (l[i].active) return l[i];
        return null;
    }
    function addAccount(label, cookies) {
        if (!label || !label.trim()) { syncToast.show("name the account"); return; }
        var a = root.accountsData || {};
        var list = [];
        for (var i = 0; i < (a.accounts || []).length; i++) list.push(a.accounts[i]);
        list.push({ id: "acc" + Date.now(), provider: "youtube", label: label.trim(),
                    cookies: cookies || "", active: false });
        var next = {};
        for (var j in a) next[j] = a[j];
        next.accounts = list;
        root.pushAccounts(next);
        root.newAccLabel = "";
        syncToast.show("account saved - press USE on it");
    }
    function removeAccount(id) {
        var a = root.accountsData || {};
        var src = a.accounts || [];
        var list = [];
        for (var i = 0; i < src.length; i++) if (src[i].id !== id) list.push(src[i]);
        if (list.length === 0) return;
        if (!list.some(function(x) { return x.active; })) list[0].active = true;
        var next = {};
        for (var j in a) next[j] = a[j];
        next.accounts = list;
        root.pushAccounts(next);
    }
    function testAccount() {
        syncToast.show("checking the session...");
        fetchJson("/accounts/test", function(r) {
            syncToast.show(r.ok ? ("session ok - " + r.detail) : ("session problem: " + r.detail));
        });
    }
    function signIn(provider) {
        if (provider === "spotify") {
            // spotify's desktop session is a librespot grant, not a web login
            hit("/oauth/start");
            syncToast.show("browser opened - complete the spotify login, then restart the app");
            return;
        }
        hit("/accounts/signin?provider=" + provider);
        syncToast.show("browser opened - sign in, then add the browser session below");
    }
    // ---------------- studio plumbing ----------------
    function studioLook() {
        var p = root.studio.page;
        return (p >= 0) ? root.lookFor(p) : ((root.appearance || {}).backdrop || ({}));
    }
    function lookVal(key, dflt) {
        var v = root.studioLook()[key];
        if (v === undefined || v === null) return dflt;
        return v;
    }
    function loadPhone() {
        fetchJson("/phone", function(d) {
            if (!d) return;
            root.phoneOpen = d.open !== false;
            root.phoneURL = d.url || "";
        });
    }
    function setPhone(on) {
        // flip the switch at once: the answer is one round trip away and a
        // control that waits for the network feels broken
        root.phoneOpen = on;
        root.phoneURL = root.phoneURL || "";
        hit("/phone?on=" + (on ? "1" : "0"));
    }
    function openStudio(tab) {
        root.studioOpen = true;
        if (tab !== undefined && tab >= 0) root.studioTab = tab;
        if (tab === 2) root.loadAccounts();
        root.loadPhone();
        // the panel is a change of surface, not a dialog: it gets the same
        // ink-in-water arrival as a room
        root.dyeAt(0.16, 0.28);
        studioPanel.show();
    }
    function closeStudio() {
        root.studioOpen = false;
        root.dyeAt(0.5, 0.45);
        studioPanel.hide();
    }
    // pick the tab being edited. this used to jump the app to that page under
    // the studio overlay, which made the studio look like it had closed.
    function studioSelectPage(p) {
        // the panel reads this through bindings, and a JS object kept in a var
        // property does not notify on a member write: assigning the whole object
        // is what makes the chip, the picker and every slider follow the choice
        root.studio = { page: p };
        root.refreshLook();
    }
    function studioVisitPage(p) {
        if (p < 0) return;
        root.closeStudio();
        root.gotoPage(p);
    }
    function studioSet(key, val) {
        root.patchLook(key, val, root.studio.page);
    }
    function openFind() { findPanel.show(); }
    function closeFind() { findPanel.hide(); }
    // ---------------- one search over every source ----------------
    function runSearch(q) {
        var s = (q || "").trim();
        var seq = ++root.findSeq;
        findGuard.restart();
        if (s.length === 0) { root.findRows = []; root.findBusy = false; return; }
        root.findBusy = true;
        root.findError = "";
        root.findRows = [];
        root.findCounts = ({ youtube: 0, soundcloud: 0, spotify: 0 });
        var sources = root.findSrc === "all" ? ["youtube", "soundcloud", "spotify"] : [root.findSrc];
        var pending = sources.length;
        for (var i = 0; i < sources.length; i++) {
            (function(src) {
                fetchJson("/sources/search?src=" + src + "&q=" + encodeURIComponent(s), function(d) {
                    // a later search invalidates this answer
                    if (seq !== root.findSeq) return;
                    var rows = d.results || [];
                    root.findCounts[src] = rows.length;
                    root.findCounts = root.findCounts;
                    for (var j = 0; j < rows.length; j++) {
                        var r = rows[j];
                        r.source = r.source || src;
                    }
                    // sources land as they answer: youtube should not wait for a
                    // throttled spotify before showing what it found
                    if (rows.length > 0) root.findRows = root.findRows.concat(rows);
                    if (d.error) root.findError = d.error;
                    pending--;
                    if (pending <= 0) root.findBusy = false;
                });
            })(sources[i]);
        }
        if (sources.length === 0) { root.findBusy = false; }
    }
    Timer { id: findGuard; interval: 14000; onTriggered: root.findBusy = false }
    function useResult(row) {
        if (!row) return;
        if (row.source === "spotify") {
            fetchJson("/playlist/add_spotify?url=" + encodeURIComponent(row.uri || row.url), function(r) {
                if (r.ok) { root.lastLibVer = -1; hit("/play?id=" + r.id); syncToast.show("playing " + row.title); }
                else syncToast.show(r.error || "could not add that track");
            });
            return;
        }
        hit("/youtube/add?url=" + encodeURIComponent(row.url) + "&play=1");
        syncToast.show("fetching " + row.title + " - it will play when it lands");
    }
    function importResult(row) {
        if (!row) return;
        if (row.source === "spotify") {
            fetchJson("/playlist/add_spotify?url=" + encodeURIComponent(row.uri || row.url), function(r) {
                syncToast.show(r.ok ? "added to this playlist" : (r.error || "add failed"));
                if (r.ok) root.lastLibVer = -1;
            });
            return;
        }
        hit("/youtube/add?url=" + encodeURIComponent(row.url));
        syncToast.show("adding " + row.title);
    }
    // ---------- command palette ----------
    function openPalette() { root.palOpen = true; }
    function closePalette() {
        root.palOpen = false;
        keyCatcher.forceActiveFocus();
    }
    function buildPalette() {
        var q = root.palQ.trim().toLowerCase();
        var out = [];
        function match(t) { return q.length === 0 || ("" + (t || "")).toLowerCase().indexOf(q) >= 0; }
        function push(kind, label, sub, extra) {
            var r = { kind: kind, label: label, sub: sub };
            if (extra) { for (var k in extra) r[k] = extra[k]; }
            out.push(r);
        }
        // while typing, songs come first: that is what the hand reaches for
        if (q.length > 0) {
            var src = root.lib.tracks || [];
            var hits = 0;
            for (var i = 0; i < src.length && hits < 8; i++) {
                var t = src[i];
                if (!match(t.title) && !match(t.artist)) continue;
                push("track", t.title, (t.artist || "") + "  ·  " + (t.origin === "local" ? "local file" : "playlist"), { id: t.id });
                hits++;
            }
            var ths = root.themeCards || [];
            var ht = 0;
            for (var j = 0; j < ths.length && ht < 5; j++) {
                if (!match(ths[j].name)) continue;
                push("theme", ths[j].name, "theme  ·  " + (ths[j].scene || "a room"), { id: ths[j].id });
                ht++;
            }
        }
        var pages = [
            { n: 5, t: "Home", s: "now playing" },
            { n: 0, t: "Playlist", s: "the synced catalog" },
            { n: 1, t: "Local vault", s: "files on this machine" },
            { n: 2, t: "Vibe", s: "stage and lyrics" },
            { n: 3, t: "Queue", s: "what comes next" },
            { n: 4, t: "Themes", s: "twenty rooms" },
            { n: 6, t: "Settings", s: "engine and surface" }
        ];
        for (var pg = 0; pg < pages.length; pg++) {
            if (match(pages[pg].t) || match(pages[pg].s)) push("go", pages[pg].t, "go  ·  " + pages[pg].s, { n: pages[pg].n });
        }
        var acts = [
            { l: "Play / pause", s: "transport", c: "/toggle" },
            { l: "Next track", s: "transport", c: "/next" },
            { l: "Previous track", s: "transport", c: "/prev" },
            { l: "Shuffle", s: root.s.shuffle ? "currently on" : "currently off", c: "/shuffle?s=" + (root.s.shuffle ? 0 : 1) },
            { l: "Repeat", s: "currently " + ["off", "all", "one"][root.s.repeat], c: "/repeat?r=" + ((root.s.repeat + 1) % 3) },
            { l: "Mute / unmute", s: "air", c: "/volume?v=" + (root.s.volume > 0 ? 0 : 70) }
        ];
        for (var k = 0; k < acts.length; k++) {
            if (match(acts[k].l)) push("cmd", acts[k].l, "do  ·  " + acts[k].s, { cmd: acts[k].c });
        }
        if (match("Add music")) push("special", "Add music", "youtube, local files, a link", { code: "sheet" });
        if (match("Find songs")) push("special", "Find songs", "youtube  ·  soundcloud  ·  spotify", { code: "find" });
        if (match("Studio") || match("appearance")) push("special", "Studio", "type, wallpaper, a world per tab", { code: "studio" });
        if (match("Accounts")) push("special", "Accounts", "youtube sessions and the spotify link", { code: "accounts" });
        if (match("Now playing")) push("special", "Now playing", "the full screen stage", { code: "np" });
        if (match("Sleep 30")) push("special", "Sleep in 30 minutes", "fade out, then stop", { n: 30 });
        if (match("Sleep 60")) push("special", "Sleep in 60 minutes", "fade out, then stop", { n: 60 });
        if (root.sleepMins > 0 && match("Clear sleep")) push("special", "Clear the sleep timer", "keep the room awake", { n: 0 });
        return out;
    }
    function palRun(r) {
        if (!r) { root.closePalette(); return; }
        if (r.kind === "go") root.gotoPage(r.n);
        else if (r.kind === "track") { root.hit("/play?id=" + r.id); }
        else if (r.kind === "theme") { root.setTheme(r.id, r.label); root.exciteWorld(); }
        else if (r.kind === "cmd") root.hit(r.cmd);
        else if (r.kind === "special") {
            if (r.code === "sheet") addSheet.open();
            else if (r.code === "find") root.openFind();
            else if (r.code === "studio") root.openStudio(0);
            else if (r.code === "accounts") root.openStudio(3);
            else if (r.code === "np") np.open();
            else if (r.n !== undefined) root.setSleep(r.n);
        }
        root.closePalette();
    }
    // ---------- sleep: a fade, not a guillotine ----------
    // The engine owns the ramp now (see state::sleep_start): the last 20 s of
    // the wait dim the output inside the device callback, then the deck pauses
    // and the volume is restored. The ui only carries the countdown, so nothing
    // fights over /volume.
    function setSleep(mins) {
        root.sleepMins = mins;
        root.sleepDeadline = 0;
        root.sleepLastVol = -1;
        root.hit(mins <= 0 ? "/sleep?s=0" : "/sleep?m=" + mins);
        root.toastNow(mins <= 0 ? "sleep timer cleared" : ("the room dims in " + mins + " minutes"));
    }
    function fmtSleep() {
        var ms = root.s.sleep_ms || 0;
        if (ms <= 0) return "";
        var m = Math.floor(ms / 60000);
        var sec = Math.floor((ms % 60000) / 1000);
        return m > 0 ? (m + ":" + (sec < 10 ? "0" : "") + sec) : (sec + "s");
    }
    function toggleHotkeys() {
        var on = !root.s.hotkeys;
        root.fetchJson("/config?k=hotkeys&v=" + (on ? "1" : "0"), function() {
            root.s.hotkeys = on;
            syncToast.show(on ? "global keys on: ctrl+alt+space, arrows" : "global keys off");
        });
    }
    function fetchExts() {
        fetchJson("/extensions", function(d) { exts = d.extensions || []; });
    }
    function loadPlaylists() {
        fetchJson("/playlists", function(d) {
            playlistRows = d.playlists || [];
            activePlaylistFile = d.active || "";
        });
    }
    function switchPlaylist(file, quiet) {
        fetchJson("/playlist/switch?id=" + encodeURIComponent(file), function(r) {
            if (r.ok) {
                if (!quiet) syncToast.show("switched to " + r.name);
                root.lastLibVer = -1;
                root.newPlOpen = false;
                root.loadPlaylists();
                addSheet.close();
            } else {
                syncToast.show(r.error || "could not switch playlist");
            }
        });
    }
    // shelf -> list: the room opens while the card is still leaving, and the
    // change of depth is carried by the same dye the rooms use
    function openPlaylist(file) {
        root.plOpen = true;
        root.shelfCreating = false;
        root.dyeAt(0.26, 0.38);
        root.switchPlaylist(file, true);
    }
    function closePlaylist() {
        root.plOpen = false;
        root.dyeAt(0.22, 0.34);
        root.loadPlaylists();
    }
    function removeTrackFromPlaylist(trk) {
        if (!trk) return;
        fetchJson("/playlist/remove?id=" + trk.id, function(r) {
            if (r.ok) {
                syncToast.show("removed " + trk.title);
                root.lastLibVer = -1;
                root.loadPlaylists();
            } else {
                syncToast.show(r.error || "could not remove that song");
            }
        });
    }
    function renamePlaylist(file, name) {
        var n = ("" + name).trim();
        if (!n) { syncToast.show("a room needs a name"); return; }
        fetchJson("/playlist/rename?id=" + encodeURIComponent(file) + "&name=" + encodeURIComponent(n), function(r) {
            if (r.ok) {
                syncToast.show("renamed to " + n);
                root.loadPlaylists();
            } else {
                syncToast.show(r.error || "could not rename that room");
                root.loadPlaylists();
            }
        });
    }
    function retirePlaylist(file, name) {
        fetchJson("/playlist/retire?id=" + encodeURIComponent(file), function(r) {
            if (r.ok) {
                syncToast.show("moved \"" + root.readable(name) + "\" to library/backups");
                root.loadPlaylists();
            } else {
                syncToast.show(r.error || "could not remove that room");
            }
        });
    }
    function createPlaylist(name) {
        if (!name || !name.trim()) { syncToast.show("give the playlist a name"); return; }
        fetchJson("/playlist/new?name=" + encodeURIComponent(name.trim()), function(r) {
            if (r.ok) {
                syncToast.show("created " + r.name);
                root.lastLibVer = -1;
                root.newPlOpen = false;
                root.newPlName = "";
                root.shelfCreating = false;
                root.loadPlaylists();
                root.plOpen = true;
            } else {
                syncToast.show(r.error || "could not create playlist");
            }
        });
    }
    // The add sheet is not a youtube sheet: soundcloud is downloaded by the
    // exact same yt-dlp path, so one query goes to both and the rows merge as
    // they answer. A soundcloud-only track is a first-class playlist song.
    function searchYoutube(q) {
        if (!q || !q.trim()) return;
        var needle = q.trim();
        var seq = ++root.ytSeq;
        root.ytSearching = true;
        root.ytResults = [];
        var srcs = ["youtube", "soundcloud"];
        var pending = srcs.length;
        for (var i = 0; i < srcs.length; i++) {
            (function(src) {
                fetchJson("/sources/search?src=" + src + "&q=" + encodeURIComponent(needle), function(d) {
                    if (seq !== root.ytSeq) return;
                    var rows = (d && d.results) ? d.results : [];
                    for (var j = 0; j < rows.length; j++)
                        if (!rows[j].source) rows[j].source = src;
                    if (rows.length > 0) root.ytResults = root.ytResults.concat(rows);
                    pending--;
                    if (pending <= 0) root.ytSearching = false;
                    if (d && d.error) syncToast.show(d.error);
                });
            })(srcs[i]);
        }
    }
    function addYoutube(url) {
        if (!url) return;
        if (root.ytState(url) === "queued") { syncToast.show("already in the queue"); return; }
        root.setYtState(url, "queued");
        syncToast.show(root.addMode === "file" ? "queued for download" : "adding as a stream");
        fetchJson("/youtube/add?url=" + encodeURIComponent(url) + "&mode=" + root.addMode, function(r) {
            if (!r.ok) {
                root.setYtState(url, "");
                syncToast.show(r.error || "could not add that song");
            }
        });
    }
    function setAddMode(m) {
        root.addMode = m;
        root.patchAppearance("library", "add_mode", m);
    }
    function addLink(raw) {
        var s = (raw || "").trim();
        if (s.length < 5) { syncToast.show("paste a link first"); return; }
        if (s.indexOf("youtube.com") >= 0 || s.indexOf("youtu.be") >= 0) {
            root.addYoutube(s);
        } else if (s.indexOf("soundcloud.com") >= 0) {
            // soundcloud was falling through to the local-path branch below
            // (it contains slashes), so pasting a track link always failed
            root.addYoutube(s);
        } else if (s.indexOf("spotify.com") >= 0 || s.indexOf("spotify:track:") === 0) {
            fetchJson("/playlist/add_spotify?url=" + encodeURIComponent(s), function(r) {
                syncToast.show(r.ok ? "added to this playlist" : (r.error || "add failed"));
                if (r.ok) root.lastLibVer = -1;
            });
        } else if (s.indexOf(":\\") > 0 || s.indexOf("/") >= 0) {
            fetchJson("/playlist/add_local?path=" + encodeURIComponent(s), function(r) {
                syncToast.show(r.ok ? "local song added" : (r.error || "add failed"));
                if (r.ok) root.lastLibVer = -1;
            });
        } else {
            root.searchYoutube(s);
        }
    }
    function openCtx(trk, gx, gy) {
        if (!trk || trk.id === undefined) return;
        root.ctxTrack = trk;
        root.ctxMode = 0;
        root.ctxIsLocal = trk.origin === "local";
        root.ctxX = Math.min(Math.max(10, gx), root.width - 226);
        root.ctxY = Math.min(Math.max(56, gy), root.height - 246);
        root.ctxOpenState = true;
    }
    function closeCtx() { root.ctxOpenState = false; root.ctxTrack = null; root.ctxMode = 0; }
    // what a song can do depends on where it is standing: a playlist row can
    // also leave the list it belongs to
    function ctxActions() {
        var t = root.ctxTrack;
        var a = [
            { id: "play", label: "PLAY NOW", mark: "play" },
            { id: "next", label: "PLAY NEXT", mark: "next" },
            { id: "queue", label: "ADD TO QUEUE", mark: "list" },
            { id: "addpl", label: "ADD TO PLAYLIST", mark: "cloud" },
            { id: "lyrics", label: "LYRICS + SYNC", mark: "wave" },
            { id: "like", label: (t && t.liked) ? "REMOVE FROM LIKED" : "LIKE THIS SONG", mark: "heart" },
            { id: "info", label: "TRACK INFO", mark: "info" }
        ];
        if (t && t.web && !t.playable) {
            a.push({ id: "save", label: "SAVE FOR OFFLINE", mark: "download" });
        }
        if (t && t && t.playable) {
            a.push({ id: "reveal", label: "SHOW IN FOLDER", mark: "folder" });
        }
        if (t && t.origin === "playlist") {
            a.push({ id: "remove", label: "REMOVE FROM PLAYLIST", mark: "trash" });
        }
        return a;
    }
    function ctxAppend(plId) {
        var trk = root.ctxTrack;
        if (!trk) return;
        fetchJson("/playlist/append?pl=" + encodeURIComponent(plId) + "&id=" + trk.id, function(r) {
            if (r.ok) syncToast.show(r.duplicate ? "already in that playlist" : ("added to playlist (" + r.total + " songs)"));
            else syncToast.show(r.error || "could not add");
            if (r.ok) { root.lastLibVer = -1; root.loadPlaylists(); }
        });
        root.closeCtx();
    }
    function refreshAddState() {
        fetchJson("/youtube/status", function(d) {
            var was = root.ytAddState;
            var before = (d.done || 0) + (d.failed || 0);
            var prev = (was.done || 0) + (was.failed || 0);
            root.ytAddState = d;
            // every finished item refreshes the rooms, not just the last one
            if (before !== prev) {
                root.lastLibVer = -1;
                root.loadPlaylists();
                if (d.last_title && d.last_title.length > 0 && (d.done || 0) > (was.done || 0)) {
                    syncToast.show("added " + d.last_title);
                } else if (d.last_error && d.last_error.length > 0) {
                    syncToast.show("add failed: " + d.last_error);
                }
            }
            if (was.running && !d.running) {
                root.clearYtPending();
                root.lastLibVer = -1;
                root.loadPlaylists();
            }
        });
    }
    function loadThemeCards() {
        fetchJson("/themes", function(d) {
            var names = d.themes || [];
            var cards = [];
            var done = 0;
            for (var i = 0; i < names.length; i++) {
                fetchJson("/theme?name=" + names[i] + "&preview=1", (function(nm) {
                    return function(body) {
                        cards.push({ id: nm, name: body.name || nm, accent: body.accent, bar: body.bar,
                                     accent2: body.accent2 || body.bar, glow: body.glow || body.accent,
                                     bg: body.bg, panel: body.panel || body.bg, text: body.text,
                                     dim: body.dim || body.text, light: body.light === true,
                                     anim: body.anim || "", tag: body.tag || "", line: body.line || "",
                                     mood: body.mood || body.line || "", signature: body.signature || body.anim || "",
                                     scene: body.scene || "", depth: body.depth || {}, transition: body.transition || {} });
                        done++;
                        if (done === names.length) {
                            cards.sort(function(a, b) { return (a.name || "").localeCompare(b.name || ""); });
                            themeCards = cards.slice();
                        }
                    };
                })(names[i]));
            }
        });
    }
    // per-song lyric calibration: nudge the words until they sit on the voice
    function nudgeLyrics(delta) {
        if (root.s.track_id === null) { syncToast.show("nothing is playing"); return; }
        var id = root.s.track_id;
        var cur = root.s.lyric_offset_ms || 0;
        var next = Math.max(-30000, Math.min(30000, cur + delta));
        root.s.lyric_offset_ms = next;
        root.hit("/lyricoffset?id=" + id + "&ms=" + next);
        syncToast.show("lyrics " + (next > 0 ? "+" : "") + next + " ms");
    }
    function fetchLyrics(id) {
        fetchJson("/lyrics?id=" + id, function(d) {
            var lines = [];
            var raw = (d.lyrics || "").split("\n");
            var synced = d.synced === true;
            // a file-wide [offset:+340] tag shifts every line; ignoring it was
            // one of the reasons whole songs sat consistently early or late
            var offset = 0;
            for (var oi = 0; oi < raw.length; oi++) {
                var om = raw[oi].match(/^\s*\[offset:\s*([+-]?\d+)\]/i);
                if (om) offset = parseInt(om[1], 10) || 0;
            }
            function stamp(txt) {
                var parts = txt.split(":");
                if (parts.length !== 2) return -1;
                var mm = parseInt(parts[0], 10);
                var ss = parseFloat(parts[1]);
                if (isNaN(mm) || isNaN(ss)) return -1;
                return mm * 60000 + Math.round(ss * 1000);
            }
            for (var i = 0; i < raw.length; i++) {
                var ln = raw[i];
                if (synced) {
                    // one line may carry several timestamps (repeated hooks)
                    var re = /\[(\d+:\d+(?:[.:]\d+)?)\]/g;
                    var m;
                    var stamps = [];
                    while ((m = re.exec(ln)) !== null) {
                        var t0 = stamp(m[1]);
                        if (t0 >= 0) stamps.push(t0);
                    }
                    if (stamps.length > 0) {
                        // enhanced LRC carries <mm:ss.xx> word marks inside the
                        // line: they are timing, not words
                        var text = ln.replace(/\[[^\]]*\]/g, "").replace(/<[^>]*>/g, "").trim();
                        if (text.length === 0) text = "\u266a";
                        for (var si = 0; si < stamps.length; si++) lines.push({ t: Math.max(0, stamps[si] + offset), text: text });
                        continue;
                    }
                    // metadata tags such as [ar:], [ti:], [offset:] are not lyrics
                    if (ln.charAt(0) === "[") continue;
                }
                if (ln.trim().length > 0) lines.push({ t: -1, text: ln.trim() });
            }
            if (synced) lines.sort(function(a, b) { return a.t - b.t; });
            // a line with no successor still needs a duration for the fill
            for (var li = 0; li < lines.length; li++) {
                if (lines[li].t < 0) continue;
                if (li + 1 < lines.length && lines[li + 1].t > lines[li].t) {
                    lines[li].d = lines[li + 1].t - lines[li].t;
                } else {
                    lines[li].d = 4200;
                }
            }
            lyricsData = { lines: lines, synced: synced };
            lyricLine = -1;
        });
    }

    // ---------------- data polling ----------------
    Timer {
        // 10 polls a second was chatty for a paused deck; while playing 5/s is
        // plenty because the clock between polls is interpolated locally
        // while minimized the mini bar still needs the song: one poll a second
        // is enough for that, and it keeps the shell from working in the tray
        interval: root.visibility === Window.Minimized ? 1000 : (root.s.playing ? 200 : 500)
        running: root.visible
        repeat: true
        onTriggered: {
            fetchJson("/state", function(d) {
                var old = s;
                var serverPos = d.position_ms || 0;
                var nowMs = Date.now();
                s = d;
                // reconcile instead of snapping: predicted position comes from
                // the anchor; a small drift is slewed out, a real seek is caught
                var predicted = root.anchorPos + (nowMs - root.anchorAt);
                var drift = serverPos - predicted;
                var restarted = (!old.playing && d.playing) || d.track_id !== old.track_id;
                // The engine reports its position in steps (a streamed track
                // gets a correction roughly once a second). Treating every step
                // as an error to erase made the scrubber stall between reports
                // and snap backwards when the next one landed - the jitter you
                // could watch on the progress line. The local clock is the thing
                // that is actually smooth, so it carries the line now: only a
                // real seek, a new track or a pause re-anchors it, and a small
                // lag is bled out a few milliseconds at a time.
                if (!d.playing || restarted || Math.abs(drift) > 2000) {
                    root.anchorPos = serverPos;
                    root.anchorAt = nowMs;
                    root.posMs = serverPos;
                } else if (drift > 40) {
                    root.anchorPos += Math.min(drift, 400) * 0.12;
                    root.anchorAt = nowMs;
                }
                root.lastServerPos = serverPos;
                // external page switches (CLI /page?n=): apply ONLY when the server's
                // page value itself changed since the last poll. The user's own clicks
                // keep server + client in sync via gotoPage's write-back, so this
                // must not fire on every tick or it would yank the user back.
                if (d.page !== undefined && d.page !== lastServerPage) {
                    lastServerPage = d.page;
                    if (d.page !== currentPage && d.page >= 0 && d.page <= 6 && leavingPage === -1) {
                        gotoPage(d.page);
                    }
                }
                if (d.library_version !== lastLibVer) {
                    lastLibVer = d.library_version;
                    fetchJson("/library", function(l) {
                        lib = l;
                        applyFilter();
                        root.loadPlaylists();
                    });
                }
                if (d.theme && d.theme !== root.themeSlug) {
                    root.themeSlug = d.theme;
                    root.baseThemeId = d.theme;
                    // a page that carries its own world keeps it: only the
                    // pages with no override follow the app theme
                    root.refreshLook();
                }
                var lv = d.levels || [];
                var lsum = 0;
                for (var li = 0; li < lv.length; li++) lsum += lv[li];
                root.brandPulse = Math.min(1, (lsum / Math.max(1, lv.length)) * 3.4);
                if (d.track_id !== null && d.track_id !== lastTrackId) {
                    lastTrackId = d.track_id;
                    fetchLyrics(d.track_id);
                    fetchJson("/lyricstyle?id=" + d.track_id, function(st) { root.lyricStyle = st; });
                }
                if (currentPage === 3) {
                    fetchJson("/queue", function(q) { queueData = q; });
                }
            });
        }
    }
    // The smoother runs on the frame clock now (frameProbe). Fast attack,
    // slow release, with every coefficient scaled by the real frame time so the
    // curve is identical at 60 or 120Hz - and the room's light follows the
    // audio at the same rate it is drawn, instead of a 60Hz light in a 120Hz
    // room.
    function smoothLevelsTick(dt) {
        {
            // the cascade clock is only live while a page is still arriving;
            // freezing it afterwards stops hundreds of row bindings recomputing
            if (root.pageClock - root.enterStamp < 6.0) root.pageClock += dt / 1000;
            if (!root.s.playing && root.bassLevel < 0.002) return;
            root.eqPhase = (root.eqPhase + dt * 0.000228) % (Math.PI * 2);
            var target = root.s.levels || [];
            var cur = root.rawLevels;
            var pk = root.rawPeaks;
            if (cur.length !== target.length) {
                cur = [];
                pk = [];
                for (var si = 0; si < target.length; si++) { cur.push(0); pk.push(0); }
            }
            // exponential coefficients converted from their per-tick value, so
            // the attack/release feel does not change with the frame rate
            var aUp = 1 - Math.pow(1 - 0.55, dt / 16);
            var aDn = 1 - Math.pow(1 - 0.10, dt / 16);
            var aPk = Math.pow(0.965, dt / 16);
            for (var i = 0; i < cur.length; i++) {
                var tv = target[i] || 0;
                var k = tv > cur[i] ? aUp : aDn;
                cur[i] = cur[i] + (tv - cur[i]) * k;
                // peak-hold: jump to the peak, decay slowly
                pk[i] = Math.max(cur[i], (pk[i] || 0) * aPk);
            }
            root.rawLevels = cur;
            root.rawPeaks = pk;
            // ---------------- display gain ----------------
            // The engine normalises each band against its own long-term peak.
            // That is honest data, but an ordinary master sits at 0.04-0.08 and
            // the ring then drew 32 identical nubs - which is exactly why the
            // equaliser read as a static ornament even while the song moved.
            // A slow auto-gain lifts what is DRAWN, not what is measured: quiet
            // masters become legible, loud ones keep headroom, and the meter can
            // never sit at zero for a song that is playing.
            var mx = 0;
            for (var g = 0; g < cur.length; g++) if (cur[g] > mx) mx = cur[g];
            var want = Math.min(5.0, 0.92 / Math.max(0.055, mx));
            // rises over about a second, falls back slower: a gain that pumps is
            // worse than a quiet meter
            root.eqGain += (want - root.eqGain) * (want > root.eqGain ? 0.022 : 0.010);
            var shown = [], shownPk = [];
            for (var h = 0; h < cur.length; h++) {
                shown.push(Math.min(1, cur[h] * root.eqGain));
                shownPk.push(Math.min(1, (pk[h] || 0) * root.eqGain));
            }
            root.smoothLevels = shown;
            root.smoothPeaks = shownPk;
            var bl = 0;
            for (var bj = 0; bj < 4 && bj < cur.length; bj++) bl += cur[bj] * root.eqGain;
            root.bassLevel = Math.min(1, bl / 2.2);
            if (bg3d.item) bg3d.item.audio = root.bassLevel;
        }
    }
    Timer {
        id: vizTimer
        interval: 33
        // a spectrum nobody can see is a fan spinning in an empty room: the
        // meter stops while the window is minimised or behind another app
        running: root.s.playing === true && root.visible
                 && root.visibility !== Window.Minimized && root.active
        repeat: true
        onTriggered: {
            // only the little spectrum needs its own paint clock: it is a
            // Canvas, and canvases rasterise on the GUI thread. everything
            // else reads the frame clock below.
            if (root.s.playing) miniViz.requestPaint();
        }
    }
    Timer { id: hideTimer; interval: 320; onTriggered: leavingPage = -1 }

    // One clock for the song. It used to be a 16 ms Timer, which on Windows
    // is a 15.6 ms timer: it fired in bursts, the lyric fill and the line
    // index were computed on different ticks, and both were sampled at a
    // different phase than the screen. Now the position is advanced by the
    // frame probe below - once, with the frame it will be drawn in - so the
    // scrubber, the ring, the fill and the active line can never disagree.
    function clockTick(dt) {
        if (root.s.playing && root.s.duration_ms > 0) {
            var p = root.anchorPos + (Date.now() - root.anchorAt);
            if (root.s.duration_ms > 0) p = Math.min(p, root.s.duration_ms);
            // One-way under a running clock. A late report from the engine can
            // pull the anchor back, but it can never drag the drawn position
            // backwards a frame: that single backward step is what the eye
            // reads as a stutter, even when it is only a few milliseconds.
            if (p < root.posMs) p = root.posMs;
            root.posMs = Math.max(0, p);
        }
        if (!lyricsData.synced || lyricsData.lines.length === 0) return;
        var pos = Math.max(0, root.posMs + (s.lyric_offset_ms !== undefined ? s.lyric_offset_ms : 0));
        var idx = -1;
        for (var i = 0; i < lyricsData.lines.length; i++) {
            if (lyricsData.lines[i].t >= 0 && lyricsData.lines[i].t <= pos) idx = i; else break;
        }
        // hysteresis: the clock is slewed toward the server every poll, so on
        // a line boundary it can step back a few milliseconds for one frame.
        // without this the line flickered and the column shuddered with it.
        // a real seek backwards is a whole jump, so only that may retreat.
        if (idx < lyricLine) {
            var cur = lyricsData.lines[lyricLine];
            var jumpedBack = cur && cur.t >= 0 && (cur.t - pos) > 1200;
            if (!jumpedBack) idx = lyricLine;
        }
        if (idx !== lyricLine) lyricLine = idx;
    }

    Component.onCompleted: {
        root.uiIn = 0;
        uiInAnim.start();
        fetchJson("/theme/current", function(t) {
            if (!t || !t.bg) return;
            tc = t;
            // the id, not the display name: "ink" is a file, "Ink" is a label.
            // storing the label made "go back to the app theme" fetch a theme
            // that does not exist, so a tab's world leaked into every room.
            var tid = t.id || t.name || "";
            root.themeSlug = tid;
            root.lookThemeId = tid;
            root.baseThemeId = tid;
            root.applyBg3d();
            // a tab with its own world overrides the base theme even on launch
            root.refreshLook();
        });
        fetchJson("/state", function(d0) {
            if (d0.theme) { root.themeSlug = d0.theme; root.baseThemeId = d0.theme; }
        });
        root.loadAppearance();
        root.loadAccounts();
        fetchExts();
        loadThemeCards();
        loadPlaylists();
    }
    Timer {
        interval: 900; running: addSheet.visible; repeat: true
        onTriggered: root.refreshAddState()
    }

    // ---------------- liquid glass surface ----------------
    component GlassSurface : Rectangle {
        id: gs
        property real corner: 24
        property real tintAlpha: 0.12
        property color tint: th.panel
        property real blurAmt: 0.86
        property int blurMax: 30
        property real saturation: 0.16
        property real sheen: 0.16
        property real haloAmt: 0
        property color haloCol: th.accent
        property real shadowAmt: 0.5
        radius: corner
        color: "transparent"

        RectangularShadow {
            anchors.fill: parent
            radius: gs.corner
            blur: 34
            spread: 2
            offset: Qt.vector2d(0, 12)
            color: root.rgba("#000000", tc.light ? 0.16 : gs.shadowAmt)
        }
        // the window's world, refracted through the pane
        MultiEffect {
            anchors.fill: parent
            source: glassCapture
            blurEnabled: true
            blur: gs.blurAmt
            blurMax: gs.blurMax
            saturation: gs.saturation
            maskEnabled: true
            maskSource: gsMask
        }
        Rectangle {
            anchors.fill: parent
            radius: gs.corner
            color: root.rgba(gs.tint, gs.tintAlpha * (tc.light ? 1.7 : 1) * 1.15)
            border.width: 0
        }
        // specular bloom, top-left
        Rectangle {
            anchors.fill: parent
            radius: gs.corner
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba("#ffffff", gs.sheen) }
                GradientStop { position: 0.36; color: root.rgba("#ffffff", gs.sheen * 0.24) }
                GradientStop { position: 1; color: root.rgba("#ffffff", 0) }
            }
            opacity: tc.light ? 0.6 : 1
        }
        // the top light is a breath, not a rule: it dissolves before it
        // reaches either edge, so a panel never reads as a boxed-off pane
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: 1
            height: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba("#ffffff", 0) }
                GradientStop { position: 0.22; color: root.rgba("#ffffff", tc.light ? 0.45 : 0.20) }
                GradientStop { position: 0.78; color: root.rgba("#ffffff", tc.light ? 0.45 : 0.20) }
                GradientStop { position: 1; color: root.rgba("#ffffff", 0) }
            }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.margins: 1
            height: Math.max(10, parent.height * 0.34)
            radius: gs.corner - 1
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(gs.haloCol, 0) }
                GradientStop { position: 1; color: root.rgba(gs.haloCol, gs.haloAmt) }
            }
        }
        Rectangle {
            id: gsMask
            visible: false
            layer.enabled: true
            anchors.fill: parent
            radius: gs.corner
            color: "white"
        }
    }

    // ---------------- world change ----------------
    // switching a theme is walking through a door, not swapping a palette:
    // one narrow band of the new world's light crosses the room while the
    // colours settle. nothing else moves, so the wipe never fights the UI.
    Item {
        id: themeWipe
        z: 30
        anchors.fill: parent
        enabled: false
        visible: root.themeFlash > 0.004
        opacity: Math.min(1, root.themeFlash)

        Rectangle {
            id: wipeBand
            width: parent.width * 0.26
            height: parent.height * 1.4
            y: -parent.height * 0.2
            rotation: 10
            x: -width + (parent.width + width * 2) * (1 - root.themeFlash)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba(th.accent, 0) }
                GradientStop { position: 0.42; color: root.rgba(th.accent, 0.07) }
                GradientStop { position: 0.5; color: root.rgba("#ffffff", 0.06) }
                GradientStop { position: 0.58; color: root.rgba(th.accent, 0.07) }
                GradientStop { position: 1; color: root.rgba(th.accent, 0) }
            }
        }
        Rectangle {
            anchors.fill: parent
            color: root.rgba(th.accent, 0.025)
        }
    }

    // ---------------- transparent titlebar ----------------
    // No bar, no capsule: the header floats directly on the room.
    Rectangle {
        id: topbar
        z: 20
        height: 58
        opacity: root.themeWorldOpen ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        radius: 0
        color: "transparent"

        // The header has no surface and no shade. A gradient still has a last
        // stop, and the last stop is a line: the only thing that belongs up
        // here is the type itself, held by its own outline.
        // no rule under the header: the title simply lives in the same air as
        // the page, separated by gravity instead of a line

        // There used to be a lit band here that swept the width of the bar on
        // every room change. On a dark room it read as a stray rule travelling
        // through the type, so the header now simply cross-fades its name and
        // leaves the light to the page.

        // drag surface + double-click maximize
        MouseArea {
            anchors.fill: parent
            onPressed: root.startSystemMove()
            onDoubleClicked: {
                if (root.visibility === Window.Maximized) root.showNormal();
                else root.showMaximized();
            }
        }

        // traffic lights (functional)
        Row {
            x: 20; y: parent.height / 2 - 6; spacing: 8
            Repeater {
                model: [{c:"#FF5F57", g:"\u00d7"},{c:"#FEBC2E", g:"\u2013"},{c:"#28C840", g:"+"}]
                delegate: Rectangle {
                    width: 12; height: 12; radius: 6
                    color: tlMa.containsMouse ? modelData.c : root.rgba(modelData.c, tc.light ? 0.62 : 0.5)
                    border.width: 1; border.color: root.rgba("#000000", 0.18)
                    Behavior on color { ColorAnimation { duration: 140 } }
                    Text {
                        anchors.centerIn: parent
                        text: modelData.g
                        color: root.rgba("#000000", 0.62)
                        font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true
                        visible: tlMa.containsMouse
                    }
                    MouseArea {
                        id: tlMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.playTap();
                            if (index === 0) root.close();
                            else if (index === 1) root.minimizeWindow();
                            else { if (root.visibility === Window.Maximized) root.showNormal(); else root.showMaximized(); }
                        }
                    }
                }
            }
        }

        // ---------------- the rooms live up here ----------------
        // Seven small marks in the header, on the room itself. There is no
        // column to pull out, so there is no column edge to see: the nav is
        // part of the same air as the type. The mark under the hand swells a
        // little and takes the accent; the active one keeps it.
        Row {
            id: navRow
            x: 82
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Repeater {
                model: [
                    { n: 5, k: "home",    t: "Home" },
                    { n: 0, k: "cloud",   t: "Playlist" },
                    { n: 1, k: "folder",  t: "Local" },
                    { n: 2, k: "wave",    t: "Vibe" },
                    { n: 3, k: "list",    t: "Queue" },
                    { n: 4, k: "palette", t: "Themes" },
                    { n: 6, k: "gear",    t: "Settings" }
                ]
                delegate: Item {
                    id: navDot
                    width: 31; height: 30
                    readonly property bool on: root.currentPage === modelData.n
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width - 3; height: parent.height - 4
                        radius: 10
                        color: root.rgba(th.accent, navDot.on ? 0.15 : (navMa.containsMouse ? 0.08 : 0))
                        Behavior on color { ColorAnimation { duration: 170 } }
                    }
                    NavIcon {
                        anchors.centerIn: parent
                        width: navDot.on ? 17 : 15; height: width
                        kind: modelData.k
                        col: navDot.on ? "" + th.accent : root.rgba(th.text, navMa.containsMouse ? 0.96 : 0.60)
                        Behavior on width { NumberAnimation { duration: 170; easing.type: Easing.OutBack } }
                    }
                    MouseArea {
                        id: navMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.playTap(); root.gotoPage(modelData.n) }
                    }
                }
            }
        }

        // Identity + current room, centred in the air that is actually free.
        // Anchoring this row to the middle of the window put "AetherMix · HOME"
        // under the CTRL K / WATCH pills the moment the bar got busy - the two
        // rows simply grew into each other. It is now measured off its two
        // neighbours, so it can never be drawn on top of either, and it steps
        // out of the way entirely when the gap is too narrow to hold it.
        Row {
            id: identityRow
            readonly property real freeLeft: navRow.x + navRow.width + 16
            readonly property real freeRight: rightCluster.x - 16
            readonly property real gap: freeRight - freeLeft
            // the window's middle when there is room for it, otherwise the
            // middle of whatever gap is left - never on top of a neighbour
            x: Math.max(freeLeft, Math.min((parent.width - width) / 2, freeRight - width))
            opacity: (width + 24) < gap ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            spacing: 9
            Item {
                width: 22; height: 22
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.centerIn: parent
                    width: 24; height: 24; radius: 8
                    color: th.accent
                    opacity: root.brandPulse * 0.18 + 0.04
                }
                Image {
                    source: Qt.resolvedUrl("../assets/icon.png")
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    smooth: true; mipmap: true
                    scale: 1 + root.brandPulse * 0.05
                    Behavior on scale { NumberAnimation { duration: 110 } }
                }
            }
            Text {
                text: "AetherMix"
                color: th.text
                font.family: root.tf; font.pixelSize: (12) * root.ts; font.bold: true; font.letterSpacing: 0.5
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                width: 3; height: 3; radius: 1.5
                color: root.rgba(th.dim, 0.6)
                anchors.verticalCenter: parent.verticalCenter
            }
            // the room's name: a box reserves its place in the row, and the
            // label drifts inside it. binding x on a Row child fought the
            // layout and parked the title on top of the logo.
            Item {
                width: Math.min(pageNameText.implicitWidth, 180)
                height: 16
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    id: pageNameText
                    width: parent.width
                    text: root.pageName()
                    color: root.rgba(th.dim, 0.95)
                    font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 1.8
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    x: (root.navDir || 1) * root.pageNameShift * 7
                    opacity: 1 - root.pageNameShift * 0.7
                }
            }
            // the material name used to sit here, and a long room title
            // pushed it under the search pill. the atmosphere is already
            // named at the far right of the bar, so the row stops at the room.
        }

        // right cluster: live state, clock, current atmosphere
        Row {
            id: rightCluster
            anchors.right: parent.right; anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            // the fastest way in: one pill, one keystroke
            Rectangle {
                id: palHint
                // below this width the two shortcut pills are the first thing
                // to go: they are hints, and the room needs the air more
                visible: root.width >= 1180
                width: palHintRow.width + 18; height: 21; radius: 10.5
                anchors.verticalCenter: parent.verticalCenter
                color: palHintMa.containsMouse ? root.rgba(th.accent, 0.16) : (tc.light ? "#12000000" : "#0effffff")
                border.width: 1
                border.color: palHintMa.containsMouse ? root.rgba(th.accent, 0.5) : (tc.light ? "#26000000" : "#1cffffff")
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                    id: palHintRow
                    anchors.centerIn: parent
                    spacing: 6
                    NavIcon { width: 11; height: 11; kind: "search"; col: palHintMa.containsMouse ? th.accent : root.rgba(th.dim, 0.9); anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        text: "CTRL K"
                        color: palHintMa.containsMouse ? th.accent : root.rgba(th.dim, 0.85)
                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: palHintMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.openPalette() }
                }
            }
            // one press reaches every source the app can play
            Rectangle {
                id: findHint
                visible: root.width >= 1180
                width: findHintRow.width + 18; height: 21; radius: 10.5
                anchors.verticalCenter: parent.verticalCenter
                color: findHintMa.containsMouse ? root.rgba(th.accent, 0.16) : (tc.light ? "#12000000" : "#0effffff")
                border.width: 1
                border.color: findHintMa.containsMouse ? root.rgba(th.accent, 0.5) : (tc.light ? "#26000000" : "#1cffffff")
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                    id: findHintRow
                    anchors.centerIn: parent
                    spacing: 6
                    NavIcon { width: 11; height: 11; kind: "search"; col: findHintMa.containsMouse ? th.accent : root.rgba(th.dim, 0.9); anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        text: "FIND"
                        color: findHintMa.containsMouse ? th.accent : root.rgba(th.dim, 0.85)
                        font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: findHintMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.openFind() }
                }
            }
            // a screen inside the room: play the video, never the ad
            Rectangle {
                width: watchHintLabel.width + 30; height: 21; radius: 10.5
                anchors.verticalCenter: parent.verticalCenter
                color: watchHintMa.containsMouse ? root.rgba(th.bar, 0.16) : (tc.light ? "#12000000" : "#0effffff")
                border.width: 1
                border.color: watchHintMa.containsMouse ? root.rgba(th.bar, 0.5) : (tc.light ? "#26000000" : "#1cffffff")
                Behavior on color { ColorAnimation { duration: 150 } }
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Rectangle {
                        width: 7; height: 7; radius: 3.5
                        color: watchHintMa.containsMouse ? th.bar : root.rgba(th.dim, 0.9)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        id: watchHintLabel
                        text: "WATCH"
                        color: watchHintMa.containsMouse ? th.bar : root.rgba(th.dim, 0.85)
                        font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                MouseArea {
                    id: watchHintMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // a film already in the slot reopens on the film, and the
                    // transport carries the way back to the browser; an empty
                    // slot opens the browser with the last query intact
                    onClicked: { root.playTap(); if (root.watch.path.length > 3) watchPanel.show(); else root.watchBrowse(); watchPanel.show(); }
                }
            }
            // the session that is listening, always one press from the switcher
            Rectangle {
                width: 21; height: 21; radius: 10.5
                anchors.verticalCenter: parent.verticalCenter
                color: accMa.containsMouse ? root.rgba(th.bar, 0.24) : root.rgba(th.bar, 0.12)
                border.width: 1
                border.color: root.rgba(th.bar, accMa.containsMouse ? 0.7 : 0.4)
                Behavior on color { ColorAnimation { duration: 150 } }
                Text {
                    anchors.centerIn: parent
                    text: {
                        var a = root.activeAccount();
                        return (a && a.label && a.label.length > 0) ? a.label.charAt(0).toUpperCase() : "A";
                    }
                    color: th.bar
                    font.pixelSize: (9) * root.ts; font.bold: true
                }
                MouseArea {
                    id: accMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.openStudio(3) }
                }
            }
            Rectangle {
                width: streamPillText.width + 18; height: 21; radius: 10.5
                anchors.verticalCenter: parent.verticalCenter
                color: s.streaming ? root.rgba(th.accent, 0.13) : (tc.light ? "#12000000" : "#0effffff")
                border.width: 1
                border.color: s.streaming ? root.rgba(th.accent, 0.5) : (tc.light ? "#26000000" : "#1cffffff")
                Row {
                    anchors.centerIn: parent; spacing: 5
                    Rectangle {
                        width: 6; height: 6; radius: 3
                        color: s.streaming ? th.accent : th.dim
                        anchors.verticalCenter: parent.verticalCenter
                        SequentialAnimation on opacity {
                            running: s.streaming
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 1100; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
                        }
                    }
                    Text { id: streamPillText; text: s.streaming ? "STREAM LIVE" : "LOCAL"; color: s.streaming ? th.accent : th.dim; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                }
            }
            // the room's pulse in the title bar: six bars, no canvas, no
            // repaint timer - the state poll already carries the levels
            Row {
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: 6
                    delegate: Item {
                        width: 2; height: 15
                        Rectangle {
                            width: parent.width
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 1
                            color: root.rgba(th.accent, root.s.playing ? 0.85 : 0.45)
                            height: root.s.playing && root.s.levels
                                    ? 3 + Math.min(1, root.s.levels[index * 4 + 1] || 0) * 12
                                    : [3, 7, 12, 9, 5, 2][index]
                            Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }
                        }
                    }
                }
            }
            Text {
                id: topClock
                color: root.rgba(th.text, 0.9)
                font.pixelSize: (12) * root.ts; font.bold: true; font.family: "Consolas"
                anchors.verticalCenter: parent.verticalCenter
                Timer {
                    interval: 1000; running: true; repeat: true; triggeredOnStart: true
                    onTriggered: {
                        var d = new Date();
                        topClock.text = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
                    }
                }
            }
            Rectangle {
                width: 1; height: 16; color: tc.light ? "#26000000" : "#22ffffff"
                anchors.verticalCenter: parent.verticalCenter
            }
            // fixed box: a long theme name used to push this row past the
            // window edge, so the swatch sat half outside the frame
            Row {
                width: 96
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: 9; height: 9; radius: 3
                    color: root.accent2()
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: 0.9
                }
                Text {
                    width: 79
                    text: tc.name
                    color: root.rgba(th.text, 0.82); font.family: root.tf; font.pixelSize: (10) * root.ts
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                }
            }
        }
    }

    // left-edge grab hint when the rail is hidden
    Item {
        z: 10
        x: 0; width: 3
        anchors.top: topbar.bottom; anchors.bottom: parent.bottom
        opacity: root.railShown ? 0 : 0.55
        Behavior on opacity { NumberAnimation { duration: 260 } }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(th.accent, 0) }
                GradientStop { position: 0.22; color: root.rgba(th.accent, 0.30) }
                GradientStop { position: 0.78; color: root.rgba(th.accent, 0.30) }
                GradientStop { position: 1; color: root.rgba(th.accent, 0) }
            }
        }
    }

    // content area: width animates when the rail reveals/hides
    Item {
        id: contentArea
        z: 0
        anchors.left: parent.left
        anchors.top: topbar.bottom
        anchors.bottom: bar.top
        // zero: pages run the full width of the room under the header
        width: 0
    }

    // frameless edge resizers
    MouseArea { x: 0; width: 5; z: 9; anchors.top: topbar.bottom; anchors.bottom: parent.bottom; cursorShape: Qt.SizeHorCursor; onPressed: root.startSystemResize(Qt.LeftEdge) }
    MouseArea { anchors.right: parent.right; width: 5; z: 9; anchors.top: topbar.bottom; anchors.bottom: parent.bottom; cursorShape: Qt.SizeHorCursor; onPressed: root.startSystemResize(Qt.RightEdge) }
    MouseArea { anchors.bottom: parent.bottom; height: 5; z: 9; anchors.left: parent.left; anchors.right: parent.right; cursorShape: Qt.SizeVerCursor; onPressed: root.startSystemResize(Qt.BottomEdge) }
    MouseArea { x: 0; y: parent.height - 16; width: 16; height: 16; z: 9; cursorShape: Qt.SizeBDiagCursor; onPressed: root.startSystemResize(Qt.LeftEdge | Qt.BottomEdge) }
    MouseArea { anchors.right: parent.right; anchors.bottom: parent.bottom; width: 16; height: 16; z: 9; cursorShape: Qt.SizeFDiagCursor; onPressed: root.startSystemResize(Qt.RightEdge | Qt.BottomEdge) }

    // frosted glass: ONE shared window capture, blurred per panel (cheap + smooth)
    ShaderEffectSource {
        id: glassCapture
        // IN-VIEW (behind the opaque shell at z:-3, never culled), LIVE (renders
        // every frame), never scheduled manually - the only deadlock-free shape.
        z: -4
        anchors.fill: parent
        sourceItem: bg3d
        sourceRect: Qt.rect(0, 0, root.width, root.height)
        textureSize: Qt.size(Math.max(64, root.width / 4), Math.max(64, root.height / 4))
        // NOT live: a live capture renders the whole 3D world a second time
        // every frame. The frosted panels sample it on a slow timer instead -
        // the blur hides the delay completely. Each refresh is a full off-
        // screen render of the room, so at 400 ms it was also a visible hitch
        // two and a half times a second; a quarter-res frame every second is
        // indistinguishable under the frost and costs a sixth as much.
        live: false
    }
    Timer {
        interval: 1000
        // the frosted layer only needs a refresh while somebody can see it:
        // minimized or behind another app, the old frame is still correct
        running: root.visible && root.visibility !== Window.Minimized && root.active
        repeat: true
        onTriggered: glassCapture.scheduleUpdate()
    }
        // transition accent sweep - a light bar crossing the content on glitch/offset/wipe themes
    Rectangle {
        id: trSweep
        z: 30
        visible: false
        y: topbar.height
        height: root.height - topbar.height - bar.height
        width: 3
        rotation: 8
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: rgba(th.accent, 0) }
            GradientStop { position: 0.5; color: rgba(th.accent, 0.9) }
            GradientStop { position: 1; color: rgba(th.accent, 0) }
        }
        SequentialAnimation {
            id: sweepAnim
            NumberAnimation { target: trSweep; property: "x"; to: root.width + 40; duration: root.trDur(); easing.type: Easing.OutCubic }
            onStopped: trSweep.visible = false
        }
    }
    // the lean is a two-leg animation, never a hand-set value: an impulse that
    // appeared in one frame and decayed on the frame clock lurched the camera.
    // `kickDecay` (a timer that no longer exists) used to be restarted here,
    // which threw a ReferenceError and aborted gotoPage() before
    // pageTransition could run - the pages cut instead of moving.
    SequentialAnimation {
        id: kickLean
        NumberAnimation { target: root; property: "trKick"
                          to: 0.34; duration: 200; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "trKick"
                          to: 0.0; duration: 640; easing.type: Easing.InOutCubic }
    }

    // the governor: reads real frame intervals and, only when the room has
    // been unable to hold a smooth rate for a couple of seconds, asks the
    // world for less geometry and fewer halos. it never steps back up, so
    // there is at most one scene change per session and no oscillation.
    FrameAnimation {
        id: frameProbe
        running: root.visible && root.visibility !== Window.Minimized
        property real last: 0
        property real warm: 0
        property real slowest: 0
        property real report: 0
        property int slow: 0      // frames over 20ms in this window
        property int vslow: 0     // frames over 40ms: a visible hitch
        property var trail: []    // last 80 frame times, for the pacing log
        onTriggered: {
            var now = Date.now();
            var first = (last === 0);
            var dt = now - last;
            last = now;
            if (first) return;
            if (dt < 4) return;                     // no frame time to read
            if (dt > 50) dt = 50;                   // after a stall, do not jump
            // every continuous value in the room advances here, once, with the
            // frame it will be drawn in
            root.cardPhase += dt * 0.001125;
            root.smoothLevelsTick(dt);
            root.clockTick(dt);
            root.fps = root.fps * 0.88 + (1000 / dt) * 0.12;
            if (dt > slowest) slowest = dt;
            if (dt > 20) slow++;
            if (dt > 40) vslow++;
            trail.push(Math.round(dt));
            if (trail.length > 80) trail.shift();
            report += dt;
            if (report > 3000) {
                report = 0;
                // worst frame of the last three seconds is what the eye reads
                // as stutter: a 60fps average can still hide a 40ms hitch
                root.hit("/frame?f=" + Math.round(root.fps)
                         + "&worst=" + Math.round(slowest)
                         + "&q=" + Math.round(root.q * 100)
                         + "&slow=" + slow + "&vslow=" + vslow
                         + "&d=PG" + root.currentPage + "," + root.leavingPage + ","
                         + Math.round(root.pageEnter * 100) + ";" + trail.slice(-24).join(","));
                slowest = 0; slow = 0; vslow = 0;
            }
            if (root.qDropped) return;
            warm += dt;
            if (warm < 3000) return;                // let the first frames settle
            if (root.fps >= 50) {
                root.qSick = 0; root.qSteady += dt;
            } else                // One step, and only after two and a half seconds of a room
                // that genuinely cannot run. 0.3 used to strip the room to a
                // shell; 0.5 keeps every object and gives up the expensive
                // edges instead (MSAA and the transmission pass).
                if (root.fps < 44) {
                    root.qSteady = 0; root.qSick += dt;
                    if (root.qSick > 2500 && !root.qDropped) {
                        root.q = 0.5;
                        root.qDropped = true;
                        root.qSick = 0;
                    }
                } else {
                root.qSick = 0; root.qSteady = 0;
            }
        }
    }

    // sync toast
    Rectangle {
        id: syncToast
        property string msg: ""
        property real life: 1
        opacity: 0
        scale: 0.9 + 0.1 * toastAnimProgress.value
        anchors.right: parent.right; anchors.rightMargin: 28
        anchors.bottom: bar.top; anchors.bottomMargin: 18
        width: toastText.width + 40; height: 38; radius: 19
        color: "transparent"
        border.width: 0
        property real toastAnimProgress: opacity
        // glass body
        MultiEffect {
            anchors.fill: parent
            source: glassCapture
            blurEnabled: true
            blur: 0.85
            blurMax: 24
        }
        Rectangle { anchors.fill: parent; radius: 19; color: rgba(th.panel, 0.88); border.width: 1; border.color: (tc.light ? "#26000000" : "#30ffffff") }
        // accent dot
        Rectangle { x: 12; width: 7; height: 7; radius: 3.5; anchors.verticalCenter: parent.verticalCenter; color: th.accent }
        Text { id: toastText; x: 26; anchors.verticalCenter: parent.verticalCenter; text: syncToast.msg; color: th.text; font.family: root.tf; font.pixelSize: (12) * root.ts }
        // life bar: drains while the toast lives
        Rectangle {
            anchors.bottom: parent.bottom; anchors.bottomMargin: 5
            anchors.horizontalCenter: parent.horizontalCenter
            width: (parent.width - 24) * syncToast.life
            height: 2; radius: 1
            color: rgba(th.accent, 0.55)
            Behavior on width { NumberAnimation { duration: 120 } }
        }
        function show(m) {
            msg = m;
            opacity = 1;
            life = 1;
            toastHide.restart();
            toastDrain.restart();
        }
        // ease-out on dismiss, spring on entry
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Timer { id: toastHide; interval: 2600; onTriggered: syncToast.opacity = 0 }
        Timer { id: toastDrain; interval: 52; repeat: true; onTriggered: { syncToast.life = Math.max(0, syncToast.life - 0.02); if (syncToast.life <= 0) toastDrain.stop(); } }
    }

    // ---------------- keyboard ----------------
    // global keys; skipped while typing in a text field so search stays sane
    Item {
        id: keyCatcher
        focus: true
        anchors.fill: parent
        Keys.onPressed: function(ev) {
            var f = root.activeFocusItem;
            var typing = f && (f instanceof TextField || f instanceof TextArea);
            if (ev.key === Qt.Key_K && (ev.modifiers & Qt.ControlModifier)) {
                if (root.palOpen) root.closePalette(); else root.openPalette();
                ev.accepted = true;
                return;
            }
            if (ev.key === Qt.Key_F && (ev.modifiers & Qt.ControlModifier)) {
                root.openFind();
                ev.accepted = true;
                return;
            }
            if (ev.key === Qt.Key_Comma && (ev.modifiers & Qt.ControlModifier)) {
                root.openStudio(0);
                ev.accepted = true;
                return;
            }
            if (ev.key === Qt.Key_Escape) {
                if (root.infoOpen) root.closeInfo();
                else if (root.ctxOpenState) root.closeCtx();
                else if (findPanel.findSlide > 0.4) root.closeFind();
                else if (studioPanel.studioSlide > 0.4) root.closeStudio();
                else if (root.palOpen) root.closePalette();
                else if (root.themeWorldOpen) root.leaveThemeWorld();
                else if (addSheet.addSlide > 0.5) addSheet.close();
                else if (np.npSlide > 0.5) np.close();
                else if (scOverlay.scSlide > 0.5) scOverlay.close();
                else if (typing) f.focus = false;
                ev.accepted = true;
                return;
            }
            if (typing) return;
            if (ev.key === Qt.Key_Space) { hit("/toggle"); ev.accepted = true; }
            else if (ev.key === Qt.Key_Right) {
                if (ev.modifiers & Qt.ShiftModifier) { hit("/next"); toastNow("next track"); }
                else hit("/seek?ms=" + (root.posMs + 10000));
                ev.accepted = true;
            }
            else if (ev.key === Qt.Key_Left) {
                if (ev.modifiers & Qt.ShiftModifier) { hit("/prev"); toastNow("previous track"); }
                else hit("/seek?ms=" + Math.max(0, root.posMs - 10000));
                ev.accepted = true;
            }
            else if (ev.key === Qt.Key_Up) { root.setVolume(s.volume + 5); ev.accepted = true; }
            else if (ev.key === Qt.Key_Down) { root.setVolume(s.volume - 5); ev.accepted = true; }
            else if (ev.key >= Qt.Key_1 && ev.key <= Qt.Key_7) { gotoPage(ev.key - Qt.Key_1); ev.accepted = true; }
            else if (ev.key === Qt.Key_S) {
                var next = !s.shuffle;
                hit("/shuffle?s=" + (next ? 1 : 0) + "&mode=" + (next ? "smart" : "random"));
                toastNow(next ? "smart shuffle on" : "shuffle off");
                ev.accepted = true;
            }
            else if (ev.key === Qt.Key_R) { hit("/repeat?r=" + ((s.repeat + 1) % 3)); toastNow(["repeat off", "repeat all", "repeat one"][(s.repeat + 1) % 3]); ev.accepted = true; }
            else if (ev.key === Qt.Key_M) { root.setVolume(s.volume > 0 ? 0 : 70); ev.accepted = true; }
            else if (ev.key === Qt.Key_BracketLeft) { root.nudgeLyrics((ev.modifiers & Qt.ShiftModifier) ? -500 : -100); ev.accepted = true; }
            else if (ev.key === Qt.Key_BracketRight) { root.nudgeLyrics((ev.modifiers & Qt.ShiftModifier) ? 500 : 100); ev.accepted = true; }
            else if (ev.key === Qt.Key_L) { np.open(); ev.accepted = true; }
            else if (ev.key === Qt.Key_Q) { gotoPage(3); ev.accepted = true; }
            else if (ev.key === Qt.Key_H) { gotoPage(5); ev.accepted = true; }
            else if (ev.key === Qt.Key_T) { gotoPage(4); ev.accepted = true; }
            else if (ev.key === Qt.Key_Question || ev.key === Qt.Key_Slash) { scOverlay.open(); ev.accepted = true; }
        }
    }

    // ---------------- stream-needed sheet ----------------
    // small glass tab when a track needs sourcing: convert now, or pick
    // it as the shell/stream target later. never blocks the app.
    Item {
        id: streamSheet
        z: 70
        anchors.fill: parent
        visible: sheetSlide > 0.002
        property real sheetSlide: 0
        property int trackId: -1
        property string trackTitle: ""
        property string trackArtist: ""
        function openFor(id, title, artist) {
            trackId = id; trackTitle = title; trackArtist = artist;
            sheetAnim.duration = 420; sheetAnim.easing.type = Easing.OutQuint;
            sheetAnim.to = 1; sheetAnim.restart();
        }
        function close() {
            sheetAnim.duration = 240; sheetAnim.easing.type = Easing.InCubic;
            sheetAnim.to = 0; sheetAnim.restart();
        }
        NumberAnimation { id: sheetAnim; target: streamSheet; property: "sheetSlide"; from: streamSheet.sheetSlide; duration: 380; easing.type: Easing.OutCubic }

        Rectangle { anchors.fill: parent; color: rgba("#000000", 0.28 * streamSheet.sheetSlide); MouseArea { anchors.fill: parent; onClicked: { root.playTap(); streamSheet.close() } } }

        Rectangle {
            anchors.centerIn: parent
            width: 380; height: 250
            radius: 20
            color: "transparent"
            MultiEffect {
                anchors.fill: parent
                source: glassCapture
                blurEnabled: true
                blur: 0.9
                blurMax: 30
                opacity: streamSheet.sheetSlide
            }
            Rectangle { anchors.fill: parent; radius: 20; color: rgba(th.panel, 0.85); border.width: 1; border.color: (tc.light ? "#22000000" : "#28ffffff") }
            opacity: streamSheet.sheetSlide
            scale: 0.94 + 0.06 * streamSheet.sheetSlide
            transform: Translate { y: (1 - streamSheet.sheetSlide) * 26 }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 10
                Text { text: "not local yet"; color: th.dim; font.family: root.tf; font.pixelSize: (9) * root.ts; font.letterSpacing: 1.6; font.bold: true }
                Text {
                    text: streamSheet.trackTitle
                    color: th.text; font.family: root.tf; font.pixelSize: (17) * root.ts; font.bold: true
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
                Text {
                    text: streamSheet.trackArtist
                    color: th.dim; font.family: root.tf; font.pixelSize: (12) * root.ts
                    elide: Text.ElideRight; Layout.fillWidth: true
                }
                Item { Layout.fillHeight: true }
                Text { text: "pull this one in now, or leave it as a catalog entry"; color: th.dim; font.family: root.tf; font.pixelSize: (10) * root.ts }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    GlowButton {
                        Layout.fillWidth: true
                        label: "CONVERT THIS ONE"
                        onClicked: { root.hit("/convert/one?id=" + streamSheet.trackId);
                            syncToast.show("sourcing \"" + streamSheet.trackTitle + "\" - rescan in a moment");
                            streamSheet.close();
                        }
                    }
                    GlowButton {
                        label: "CLOSE"
                        glow: th.dim
                        onClicked: { streamSheet.close() }
                    }
                }
            }
        }
    }

    // ---------------- shortcuts overlay ----------------
    Item {
        id: scOverlay
        z: 60
        anchors.fill: parent
        visible: scSlide > 0.002
        property real scSlide: 0
        function open() {
            scAnim.duration = 420; scAnim.easing.type = Easing.OutQuint;
            scAnim.to = 1; scAnim.restart();
        }
        function close() {
            scAnim.duration = 220; scAnim.easing.type = Easing.InCubic;
            scAnim.to = 0; scAnim.restart();
        }
        NumberAnimation { id: scAnim; target: scOverlay; property: "scSlide"; from: scOverlay.scSlide; duration: 420; easing.type: Easing.OutCubic }
        Rectangle { anchors.fill: parent; color: rgba("#000000", 0.30 * scOverlay.scSlide); MouseArea { anchors.fill: parent; onClicked: { root.playTap(); scOverlay.close() } } }
        Rectangle {
            anchors.centerIn: parent
            width: 470; height: 456
            radius: 22
            color: "transparent"
            border.width: 0
            // glass body
            MultiEffect {
                anchors.fill: parent
                source: glassCapture
                blurEnabled: true
                blur: 0.9
                blurMax: 30
                opacity: scOverlay.scSlide
            }
            Rectangle { anchors.fill: parent; radius: 22; color: rgba(th.panel, 0.82); border.width: 1; border.color: (tc.light ? "#22000000" : "#28ffffff") }
            opacity: scOverlay.scSlide
            scale: 0.92 + 0.08 * scOverlay.scSlide
            transform: Translate { y: (1 - scOverlay.scSlide) * 40 }
            Column {
                anchors.fill: parent
                anchors.margins: 26
                spacing: 14
                Text { text: "KEYS"; color: th.text; font.family: root.tf; font.pixelSize: (18) * root.ts; font.bold: true; font.letterSpacing: 2 }
                Text { text: "press / anytime \u00b7 esc closes"; color: th.dim; font.family: root.tf; font.pixelSize: (10) * root.ts }
                Repeater {
                    model: [
                        { k: "SPACE", d: "play / pause" },
                        { k: "\u2190 \u2192", d: "seek \u00b1 10s" },
                        { k: "SHIFT \u2190 \u2192", d: "prev / next track" },
                        { k: "\u2191 \u2193", d: "volume \u00b1 5" },
                        { k: "M", d: "mute / unmute" },
                        { k: "S", d: "smart shuffle" },
                        { k: "R", d: "repeat mode" },
                        { k: "L", d: "immersive stage" },
                        { k: "CTRL K", d: "search everything" },
                        { k: "1 - 7", d: "jump to page" },
                        { k: "H T Q", d: "home themes queue" },
                        { k: "ESC", d: "close anything" }
                    ]
                    delegate: Row {
                        width: parent.width
                        spacing: 12
                        Rectangle {
                            width: Math.max(64, scKeyText.width + 16); height: 24; radius: 6
                            color: rgba(th.accent, 0.14)
                            border.width: 1; border.color: rgba(th.accent, 0.45)
                            Text { id: scKeyText; anchors.centerIn: parent; text: modelData.k; color: th.accent; font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 0.5 }
                        }
                        Text { text: modelData.d; color: th.text; font.family: root.tf; font.pixelSize: (11) * root.ts; anchors.verticalCenter: parent.verticalCenter }
                    }
                }
            }
        }
    }

    // ---------------- animated background ----------------
        // opaque rounded shell: fills the window except the true corners
    Rectangle {
        id: shell
        z: -3
        anchors.fill: parent
        radius: 16
        color: th.bg
        Behavior on color { ColorAnimation { duration: 460 } }
    }

    // rounded-corner mask for the 3D: a RENDERED mask via hideSource (visible:false
    // items never render into sources - hideSource is the correct mechanism)

    // ---------------- 3D animated background ----------------
    Loader {
        id: bg3d
        anchors.fill: parent
        z: 0
        // a change of world is a dissolve, never a cut: the scene rises from
        // the room's own dark while the old palette is still fading out
        opacity: root.worldFade
        source: Qt.resolvedUrl("Background3D.qml")
        onLoaded: {
            root.applyBg3d();
            item.kick = Qt.binding(function() { return root.trKick; });
            item.quality = Qt.binding(function() { return root.q; });
            // the room sleeps under a full-window stage or film
            item.paused = Qt.binding(function() {
                // under a full-window stage, behind another app, or tucked in
                // the tray the room costs nothing: the last frame still shows
                // the moment the window comes back and the scene resumes
                return np.npSlide > 0.97 || watchPanel.watchSlide > 0.97
                       || root.themeWorldOpen || !root.active;
            });
        }
    }

    // the breath the theme change hides behind: the previous room's colour,
    // laid over everything for a beat and then dissolved
    Rectangle {
        id: themeCurtain
        z: 88
        anchors.fill: parent
        color: root.curtainCol
        opacity: root.curtainAmt
        visible: root.curtainAmt > 0.002
        // decoration only: never swallows a click
        enabled: false
    }

    // ink meeting water: the room change washes through every surface at
    // once, including the bars, so nothing reads as a separate pane
    DyeWash {
        id: dyeWash
        z: 89
        anchors.fill: parent
        progress: root.dyeAmt
        origin: root.dyeOrigin
        inkA: root.dyeInkA
        inkB: root.dyeInkB
        seed: root.dyeSeed
        strength: 0.72
        opacity: 0.38
        // OFF (2026-10-25). Measured against the window: this wash lifted the
        // whole frame - title bar, dock and all - by ~35 luma for two frames on
        // every room change, in the room's accent colour. That is the "green
        // jumpscare". Two things made it uncontrollable: the compiled shader
        // cache (%LOCALAPPDATA%/aethermix/cache/qtshadercache-*) keeps serving
        // the old program after a .frag rebuild, and the shader's `strength`
        // uniform does not reach the GPU on this machine, so neither the QML
        // strength nor the item opacity can tame it. The page move, the world
        // dip and the click already carry a room change; the dye is retired
        // rather than left in as a flash. DyeWash.qml and dye.frag remain for
        // the day the uniform path is worth debugging.
        visible: false
        enabled: false
    }

    // the room's other wallpaper: image, gif, film, a clip from a link, or the
    // record that is playing. sits above the world and under its weather, so
    // the theme still grades it and the type still sits on top.
    MediaBackdrop {
        id: mediaBackdrop
        z: 0.5
        anchors.fill: parent
        look: root.effLook
        kind: root.backdropKind(root.effLook)
        mediaSource: root.backdropSource(root.effLook)
    }

    // ---------------- atmosphere ----------------
    // A room has air between you and the far wall. Two linear grades (one from
    // the rail side, one from the floor) give every theme the same readable
    // ground without touching its colours, and they melt the edges of whatever
    // the world is doing behind the type.
    Item {
        id: atmosphere
        z: 0.9
        anchors.fill: parent
        enabled: false
        readonly property real vig: (root.tc && root.tc.depth && root.tc.depth.vignette !== undefined)
                                      ? root.tc.depth.vignette : 0.4
        // A film or a bright sleeve behind the page needs a floor to stand on.
        // This is not a box around the content: it is one full-window wash in
        // the room's own background colour, so the image is still there and the
        // type keeps its contrast.
        // The wash follows the wallpaper's own presence, which MediaBackdrop
        // already eases: driving it from `visible` popped 0.58 of solid colour
        // onto a page the instant a tab with a wallpaper was entered, and the
        // picture then rose underneath it. Now both arrive together.
        Rectangle {
            anchors.fill: parent
            color: root.rgba(root.tc.bg, 0.58)
            opacity: mediaBackdrop.presence
            visible: opacity > 0.004
        }
        // the header carries the smallest type on the page, so the wash is a
        // little deeper up there and under the dock
        Rectangle {
            anchors.fill: parent
            opacity: mediaBackdrop.presence
            visible: opacity > 0.004
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: root.rgba(root.tc.bg, 0.34) }
                GradientStop { position: 0.22; color: root.rgba(root.tc.bg, 0.05) }
                GradientStop { position: 0.78; color: root.rgba(root.tc.bg, 0.05) }
                GradientStop { position: 1.0; color: root.rgba(root.tc.bg, 0.40) }
            }
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: root.rgba(root.tc.light ? "#ffffff" : root.tc.bg, 0.10 * atmosphere.vig + 0.04) }
                GradientStop { position: 0.38; color: root.rgba(root.tc.bg, 0) }
                GradientStop { position: 0.72; color: root.rgba(root.tc.bg, 0) }
                GradientStop { position: 1; color: root.rgba(root.tc.bg, 0.30 * atmosphere.vig + 0.06) }
            }
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba(root.tc.bg, 0.26 * atmosphere.vig) }
                GradientStop { position: 0.30; color: root.rgba(root.tc.bg, 0) }
                GradientStop { position: 0.86; color: root.rgba(root.tc.bg, 0) }
                GradientStop { position: 1; color: root.rgba(root.tc.bg, 0.16 * atmosphere.vig) }
            }
        }
    }


    // the room breathes with the low end: a huge soft bloom behind the glass.
    // only its opacity changes, so the blur is rendered once and reused.
    Item {
        id: beatBloom
        z: 1
        anchors.fill: parent
        enabled: false
        opacity: Math.min(0.6, Math.pow(root.bassLevel, 1.4) * 0.8)
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(root.width, root.height) * 1.5
            height: width
            radius: width / 2
            color: root.rgba(th.accent, 0.30)
            // a blurred screen-sized disc costs a full pass even at zero alpha
            layer.enabled: root.bassLevel > 0.03
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 140 }
        }
    }

    // a fixed film grain: photographic bite, never animated, painted per theme
    component FilmGrain : Canvas {
        id: fg
        property real amount: 0.12
        property color grainInk: "#ffffff"
        anchors.fill: parent
        opacity: Math.min(0.35, amount * 0.42)
        onAmountChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            if (w <= 0 || h <= 0) return;
            ctx.fillStyle = root.rgba(grainInk, 0.5);
            var seed = 2207;
            var n = Math.min(3200, Math.round(w * h / 2800));
            for (var i = 0; i < n; i++) {
                seed = (seed * 1664525 + 1013904223) % 4294967296;
                var x = (seed >>> 8) % w;
                seed = (seed * 1664525 + 1013904223) % 4294967296;
                var y = (seed >>> 8) % h;
                ctx.fillRect(x, y, 1, 1);
            }
        }
        Connections { target: root; function onTcChanged() { fg.requestPaint(); } }
    }

    // The world softens behind the interface: one frosted breath, drawn as the
    // quarter-res capture itself (see frost below). It is *not* a per-frame
    // 1280x760 nine-tap blur any more: on this GPU that pass alone was most of
    // a millisecond budget the room needed to hold 60.
    Rectangle {
        z: 1.01
        anchors.fill: parent
        gradient: Gradient {
            // bright worlds need a quieter room behind the type; dark worlds
            // keep more of the vista
            GradientStop { position: 0; color: root.rgba(th.bg, (tc.light ? 0.46 : 0.50) * root.veilK * (1 - 0.38 * root.mediaK)) }
            GradientStop { position: 0.42; color: root.rgba(th.bg, (tc.light ? 0.40 : 0.42) * root.veilK * (1 - 0.42 * root.mediaK)) }
            GradientStop { position: 1; color: root.rgba(th.bg, (tc.light ? 0.54 : 0.60) * root.veilK * (1 - 0.30 * root.mediaK)) }
        }
    }
    Rectangle {
        z: 1.02
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: root.rgba(th.bg, root.dep("vignette", 0.3) * 0.7 * (1 - 0.5 * root.mediaK)) }
            GradientStop { position: 0.14; color: root.rgba(th.bg, 0) }
            GradientStop { position: 0.86; color: root.rgba(th.bg, 0) }
            GradientStop { position: 1; color: root.rgba(th.bg, root.dep("vignette", 0.3) * 0.7 * (1 - 0.5 * root.mediaK)) }
        }
    }
    // a quiet well of ink under the reading column. worlds can be as bright as
    // they like at the edges; the middle is where the type has to hold.
    Canvas {
        id: inkWell
        z: 1.025
        anchors.fill: parent
        opacity: 1 - 0.45 * root.mediaK
        property color ink: th.bg
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
        Connections { target: root; function onTcChanged() { inkWell.requestPaint(); } }
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            if (w <= 0 || h <= 0) return;
            // centred on the page, not the window: the rail keeps its air
            var cx = w * 0.60, cy = h * 0.50;
            var r = Math.max(w * 0.62, h * 0.82);
            var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
            g.addColorStop(0, root.rgba(ink, tc.light ? 0.16 : 0.30));
            g.addColorStop(0.55, root.rgba(ink, tc.light ? 0.10 : 0.18));
            g.addColorStop(1, root.rgba(ink, 0));
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, w, h);
        }
    }
    FilmGrain {
        z: 1.03
        amount: root.dep("grain", 0.12)
        grainInk: tc.light ? "#000000" : "#ffffff"
    }

    // every theme gets its own weather painted over the 3D world, under the UI.
    // one static canvas per theme change: depth without a per-frame cost.
    component ThemeAura : Canvas {
        id: ta
        property string sig: ""
        property color ink: "#ffffff"
        property color ink2: "#ffffff"
        opacity: 0.9 - 0.62 * root.mediaK
        onSigChanged: requestPaint()
        onInkChanged: requestPaint()
        onInk2Changed: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
        Connections { target: root; function onTcChanged() { ta.requestPaint(); } }
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            if (w <= 0 || h <= 0) return;
            var s = (ta.sig || "").toLowerCase();
            var a1 = ctx.createRadialGradient(w * 0.22, h * 0.2, 0, w * 0.22, h * 0.2, w * 0.7);
            a1.addColorStop(0, root.rgba(ta.ink, tc.light ? 0.08 : 0.12));
            a1.addColorStop(1, root.rgba(ta.ink, 0));
            ctx.fillStyle = a1;
            ctx.fillRect(0, 0, w, h);
            var a2 = ctx.createRadialGradient(w * 0.86, h * 0.78, 0, w * 0.86, h * 0.78, w * 0.62);
            a2.addColorStop(0, root.rgba(ta.ink2, tc.light ? 0.06 : 0.09));
            a2.addColorStop(1, root.rgba(ta.ink2, 0));
            ctx.fillStyle = a2;
            ctx.fillRect(0, 0, w, h);

            ctx.lineCap = "round";
            ctx.lineWidth = 1;
            var ink = root.rgba(ta.ink, tc.light ? 0.07 : 0.10);
            var ink2 = root.rgba(ta.ink2, tc.light ? 0.06 : 0.09);
            ctx.strokeStyle = ink;
            ctx.fillStyle = ink;

            if (s === "rain" || s === "glyph" || s === "dither") {
                ctx.lineWidth = 1;
                for (var i = 0; i < 90; i++) {
                    var x = (i * 97 % w);
                    var top = ((i * 53) % h) * 0.5;
                    ctx.globalAlpha = 0.16 + (i % 5) * 0.05;
                    ctx.beginPath();
                    ctx.moveTo(x, top);
                    ctx.lineTo(x - 22, top + h * 0.4);
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
                if (s === "dither") {
                    for (var dx = 0; dx < w; dx += 7) {
                        for (var dy = 0; dy < h; dy += 7) {
                            if (((dx / 7) + (dy / 7)) % 3 === 0) {
                                ctx.globalAlpha = 0.10;
                                ctx.fillRect(dx, dy, 2, 2);
                            }
                        }
                    }
                    ctx.globalAlpha = 1;
                }
            } else if (s === "grid" || s === "circuit") {
                for (var gx = 0; gx < w; gx += 86) {
                    ctx.beginPath(); ctx.moveTo(gx, 0); ctx.lineTo(gx, h); ctx.stroke();
                }
                for (var gy = 0; gy < h; gy += 64) {
                    ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke();
                }
                ctx.strokeStyle = ink2;
                for (var c = 0; c < 7; c++) {
                    var px = (c * 191) % w, py = (c * 97) % h;
                    ctx.beginPath();
                    ctx.moveTo(px, py); ctx.lineTo(px + 70, py); ctx.lineTo(px + 100, py + 30); ctx.lineTo(px + 160, py + 30);
                    ctx.stroke();
                }
            } else if (s === "shapes" || s === "lowpoly") {
                for (var t = 0; t < 8; t++) {
                    var cx = (t * 277 + 90) % w;
                    var cy = (t * 163 + 100) % h;
                    var r = 70 + (t % 4) * 44;
                    ctx.globalAlpha = 0.11;
                    ctx.beginPath();
                    ctx.moveTo(cx, cy - r);
                    ctx.lineTo(cx + r * 0.86, cy + r * 0.5);
                    ctx.lineTo(cx - r * 0.86, cy + r * 0.5);
                    ctx.closePath();
                    ctx.stroke();
                    if (s === "shapes") {
                        ctx.beginPath(); ctx.arc(cx + r * 0.3, cy + r * 0.3, r * 0.28, 0, Math.PI * 2); ctx.stroke();
                    }
                }
                ctx.globalAlpha = 1;
            } else if (s === "motes" || s === "embers" || s === "firefly") {
                for (var d = 0; d < 140; d++) {
                    var mx = ((d * 137) % w);
                    var my = ((d * 71) % h);
                    var mr = 0.7 + (d % 4) * 0.6;
                    ctx.globalAlpha = 0.12 + (d % 6) * 0.025;
                    ctx.beginPath(); ctx.arc(mx, my, mr, 0, Math.PI * 2); ctx.fill();
                }
                ctx.globalAlpha = 1;
            } else if (s === "orbit" || s === "rings" || s === "gear") {
                ctx.save();
                ctx.translate(w * 0.82, h * 0.26);
                ctx.rotate(-0.5);
                ctx.strokeStyle = ink2;
                for (var o = 0; o < 5; o++) {
                    ctx.globalAlpha = 0.12 - o * 0.015;
                    ctx.lineWidth = 1.2;
                    ctx.save();
                    ctx.scale(1, (0.04 + o * 0.03) / (0.1 + o * 0.055));
                    ctx.beginPath();
                    ctx.arc(0, 0, w * (0.1 + o * 0.055), 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.restore();
                }
                if (s === "gear") {
                    ctx.strokeStyle = ink;
                    for (var tt = 0; tt < 24; tt++) {
                        var ang = tt * Math.PI / 12;
                        ctx.globalAlpha = 0.10;
                        ctx.beginPath();
                        ctx.moveTo(Math.cos(ang) * 40, Math.sin(ang) * 40);
                        ctx.lineTo(Math.cos(ang) * 54, Math.sin(ang) * 54);
                        ctx.stroke();
                    }
                }
                ctx.restore();
                ctx.globalAlpha = 1;
            } else if (s === "glass" || s === "holo" || s === "vitrail") {
                for (var f = 0; f < 6; f++) {
                    var bx = (f * 233 + 120) % w;
                    var by = (f * 149 + 40) % h;
                    ctx.globalAlpha = 0.12;
                    ctx.strokeStyle = f % 2 === 0 ? ink : ink2;
                    ctx.beginPath();
                    ctx.moveTo(bx, by);
                    ctx.lineTo(bx + 150, by + 40);
                    ctx.lineTo(bx + 100, by + 180);
                    ctx.closePath();
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
            } else if (s === "vapor") {
                ctx.strokeStyle = ink2;
                var horizon = h * 0.46;
                for (var v = 0; v < 10; v++) {
                    ctx.globalAlpha = 0.10;
                    ctx.beginPath();
                    ctx.moveTo(0, horizon + v * 9);
                    ctx.lineTo(w, horizon + v * 9);
                    ctx.stroke();
                }
                ctx.globalAlpha = 0.14;
                ctx.beginPath(); ctx.arc(w * 0.62, horizon, w * 0.18, Math.PI, 0); ctx.stroke();
                ctx.globalAlpha = 1;
            } else if (s === "ink") {
                ctx.strokeStyle = ink;
                for (var b = 0; b < 4; b++) {
                    ctx.globalAlpha = 0.10;
                    ctx.lineWidth = 2 + b * 3;
                    ctx.beginPath();
                    ctx.moveTo(-20, h * (0.3 + b * 0.14));
                    ctx.bezierCurveTo(w * 0.3, h * (0.16 + b * 0.13), w * 0.68, h * (0.86 - b * 0.08), w + 20, h * (0.3 + b * 0.1));
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
            } else {
                // ribbons / silk / veil / default
                for (var r = 0; r < 4; r++) {
                    ctx.strokeStyle = r % 2 === 0 ? ink : ink2;
                    ctx.globalAlpha = 0.12;
                    ctx.lineWidth = 1.2;
                    ctx.beginPath();
                    var yy = h * (0.2 + r * 0.18);
                    ctx.moveTo(-40, yy);
                    ctx.bezierCurveTo(w * 0.32, yy - h * 0.22, w * 0.64, yy + h * 0.24, w + 40, yy - h * 0.04);
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
            }
        }
    }

    // the painted aura used to draw grids and contour lines straight across the
    // interface. the 3D world now carries that detail, so the surface stays clean.
    ThemeAura {
        z: 1.04
        anchors.fill: parent
        sig: root.tc.signature || root.tc.anim || ""
        ink: root.tc.accent || "#ffffff"
        ink2: root.accent2()
        visible: false
    }

    // glass scrollbar: slim accent handle, fades in on movement, silent otherwise
    component GlassScroll : ScrollBar {
        id: gs
        implicitWidth: 5
        policy: ScrollBar.AsNeeded
        contentItem: Rectangle {
            implicitWidth: 3
            radius: 1.5
            color: rgba(th.accent, 0.7)
        }
        background: Item { }
        // only there while the hand is moving: no permanent rail down the page
        opacity: gs.active || gs.pressed ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }    // unified spring-physics button: hover lift, light sweep, glow ring, press dip
    component GlowButton : Rectangle {
        id: gb
        property string label: ""
        property color glow: th.accent
        property real bh: 32
        property real sweep: 0
        signal clicked()
        width: gbtnText.width + 24; height: bh; radius: bh / 2
        // no outline here either: pressed, hovered and resting are three
        // depths of the same material, and the specular sweep below is what
        // tells the eye the button is glass
        color: gbMa.pressed ? rgba(gb.glow, 0.34) : (gbMa.containsMouse ? (tc.light ? "#32000000" : "#28ffffff") : (tc.light ? "#1c000000" : "#18ffffff"))
        border.width: 0
        // press dips hard and springs back once; hover lifts less than the press drops
        scale: gbMa.pressed ? 0.945 : (gbMa.containsMouse ? 1.045 : 1.0)
        Behavior on scale { NumberAnimation { duration: gbMa.pressed ? 90 : 260; easing.type: Easing.OutBack } }
        Behavior on color { ColorAnimation { duration: 120 } }
        NumberAnimation {
            id: gbSweep
            target: gb; property: "sweep"
            from: 0; to: 1; duration: 560
            easing.type: Easing.OutCubic
        }
        // a single specular pass: what glass does when the light moves
        Item {
            anchors.fill: parent; anchors.margins: 1
            clip: true
            Rectangle {
                width: parent.width * 0.5; height: parent.height
                radius: gb.radius
                x: gb.sweep * (parent.width * 1.6) - width
                opacity: gb.sweep > 0.001 && gb.sweep < 0.999 ? 0.55 : 0
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: root.rgba("#ffffff", 0) }
                    GradientStop { position: 0.5; color: root.rgba("#ffffff", 0.20) }
                    GradientStop { position: 1; color: root.rgba("#ffffff", 0) }
                }
            }
        }
        // hover glow ring: two rings, one tight and bright, one wide and soft
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 7; height: parent.height + 7
            radius: parent.radius + 3.5
            color: "transparent"
            border.width: 2
            border.color: rgba(gb.glow, gbMa.containsMouse ? 0.4 : 0)
            Behavior on border.color { ColorAnimation { duration: 200 } }
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 16; height: parent.height + 16
            radius: parent.radius + 8
            color: "transparent"
            border.width: 1
            border.color: rgba(gb.glow, gbMa.containsMouse ? 0.14 : 0)
            Behavior on border.color { ColorAnimation { duration: 260 } }
        }
        Text {
            id: gbtnText
            anchors.centerIn: parent
            text: gb.label
            color: gbMa.containsMouse ? gb.glow : th.text
            font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: true; font.letterSpacing: 1.2
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        MouseArea {
            id: gbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.playTap();
                gb.sweep = 0;
                gbSweep.restart();
                gb.clicked();
            }
            onContainsMouseChanged: if (containsMouse) { gb.sweep = 0; gbSweep.restart(); }
        }
    }

    // album art with true rounded corners (MultiEffect mask)
    component RoundImage : Item {
        id: ri
        property string source: ""
        property bool bad: false
        // a sleeve never snaps into place: it arrives over its own fallback,
        // so a track change reads as a change of record, not a redraw
        property real fade: 1
        onSourceChanged: {
            bad = false;
            if (source.length > 4) { fade = 0; fadeIn.restart(); }
        }
        NumberAnimation { id: fadeIn; target: ri; property: "fade"; to: 1; duration: 340; easing.type: Easing.OutCubic }
        property real corner: 8
        property alias async: rim.asynchronous
        Image {
            id: rim
            anchors.fill: parent
            visible: false
            source: ri.bad ? "" : ri.source
            onStatusChanged: if (status === Image.Error) ri.bad = true
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            asynchronous: true
            // a 34px row thumbnail used to decode the full 1000px cover: 63 of
            // those is where the memory went. decode to the size we draw, and
            // never past 768: a full-bleed sleeve does not need 4000px.
            sourceSize.width: Math.min(768, Math.max(24, Math.round(ri.width * 2)))
            sourceSize.height: Math.min(768, Math.max(24, Math.round(ri.height * 2)))
            cache: ri.width < 120
        }
        MultiEffect {
            anchors.fill: parent
            source: rim
            opacity: ri.fade
            maskEnabled: true
            maskSource: riMask
        }
        Rectangle {
            id: riMask
            visible: false
            layer.enabled: true
            anchors.fill: parent
            radius: ri.corner
            color: "white"
        }
    }

    // album art with a designed fallback: gradient, grooved ghost disc, glyph.
    // every row in the app renders through this so art is never a flat block.
    component Art : Item {
        id: art
        property string source: ""
        property real corner: 10
        property int seed: 0
        property bool glow: false
        readonly property bool hasArt: source.length > 4
        Rectangle {
            anchors.fill: parent
            radius: art.corner
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.mixColor(root.colorFor(art.seed), "#ffffff", 0.10) }
                GradientStop { position: 0.55; color: root.mixColor(root.colorFor(art.seed), "#05060a", 0.52) }
                GradientStop { position: 1; color: root.mixColor(root.accent2(), "#05060a", 0.72) }
            }
        }
        Canvas {
            anchors.fill: parent
            visible: !art.hasArt
            opacity: 0.30
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var c = Math.min(width, height) * 0.5;
                for (var i = 1; i < 5; i++) {
                    ctx.strokeStyle = "rgba(255,255,255,0.22)";
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.arc(width / 2, height / 2, c * (0.22 + i * 0.16), 0, Math.PI * 2);
                    ctx.stroke();
                }
            }
        }
        Image {
            anchors.centerIn: parent
            width: parent.width * 0.34; height: width
            source: Qt.resolvedUrl("../assets/icon.png")
            visible: !art.hasArt
            opacity: 0.55; smooth: true; mipmap: true
        }
        RoundImage {
            anchors.fill: parent
            corner: art.corner
            source: art.hasArt ? art.source : ""
        }
        Rectangle {
            anchors.fill: parent
            radius: art.corner
            color: "transparent"
            border.width: 1
            border.color: root.rgba("#ffffff", tc.light ? 0.3 : 0.14)
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            height: Math.max(6, parent.height * 0.34)
            radius: art.corner
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba("#ffffff", 0.14) }
                GradientStop { position: 1; color: root.rgba("#ffffff", 0) }
            }
        }
    }

    // a list edge that dissolves instead of ending: the content fades out at
    // the top and bottom of its own viewport, so there is no hard cut anywhere
    // a soft edge for scrolling surfaces: the content itself dissolves at the
    // top and bottom of its viewport instead of being covered by a band of colour
    component FadeMask : Item {
        id: fm
        visible: false
        layer.enabled: true
        property real topFade: 0.06
        property real bottomFade: 0.10
        property color tint: "#ffffff"
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(fm.tint, fm.topFade > 0 ? 0 : 1) }
                GradientStop { position: Math.max(0.0001, fm.topFade); color: root.rgba(fm.tint, 1) }
                GradientStop { position: 1 - fm.bottomFade; color: root.rgba(fm.tint, 1) }
                GradientStop { position: 1; color: root.rgba(fm.tint, fm.bottomFade > 0 ? 0 : 1) }
            }
        }
    }

    // mouse wheel as a glide, not a jump: each notch eases the view toward the
    // next position; the target is clamped so the list never bounces at an end
    // one shared glide engine: the wheel only aims, the animation carries the view
    property var glideView: null
    property real glideAim: 0
    NumberAnimation {
        id: glideAnim
        target: root.glideView
        property: "contentY"
        duration: 320
        easing.type: Easing.OutCubic
    }
    function glideScroll(view, dy) {
        if (!view) return;
        var cur = (glideAnim.running && root.glideView === view) ? root.glideAim : view.contentY;
        var maxY = Math.max(0, view.contentHeight - view.height);
        var aim = Math.max(0, Math.min(maxY, cur - dy));
        if (Math.abs(aim - view.contentY) < 0.5 && !glideAnim.running) return;
        root.glideView = view;
        root.glideAim = aim;
        glideAnim.stop();
        glideAnim.from = view.contentY;
        glideAnim.to = aim;
        glideAnim.restart();
    }
    component GlideWheel : WheelHandler {
        id: gw
        property Flickable view: null
        property real step: 120
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(ev) {
            if (!gw.view) return;
            var dy = (ev.pixelDelta && ev.pixelDelta.y !== 0)
                     ? ev.pixelDelta.y * 2.0
                     : (ev.angleDelta.y / 120) * gw.step;
            root.glideScroll(gw.view, dy);
        }
    }

    // springy glass scrubber: local tracking while dragging, one write on release
    component ScrubBar : Item {
        id: sb
        property real value: 0
        property real max: 1
        property real thickness: 4
        property color col: th.accent
        property color col2: root.accent2()
        property real hoverGrow: 1
        signal seek(real ratio)
        height: 22
        readonly property real ratio: Math.max(0, Math.min(1, value / Math.max(0.0001, max)))
        property real dragP: -1
        readonly property real shown: dragP >= 0 ? dragP : ratio
        Rectangle {
            id: sbTrack
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: sb.thickness
            radius: height / 2
            // an empty track reads as a stray rule across the page: it only
            // exists while you are using it
            color: sbMa.containsMouse || sb.dragP >= 0
                   ? (tc.light ? "#1e000000" : "#20ffffff")
                   : "#00000000"
            Behavior on color { ColorAnimation { duration: 180 } }
            Rectangle {
                width: parent.width * sb.shown
                height: parent.height; radius: height / 2
                // fractional widths are drawn, not snapped to whole pixels:
                // a 1 px step every fifth of a second is a visible tick
                antialiasing: true
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: sb.col }
                    GradientStop { position: 1; color: sb.col2 }
                }
                Rectangle {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3
                    color: root.rgba(sb.col2, 0.28)
                    visible: sb.shown > 0.001
                }
            }
        }
        Rectangle {
            x: Math.max(5, Math.min(sb.width - 5, sb.width * sb.shown - 5))
            anchors.verticalCenter: parent.verticalCenter
            width: sbMa.containsMouse || sbMa.pressed ? 13 : 9
            height: width; radius: width / 2
            color: tc.light ? "#ffffff" : root.rgba(sb.col2, 0.95)
            border.width: 1.5; border.color: root.rgba("#ffffff", 0.55)
            visible: sb.dragP >= 0 || sbMa.containsMouse
            scale: sbMa.pressed ? 1.15 : 1
            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
        }
        MouseArea {
            id: sbMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            function at(x) { return Math.max(0, Math.min(1, x / width)); }
            onPressed: sb.dragP = at(mouse.x)
            onPositionChanged: if (pressed) sb.dragP = at(mouse.x)
            onReleased: { sb.seek(sb.dragP); sb.dragP = -1; }
            onCanceled: sb.dragP = -1
        }
    }

    // a small signature drawing for each theme card: weather, geometry, matter
    component ThemeMark : Canvas {
        id: tm
        property string signature: ""
        property color ink: "#ffffff"
        opacity: 0.3
        onSignatureChanged: requestPaint()
        onInkChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            ctx.strokeStyle = tm.ink;
            ctx.fillStyle = tm.ink;
            ctx.lineWidth = Math.max(1, w * 0.006);
            ctx.lineCap = "round";
            var s = tm.signature;
            if (s === "ribbon" || s === "veil" || s === "silk") {
                for (var i = 0; i < 3; i++) {
                    ctx.beginPath();
                    var y = h * (0.28 + i * 0.22);
                    ctx.moveTo(w * 0.08, y);
                    ctx.bezierCurveTo(w * 0.32, y - h * 0.18, w * 0.6, y + h * 0.22, w * 0.92, y - h * 0.04);
                    ctx.stroke();
                }
            } else if (s === "rain" || s === "glyph") {
                for (var r = 0; r < 12; r++) {
                    var x = w * (0.08 + (r % 6) * 0.165) + (r > 5 ? w * 0.05 : 0);
                    var top = h * (0.18 + ((r * 7) % 5) * 0.08);
                    var bot = h * (0.72 + ((r * 3) % 3) * 0.06);
                    ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, bot); ctx.stroke();
                }
            } else if (s === "orbit" || s === "rings" || s === "sunrings") {
                for (var o = 0; o < 3; o++) {
                    ctx.save();
                    ctx.translate(w * 0.5, h * 0.52);
                    ctx.rotate(o * 0.5);
                    ctx.scale(1, 0.5 + o * 0.2);
                    ctx.beginPath();
                    ctx.arc(0, 0, w * (0.2 + o * 0.11), 0, Math.PI * 2);
                    ctx.stroke();
                    ctx.restore();
                }
            } else if (s === "grid" || s === "circuit") {
                for (var g = 0; g < 7; g++) {
                    var yv = h * 0.25 + g * h * 0.09;
                    ctx.beginPath(); ctx.moveTo(w * (0.08 + g * 0.02), yv); ctx.lineTo(w - w * 0.08, yv); ctx.stroke();
                }
                for (var gv = 0; gv < 9; gv++) {
                    var xv = w * 0.08 + gv * w * 0.105;
                    ctx.beginPath(); ctx.moveTo(xv, h * 0.2); ctx.lineTo(xv, h * 0.9); ctx.stroke();
                }
            } else if (s === "prims" || s === "shapes" || s === "lowpoly") {
                ctx.beginPath(); ctx.arc(w * 0.32, h * 0.5, w * 0.17, 0, Math.PI * 2); ctx.stroke();
                ctx.beginPath(); ctx.moveTo(w * 0.55, h * 0.72); ctx.lineTo(w * 0.7, h * 0.3); ctx.lineTo(w * 0.86, h * 0.72); ctx.closePath(); ctx.stroke();
            } else if (s === "embers" || s === "motes" || s === "firefly") {
                for (var d = 0; d < 26; d++) {
                    var dx = w * (0.08 + ((d * 37) % 84) / 100);
                    var dy = h * (0.16 + ((d * 53) % 70) / 100);
                    ctx.beginPath(); ctx.arc(dx, dy, Math.max(0.8, w * 0.006), 0, Math.PI * 2); ctx.fill();
                }
            } else if (s === "vapor") {
                ctx.beginPath(); ctx.arc(w * 0.5, h * 0.42, w * 0.2, Math.PI, 0); ctx.stroke();
                for (var v = 0; v < 6; v++) {
                    var vy = h * (0.55 + v * 0.075);
                    ctx.beginPath(); ctx.moveTo(w * 0.06, vy); ctx.lineTo(w * 0.94, vy); ctx.stroke();
                }
            } else if (s === "ink") {
                ctx.beginPath();
                ctx.moveTo(w * 0.1, h * 0.62);
                ctx.bezierCurveTo(w * 0.3, h * 0.22, w * 0.6, h * 0.88, w * 0.92, h * 0.34);
                ctx.lineWidth = Math.max(2, w * 0.028);
                ctx.stroke();
            } else if (s === "glass" || s === "holo" || s === "vitrail") {
                for (var f = 0; f < 4; f++) {
                    ctx.beginPath();
                    ctx.moveTo(w * (0.1 + f * 0.2), h * 0.18);
                    ctx.lineTo(w * (0.3 + f * 0.2), h * 0.82);
                    ctx.lineTo(w * (0.16 + f * 0.2), h * 0.82);
                    ctx.stroke();
                }
            } else if (s === "gear") {
                for (var t = 0; t < 16; t++) {
                    var ta = t * Math.PI / 8;
                    ctx.beginPath();
                    ctx.moveTo(w * 0.5 + Math.cos(ta) * w * 0.2, h * 0.5 + Math.sin(ta) * w * 0.2);
                    ctx.lineTo(w * 0.5 + Math.cos(ta) * w * 0.26, h * 0.5 + Math.sin(ta) * w * 0.26);
                    ctx.stroke();
                }
                ctx.beginPath(); ctx.arc(w * 0.5, h * 0.5, w * 0.2, 0, Math.PI * 2); ctx.stroke();
            } else {
                for (var c = 0; c < 4; c++) {
                    ctx.beginPath();
                    ctx.arc(w * 0.5, h * 0.5, w * (0.12 + c * 0.07), 0, Math.PI * 1.6);
                    ctx.stroke();
                }
            }
        }
    }

    // circular spectrum EQ - smooth 60fps, three circular modes
    component CircEQ : Canvas {
        id: ce
        property int mode: 0          // 0 ring | 1 bloom | 2 wave
        property int bars: 64
        property real inner: 0.62
        property real size: 260
        // the chosen pair, or this meter's own bar -> accent when the room has
        // no opinion about equaliser colour
        property color colA: root.eqAOn ? root.eqA : th.bar
        property color colB: root.eqBOn ? root.eqB : th.accent
        width: size; height: size
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height, cx = w / 2, cy = h / 2;
            var R = Math.min(w, h) / 2 - 14;
            var r0 = R * ce.inner;
            var lv = root.smoothLevels;
            var pk = root.smoothPeaks;
            var wave = root.s.wave || [];
            var rot = root.eqPhase;
            ctx.lineCap = "round";

            // outer halo ring - breathes with the low bands
            var bass = 0;
            for (var bi = 0; bi < 4 && bi < lv.length; bi++) bass += lv[bi];
            bass = Math.min(1, bass / 3);
            ctx.strokeStyle = root.rgba(ce.colB, 0.05 + bass * 0.12);
            ctx.lineWidth = 7 + bass * 7;
            ctx.beginPath();
            ctx.arc(cx, cy, R + 3, 0, Math.PI * 2);
            ctx.stroke();

            // rotating highlight arc
            ctx.strokeStyle = root.rgba(ce.colA, 0.35);
            ctx.lineWidth = 2;
            ctx.beginPath();
            ctx.arc(cx, cy, R - 2, rot, rot + Math.PI * 0.16);
            ctx.stroke();

            if (ce.mode === 2 && wave.length > 3) {
                // polar waveform ring
                ctx.strokeStyle = root.rgba(ce.colA, 0.85);
                ctx.lineWidth = 2.4;
                ctx.beginPath();
                for (var k = 0; k <= 96; k++) {
                    var ka = (k / 96) * Math.PI * 2 + rot * 0.3;
                    var wv = wave[Math.floor((k % 96) / 96 * wave.length)] || 0;
                    var rr = r0 + wv * (R - r0) * 0.9;
                    var px = cx + Math.cos(ka) * rr, py = cy + Math.sin(ka) * rr;
                    if (k === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                }
                ctx.closePath();
                ctx.stroke();
                ctx.strokeStyle = root.rgba(ce.colB, 0.4);
                ctx.lineWidth = 6;
                ctx.stroke();
            } else {
                var n = Math.max(24, Math.min(ce.bars, (lv.length || 64)));
                var arcStep = (Math.PI * 2 * r0) / n;
                for (var i = 0; i < n; i++) {
                    var v = lv.length ? (lv[Math.floor(i * lv.length / n)] || 0) : 0;
                    var p = pk.length ? (pk[Math.floor(i * pk.length / n)] || 0) : 0;
                    var a = (i / n) * Math.PI * 2 - Math.PI / 2 + rot * 0.35;
                    var len = 4 + v * (R - r0 - 2);
                    var t = Math.min(1, v * 1.7);
                    // tapered bar: bright tip over a deep base
                    var lw = Math.max(2.5, arcStep * 0.52);
                    var tipLen = Math.max(2, len * 0.3);
                    ctx.lineWidth = lw;
                    ctx.globalAlpha = 0.3 + v * 0.55;
                    ctx.strokeStyle = root.mixColor(ce.colA, ce.colB, t * 0.45);
                    ctx.beginPath();
                    ctx.moveTo(cx + Math.cos(a) * r0, cy + Math.sin(a) * r0);
                    ctx.lineTo(cx + Math.cos(a) * (r0 + len - tipLen), cy + Math.sin(a) * (r0 + len - tipLen));
                    ctx.stroke();
                    ctx.globalAlpha = 0.55 + v * 0.45;
                    ctx.strokeStyle = root.mixColor(ce.colA, ce.colB, 0.35 + t * 0.65);
                    ctx.beginPath();
                    ctx.moveTo(cx + Math.cos(a) * (r0 + len - tipLen), cy + Math.sin(a) * (r0 + len - tipLen));
                    ctx.lineTo(cx + Math.cos(a) * (r0 + len), cy + Math.sin(a) * (r0 + len));
                    ctx.stroke();
                    // peak-hold cap: a bright dot that floats above the bar and falls slowly
                    if (p > v + 0.02) {
                        ctx.globalAlpha = 0.85;
                        ctx.fillStyle = root.rgba(ce.colB, 0.9);
                        ctx.beginPath();
                        ctx.arc(cx + Math.cos(a) * (r0 + 3 + p * (R - r0 - 2)), cy + Math.sin(a) * (r0 + 3 + p * (R - r0 - 2)), lw * 0.32, 0, Math.PI * 2);
                        ctx.fill();
                    }
                    // inner mirrored tick - depth cue
                    ctx.globalAlpha = 0.12 + v * 0.26;
                    var il = ce.mode === 1 ? len * 0.5 : len * 0.3;
                    ctx.strokeStyle = root.mixColor(ce.colA, ce.colB, t * 0.6);
                    ctx.beginPath();
                    ctx.moveTo(cx + Math.cos(a) * (r0 - 2), cy + Math.sin(a) * (r0 - 2));
                    ctx.lineTo(cx + Math.cos(a) * (r0 - 2 - il), cy + Math.sin(a) * (r0 - 2 - il));
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
            }
            // guide rings
            ctx.strokeStyle = root.rgba(th.text, 0.07);
            ctx.lineWidth = 1;
            ctx.beginPath(); ctx.arc(cx, cy, r0 - 8, 0, Math.PI * 2); ctx.stroke();
            ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke();
        }
        // The equalizer is a Canvas, and a Canvas rasterises on the GUI
        // thread. Three of these live in the shell (stage, playlist hero,
        // immersive) and their own `visible` stays true even when the page
        // around them does not, so this used to run three large canvases at
        // 60 fps *all the time* while a song played - by far the biggest
        // source of stutter in the room. Only the instance you can actually
        // see ticks now, at 30 fps, which is all a bar meter needs.
        property bool live: true
        Timer {
            interval: 33
            running: ce.live && root.s.playing && root.visible
            repeat: true
            onTriggered: ce.requestPaint()
        }
        // a meter that becomes visible again must not show the last frame it
        // drew minutes ago
        onLiveChanged: if (live) requestPaint()
        Connections { target: root; function onTcChanged() { ce.requestPaint() } }
        Component.onCompleted: requestPaint()
    }

    // vertical EQ gain slider, -12..+12 dB, glass track
    component EqSlider : Item {
        id: eqs
        property real value: 0
        property string label: ""
        signal moved(real v)
        width: 46; height: 176
        readonly property real trackY: 20
        readonly property real trackH: 132
        readonly property real fillH: Math.abs(value) / 12.0 * (trackH / 2 - 4)
        Text { anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter; text: (eqs.value > 0 ? "+" : "") + eqs.value.toFixed(1); color: th.text; font.family: root.tf; font.pixelSize: (10) * root.ts }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: eqs.trackY; height: eqs.trackH; width: 14; radius: 7
            color: tc.light ? "#10000000" : "#14ffffff"
            border.width: 1; border.color: (tc.light ? "#33000000" : "#26ffffff")
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height / 2 - 0.5; width: parent.width - 4; height: 1
                color: (tc.light ? "#38000000" : "#34ffffff")
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                y: eqs.value >= 0 ? parent.height / 2 - eqs.fillH : parent.height / 2
                width: 8; radius: 4; height: eqs.fillH
                color: eqs.value >= 0 ? th.accent : th.dim
            }
        }
        Rectangle {
            width: 22; height: 22; radius: 11
            anchors.horizontalCenter: parent.horizontalCenter
            y: eqs.trackY + eqs.trackH * (1 - (eqs.value + 12) / 24) - 11
            color: th.panel
            border.width: 2; border.color: th.accent
        }
        Text { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; text: eqs.label; color: th.dim; font.family: root.tf; font.pixelSize: (9) * root.ts }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onPressed: eqs.setFromY(mouse.y)
            onPositionChanged: if (pressed) eqs.setFromY(mouse.y)
            onReleased: eqs.moved(eqs.value)
        }
        function setFromY(yp) {
            var t = 1 - (yp - eqs.trackY) / eqs.trackH;
            var v = Math.round(((t * 24) - 12) * 2) / 2;
            value = Math.max(-12, Math.min(12, v));
        }
    }

    // hand-drawn vector icons - drawn once, tinted per theme
    component NavIcon : Canvas {
        id: nv
        property string kind: "cloud"
        property color col: "#ffffff"
        width: 18; height: 18
        onColChanged: requestPaint()
        onKindChanged: requestPaint()
        Component.onCompleted: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var s = width;
            ctx.clearRect(0, 0, s, s);
            ctx.strokeStyle = nv.col;
            ctx.fillStyle = nv.col;
            ctx.lineWidth = Math.max(1.4, s * 0.085);
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            if (kind === "cloud") {
                ctx.beginPath();
                ctx.moveTo(s * 0.18, s * 0.68);
                ctx.bezierCurveTo(s * 0.08, s * 0.54, s * 0.2, s * 0.38, s * 0.36, s * 0.42);
                ctx.bezierCurveTo(s * 0.4, s * 0.24, s * 0.64, s * 0.22, s * 0.7, s * 0.38);
                ctx.bezierCurveTo(s * 0.9, s * 0.36, s * 0.96, s * 0.6, s * 0.82, s * 0.68);
                ctx.closePath();
                ctx.stroke();
            } else if (kind === "home") {
                ctx.beginPath();
                ctx.moveTo(s * 0.18, s * 0.52);
                ctx.lineTo(s * 0.5, s * 0.24);
                ctx.lineTo(s * 0.82, s * 0.52);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.28, s * 0.48);
                ctx.lineTo(s * 0.28, s * 0.8);
                ctx.lineTo(s * 0.72, s * 0.8);
                ctx.lineTo(s * 0.72, s * 0.48);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.5, s * 0.8);
                ctx.lineTo(s * 0.5, s * 0.64);
                ctx.stroke();
            } else if (kind === "wave") {
                var hs = [0.42, 0.8, 0.58, 0.95, 0.5];
                for (var i = 0; i < 5; i++) {
                    var x = s * (0.16 + i * 0.17);
                    var h = s * hs[i] * 0.62;
                    ctx.beginPath();
                    ctx.moveTo(x, s * 0.82);
                    ctx.lineTo(x, s * 0.82 - h);
                    ctx.stroke();
                }
            } else if (kind === "list") {
                for (var j = 0; j < 3; j++) {
                    var y = s * (0.28 + j * 0.22);
                    ctx.beginPath();
                    ctx.arc(s * 0.16, y, s * 0.05, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.beginPath();
                    ctx.moveTo(s * 0.3, y);
                    ctx.lineTo(s * 0.86, y);
                    ctx.stroke();
                }
            } else if (kind === "palette") {
                ctx.beginPath();
                ctx.moveTo(s * 0.5, s * 0.16);
                ctx.bezierCurveTo(s * 0.68, s * 0.4, s * 0.78, s * 0.52, s * 0.78, s * 0.62);
                ctx.bezierCurveTo(s * 0.78, s * 0.82, s * 0.62, s * 0.9, s * 0.5, s * 0.9);
                ctx.bezierCurveTo(s * 0.38, s * 0.9, s * 0.22, s * 0.82, s * 0.22, s * 0.62);
                ctx.bezierCurveTo(s * 0.22, s * 0.52, s * 0.32, s * 0.4, s * 0.5, s * 0.16);
                ctx.closePath();
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.64, s * 0.09, 0, Math.PI * 2);
                ctx.fill();
            } else if (kind === "prev") {
                ctx.beginPath();
                ctx.moveTo(s * 0.78, s * 0.22);
                ctx.lineTo(s * 0.78, s * 0.78);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.64, s * 0.5);
                ctx.lineTo(s * 0.2, s * 0.2);
                ctx.lineTo(s * 0.2, s * 0.8);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "next") {
                ctx.beginPath();
                ctx.moveTo(s * 0.22, s * 0.22);
                ctx.lineTo(s * 0.22, s * 0.78);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.36, s * 0.5);
                ctx.lineTo(s * 0.8, s * 0.2);
                ctx.lineTo(s * 0.8, s * 0.8);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "chev") {
                // a door, not a track: the portal hover hint used the transport
                // "next" glyph, so walking into Playlist looked like seeking
                ctx.beginPath();
                ctx.moveTo(s * 0.42, s * 0.26);
                ctx.lineTo(s * 0.66, s * 0.5);
                ctx.lineTo(s * 0.42, s * 0.74);
                ctx.stroke();
            } else if (kind === "play") {
                ctx.beginPath();
                ctx.moveTo(s * 0.32, s * 0.2);
                ctx.lineTo(s * 0.82, s * 0.5);
                ctx.lineTo(s * 0.32, s * 0.8);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "pause") {
                ctx.beginPath();
                ctx.moveTo(s * 0.3, s * 0.22);
                ctx.lineTo(s * 0.3, s * 0.78);
                ctx.lineWidth = Math.max(2, s * 0.14);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.7, s * 0.22);
                ctx.lineTo(s * 0.7, s * 0.78);
                ctx.stroke();
            } else if (kind === "shuffle") {
                ctx.beginPath();
                ctx.moveTo(s * 0.16, s * 0.3);
                ctx.lineTo(s * 0.52, s * 0.3);
                ctx.quadraticCurveTo(s * 0.84, s * 0.3, s * 0.84, s * 0.58);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.16, s * 0.7);
                ctx.lineTo(s * 0.52, s * 0.7);
                ctx.quadraticCurveTo(s * 0.84, s * 0.7, s * 0.84, s * 0.42);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.74, s * 0.5);
                ctx.lineTo(s * 0.9, s * 0.62);
                ctx.lineTo(s * 0.74, s * 0.74);
                ctx.closePath();
                ctx.fill();
                ctx.beginPath();
                ctx.moveTo(s * 0.74, s * 0.26);
                ctx.lineTo(s * 0.9, s * 0.38);
                ctx.lineTo(s * 0.74, s * 0.5);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "repeat") {
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.52, s * 0.26, Math.PI * 0.2, Math.PI * 1.3);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.72, s * 0.24);
                ctx.lineTo(s * 0.84, s * 0.42);
                ctx.lineTo(s * 0.62, s * 0.42);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "folder") {
                ctx.beginPath();
                ctx.moveTo(s * 0.14, s * 0.26);
                ctx.lineTo(s * 0.38, s * 0.26);
                ctx.lineTo(s * 0.46, s * 0.36);
                ctx.lineTo(s * 0.86, s * 0.36);
                ctx.lineTo(s * 0.86, s * 0.76);
                ctx.lineTo(s * 0.14, s * 0.76);
                ctx.closePath();
                ctx.stroke();
            } else if (kind === "gear") {
                for (var k = 0; k < 8; k++) {
                    var a = k * Math.PI / 4;
                    ctx.beginPath();
                    ctx.moveTo(s * 0.5 + Math.cos(a) * s * 0.30, s * 0.5 + Math.sin(a) * s * 0.30);
                    ctx.lineTo(s * 0.5 + Math.cos(a) * s * 0.42, s * 0.5 + Math.sin(a) * s * 0.42);
                    ctx.stroke();
                }
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.5, s * 0.30, 0, Math.PI * 2);
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.5, s * 0.12, 0, Math.PI * 2);
                ctx.fill();
            } else if (kind === "volume") {
                ctx.beginPath();
                ctx.moveTo(s * 0.16, s * 0.42);
                ctx.lineTo(s * 0.3, s * 0.42);
                ctx.lineTo(s * 0.46, s * 0.28);
                ctx.lineTo(s * 0.46, s * 0.72);
                ctx.lineTo(s * 0.3, s * 0.58);
                ctx.lineTo(s * 0.16, s * 0.58);
                ctx.closePath();
                ctx.fill();
                ctx.beginPath();
                ctx.arc(s * 0.47, s * 0.5, s * 0.18, -Math.PI * 0.42, Math.PI * 0.42);
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(s * 0.47, s * 0.5, s * 0.32, -Math.PI * 0.38, Math.PI * 0.38);
                ctx.stroke();
            } else if (kind === "search") {
                ctx.beginPath();
                ctx.arc(s * 0.44, s * 0.44, s * 0.24, 0, Math.PI * 2);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.62, s * 0.62);
                ctx.lineTo(s * 0.82, s * 0.82);
                ctx.stroke();
            } else if (kind === "trash") {
                ctx.beginPath();
                ctx.moveTo(s * 0.32, s * 0.34);
                ctx.lineTo(s * 0.68, s * 0.34);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.42, s * 0.34);
                ctx.lineTo(s * 0.44, s * 0.24);
                ctx.lineTo(s * 0.56, s * 0.24);
                ctx.lineTo(s * 0.58, s * 0.34);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.38, s * 0.42);
                ctx.lineTo(s * 0.4, s * 0.78);
                ctx.lineTo(s * 0.6, s * 0.78);
                ctx.lineTo(s * 0.62, s * 0.42);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(s * 0.47, s * 0.48);
                ctx.lineTo(s * 0.47, s * 0.7);
                ctx.moveTo(s * 0.53, s * 0.48);
                ctx.lineTo(s * 0.53, s * 0.7);
                ctx.stroke();
            } else if (kind === "heart") {
                ctx.beginPath();
                ctx.moveTo(s * 0.5, s * 0.80);
                ctx.bezierCurveTo(s * 0.10, s * 0.56, s * 0.16, s * 0.16, s * 0.5, s * 0.36);
                ctx.bezierCurveTo(s * 0.84, s * 0.16, s * 0.90, s * 0.56, s * 0.5, s * 0.80);
                ctx.closePath();
                ctx.fill();
            } else if (kind === "info") {
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.5, s * 0.36, 0, Math.PI * 2);
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.31, s * 0.055, 0, Math.PI * 2);
                ctx.fill();
                ctx.beginPath();
                ctx.moveTo(s * 0.5, s * 0.44);
                ctx.lineTo(s * 0.5, s * 0.70);
                ctx.stroke();
            } else if (kind === "spark") {
                ctx.beginPath();
                for (var sp = 0; sp < 8; sp++) {
                    var sa = sp * Math.PI / 4;
                    var sr = (sp % 2 === 0) ? s * 0.38 : s * 0.1;
                    var px = s * 0.5 + Math.cos(sa) * sr;
                    var py = s * 0.5 + Math.sin(sa) * sr;
                    if (sp === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                }
                ctx.closePath();
                ctx.fill();
            } else {
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.5, s * 0.34, 0, Math.PI * 2);
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(s * 0.5, s * 0.5, s * 0.1, 0, Math.PI * 2);
                ctx.fill();
            }
        }
    }

    // ---------------- navigation ----------------
    // The old pull-out column is gone. Everything it used to hold - identity,
    // SPACE label, seven rows, the version stamp - either moved into the
    // header or was already on the page. A full-height panel is the one shape
    // that cannot be blended into a room: its left and right edges are the
    // window, and its top and bottom are two horizontal cuts.
// ---------------- pages container ----------------
    Item {
        id: pagesHost
        z: 2
        opacity: root.themeWorldOpen ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }        anchors.left: contentArea.right
        anchors.right: parent.right
        anchors.top: topbar.bottom
        anchors.bottom: bar.top

        // depth fog between the room and the words: no panel, no edge, just
        // enough distance for type to stay readable over any 3D scene
        Rectangle {
            z: 0
            anchors.fill: parent
            enabled: false
            gradient: Gradient {
                orientation: Gradient.Vertical
                // the fog has no top or bottom edge: it arrives from nothing and
                // returns to nothing, so the page never feels like a panel
                GradientStop { position: 0; color: root.rgba(th.bg, 0) }
                GradientStop { position: 0.16; color: root.rgba(th.bg, tc.light ? 0.46 : 0.24) }
                GradientStop { position: 0.5; color: root.rgba(th.bg, tc.light ? 0.28 : 0.14) }
                GradientStop { position: 0.86; color: root.rgba(th.bg, tc.light ? 0.36 : 0.20) }
                GradientStop { position: 1; color: root.rgba(th.bg, 0) }
            }
        }

        // the room is lit from the side you entered from, then the light
        // settles: the page change reads as a change of place, not of file
        Rectangle {
            z: 4
            anchors.fill: parent
            enabled: false
            visible: root.trBloom > 0.01
            opacity: Math.min(1, root.trBloom * 1.1)
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: root.rgba(th.accent, root.navDir < 0 ? 0.13 : 0.0) }
                GradientStop { position: 0.26; color: root.rgba(th.accent, 0.02) }
                GradientStop { position: 0.74; color: root.rgba(root.accent2(), 0.02) }
                GradientStop { position: 1.0; color: root.rgba(root.accent2(), root.navDir > 0 ? 0.13 : 0.0) }
            }
        }
        // No travelling hairline, no crossing band. A page change is carried by
        // the page itself (slide, fade, depth) and by the dye bloom; anything
        // drawn on top of the room to "announce" the move is a line the eye
        // cannot unsee, so it is gone.

        // PAGE 0: LIBRARY
        Item {
            id: page0
            property int pageIndex: 0
            anchors.fill: parent
            visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
            z: pageIndex === root.currentPage ? 2 : 1
            clip: true
            readonly property var tv: root.trFor(pageIndex)
            opacity: page0.tv.o
            transform: [
                Translate { x: page0.tv.x; y: page0.tv.y },
                Rotation { origin.x: page0.width / 2; origin.y: page0.height / 2; axis { x: 0; y: 1; z: 0 } angle: page0.tv.ry },
                Scale { origin.x: page0.width / 2; origin.y: page0.height / 2; xScale: page0.tv.s; yScale: page0.tv.s }
            ]

            ColumnLayout {
                id: plDetailBody
                anchors.fill: parent
                anchors.leftMargin: 30; anchors.rightMargin: 30
                anchors.topMargin: 10; anchors.bottomMargin: 10
                spacing: 18
                transformOrigin: Item.Center
                opacity: root.plOpen ? 1 : 0
                enabled: root.plOpen
                scale: root.plOpen ? 1 : 0.982
                Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

                // ---------------- playlist identity ----------------
                // Open editorial header: artwork and type sit directly in the room.
                Rectangle {
                    Layout.fillWidth: true
                    height: 160
                    radius: 0
                    color: "transparent"
                    border.width: 0
                    clip: true

                    // (the accent pool that used to wash this header is gone:
                    // behind the cover it read as a coloured plate, which is the
                    // exact "separate square" look the room is trying to lose)


                    RowLayout {
                        anchors.fill: parent
                        anchors.topMargin: 10; anchors.bottomMargin: 14
                        anchors.leftMargin: 4; anchors.rightMargin: 4
                        spacing: 22

                        Item {
                            width: 112; height: 112
                            Layout.alignment: Qt.AlignVCenter
                            // no RectangularShadow here: on this renderer it draws
                            // as a solid plate slightly larger than the artwork
                            Art {
                                id: listArt
                                anchors.fill: parent
                                corner: 18
                                seed: 1
                                source: root.libCover()
                            }
                            Rectangle {
                                anchors.right: parent.right; anchors.bottom: parent.bottom
                                anchors.margins: 7
                                width: 26; height: 26; radius: 13
                                color: root.rgba(th.bg, 0.78)
                                border.width: 1; border.color: root.rgba("#ffffff", 0.35)
                                NavIcon { anchors.centerIn: parent; width: 12; height: 12; kind: "wave"; col: th.accent }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 3
                            RowLayout {
                                spacing: 10
                                // out of the list and back onto the shelf. one text,
                                // one hit area: nothing to overlap
                                Item {
                                    width: backLabel.implicitWidth + 4
                                    height: 18
                                    Text {
                                        id: backLabel
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "\u2039  ALL PLAYLISTS"
                                        color: plBackMa.containsMouse ? th.accent : root.rgba(th.accent, 0.78)
                                        font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.3
                                        Behavior on color { ColorAnimation { duration: 140 } }
                                    }
                                    MouseArea {
                                        id: plBackMa
                                        anchors.fill: parent; anchors.margins: -8
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.closePlaylist() }
                                    }
                                }
                                Rectangle { width: 3; height: 3; radius: 1.5; color: root.rgba(th.dim, 0.5) }
                                Text { text: "PLAYLIST"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2 }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.readable(root.lib.playlist_name)
                                color: th.text
                                font.family: root.tf; font.pixelSize: (25) * root.ts; font.bold: true; font.letterSpacing: -0.3
                                elide: Text.ElideRight
                            }
                            Text {
                                text: (root.lib.playlist_owner || "you") + "  ·  " + root.lib.stream_count + " songs in this list  ·  " + root.lib.local_count + " local files stay in the vault"
                                color: root.rgba(th.dim, 0.9); font.family: root.tf; font.pixelSize: (10) * root.ts
                            }
                            RowLayout {
                                spacing: 6
                                Rectangle {
                                    width: plStreamText.width + 14; height: 19; radius: 9
                                    color: root.rgba(th.accent, 0.1)
                                    border.width: 1; border.color: root.rgba(th.accent, 0.25)
                                    Text { id: plStreamText; anchors.centerIn: parent; text: root.lib.stream_count + " IN PLAYLIST"; color: root.rgba(th.accent, 0.9); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                                }
                                Rectangle {
                                    width: plLocalText.width + 14; height: 19; radius: 9
                                    color: root.rgba(th.bar, 0.08)
                                    border.width: 1; border.color: root.rgba(th.bar, 0.22)
                                    Text { id: plLocalText; anchors.centerIn: parent; text: root.lib.local_count + " LOCAL VAULT"; color: root.rgba(th.bar, 0.85); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.preferredWidth: 306
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 8

                            // search
                            Rectangle {
                                Layout.fillWidth: true
                                height: 36
                                radius: 18
                                color: tc.light ? "#14000000" : "#10ffffff"
                                border.width: searchField.activeFocus ? 1.5 : 1
                                border.color: searchField.activeFocus ? root.rgba(th.accent, 0.65) : (tc.light ? "#24000000" : "#1effffff")
                                Behavior on border.color { ColorAnimation { duration: 180 } }

                                NavIcon {
                                    x: 13; width: 13; height: 13
                                    anchors.verticalCenter: parent.verticalCenter
                                    kind: "search"
                                    col: root.rgba(th.dim, 0.8)
                                }
                                TextField {
                                    Keys.onPressed: function(ev) {
                                        if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                            root.typeKey();
                                    }
                                    id: searchField
                                    anchors.left: parent.left; anchors.leftMargin: 34
                                    anchors.right: clearSearch.left; anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    placeholderText: "search title, artist or album"
                                    color: th.text
                                    placeholderTextColor: root.rgba(th.dim, 0.6)
                                    font.family: root.tf; font.pixelSize: (10) * root.ts
                                    selectByMouse: true
                                    background: Item { }
                                    onTextChanged: { root.searchQ = text; root.applyFilter(); }
                                }
                                Item {
                                    id: clearSearch
                                    anchors.right: parent.right; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16; height: 16
                                    visible: searchField.text.length > 0
                                    Text { anchors.centerIn: parent; text: "\u2715"; color: root.rgba(th.dim, 0.9); font.family: root.tf; font.pixelSize: (10) * root.ts }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); searchField.text = ""; root.searchQ = ""; root.applyFilter(); }
                                    }
                                }
                            }

                            // view controls: order, liked-only, and how big the
                            // room actually is
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Rectangle {
                                    width: sortTxt.width + 18; height: 22; radius: 11
                                    color: sortMa.containsMouse ? root.rgba(th.accent, 0.18) : root.rgba(th.accent, 0.09)
                                    border.width: 1; border.color: root.rgba(th.accent, 0.28)
                                    Behavior on color { ColorAnimation { duration: 140 } }
                                    Text {
                                        id: sortTxt; anchors.centerIn: parent
                                        text: "SORT " + root.sortLabel()
                                        color: th.accent; font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                    }
                                    MouseArea { id: sortMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.cycleSort() } }
                                }
                                Rectangle {
                                    width: likedTxt.width + 18; height: 22; radius: 11
                                    color: root.likedOnly ? root.rgba(th.accent, 0.22)
                                         : (likedMa.containsMouse ? root.rgba(th.accent, 0.12) : root.rgba("#ffffff", 0.045))
                                    border.width: 1
                                    border.color: root.likedOnly ? root.rgba(th.accent, 0.55) : root.rgba("#ffffff", 0.14)
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Text {
                                        id: likedTxt; anchors.centerIn: parent
                                        text: "\u2665 " + (root.lib.liked || 0) + " LIKED"
                                        color: root.likedOnly ? th.accent : root.rgba(th.text, 0.78)
                                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                    }
                                    MouseArea { id: likedMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.toggleLikedView() } }
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    // both numbers describe the *view*, so a
                                    // filter never leaves a count and a
                                    // duration that disagree
                                    text: (root.filtered.length) + "  \u00b7  " + root.fmtLong(root.filteredMs())
                                    color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 7
                                GlowButton {
                                    label: "PLAY ALL"
                                    bh: 32
                                    glow: th.accent
                                    onClicked: { var t = root.trackById(root.filtered.length > 0 ? root.filtered[0].id : -1);
                                        if (t) root.hit("/play?id=" + t.id);
                                    }
                                }
                                GlowButton {
                                    label: "+ ADD MUSIC"
                                    bh: 32
                                    glow: th.accent
                                    onClicked: { addSheet.open() }
                                }
                                GlowButton {
                                    label: root.syncBusy ? "SYNCING" : "SYNC"
                                    bh: 32
                                    glow: th.bar
                                    onClicked: { root.syncBusy = true;
                                        syncToast.show("syncing playlist...");
                                        root.fetchJson("/catalog/sync", function(r) {
                                            root.syncBusy = false;
                                            if (!r.ok) syncToast.show("sync unavailable (offline)");
                                            else if (r.added > 0) syncToast.show("+" + r.added + " new track" + (r.added === 1 ? "" : "s"));
                                            else syncToast.show("catalog up to date");
                                        });
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: "LOCAL VAULT  " + root.lib.local_count + "  \u2192"
                                    color: vaultMa.containsMouse ? th.bar : root.rgba(th.bar, 0.72)
                                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                    MouseArea {
                                        id: vaultMa
                                        anchors.fill: parent; anchors.margins: -6
                                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.gotoPage(1) }
                                    }
                                }
                            }
                        }
                    }
                }


                // ---------------- tracks ----------------
                // The list is the page. No panel, no inner tray.
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 12; Layout.rightMargin: 14
                            Layout.topMargin: 5; Layout.bottomMargin: 7
                            spacing: 12
                            Text { text: "#"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.preferredWidth: 24; horizontalAlignment: Text.AlignHCenter }
                            Item { width: 34; height: 1 }
                            Text { text: "TITLE"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.fillWidth: true }
                            Text { text: "ALBUM"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.preferredWidth: 220; visible: root.width > 1150 }
                            Text { text: "TIME"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.preferredWidth: 42; horizontalAlignment: Text.AlignRight }
                        }

                        Flickable {
                            id: listFlick
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: listMask
                            }
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            contentHeight: listCol.height
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            flickDeceleration: 1200
                            maximumFlickVelocity: 3200
                            ScrollBar.vertical: GlassScroll { }
                            GlideWheel { view: listFlick; step: 130 }
                            Connections {
                                target: root
                                function onFilteredChanged() { listFlick.contentY = 0; }
                            }

                            ColumnLayout {
                                id: listCol
                                width: listFlick.width
                                spacing: 2
                                Layout.topMargin: 4

                                Repeater {
                                    model: root.filtered
                                    delegate: Rectangle {
                                        id: row
                                        readonly property var trk: modelData
                                        readonly property bool isCur: root.s.track_id === trk.id
                                        readonly property real casc: root.cascFor(index, 0)
                                        Layout.fillWidth: true
                                        height: 50
                                        radius: 0
                                        color: isCur ? root.rgba(th.accent, 0.075) : (rowMa.containsMouse ? (tc.light ? "#0b000000" : "#09ffffff") : "transparent")
                                        Behavior on color { ColorAnimation { duration: 160 } }
                                        opacity: casc
                                        transform: Translate { y: (1 - casc) * 12 }

                                        Rectangle {
                                            visible: isCur || rowMa.containsMouse
                                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                            width: 2; height: 24; radius: 1
                                            color: isCur ? th.accent : root.rgba(th.accent, rowMa.containsMouse ? 0.45 : 0)
                                        }
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 12; anchors.rightMargin: 14
                                            spacing: 12

                                            Item {
                                                Layout.preferredWidth: 24
                                                Layout.fillHeight: true
                                                Text {
                                                    anchors.centerIn: parent
                                                    visible: !rowMa.containsMouse
                                                    text: index + 1
                                                    color: isCur ? th.accent : root.rgba(th.dim, 0.55)
                                                    font.pixelSize: (10) * root.ts; font.family: "Consolas"
                                                }
                                                NavIcon {
                                                    anchors.centerIn: parent
                                                    visible: rowMa.containsMouse
                                                    width: 13; height: 13
                                                    kind: isCur && root.s.playing ? "pause" : "play"
                                                    col: isCur ? th.accent : th.text
                                                }
                                            }

                                            Item {
                                                width: 34; height: 34
                                                Layout.alignment: Qt.AlignVCenter
                                                Art {
                                                    anchors.fill: parent
                                                    corner: 8
                                                    seed: row.trk.id
                                                    source: row.trk.cover && row.trk.cover.length > 4 ? row.trk.cover : ""
                                                    scale: rowArtMa.pressed ? 0.93 : (rowMa.containsMouse ? 1.05 : 1)
                                                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                                }
                                                Rectangle {
                                                    anchors.fill: parent; radius: 8
                                                    color: root.rgba(th.bg, 0.35)
                                                    opacity: rowArtMa.containsMouse ? 1 : 0
                                                    Behavior on opacity { NumberAnimation { duration: 140 } }
                                                    NavIcon { anchors.centerIn: parent; width: 11; height: 11; kind: isCur && root.s.playing ? "pause" : "play"; col: "" + th.text }
                                                }
                                                MouseArea {
                                                    id: rowArtMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.playTap();
                                                        if (row.trk.playable || (row.trk.streamable && root.s.streaming)) root.hit("/play?id=" + row.trk.id);
                                                        else streamSheet.openFor(row.trk.id, row.trk.title, row.trk.artist);
                                                    }
                                                }
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 0
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: row.trk.title
                                                    color: row.isCur ? th.accent : th.text
                                                    font.family: root.tf; font.pixelSize: (12) * root.ts
                                                    font.bold: row.isCur
                                                    elide: Text.ElideRight
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: row.trk.artist
                                                    color: root.rgba(th.dim, 0.82)
                                                    font.family: root.tf; font.pixelSize: (9) * root.ts
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Text {
                                                Layout.preferredWidth: 220
                                                visible: root.width > 1150
                                                text: row.trk.album || ""
                                                color: root.rgba(th.dim, 0.55)
                                                font.family: root.tf; font.pixelSize: (9) * root.ts
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                visible: !row.trk.playable
                                                text: row.trk.streamable && root.s.streaming ? "STREAM" : "CATALOG"
                                                color: row.trk.streamable && root.s.streaming ? root.rgba(th.accent, 0.8) : root.rgba(th.dim, 0.5)
                                                font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                            }
                                            Text {
                                                visible: row.trk.playable && row.trk.origin === "local"
                                                text: "LOCAL"
                                                color: root.rgba(th.dim, 0.45)
                                                font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                            }

                                            // the heart is a like, not a rating: it is
                                            // always there once given, and slides in
                                            // under the hand otherwise
                                            Item {
                                                Layout.preferredWidth: 18
                                                Layout.fillHeight: true
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: root.isLiked(row.trk) ? "\u2665" : "\u2661"
                                                    color: root.isLiked(row.trk) ? th.accent : root.rgba(th.text, 0.55)
                                                    // a like is discoverable before it is
                                                    // given: faint, never invisible
                                                    opacity: root.isLiked(row.trk) ? 1 : ((rowMa.containsMouse || heartMa.containsMouse) ? 0.92 : 0.3)
                                                    Behavior on opacity { NumberAnimation { duration: 140 } }
                                                    font.pixelSize: (13) * root.ts
                                                }
                                                MouseArea {
                                                    id: heartMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.playTap(); root.toggleLike(row.trk) }
                                                }
                                            }

                                            // removal lives on the row itself: one quiet
                                            // mark, only there under the hand
                                            Item {
                                                Layout.preferredWidth: 20
                                                Layout.fillHeight: true
                                                opacity: rowMa.containsMouse ? 1 : 0
                                                Behavior on opacity { NumberAnimation { duration: 140 } }
                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: 18; height: 18; radius: 9
                                                    color: removeMa.containsMouse ? root.rgba("#ff8a8a", 0.2) : "transparent"
                                                    Behavior on color { ColorAnimation { duration: 120 } }
                                                    Text {
                                                        anchors.centerIn: parent
                                                        text: "\u2715"
                                                        color: removeMa.containsMouse ? "#ff9a9a" : root.rgba(th.dim, 0.8)
                                                        font.family: root.tf; font.pixelSize: (9) * root.ts
                                                    }
                                                }
                                            }

                                            Text {
                                                Layout.preferredWidth: 42
                                                horizontalAlignment: Text.AlignRight
                                                text: root.fmt(row.trk.duration_ms)
                                                color: root.rgba(th.dim, 0.7)
                                                font.pixelSize: (9) * root.ts; font.family: "Consolas"
                                            }
                                        }

                                        MouseArea {
                                            id: rowMa
                                            // under the row's own controls (heart,
                                            // remove) but still over its background:
                                            // a like must never start the song
                                            z: -1
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                                            onClicked: { root.playTap();
                                                if (mouse.button === Qt.RightButton) {
                                                    var gp = mapToItem(null, mouse.x, mouse.y);
                                                    root.openCtx(row.trk, gp.x, gp.y);
                                                    return;
                                                }
                                                if (row.trk.playable || (row.trk.streamable && root.s.streaming)) root.hit("/play?id=" + row.trk.id);
                                                else streamSheet.openFor(row.trk.id, row.trk.title, row.trk.artist);
                                            }
                                        }

                                        // sits above the row's own click surface, so the
                                        // mark removes instead of starting the song
                                        MouseArea {
                                            id: removeMa
                                            anchors.right: parent.right; anchors.rightMargin: 68
                                            width: 20; height: 40
                                            anchors.verticalCenter: parent.verticalCenter
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.playTap(); root.removeTrackFromPlaylist(row.trk) }
                                        }


                                    }
                                }

                                ColumnLayout {
                                    visible: root.filtered.length === 0
                                    Layout.fillWidth: true
                                    spacing: 10
                                    Item { Layout.fillHeight: true; Layout.minimumHeight: 34 }
                                    Rectangle {
                                        Layout.alignment: Qt.AlignHCenter
                                        width: 58; height: 58; radius: 29
                                        color: root.rgba(th.accent, 0.08)
                                        border.width: 1; border.color: root.rgba(th.accent, 0.24)
                                        NavIcon { anchors.centerIn: parent; width: 22; height: 22; kind: root.searchQ.length > 0 ? "search" : "cloud"; col: "" + th.accent; opacity: 0.8 }
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: root.searchQ.length > 0 ? ("nothing matches \u201c" + root.searchQ + "\u201d") : "no tracks yet"
                                        color: th.text; font.family: root.tf; font.pixelSize: (14) * root.ts; font.bold: true
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: root.searchQ.length > 0 ? "try a shorter phrase, or clear the search" : "press + ADD MUSIC, or drop a file into Downloads"
                                        color: root.rgba(th.dim, 0.75); font.family: root.tf; font.pixelSize: (10) * root.ts
                                    }
                                    GlowButton {
                                        Layout.alignment: Qt.AlignHCenter
                                        visible: root.searchQ.length > 0
                                        label: "CLEAR SEARCH"
                                        onClicked: { searchField.text = ""; root.searchQ = ""; root.applyFilter(); }
                                    }
                                    Item { Layout.fillHeight: true; Layout.minimumHeight: 34 }
                                }

                                Item { height: 6 }
                            }
                        }
                    }
                }
            }

            // ---------------- playlist shelf ----------------
            // The room opens on the collection instead of one list: every saved
            // playlist is a card with its own art, and the add tile sits in the
            // same grid. Choosing a card carries you into that list; the back
            // mark in the header brings you out to the shelf again.
            Item {
                id: shelf
                anchors.fill: parent
                anchors.leftMargin: 30; anchors.rightMargin: 30
                anchors.topMargin: 10; anchors.bottomMargin: 10
                opacity: root.plOpen ? 0 : 1
                visible: opacity > 0.004
                enabled: !root.plOpen
                Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                property real drift: root.plOpen ? 1 : 0
                Behavior on drift { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
                transform: Translate { x: -24 * shelf.drift; y: -8 * shelf.drift }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14
                        ColumnLayout {
                            spacing: 4
                            Text {
                                text: "PLAYLISTS"
                                color: th.text
                                font.family: root.tf; font.pixelSize: (27) * root.ts; font.bold: true; font.letterSpacing: -0.4
                            }
                            Text {
                                text: root.playlistRows.length + (root.playlistRows.length === 1 ? " collection" : " collections")
                                      + "  \u00b7  a shelf of rooms, each with its own songs"
                                color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (10) * root.ts
                            }
                        }
                        Item { Layout.fillWidth: true }
                        // an import keeps building in the background: the shelf shows its pulse
                        Rectangle {
                            visible: root.importStatus.running
                            width: importPill.width + 22; height: 26; radius: 13
                            color: root.rgba(th.bar, 0.14)
                            Row {
                                id: importPill
                                anchors.centerIn: parent
                                spacing: 7
                                Rectangle {
                                    width: 5; height: 5; radius: 2.5; anchors.verticalCenter: parent.verticalCenter
                                    color: th.bar
                                    SequentialAnimation on opacity { loops: Animation.Infinite; NumberAnimation { to: 0.25; duration: 800; easing.type: Easing.InOutSine } NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine } }
                                }
                                Text {
                                    text: "IMPORTING " + root.importStatus.done + "/" + root.importStatus.total
                                    color: th.bar; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.2
                                }
                            }
                        }
                        GlowButton {
                            label: "FROM LINK"
                            bh: 32
                            glow: th.bar
                            onClicked: { importPanel.show() }
                        }
                        GlowButton {
                            label: root.shelfCreating ? "CLOSE" : "+ NEW PLAYLIST"
                            bh: 32
                            glow: th.accent
                            onClicked: { root.shelfCreating = !root.shelfCreating;
                                if (root.shelfCreating) Qt.callLater(function() { if (shelfName) shelfName.forceActiveFocus() });
                            }
                        }
                    }

                    Item { height: 8 }

                    Flickable {
                        id: shelfFlick
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentWidth: width
                        contentHeight: shelfFlow.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 1100
                        maximumFlickVelocity: 3000
                        ScrollBar.vertical: GlassScroll { }
                        GlideWheel { view: shelfFlick; step: 120 }

                        Flow {
                            id: shelfFlow
                            width: shelfFlick.width
                            spacing: 24

                            Repeater {
                                model: root.playlistRows
                                delegate: Item {
                                    id: plCard
                                    readonly property bool on: modelData.active
                                    width: 172
                                    height: 244
                                    property real hov: plCardMa.containsMouse ? 1 : 0
                                    property bool renaming: false
                                    property bool menu: false
                                    Behavior on hov { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

                                    // (the two tinted "sleeves" that fanned out behind
                                    //  every playlist cover are gone - on a busy shelf
                                    //  they read as coloured squares stacked behind the
                                    //  art, which is exactly the sectioned look we are
                                    //  losing. The shadow under the cover carries depth.)

                                    Item {
                                        id: plCardArt
                                        width: 160; height: 160
                                        y: -4 * plCard.hov
                                        Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

                                        // (the shadow plate under each playlist cover
                                        //  is gone; the cover meets the room directly)
                                        Art {
                                            anchors.fill: parent
                                            corner: 18
                                            seed: index + 3
                                            source: (modelData.cover && ("" + modelData.cover).length > 4) ? modelData.cover
                                                    : (modelData.covers && modelData.covers.length > 0 ? modelData.covers[0] : "")
                                            scale: 1 + 0.022 * plCard.hov
                                            Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                                        }
                                        // a nail of light marks the list you are standing in
                                        Rectangle {
                                            anchors.fill: parent; radius: 18
                                            color: "transparent"
                                            border.width: 1.5
                                            border.color: root.rgba(th.accent, plCard.on ? 0.85 : 0.0)
                                            Behavior on border.color { ColorAnimation { duration: 200 } }
                                        }
                                        Rectangle {
                                            anchors.right: parent.right; anchors.bottom: parent.bottom
                                            anchors.margins: 9
                                            width: plCount.width + 16; height: 21; radius: 10.5
                                            color: root.rgba(th.bg, 0.62)
                                            Text {
                                                id: plCount
                                                anchors.centerIn: parent
                                                text: modelData.total
                                                color: root.rgba(th.text, 0.92)
                                                font.pixelSize: (8) * root.ts; font.bold: true; font.family: "Consolas"
                                            }
                                        }
                                        // the open list answers the pointer: a play mark
                                        // rises out of the art like it does on a song row
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 46; height: 46; radius: 23
                                            color: root.rgba(th.bg, 0.55)
                                            border.width: 1; border.color: root.rgba("#ffffff", 0.25)
                                            opacity: plCard.hov * (plCard.on ? 0 : 1)
                                            scale: 0.8 + plCard.hov * 0.2
                                            Behavior on opacity { NumberAnimation { duration: 160 } }
                                            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                                            NavIcon {
                                                anchors.centerIn: parent
                                                width: 16; height: 16; kind: "play"
                                                col: "" + th.text
                                            }
                                        }
                                    }

                                    // the name doubles as a field while renaming: the
                                    // card never jumps to another shape, it just becomes
                                    // editable where the eye already is
                                    TextInput {
                                        id: plRename
                                        y: 172
                                        width: parent.width - 6
                                        height: 20
                                        visible: plCard.renaming
                                        text: modelData.name
                                        color: th.accent
                                        selectionColor: root.rgba(th.accent, 0.35)
                                        selectedTextColor: th.bg
                                        font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true
                                        clip: true
                                        onAccepted: root.renamePlaylist(modelData.id, text)
                                        Keys.onEscapePressed: { plCard.renaming = false; root.loadPlaylists() }
                                    }
                                    Text {
                                        y: 172
                                        width: parent.width - 6
                                        visible: !plCard.renaming
                                        text: root.readable(modelData.name)
                                        color: plCard.on ? th.accent : th.text
                                        font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true
                                        elide: Text.ElideRight
                                    }
                                    // one hover affordance, top-right of the sleeve, holding
                                    // the two things a room can do to itself. It sits on the
                                    // art so it costs no layout and never crowds the name.
                                    Item {
                                        width: 22; height: 22
                                        x: plCardArt.width - 26
                                        y: plCardArt.y + 4
                                        z: 3
                                        opacity: (plCard.hov || plCard.menu) ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 160 } }
                                        Rectangle {
                                            anchors.fill: parent; radius: 11
                                            color: root.rgba(th.bg, plCard.menu ? 0.85 : 0.55)
                                            border.width: 1
                                            border.color: root.rgba(th.text, 0.16)
                                        }
                                        Text {
                                            anchors.centerIn: parent
                                            text: "\u22ef"
                                            color: root.rgba(th.text, 0.9)
                                            font.pixelSize: (13) * root.ts; font.bold: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.playTap(); plCard.menu = !plCard.menu }
                                        }
                                    }
                                    Column {
                                        z: 4
                                        visible: opacity > 0
                                        opacity: plCard.menu ? 1 : 0
                                        x: plCardArt.width - 106
                                        y: plCardArt.y + 30
                                        spacing: 4
                                        Behavior on opacity { NumberAnimation { duration: 140 } }
                                        Rectangle {
                                            width: 88; height: 24; radius: 12
                                            color: renMa.containsMouse ? root.rgba(th.accent, 0.24) : root.rgba(th.bg, 0.88)
                                            border.width: 1; border.color: root.rgba(th.text, 0.12)
                                            Behavior on color { ColorAnimation { duration: 130 } }
                                            Text {
                                                anchors.centerIn: parent; text: "RENAME"
                                                color: renMa.containsMouse ? th.accent : root.rgba(th.text, 0.9)
                                                font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                            }
                                            MouseArea {
                                                id: renMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    plCard.menu = false;
                                                    plCard.renaming = true;
                                                    Qt.callLater(function() { plRename.forceActiveFocus(); plRename.selectAll(); });
                                                }
                                            }
                                        }
                                        Rectangle {
                                            width: 88; height: 24; radius: 12
                                            color: retMa.containsMouse ? root.rgba("#ff6b81", 0.22) : root.rgba(th.bg, 0.88)
                                            border.width: 1; border.color: root.rgba(th.text, 0.12)
                                            Behavior on color { ColorAnimation { duration: 130 } }
                                            Text {
                                                anchors.centerIn: parent
                                                text: "REMOVE"
                                                color: retMa.containsMouse ? "#ff8095" : root.rgba(th.text, 0.75)
                                                font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                            }
                                            MouseArea {
                                                id: retMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { plCard.menu = false; root.retirePlaylist(modelData.id, modelData.name) }
                                            }
                                        }
                                    }
                                    Row {
                                        y: 196
                                        spacing: 6
                                        Rectangle {
                                            width: 5; height: 5; radius: 2.5
                                            color: plCard.on ? th.accent : root.rgba(th.dim, 0.5)
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                        Text {
                                            text: plCard.on
                                                  ? (root.s.playing ? "PLAYING FROM HERE" : "OPEN  \u00b7  ACTIVE")
                                                  : (modelData.total + " SONGS")
                                            color: plCard.on ? root.rgba(th.accent, 0.85) : root.rgba(th.dim, 0.6)
                                            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                        }
                                    }

                                    // the whole card is the door - and, like a song row,
                                    // the door sits *under* everything else, or the rename
                                    // field and the menu would never see a click
                                    MouseArea {
                                        id: plCardMa
                                        anchors.fill: parent
                                        anchors.topMargin: -6
                                        z: -1
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.playTap();
                                            if (plCard.renaming || plCard.menu) { plCard.menu = false; return; }
                                            root.openPlaylist(modelData.id)
                                        }
                                    }
                                }
                            }

                            // ---------------- make a new one ----------------
                            Item {
                                id: newCard
                                width: 172
                                height: 244
                                property real hov: newCardMa.containsMouse ? 1 : 0
                                Behavior on hov { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                Rectangle {
                                    width: 160; height: 160; radius: 18
                                    border.width: 1
                                    border.color: root.rgba(th.accent, root.shelfCreating ? 0.65 : (0.18 + newCard.hov * 0.22))
                                    gradient: Gradient {
                                        orientation: Gradient.Vertical
                                        GradientStop { position: 0; color: root.rgba(th.accent, 0.02 + newCard.hov * 0.03) }
                                        GradientStop { position: 1; color: root.rgba(th.accent, 0.10 + newCard.hov * 0.05) }
                                    }
                                    Behavior on border.color { ColorAnimation { duration: 180 } }
                                    // a ring you can press, not a floating glyph
                                    Rectangle {
                                        anchors.centerIn: parent
                                        anchors.verticalCenterOffset: -6
                                        width: 52; height: 52; radius: 26
                                        color: root.rgba(th.accent, root.shelfCreating ? 0.22 : 0.10 + newCard.hov * 0.06)
                                        border.width: 1; border.color: root.rgba(th.accent, 0.35)
                                        Behavior on color { ColorAnimation { duration: 180 } }
                                        Text {
                                            anchors.centerIn: parent
                                            anchors.verticalCenterOffset: -2
                                            text: "+"
                                            color: root.rgba(th.accent, root.shelfCreating ? 1 : 0.85)
                                            font.family: root.tf; font.pixelSize: (30) * root.ts; font.weight: Font.Light
                                        }
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom; anchors.bottomMargin: 16
                                        text: root.shelfCreating ? "NAME YOUR ROOM" : "EMPTY ROOM"
                                        color: root.rgba(th.accent, 0.62)
                                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                                    }
                                    MouseArea {
                                        id: newCardMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap();
                                            root.shelfCreating = true;
                                            Qt.callLater(function() { if (shelfName) shelfName.forceActiveFocus() });
                                        }
                                    }
                                }
                                Text {
                                    y: 172
                                    width: parent.width - 6
                                    text: root.shelfCreating ? "new playlist" : "NEW PLAYLIST"
                                    color: (newCard.hov || root.shelfCreating) ? th.accent : th.text
                                    font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true; font.letterSpacing: 0.4
                                    elide: Text.ElideRight
                                }
                                Rectangle {
                                    visible: root.shelfCreating
                                    y: 200
                                    width: 160; height: 26
                                    color: "transparent"
                                    Rectangle {
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                        height: 1
                                        color: shelfName.activeFocus ? root.rgba(th.accent, 0.85) : root.rgba(th.text, 0.22)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                    }
                                    TextField {
                                        Keys.onPressed: function(ev) {
                                            if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                                root.typeKey();
                                        }
                                        id: shelfName
                                        anchors.fill: parent
                                        placeholderText: "name it, then enter"
                                        color: th.text
                                        placeholderTextColor: root.rgba(th.dim, 0.55)
                                        font.family: root.tf; font.pixelSize: (11) * root.ts
                                        selectByMouse: true
                                        background: Item { }
                                        onAccepted: { root.createPlaylist(text); text = ""; }
                                        Keys.onEscapePressed: { root.shelfCreating = false; text = ""; }
                                    }
                                }
                                Text {
                                    visible: !root.shelfCreating
                                    y: 196
                                    width: parent.width - 6
                                    text: "start an empty room"
                                    color: root.rgba(th.dim, 0.6)
                                    font.family: root.tf; font.pixelSize: (8) * root.ts
                                }
                            }

                        }
                    }
                }
            }
        }
    }

    // PAGE 1: LOCAL (playable files)
    Item {
        id: page1
        property int pageIndex: 1
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page1.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page1.tv.rz
        transform: [
            Translate { x: page1.tv.x; y: page1.tv.y },
            Rotation { origin.x: page1.width / 2; origin.y: page1.height / 2; axis { x: 0; y: 1; z: 0 } angle: page1.tv.ry },
            Scale { origin.x: page1.width / 2; origin.y: page1.height / 2; xScale: page1.tv.s; yScale: page1.tv.s }
        ]

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 30; anchors.rightMargin: 30
            anchors.topMargin: 10; anchors.bottomMargin: 10
            spacing: 18

            // ---------------- vault header ----------------
            Rectangle {
                Layout.fillWidth: true
                height: 126
                radius: 0
                color: "transparent"
                border.width: 0
                clip: true

                // No band behind the vault header. A horizontal gradient has no
                // vertical stops, so its top and bottom edges sat at full alpha
                // and drew a 500x126 rectangle over the room - the "overlaying
                // box". The icon's own disc is the only surface here.

                RowLayout {
                    anchors.fill: parent
                    anchors.topMargin: 6; anchors.bottomMargin: 14
                    anchors.leftMargin: 4; anchors.rightMargin: 4
                    spacing: 18

                    Item {
                        width: 64; height: 64
                        Layout.alignment: Qt.AlignVCenter
                        Rectangle {
                            anchors.fill: parent; radius: 32
                            color: root.rgba(th.bar, 0.08)
                        }
                        NavIcon { anchors.centerIn: parent; width: 30; height: 30; kind: "folder"; col: "" + th.bar }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 2
                        Text { text: "ON THIS MACHINE"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2 }
                        Text { text: "LOCAL VAULT"; color: th.text; font.family: root.tf; font.pixelSize: (25) * root.ts; font.bold: true; font.letterSpacing: -0.2 }
                        Text {
                            text: root.localFiltered.length + " loose files  ·  outside the active playlist  ·  art pulled straight from the audio"
                            color: root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (10) * root.ts
                        }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 8

                        Rectangle {
                            width: 224; height: 34; radius: 17
                            color: tc.light ? "#14000000" : "#10ffffff"
                            border.width: 1; border.color: localSearch.activeFocus ? root.rgba(th.accent, 0.6) : (tc.light ? "#24000000" : "#1effffff")
                            NavIcon { x: 12; width: 13; height: 13; anchors.verticalCenter: parent.verticalCenter; kind: "search"; col: root.rgba(th.dim, 0.8) }
                            TextField {
                                Keys.onPressed: function(ev) {
                                    if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                        root.typeKey();
                                }
                                id: localSearch
                                anchors.left: parent.left; anchors.leftMargin: 33
                                anchors.right: parent.right; anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                placeholderText: "filter local files"
                                color: th.text
                                placeholderTextColor: root.rgba(th.dim, 0.6)
                                font.family: root.tf; font.pixelSize: (10) * root.ts
                                selectByMouse: true
                                background: Item { }
                                onTextChanged: { root.searchQ = text; root.applyFilter(); }
                            }
                        }
                        GlowButton {
                            label: "RESCAN"
                            bh: 34
                            glow: th.bar
                            onClicked: { root.hit("/rescan"); root.fetchExts(); root.toastNow("rescanning local audio"); }
                        }
                        GlowButton {
                            label: "ADD TO PLAYLIST"
                            bh: 34
                            glow: th.accent
                            onClicked: { addSheet.tab = 1; addSheet.open(); }
                        }
                    }
                }
            }

            // ---------------- file list ----------------
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 12; Layout.rightMargin: 14
                        Layout.topMargin: 5; Layout.bottomMargin: 7
                        spacing: 12
                        Item { width: 34; height: 1 }
                        Text { text: "TITLE"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.fillWidth: true }
                        Text { text: "ORIGIN"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.preferredWidth: 130 }
                        Text { text: "TIME"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2; Layout.preferredWidth: 42; horizontalAlignment: Text.AlignRight }
                    }
                    Item { height: 2 }

                    Flickable {
                        id: localFlick
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: localMask
                        }
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: localCol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 1200
                        maximumFlickVelocity: 3200
                        ScrollBar.vertical: GlassScroll { }
                        GlideWheel { view: localFlick; step: 130 }

                        ColumnLayout {
                            id: localCol
                            width: localFlick.width
                            spacing: 2

                            Repeater {
                                model: root.localFiltered
                                delegate: Rectangle {
                                    id: lrow
                                    readonly property var trk: modelData
                                    readonly property bool isCur: root.s.track_id === trk.id
                                    readonly property real casc: root.cascFor(index, 1)
                                    Layout.fillWidth: true
                                    height: 52
                                    radius: 0
                                    color: isCur ? root.rgba(th.accent, 0.075) : (lrowMa.containsMouse ? (tc.light ? "#0b000000" : "#09ffffff") : "transparent")
                                    Behavior on color { ColorAnimation { duration: 160 } }
                                    opacity: casc
                                    transform: Translate { y: (1 - casc) * 12 }

                                    Rectangle {
                                        visible: isCur || lrowMa.containsMouse
                                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                        width: 2; height: 26; radius: 1
                                        color: isCur ? th.accent : root.rgba(th.accent, 0.45)
                                    }
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12; anchors.rightMargin: 14
                                        spacing: 12

                                        Item {
                                            width: 40; height: 40
                                            Layout.alignment: Qt.AlignVCenter
                                            Art {
                                                anchors.fill: parent
                                                corner: 9
                                                seed: lrow.trk.id
                                                source: lrow.trk.cover && lrow.trk.cover.length > 4 ? lrow.trk.cover : ""
                                                scale: lrowArtMa.pressed ? 0.93 : (lrowMa.containsMouse ? 1.05 : 1)
                                                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                            }
                                            Rectangle {
                                                anchors.fill: parent; radius: 9
                                                color: root.rgba(th.bg, 0.38)
                                                opacity: lrowArtMa.containsMouse ? 1 : 0
                                                Behavior on opacity { NumberAnimation { duration: 140 } }
                                                NavIcon { anchors.centerIn: parent; width: 12; height: 12; kind: isCur && root.s.playing ? "pause" : "play"; col: "" + th.text }
                                            }
                                            MouseArea {
                                                id: lrowArtMa
                                                anchors.fill: parent
                                                hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap(); root.hit("/play?id=" + lrow.trk.id) }
                                            }
                                        }

                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Text {
                                                Layout.fillWidth: true
                                                text: lrow.trk.title
                                                color: lrow.isCur ? th.accent : th.text
                                                font.family: root.tf; font.pixelSize: (12) * root.ts; font.bold: lrow.isCur
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: lrow.trk.artist + (lrow.trk.album && lrow.trk.album.length > 0 ? "  ·  " + lrow.trk.album : "")
                                                color: root.rgba(th.dim, 0.82); font.family: root.tf; font.pixelSize: (9) * root.ts
                                                elide: Text.ElideRight
                                            }
                                        }

                                        Text {
                                            Layout.preferredWidth: 130
                                            text: lrow.trk.origin === "playlist" ? "MATCHED" : "LOCAL FILE"
                                            color: lrow.trk.origin === "playlist" ? root.rgba(th.bar, 0.7) : root.rgba(th.dim, 0.6)
                                            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                        }

                                        Text {
                                            Layout.preferredWidth: 42
                                            horizontalAlignment: Text.AlignRight
                                            text: root.fmt(lrow.trk.duration_ms)
                                            color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts; font.family: "Consolas"
                                        }
                                    }

                                    MouseArea {
                                        id: lrowMa
                                        anchors.fill: parent
                                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: { root.playTap();
                                            if (mouse.button === Qt.RightButton) {
                                                var gp2 = mapToItem(null, mouse.x, mouse.y);
                                                root.openCtx(lrow.trk, gp2.x, gp2.y);
                                                return;
                                            }
                                            root.hit("/play?id=" + lrow.trk.id);
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                visible: root.localFiltered.length === 0
                                Layout.fillWidth: true
                                spacing: 10
                                Item { Layout.fillHeight: true; Layout.minimumHeight: 30 }
                                Rectangle {
                                    Layout.alignment: Qt.AlignHCenter
                                    width: 58; height: 58; radius: 29
                                    color: root.rgba(th.bar, 0.08)
                                    border.width: 1; border.color: root.rgba(th.bar, 0.24)
                                    NavIcon { anchors.centerIn: parent; width: 23; height: 23; kind: "folder"; col: "" + th.bar; opacity: 0.85 }
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.searchQ.length > 0 ? "no local file matches that" : "the local shelf is empty"
                                    color: th.text; font.family: root.tf; font.pixelSize: (14) * root.ts; font.bold: true
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "drop mp3, flac, ogg or wav into Downloads or Music"
                                    color: root.rgba(th.dim, 0.75); font.family: root.tf; font.pixelSize: (10) * root.ts
                                }
                                GlowButton {
                                    Layout.alignment: Qt.AlignHCenter
                                    label: "RESCAN FOLDERS"
                                    onClicked: { root.hit("/rescan") }
                                }
                                Item { Layout.fillHeight: true; Layout.minimumHeight: 30 }
                            }

                            Item { height: 6 }
                        }
                    }
                }
            }
        }
    }

    // PAGE 2: VIBE (visualizer + lyrics)
    Item {
        id: page2
        property int pageIndex: 2
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page2.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page2.tv.rz
        transform: [
            Translate { x: page2.tv.x; y: page2.tv.y },
            Rotation { origin.x: page2.width / 2; origin.y: page2.height / 2; axis { x: 0; y: 1; z: 0 } angle: page2.tv.ry },
            Scale { origin.x: page2.width / 2; origin.y: page2.height / 2; xScale: page2.tv.s; yScale: page2.tv.s }
        ]

        // The cover already fills the window as this tab's backdrop. A second
        // blurred copy inside the page (with its own crop and scale) used to
        // meet the real one at the header's edge and read as a horizontal
        // seam; the room is one surface, so the backdrop owns the artwork.
        Rectangle {
            anchors.fill: parent
            // transparent at the top AND the floor: the scrim is a vignette,
            // so neither the header above nor the dock below meets an edge
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(th.bg, 0) }
                GradientStop { position: 0.1; color: root.rgba(th.bg, 0.16) }
                GradientStop { position: 0.34; color: root.rgba(th.bg, 0.32) }
                GradientStop { position: 0.64; color: root.rgba(th.bg, 0.36) }
                GradientStop { position: 0.88; color: root.rgba(th.bg, 0.14) }
                GradientStop { position: 1; color: root.rgba(th.bg, 0) }
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 30; anchors.rightMargin: 30
            anchors.topMargin: 10; anchors.bottomMargin: 10
            spacing: 20

            // ---------------- stage ----------------
            // The visualization is the room; no stage box around it.
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 0
                color: "transparent"
                border.width: 0
                clip: true

                Item {
                    id: vibeStage
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -24
                    width: Math.min(parent.width - 56, parent.height - 132)
                    height: width

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + 14; height: parent.height + 14
                        radius: width / 2
                        color: root.rgba(th.accent, root.bassLevel * 0.08)
                        Behavior on color { ColorAnimation { duration: 100 } }
                    }
                    CircEQ {
                        anchors.centerIn: parent
                        size: vibeStage.width
                        mode: root.s.viz_mode % 3
                        bars: 80
                        inner: 0.6
                        live: root.currentPage === 2
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.46; height: width
                        radius: width / 2
                        color: root.rgba(th.accent, root.s.playing ? 0.16 : 0.05)
                        scale: root.s.playing ? 1 + root.bassLevel * 0.12 : 0.96
                        Behavior on scale { NumberAnimation { duration: 120 } }
                    }
                    Art {
                        anchors.centerIn: parent
                        width: parent.width * 0.38; height: width
                        corner: width / 2
                        seed: root.s.track_id === null ? 0 : root.s.track_id
                        source: root.s.cover_url && root.s.cover_url.length > 4 ? root.s.cover_url : ""
                        scale: vibeArtMa.pressed ? 0.96 : (vibeArtMa.containsMouse ? 1.025 : 1)
                        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.38; height: width
                        radius: width / 2
                        color: "transparent"
                        border.width: 1; border.color: root.rgba("#ffffff", 0.28)
                    }
                    MouseArea {
                        id: vibeArtMa
                        anchors.centerIn: parent
                        width: parent.width * 0.38; height: width
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.playTap(); np.open() }
                    }
                }

                // stage chrome, top: labels in the air, no capsules
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 18
                    spacing: 10
                    Row {
                        spacing: 7
                        Rectangle { width: 5; height: 5; radius: 2.5; color: th.accent; anchors.verticalCenter: parent.verticalCenter }
                        Text { id: vibeDot; text: "LIVE STAGE"; color: root.rgba(th.text, 0.72); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.6 }
                    }
                    Item { Layout.fillWidth: true }
                    Row {
                        spacing: 7
                        Rectangle { width: 5; height: 5; radius: 2.5; color: root.accent2(); anchors.verticalCenter: parent.verticalCenter }
                        Text { id: modeText; text: ["RING", "BLOOM", "WAVE"][root.s.viz_mode % 3]; color: th.accent; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4 }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▸"; color: root.rgba(th.text, 0.4); font.family: root.tf; font.pixelSize: (11) * root.ts
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); root.hit("/mode?m=" + ((root.s.viz_mode + 1) % 3)) }
                            }
                        }
                    }
                }

                // track identity, bottom
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 16
                    anchors.leftMargin: 18; anchors.rightMargin: 18
                    spacing: 12
                    Column {
                        spacing: 2
                        Text {
                            text: root.s.title.length > 0 ? root.s.title : "silence"
                            color: th.text; font.family: root.tf; font.pixelSize: (17) * root.ts; font.bold: true
                            elide: Text.ElideRight; width: Math.min(420, vibeStage.width)
                        }
                        Text {
                            text: root.s.artist.length > 0 ? root.s.artist : "nothing is playing"
                            color: root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (10) * root.ts
                        }
                    }
                    Item { Layout.fillWidth: true }
                    GlowButton {
                        label: "FULL SCREEN"
                        bh: 30
                        glow: th.bar
                        onClicked: { np.open() }
                    }
                }
            }

            // ---------------- lyrics ----------------
            // the words sit on a soft edge of the room instead of inside a
            // dark card. no radius, no border, no box around the song.
            Item {
                Layout.preferredWidth: root.width > 1180 ? 404 : 348
                Layout.fillHeight: true
                clip: true

                // no dark plate behind the words: the type gets a fine outline
                // so it can sit directly on the room, like the rest of the app
                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 28; anchors.rightMargin: 14
                    anchors.topMargin: 8; anchors.bottomMargin: 8
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Text { text: "LYRICS"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2.2 }
                        Item { Layout.fillWidth: true }
                        // calibration: only shown while the song has timed words
                        Row {
                            visible: root.lyricsData.synced
                            spacing: 2
                            Layout.alignment: Qt.AlignVCenter
                            Rectangle {
                                width: 20; height: 18; radius: 9
                                color: nudgeDown.containsMouse ? root.rgba(th.accent, 0.28) : root.rgba(th.text, 0.07)
                                Text { anchors.centerIn: parent; text: "\u2212"; color: root.rgba(th.text, 0.85); font.family: root.tf; font.pixelSize: (12) * root.ts; font.bold: true }
                                MouseArea {
                                    id: nudgeDown
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.nudgeLyrics(-100) }
                                }
                            }
                            Text {
                                width: 46
                                horizontalAlignment: Text.AlignHCenter
                                anchors.verticalCenter: parent.verticalCenter
                                text: {
                                    var o = root.s.lyric_offset_ms || 0;
                                    if (o === 0) return "ON TIME";
                                    return (o > 0 ? "+" : "") + (o / 1000).toFixed(2) + "s";
                                }
                                color: (root.s.lyric_offset_ms || 0) === 0 ? root.rgba(th.dim, 0.6) : th.accent
                                font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 0.6
                                font.family: "Consolas"
                            }
                            Rectangle {
                                width: 20; height: 18; radius: 9
                                color: nudgeUp.containsMouse ? root.rgba(th.accent, 0.28) : root.rgba(th.text, 0.07)
                                Text { anchors.centerIn: parent; text: "+"; color: root.rgba(th.text, 0.85); font.family: root.tf; font.pixelSize: (11) * root.ts; font.bold: true }
                                MouseArea {
                                    id: nudgeUp
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.nudgeLyrics(100) }
                                }
                            }
                        }
                        Text {
                            text: root.lyricsData.synced ? "SYNCED" : "TEXT"
                            color: root.lyricsData.synced ? th.accent : root.rgba(th.dim, 0.6)
                            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.s.title.length > 0 ? root.s.title : "nothing on the stage"
                        color: th.text; font.family: root.tf; font.pixelSize: (21) * root.ts; font.bold: true; font.letterSpacing: -0.2
                        style: Text.Outline; styleColor: root.rgba(th.bg, 0.55)
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.s.artist.length > 0 ? root.s.artist : "choose a track and the room will breathe"
                        color: root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (10) * root.ts
                        elide: Text.ElideRight
                    }
                    Rectangle { Layout.preferredWidth: 26; Layout.preferredHeight: 1.5; color: root.rgba(th.accent, 0.7); Layout.topMargin: 2 }

                    Flickable {
                        id: lyricFlick
                        // No offscreen layer here. A MultiEffect mask re-renders
                        // the whole column into a texture and runs a shader pass
                        // on every frame of the scroll; on this GPU that alone
                        // turned the glide into a stutter. The rows fade with
                        // distance *and* with their distance from the viewport
                        // edge instead, which costs one multiply per row and
                        // needs no framebuffer at all.
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: lyricCol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 1400
                        maximumFlickVelocity: 3200
                        ScrollBar.vertical: GlassScroll { }
                        GlideWheel { view: lyricFlick; step: 110 }

                        // no fade bands: the open column simply gives the lyrics
                        // room, without drawing another edge across the page

                        ColumnLayout {
                            id: lyricCol
                            width: lyricFlick.width
                            spacing: 4

                            NumberAnimation {
                                id: lyricScroll
                                target: lyricFlick
                                property: "contentY"
                                duration: 560
                                easing.type: Easing.OutCubic
                            }

                            Repeater {
                                model: root.lyricsData.lines
                                delegate: Item {
                                    id: lyricRow
                                    readonly property var ln: modelData
                                    readonly property bool active: index === root.lyricLine
                                    readonly property int dist: Math.abs(index - root.lyricLine)
                                    readonly property double mix: root.lyricsData.lines.length > 1 ? index / (root.lyricsData.lines.length - 1) : 0
                                    // how far the song has travelled through this line.
                                    // the same offset-corrected position the line index
                                    // uses: the two clocks must never disagree
                                    readonly property real pos: Math.max(0, root.posMs + (root.s.lyric_offset_ms || 0))
                                    readonly property real lineP: {
                                        if (!active || ln.t < 0) return 0;
                                        var t0 = ln.t;
                                        var t1 = t0 + (ln.d && ln.d > 300 ? ln.d : 4200);
                                        return Math.max(0, Math.min(1, (pos - t0) / Math.max(220, t1 - t0)));
                                    }
                                    // distance emphasis, animated; the edge fade is
                                    // multiplied in separately so scrolling does not
                                    // restart an opacity animation on every row
                                    property real baseA: active ? 1 : (dist === 1 ? 0.86 : (dist === 2 ? 0.62 : (dist === 3 ? 0.42 : 0.26)))
                                    Behavior on baseA { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                                    // the line's own colour, used both as the quiet
                                    // base and as the sung ink so styles survive the fill
                                    readonly property color ink: {
                                        var pat = root.lyricStyle.pattern;
                                        if (pat === "solid") return th.text;
                                        if (pat === "gradient") return root.mixColor(th.text, th.accent, mix);
                                        if (pat === "rainbow") return Qt.hsla((index * 0.137) % 1, 0.8, 0.72, 1);
                                        return th.accent;
                                    }
                                    Layout.fillWidth: true
                                    transform: Translate {
                                        x: lyricRow.active ? 3 : 0
                                        Behavior on x { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
                                    }
                                    // the row is exactly as tall as the WRAPPED line,
                                    // and *every* line keeps the same type size, so
                                    // the column never re-flows when a line lights up:
                                    // one wrapped hook used to grow by a line, shove
                                    // the others down and clip its own tail.
                                    implicitHeight: Math.max(32, lyricBody.implicitHeight + 8)
                                    Layout.preferredHeight: implicitHeight
                                    // distance + viewport-edge dissolve: type leaves
                                    // the column into the room instead of being cut
                                    opacity: baseA * Math.max(0, Math.min(1, Math.min(
                                        (y - lyricFlick.contentY + 10) / 88,
                                        (lyricFlick.height - (y - lyricFlick.contentY) - height + 10) / 88)))

                                    Rectangle {
                                        visible: lyricRow.active
                                        x: 0; width: 2.5; height: parent.height - 12; radius: 1.5
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: th.accent
                                        opacity: 0.6 + 0.28 * Math.sin(root.cardPhase * 1.6)
                                        Behavior on height { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
                                    }
                                    Text {
                                        id: lyricBody
                                        x: 10; width: parent.width - 14
                                        y: Math.max(0, (parent.height - implicitHeight) / 2)
                                        text: ln.text.length > 0 ? ln.text : "·"
                                        // the sung line brightens as the voice moves
                                        // through it. This used to be a clipped twin
                                        // Text whose clip width changed every frame -
                                        // a second text layout and a clipped repaint
                                        // 60 times a second, which is what stuttered.
                                        // One colour ramp does the same job for free.
                                        color: !lyricRow.active ? root.rgba(th.dim, 0.9)
                                             : root.mixColor(root.rgba(lyricRow.ink, 0.34), lyricRow.ink, Math.min(1, lyricRow.lineP * 1.9))
                                        font.family: root.tf; font.pixelSize: (16) * root.ts
                                        font.bold: false
                                        font.letterSpacing: root.lyricStyle.anim === "typewriter" ? 1 : 0
                                        wrapMode: Text.WordWrap
                                        topPadding: 5; bottomPadding: 5
                                        style: Text.Outline
                                        styleColor: lyricRow.active ? root.rgba(th.accent, 0.4) : root.rgba(th.bg, 0.6)
                                    }
                                    // the hit area sits above the words so a tap
                                    // still travels to the line
                                    MouseArea {
                                        x: lyricBody.x; y: 0
                                        width: lyricBody.width; height: parent.height
                                        cursorShape: ln.t >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: { root.playTap(); if (ln.t >= 0) root.hit("/seek?ms=" + ln.t) }
                                    }
                                    Rectangle {
                                        visible: lyricRow.active && ln.t >= 0
                                        x: 10
                                        y: parent.height - 5
                                        width: Math.max(0, parent.width - 18)
                                        height: 1.4; radius: 1
                                        color: root.rgba(th.accent, 0.10)
                                        Rectangle {
                                            width: parent.width * lyricRow.lineP
                                            height: parent.height; radius: 1
                                            color: root.rgba(th.accent, 0.9)
                                        }
                                        // the fill leaves a small comet of light behind it
                                        Rectangle {
                                            x: parent.width * lyricRow.lineP - 14
                                            visible: lyricRow.lineP > 0.02 && lyricRow.lineP < 0.995
                                            width: 16; height: 3; radius: 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: root.rgba(lyricRow.ink, 0.32)
                                        }
                                    }
                                    // aim once, after layout settles. The row no
                                    // longer resizes when it lights up, so one
                                    // aim is enough - re-aiming on every height
                                    // change restarted the glide mid-flight.
                                    Timer {
                                        id: lyricAim
                                        interval: 0
                                        onTriggered: {
                                            if (!lyricRow.active) return;
                                            // a reader flicking through the
                                            // words owns the column: never
                                            // yank it out from under them
                                            if (lyricFlick.moving || lyricFlick.dragging) return;
                                            var target = Math.max(0, Math.min(
                                                lyricFlick.contentHeight - lyricFlick.height,
                                                lyricRow.y - lyricFlick.height / 2 + lyricRow.height / 2));
                                            if (Math.abs(lyricScroll.to - target) < 2 && lyricScroll.running) return;
                                            lyricScroll.to = target;
                                            lyricScroll.restart();
                                        }
                                    }
                                    onActiveChanged: if (active) lyricAim.start()
                                }
                            }

                            Column {
                                visible: root.lyricsData.lines.length === 0
                                width: parent.width
                                spacing: 8
                                Item { width: 1; height: 40 }
                                Text {
                                    width: parent.width
                                    text: root.s.title.length > 0 ? "no lyrics for this track" : "the stage is still"
                                    color: root.rgba(th.text, 0.82); font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                Text {
                                    width: parent.width
                                    text: root.s.title.length > 0 ? "drop a .lrc next to the audio file, or embed lyrics in the tag" : "play a song — the words arrive with it"
                                    color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (9) * root.ts
                                    wrapMode: Text.WordWrap
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                GlowButton {
                                    Layout.alignment: Qt.AlignHCenter
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    label: "OPEN PLAYLIST"
                                    bh: 28
                                    glow: th.accent
                                    onClicked: { root.gotoPage(0) }
                                }
                            }
                            Item { height: 12 }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "tap a line to travel there"
                        color: root.rgba(th.dim, 0.45); font.family: root.tf; font.pixelSize: (8) * root.ts
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }

    // PAGE 3: QUEUE
    Item {
        id: page3
        property int pageIndex: 3
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page3.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page3.tv.rz
        transform: [
            Translate { x: page3.tv.x; y: page3.tv.y },
            Rotation { origin.x: page3.width / 2; origin.y: page3.height / 2; axis { x: 0; y: 1; z: 0 } angle: page3.tv.ry },
            Scale { origin.x: page3.width / 2; origin.y: page3.height / 2; xScale: page3.tv.s; yScale: page3.tv.s }
        ]

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 30; anchors.rightMargin: 30
            anchors.topMargin: 10; anchors.bottomMargin: 10
            spacing: 18

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ColumnLayout {
                    spacing: 2
                    Text { text: "QUEUE"; color: th.text; font.family: root.tf; font.pixelSize: (25) * root.ts; font.bold: true; font.letterSpacing: -0.2 }
                    Text {
                        text: (root.queueData.smart ? "smart shuffle" : (root.s.shuffle ? "shuffled" : (root.s.repeat === 1 ? "repeat all" : root.s.repeat === 2 ? "repeat one" : "linear"))) + "  ·  " + Math.max(0, root.upNextCount()) + " waiting"
                        color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (10) * root.ts
                    }
                }
                Item { Layout.fillWidth: true }
                GlowButton {
                    label: "SMART SHUFFLE"
                    bh: 32
                    glow: root.queueData.smart ? th.accent : th.dim
                    onClicked: { var on = !root.queueData.smart;
                        root.hit("/shuffle?s=1&mode=" + (on ? "smart" : "random"));
                        root.fetchJson("/queue", function(q) { root.queueData = q; });
                    }
                }
                GlowButton {
                    label: "CLEAR"
                    bh: 32
                    glow: th.dim
                    onClicked: { root.hit("/queue/clear");
                        root.fetchJson("/queue", function(q) { root.queueData = q; });
                        syncToast.show("queue cleared");
                    }
                }
                GlowButton {
                    label: "VIEW PLAYLIST"
                    bh: 32
                    glow: th.bar
                    onClicked: { root.gotoPage(0) }
                }
            }

            // ---------------- now playing ----------------
            Rectangle {
                Layout.fillWidth: true
                height: 112
                radius: 0
                color: "transparent"
                border.width: 0
                clip: true


                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 14

                    Item {
                        width: 80; height: 80
                        Layout.alignment: Qt.AlignVCenter
                        Rectangle {
                            anchors.centerIn: parent
                            width: 92; height: 92; radius: 46
                            color: root.rgba(th.accent, root.s.playing ? 0.10 : 0.04)
                        }
                        Art {
                            anchors.fill: parent
                            corner: 16
                            seed: root.s.track_id === null ? 0 : root.s.track_id
                            source: root.s.cover_url && root.s.cover_url.length > 4 ? root.s.cover_url : ""
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 16
                            color: root.rgba(th.bg, 0.35)
                            opacity: npMa.containsMouse ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                            NavIcon { anchors.centerIn: parent; width: 18; height: 18; kind: "play"; col: "" + th.text }
                        }
                        MouseArea { id: npMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); np.open() } }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 4
                        RowLayout {
                            spacing: 7
                            Text { text: root.s.playing ? "PLAYING NOW" : "PAUSED"; color: root.rgba(th.accent, 0.9); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.6 }
                            Text { text: "· " + root.fmt(root.posMs) + " / " + root.fmt(root.s.duration_ms); color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.s.title.length > 0 ? root.s.title : "nothing playing"
                            color: th.text; font.family: root.tf; font.pixelSize: (18) * root.ts; font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.s.artist.length > 0 ? root.s.artist : "choose a track from the playlist"
                            color: root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (10) * root.ts
                            elide: Text.ElideRight
                        }
                        ScrubBar {
                            Layout.fillWidth: true
                            height: 16
                            thickness: 3
                            value: root.posMs
                            max: Math.max(1, root.s.duration_ms)
                            onSeek: function(p) { root.seekTo(p * root.s.duration_ms); }
                        }
                    }

                    RowLayout {
                        spacing: 8
                        Layout.alignment: Qt.AlignVCenter
                        Item {
                            width: 36; height: 36
                            NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "prev"; col: qpMa.containsMouse ? th.accent : th.text }
                            MouseArea { id: qpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/prev") } }
                        }
                        Item {
                            width: 44; height: 44
                            Rectangle {
                                anchors.fill: parent; radius: 22
                                gradient: Gradient {
                                    orientation: Gradient.Vertical
                                    GradientStop { position: 0; color: root.mixColor(th.accent, "#ffffff", 0.16) }
                                    GradientStop { position: 1; color: root.accent2() }
                                }
                                NavIcon { anchors.centerIn: parent; width: 18; height: 18; kind: root.s.playing ? "pause" : "play"; col: tc.light ? "#ffffff" : "#04121f" }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/toggle") } }
                        }
                        Item {
                            width: 36; height: 36
                            NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "next"; col: qnMa.containsMouse ? th.accent : th.text }
                            MouseArea { id: qnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/next") } }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                Text { text: "UP NEXT"; color: root.rgba(th.text, 0.9); font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 2 }
                Text { text: "the room after this one"; color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (9) * root.ts }
                Item { Layout.fillWidth: true }
                Text { text: root.s.shuffle ? "SHUFFLE ON" : "IN ORDER"; color: root.rgba(th.accent, 0.75); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1 }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                Flickable {
                    id: qFlick
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: queueMask
                    }
                    anchors.fill: parent
                    contentHeight: qCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickDeceleration: 1200
                    maximumFlickVelocity: 3200
                    ScrollBar.vertical: GlassScroll { }
                    GlideWheel { view: qFlick; step: 130 }

                    ColumnLayout {
                        id: qCol
                        width: qFlick.width
                        spacing: 2

                        Repeater {
                            model: root.queueData.up || []
                            delegate: Rectangle {
                                id: qrow
                                readonly property var trk: modelData
                                Layout.fillWidth: true
                                height: 52
                                radius: 0
                                color: qMa.containsMouse ? (tc.light ? "#0b000000" : "#09ffffff") : "transparent"
                                Behavior on color { ColorAnimation { duration: 160 } }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    spacing: 12
                                    Text {
                                        Layout.preferredWidth: 22
                                        text: index + 1
                                        color: root.rgba(th.dim, 0.5); font.pixelSize: (9) * root.ts; font.family: "Consolas"
                                        horizontalAlignment: Text.AlignRight
                                    }
                                    Art {
                                        width: 34; height: 34; corner: 8
                                        Layout.alignment: Qt.AlignVCenter
                                        seed: qrow.trk.id
                                        source: qrow.trk.cover && qrow.trk.cover.length > 4 ? qrow.trk.cover : ""
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: qrow.trk.title
                                            color: th.text; font.family: root.tf; font.pixelSize: (12) * root.ts
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: qrow.trk.artist
                                            color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (9) * root.ts
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Row {
                                        spacing: 6
                                        opacity: qMa.containsMouse ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                        Rectangle {
                                            width: 28; height: 28; radius: 14
                                            color: qNextMa.containsMouse ? root.rgba(th.accent, 0.22) : (tc.light ? "#10000000" : "#10ffffff")
                                            border.width: 1; border.color: root.rgba("#ffffff", 0.14)
                                            NavIcon { anchors.centerIn: parent; width: 12; height: 12; kind: "next"; col: "" + th.accent }
                                            MouseArea {
                                                id: qNextMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap(); root.hit("/queue/playnext?id=" + qrow.trk.id); root.fetchJson("/queue", function(q) { root.queueData = q; }); }
                                            }
                                        }
                                        Rectangle {
                                            width: 28; height: 28; radius: 14
                                            color: qRmMa.containsMouse ? root.rgba("#ff4757", 0.24) : (tc.light ? "#10000000" : "#10ffffff")
                                            border.width: 1; border.color: root.rgba("#ffffff", 0.14)
                                            Text { anchors.centerIn: parent; text: "\u2715"; color: qRmMa.containsMouse ? "#ff6b81" : root.rgba(th.dim, 0.9); font.family: root.tf; font.pixelSize: (9) * root.ts }
                                            MouseArea {
                                                id: qRmMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap(); root.hit("/queue/remove?id=" + qrow.trk.id); root.fetchJson("/queue", function(q) { root.queueData = q; }); }
                                            }
                                        }
                                    }
                                    Text {
                                        Layout.preferredWidth: 44
                                        horizontalAlignment: Text.AlignRight
                                        text: qrow.trk.playable ? "READY" : "—"
                                        color: qrow.trk.playable ? root.rgba(th.accent, 0.65) : root.rgba(th.dim, 0.4)
                                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                    }
                                }
                                MouseArea {
                                    id: qMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: qrow.trk.playable ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: { root.playTap();
                                        if (mouse.button === Qt.RightButton) {
                                            var gq = mapToItem(null, mouse.x, mouse.y);
                                            root.openCtx(qrow.trk, gq.x, gq.y);
                                            return;
                                        }
                                        if (qrow.trk.playable) root.hit("/play?id=" + qrow.trk.id);
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            visible: (root.queueData.up || []).length === 0
                            Layout.fillWidth: true
                            spacing: 10
                            Item { Layout.fillHeight: true; Layout.minimumHeight: 30 }
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                width: 58; height: 58; radius: 29
                                color: root.rgba(th.accent, 0.08)
                                border.width: 1; border.color: root.rgba(th.accent, 0.24)
                                NavIcon { anchors.centerIn: parent; width: 22; height: 22; kind: "list"; col: "" + th.accent; opacity: 0.85 }
                            }
                            Text { Layout.alignment: Qt.AlignHCenter; text: "the queue is wide open"; color: th.text; font.family: root.tf; font.pixelSize: (14) * root.ts; font.bold: true }
                            Text { Layout.alignment: Qt.AlignHCenter; text: "play anything and the next room lines up here"; color: root.rgba(th.dim, 0.75); font.family: root.tf; font.pixelSize: (10) * root.ts }
                            GlowButton { Layout.alignment: Qt.AlignHCenter; label: "OPEN PLAYLIST"; onClicked: { root.gotoPage(0) } }
                            Item { Layout.fillHeight: true; Layout.minimumHeight: 30 }
                        }
                    }
                }
            }
        }
    }

    // PAGE 4: THEMES — the page is the world
    // No cards. Choosing a theme changes the room you are standing in, and the
    // room itself is draggable: orbit it, lean in, push it with a click.
    Item {
        id: page4
        property int pageIndex: 4
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page4.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page4.tv.rz
        transform: [
            Translate { x: page4.tv.x; y: page4.tv.y },
            Rotation { origin.x: page4.width / 2; origin.y: page4.height / 2; axis { x: 0; y: 1; z: 0 } angle: page4.tv.ry },
            Scale { origin.x: page4.width / 2; origin.y: page4.height / 2; xScale: page4.tv.s; yScale: page4.tv.s }
        ]
        property real dragX: 0
        property real dragY: 0

        function switchTheme(nm) { root.setTheme(nm, ""); }
        function surprise() {
            if (root.themeCards.length === 0) return;
            var pool = [];
            for (var i = 0; i < root.themeCards.length; i++) {
                if (root.themeCards[i].id !== root.tc.id) pool.push(root.themeCards[i]);
            }
            if (pool.length === 0) return;
            var pick = pool[Math.floor(Math.random() * pool.length)];
            root.setTheme(pick.id, pick.name);
            root.exciteWorld();
        }

        // the whole page is a window into the 3D room
        MouseArea {
            id: worldDrag
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
            property real lx: 0
            property real ly: 0
            property bool moved: false
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: { lx = mouse.x; ly = mouse.y; moved = false; }
            onPositionChanged: {
                if (!pressed) return;
                var dx = mouse.x - lx, dy = mouse.y - ly;
                if (Math.abs(dx) + Math.abs(dy) > 1.5) moved = true;
                lx = mouse.x; ly = mouse.y;
                root.orbitWorld(-dx * 0.7, dy * 0.7);
            }
            onReleased: if (!moved) root.exciteWorld()
            onWheel: function(w) { root.zoomWorld(w.angleDelta.y > 0 ? -0.055 : 0.055); }
            onDoubleClicked: root.resetWorld()
        }

        // header: type on the world, no plate underneath it
        Column {
            x: 36; y: 22
            spacing: 5
            Row {
                spacing: 10
                Text { text: "THEMES"; color: th.text; font.family: root.tf; font.pixelSize: (30) * root.ts; font.bold: true; font.letterSpacing: -0.6 }
                Rectangle {
                    width: worldCount.width + 18; height: 20; radius: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.rgba(th.accent, 0.12)
                    border.width: 1; border.color: root.rgba(th.accent, 0.28)
                    Text {
                        id: worldCount
                        anchors.centerIn: parent
                        text: (root.themeCards.length || 20) + " WORLDS"
                        color: root.rgba(th.accent, 0.92)
                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                    }
                }
            }
            Text {
                text: "not a palette — a room with weight, weather and a camera"
                color: root.rgba(th.dim, 0.82); font.family: root.tf; font.pixelSize: (10) * root.ts
            }
        }

        // explore hint, floating over the world
        Column {
            anchors.right: parent.right; anchors.rightMargin: 40
            y: 26
            spacing: 4
            Text {
                text: "DRAG TO LOOK  ·  SCROLL TO MOVE CLOSER  ·  DOUBLE-CLICK TO RESET"
                color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.3
                anchors.right: parent.right
            }
            Row {
                spacing: 7
                anchors.right: parent.right
                Text {
                    text: "Y " + (bg3d.item ? Math.round(bg3d.item.yaw) : 0) + "°  ·  D " + (bg3d.item ? bg3d.item.zoom.toFixed(2) : "1.00")
                          + "  ·  " + Math.round(root.fps) + " FPS  ·  Q" + Math.round(root.q * 100)
                    color: root.rgba(th.accent, 0.72); font.pixelSize: (7) * root.ts; font.family: "Consolas"
                }
                Text {
                    text: "RESET"
                    color: resetMa.containsMouse ? th.accent : root.rgba(th.dim, 0.6)
                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                    MouseArea {
                        id: resetMa
                        anchors.fill: parent; anchors.margins: -5
                        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.playTap(); root.resetWorld() }
                    }
                }
            }
        }

        // world rail: names only. the active one gets one short line, nothing else.
        Item {
            id: worldRail
            anchors.right: parent.right; anchors.rightMargin: 36
            anchors.top: parent.top; anchors.topMargin: 92
            anchors.bottom: parent.bottom; anchors.bottomMargin: 26
            width: 250
            clip: true

            Flickable {
                anchors.fill: parent
                contentHeight: railGrid.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: GlassScroll { }
                Grid {
                    id: railGrid
                    width: parent.width
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 0
                    Repeater {
                        model: root.themeCards
                        delegate: Item {
                            readonly property var card: modelData
                            readonly property bool on: root.tc.name === card.name
                            width: (worldRail.width - 10) / 2
                            height: 30
                            // a hover surface instead of a hairline: the list
                            // reads as buttons, not as a table of rules
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: -3
                                radius: 9
                                color: on ? root.rgba(card.accent, 0.14)
                                          : (railMa.containsMouse ? root.rgba(th.text, 0.06) : "transparent")
                                Behavior on color { ColorAnimation { duration: 160 } }
                            }
                            // the swatch: a real two-stop gradient, softly haloed
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                x: 3
                                anchors.verticalCenter: parent.verticalCenter
                                opacity: on ? 0.28 : 0
                                scale: on ? 2.6 : 1
                                color: card.accent
                                Behavior on opacity { NumberAnimation { duration: 220 } }
                                Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                            }
                            Rectangle {
                                width: 8; height: 8; radius: 4
                                x: 3
                                anchors.verticalCenter: parent.verticalCenter
                                gradient: Gradient {
                                    GradientStop { position: 0; color: card.accent }
                                    GradientStop { position: 1; color: card.accent2 }
                                }
                                opacity: on ? 1 : (railMa.containsMouse ? 0.85 : 0.45)
                                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                Behavior on opacity { NumberAnimation { duration: 180 } }
                            }
                            Text {
                                anchors.left: parent.left; anchors.leftMargin: 30
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 32
                                text: card.name
                                color: on ? card.accent : (railMa.containsMouse ? th.text : root.rgba(th.text, tc.light ? 0.86 : 0.55))
                                font.family: root.tf; font.pixelSize: (9) * root.ts
                                font.bold: on
                                elide: Text.ElideRight
                                Behavior on color { ColorAnimation { duration: 160 } }
                            }
                            MouseArea {
                                id: railMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); page4.switchTheme(card.id); root.exciteWorld(); }
                            }
                        }
                    }
                }
            }
        }

        // the identity of the current world, sitting low in the room
        Column {
            x: 36
            anchors.bottom: parent.bottom; anchors.bottomMargin: 26
            width: Math.min(620, page4.width - 340)
            spacing: 7

            Row {
                spacing: 9
                Rectangle { width: 5; height: 5; radius: 2.5; color: th.accent; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    text: (root.tc.tag || "WORLD").toUpperCase()
                    color: root.rgba(th.accent, 0.92)
                    font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2.2
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.materialFor().toUpperCase()
                    color: root.rgba(th.dim, 0.65)
                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Text {
                width: parent.width
                text: root.tc.name || "Frutiger"
                color: th.text
                font.family: root.tf; font.pixelSize: (54) * root.ts; font.bold: true; font.letterSpacing: -1.4
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: (root.tc.scene || "a room") + (root.tc.line ? "  ·  " + root.tc.line : "")
                color: root.rgba(th.text, 0.8)
                font.family: root.tf; font.pixelSize: (13) * root.ts
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.tc.mood || ""
                color: root.rgba(th.accent, 0.82)
                font.family: root.tf; font.pixelSize: (11) * root.ts; font.italic: true
                elide: Text.ElideRight
            }
            Row {
                spacing: 6
                Repeater {
                    model: root.tc.palette || [root.tc.bg, root.tc.panel, root.tc.accent, root.accent2(), root.tc.bar]
                    delegate: Rectangle {
                        width: 34; height: 4; radius: 2
                        color: modelData
                        opacity: index === 0 ? 0.55 : 0.95
                    }
                }
            }
            Row {
                spacing: 10
                anchors.topMargin: 4
                GlowButton {
                    label: "STEP INSIDE"
                    bh: 34
                    glow: th.accent
                    onClicked: { root.enterThemeWorld() }
                }
                GlowButton {
                    label: "SURPRISE ME"
                    bh: 34
                    glow: th.bar
                    onClicked: { page4.surprise() }
                }
                Text {
                    text: "CLICK THE ROOM TO PULSE IT"
                    color: root.rgba(th.dim, 0.5)
                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // PAGE 5: HOME
    Item {
        id: page5
        property int pageIndex: 5
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page5.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page5.tv.rz
        transform: [
            Translate { x: page5.tv.x; y: page5.tv.y },
            Rotation { origin.x: page5.width / 2; origin.y: page5.height / 2; axis { x: 0; y: 1; z: 0 } angle: page5.tv.ry },
            Scale { origin.x: page5.width / 2; origin.y: page5.height / 2; xScale: page5.tv.s; yScale: page5.tv.s }
        ]

        Flickable {
            id: homeFlick
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: homeMask
            }
            anchors.fill: parent
            anchors.leftMargin: 30; anchors.rightMargin: 30
            anchors.topMargin: 10; anchors.bottomMargin: 10
            contentHeight: homeCol.height
            clip: true
            flickableDirection: Flickable.VerticalFlick
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 1200
            maximumFlickVelocity: 3400
            ScrollBar.vertical: GlassScroll { }
            GlideWheel { view: homeFlick; step: 150 }

            ColumnLayout {
                id: homeCol
                width: homeFlick.width
                spacing: 20

                // ---------------- hero: the song owns the room ----------------
                // A full-width stage, no container: the artwork breathes into the page.
                Rectangle {
                    id: hero
                    Layout.fillWidth: true
                    height: 296
                    radius: 0
                    color: "transparent"
                    // no clip: the light pool must be able to bleed into the page
                    border.width: 0


                    // The two light pools that used to sit behind the sleeve are
                    // gone: under a blurred room they still resolved as a bright
                    // plate behind the cover, and the cover has to belong to the
                    // room, not sit on a card. The shadow below does the lifting.

                    // left: physical artefact
                    Item {
                        id: heroArtBox
                        width: 240; height: 240
                        anchors.left: parent.left; anchors.leftMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        HoverHandler { id: heroHover }

                        // the disc slides out when you look at it
                        Item {
                            id: heroVinyl
                            width: 208; height: 208
                            // Hovering the sleeve draws the record out of it -
                            // a real slide, not a parallax nudge: the disc
                            // clears the cover by ~120px and sits proud of it.
                            // 30px of travel, not 90: the disc has to leave the
                            // sleeve without crossing into the type, and the
                            // column starts 54px to its right. The pop is the
                            // lift and the scale, not distance.
                            x: (heroHover.hovered || vinylMa.containsMouse ? 64 : 34)
                            // 16 is the centred rest position (240 - 208) / 2;
                            // y cannot be combined with a verticalCenter anchor
                            y: 16 + (heroHover.hovered || vinylMa.containsMouse ? -6 : 0)
                            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                            Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                            scale: (heroHover.hovered || vinylMa.containsMouse) ? 1.05 : 1
                            Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
                            rotation: heroArtMa.containsMouse ? 4 : 0
                            Behavior on rotation { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "#08090d"
                                border.width: 1; border.color: "#2affffff"
                                Canvas {
                                    anchors.fill: parent
                                    onPaint: {
                                        var ctx = getContext("2d");
                                        ctx.reset();
                                        var c = width / 2;
                                        for (var i = 0; i < 11; i++) {
                                            var r = 28 + i * 8.1;
                                            ctx.strokeStyle = (i % 2 === 0) ? "rgba(255,255,255,0.075)" : "rgba(0,0,0,0.45)";
                                            ctx.lineWidth = 1;
                                            ctx.beginPath(); ctx.arc(c, c, r, 0, Math.PI * 2); ctx.stroke();
                                        }
                                    }
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 90; height: 90; radius: 45
                                    color: root.colorFor(root.s.track_id === null ? 0 : root.s.track_id)
                                    Art {
                                        anchors.fill: parent
                                        corner: 45
                                        seed: root.s.track_id === null ? 0 : root.s.track_id
                                        source: (root.s.cover_url && root.s.cover_url.length > 4) ? root.s.cover_url : root.libCover()
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 9; height: 9; radius: 4.5
                                        color: "#08090d"
                                        border.width: 1; border.color: "#44ffffff"
                                    }
                                }
                                Rectangle {
                                    anchors.fill: parent; radius: width / 2
                                    rotation: 32
                                    gradient: Gradient {
                                        GradientStop { position: 0; color: "#00ffffff" }
                                        GradientStop { position: 0.44; color: "#12ffffff" }
                                        GradientStop { position: 0.48; color: "#00ffffff" }
                                    }
                                }
                            }
                            Timer {
                                // the sleeve only spins on the page that shows it
                                interval: 30
                                running: root.s.playing && root.currentPage === 0
                                         && root.visible && root.visibility !== Window.Minimized
                                repeat: true
                                onTriggered: heroVinyl.rotation = (heroVinyl.rotation + 0.35) % 360
                            }
                            // The part of the record that has slid clear of the
                            // sleeve is the door into the immersive stage. It
                            // sits under the cover, so the sleeve keeps its own
                            // click; only the drawn-out half answers here.
                            MouseArea {
                                id: vinylMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); np.open() }
                            }
                        }

                        // The drop shadow was a RectangularShadow, and on this
                        // renderer it drew as a solid rounded PLATE a few pixels
                        // larger than the sleeve - the "grey square behind the
                        // cover" that broke the artwork out of the room. The
                        // sleeve now sits on the room itself; the record behind
                        // it supplies the depth.
                        Art {
                            id: heroArt
                            width: 210; height: 210
                            corner: 22
                            seed: root.s.track_id === null
                                  ? (root.idleTrack() ? root.idleTrack().id : 0)
                                  : root.s.track_id
                            source: (root.s.cover_url && root.s.cover_url.length > 4)
                                    ? root.s.cover_url
                                    : (root.idleTrack() && root.idleTrack().cover && root.idleTrack().cover.length > 4
                                       ? root.idleTrack().cover : root.libCover())
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            scale: heroArtMa.pressed ? 0.97 : (heroArtMa.containsMouse ? 1.035 : 1)
                            Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutBack } }
                            // the sleeve has thickness: it leans with the pointer
                            transform: [
                                Rotation {
                                    origin.x: heroArt.width / 2; origin.y: heroArt.height / 2
                                    axis { x: 0; y: 1; z: 0 }
                                    angle: heroHover.hovered ? (heroHover.point.position.x - 120) * 0.045 : 0
                                    Behavior on angle { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                },
                                Rotation {
                                    origin.x: heroArt.width / 2; origin.y: heroArt.height / 2
                                    axis { x: 1; y: 0; z: 0 }
                                    angle: heroHover.hovered ? -(heroHover.point.position.y - 120) * 0.035 : 0
                                    Behavior on angle { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                }
                            ]
                        }
                        Rectangle {
                            anchors.fill: heroArt
                            radius: 22
                            color: root.rgba(th.bg, heroArtMa.containsMouse ? 0.22 : 0)
                            Behavior on color { ColorAnimation { duration: 200 } }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 54; height: 54; radius: 27
                                color: root.rgba(th.bg, 0.6)
                                border.width: 1; border.color: root.rgba("#ffffff", 0.35)
                                opacity: heroArtMa.containsMouse ? 1 : 0
                                scale: heroArtMa.containsMouse ? 1 : 0.8
                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }
                                NavIcon { anchors.centerIn: parent; width: 20; height: 20; kind: "play"; col: "" + th.text }
                            }
                        }
                        MouseArea {
                            id: heroArtMa
                            anchors.fill: heroArt
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.playTap(); np.open() }
                        }
                    }

                    // middle: identity, breath, transport
                    Column {
                        id: heroInfo
                        // Pinned to the page, not to the cover. The words used
                        // to be measured off heroArtBox.right, so anything that
                        // nudged the artefact dragged the type - and the ring -
                        // with it. 294 is where the column has always started.
                        anchors.left: parent.left; anchors.leftMargin: 294
                        anchors.right: heroRing.visible ? heroRing.left : parent.right
                        anchors.rightMargin: 30
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        Row {
                            spacing: 8
                            Rectangle {
                                width: 6; height: 6; radius: 3
                                color: th.accent
                                anchors.verticalCenter: parent.verticalCenter
                                SequentialAnimation on opacity {
                                    running: root.s.playing
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                                }
                            }
                            Text {
                                text: (root.s.track_id === null || root.s.track_id === undefined) ? "LAST PLAYED" : "NOW PLAYING"
                                color: root.rgba(th.dim, 0.9)
                                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2.2
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                visible: root.s.origin && root.s.origin.length > 0
                                text: "· " + (root.s.origin || "").toUpperCase()
                                color: root.rgba(th.accent, 0.9)
                                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.6
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                visible: root.s.album && root.s.album.length > 0
                                text: "· " + root.s.album
                                color: root.rgba(th.dim, 0.65)
                                font.family: root.tf; font.pixelSize: (9) * root.ts
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Text {
                            width: heroInfo.width
                            text: root.s.title.length > 0
                                  ? root.s.title
                                  : (root.idleTrack() ? root.idleTrack().title : "nothing playing")
                            color: th.text
                            font.family: root.tf; font.pixelSize: (34) * root.ts; font.bold: true; font.letterSpacing: -0.6
                            elide: Text.ElideRight
                        }
                        Text {
                            width: heroInfo.width
                            text: root.s.artist.length > 0
                                  ? root.s.artist
                                  : (root.idleTrack() ? root.idleTrack().artist : "pick something worth keeping")
                            color: root.rgba(th.text, 0.75)
                            font.family: root.tf; font.pixelSize: (15) * root.ts
                            elide: Text.ElideRight
                        }
                        Text {
                            width: heroInfo.width
                            height: 17
                            // a stopped deck keeps the last song's words in memory:
                            // under "nothing playing" that quote read as a ghost
                            text: (root.s.track_id === null || root.s.track_id === undefined)
                                  ? (root.idleTrack() ? "ready when you are" : (root.tc.line || root.tc.mood || ""))
                                  : (root.currentLyric().length > 0 ? "\u201c" + root.currentLyric() + "\u201d" : "")
                            color: root.rgba(th.accent, 0.82)
                            font.family: root.tf; font.pixelSize: (11) * root.ts; font.italic: true
                            elide: Text.ElideRight
                        }

                        // where the room was left: offered only on a stopped deck,
                        // and only while that song is still in this playlist
                        Rectangle {
                            readonly property var rt: root.resumeTrack()
                            width: resumeRow.width + 22; height: 26; radius: 13
                            visible: (root.s.track_id === null || root.s.track_id === undefined) && rt !== null
                            color: resumeMa.containsMouse ? root.rgba(th.accent, 0.18) : root.rgba(th.accent, 0.08)
                            border.width: 1; border.color: root.rgba(th.accent, resumeMa.containsMouse ? 0.5 : 0.26)
                            Behavior on color { ColorAnimation { duration: 160 } }
                            Row {
                                id: resumeRow
                                anchors.centerIn: parent
                                spacing: 8
                                NavIcon { width: 10; height: 10; kind: "play"; anchors.verticalCenter: parent.verticalCenter; col: th.accent }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "RESUME  " + (root.s.resume ? root.s.resume.title : "")
                                    color: th.accent; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.fmt(root.s.resume ? root.s.resume.pos_ms : 0)
                                    color: root.rgba(th.dim, 0.85); font.family: "Consolas"; font.pixelSize: (8) * root.ts
                                }
                            }
                            MouseArea { id: resumeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.resumePlay() } }
                        }

                        Item { width: 1; height: 2 }

                        ScrubBar {
                            width: heroInfo.width
                            height: 22
                            thickness: 4
                            value: root.posMs
                            max: Math.max(1, root.s.duration_ms)
                            onSeek: function(p) { root.seekTo(p * root.s.duration_ms); }
                        }
                        Row {
                            width: heroInfo.width
                            Text { text: root.fmt(root.posMs); color: root.rgba(th.dim, 0.75); font.pixelSize: (9) * root.ts; font.family: "Consolas" }
                            Item { width: parent.width - 80; height: 1 }
                            Text { text: root.fmt(root.s.duration_ms); color: root.rgba(th.dim, 0.75); font.pixelSize: (9) * root.ts; font.family: "Consolas" }
                        }

                        Item { width: 1; height: 5 }

                        Row {
                            spacing: 12
                            anchors.left: parent.left
                            // shuffle
                            Item {
                                width: 30; height: 30
                                anchors.verticalCenter: parent.verticalCenter
                                NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "shuffle"; col: root.s.shuffle ? th.accent : root.rgba(th.dim, 0.85); opacity: root.s.shuffle ? 1 : 0.7 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/shuffle?s=" + (root.s.shuffle ? 0 : 1)) } }
                            }
                            // prev
                            Item {
                                width: 38; height: 38
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle { anchors.fill: parent; radius: 19; color: heroPrevMa.containsMouse ? root.rgba(th.accent, 0.14) : root.rgba("#ffffff", 0.06); border.width: 1; border.color: tc.light ? "#28000000" : "#1effffff"; Behavior on color { ColorAnimation { duration: 140 } } }
                                NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "prev"; col: heroPrevMa.containsMouse ? th.accent : th.text }
                                MouseArea { id: heroPrevMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/prev") } }
                            }
                            // play
                            Item {
                                width: 56; height: 56
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 60; height: 60; radius: 30
                                    color: root.rgba(th.accent, 0.18)
                                    scale: root.s.playing ? 1 + root.bassLevel * 0.16 : 0.9
                                    opacity: root.s.playing ? 0.6 : 0.1
                                    Behavior on scale { NumberAnimation { duration: 120 } }
                                }
                                Rectangle {
                                    anchors.fill: parent; radius: 28
                                    gradient: Gradient {
                                        orientation: Gradient.Vertical
                                        GradientStop { position: 0; color: root.mixColor(th.accent, "#ffffff", 0.18) }
                                        GradientStop { position: 1; color: root.accent2() }
                                    }
                                    scale: heroPlayMa.pressed ? 0.92 : (heroPlayMa.containsMouse ? 1.04 : 1)
                                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                                    NavIcon { anchors.centerIn: parent; width: 23; height: 23; kind: root.s.playing ? "pause" : "play"; col: tc.light ? "#ffffff" : "#04121f" }
                                }
                                MouseArea { id: heroPlayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/toggle") } }
                            }
                            // next
                            Item {
                                width: 38; height: 38
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle { anchors.fill: parent; radius: 19; color: heroNextMa.containsMouse ? root.rgba(th.accent, 0.14) : root.rgba("#ffffff", 0.06); border.width: 1; border.color: tc.light ? "#28000000" : "#1effffff"; Behavior on color { ColorAnimation { duration: 140 } } }
                                NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "next"; col: heroNextMa.containsMouse ? th.accent : th.text }
                                MouseArea { id: heroNextMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/next") } }
                            }
                            // repeat
                            Item {
                                width: 30; height: 30
                                anchors.verticalCenter: parent.verticalCenter
                                NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "repeat"; col: root.s.repeat > 0 ? th.accent : root.rgba(th.dim, 0.85); opacity: root.s.repeat > 0 ? 1 : 0.7 }
                                Text { visible: root.s.repeat === 2; text: "1"; color: th.accent; font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; x: 20; y: 2 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/repeat?r=" + ((root.s.repeat + 1) % 3)) } }
                            }

                            Item { width: 12; height: 1 }

                            GlowButton {
                                height: 30
                                label: "VIDEO"
                                glow: th.bar
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: { root.watchCurrent() }
                            }
                            GlowButton {
                                height: 30
                                label: "IMMERSIVE"
                                glow: th.accent
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: { np.open() }
                            }
                        }
                    }

                    // right: the room listens
                    Item {
                        id: heroRing
                        width: 196; height: 196
                        anchors.right: parent.right; anchors.rightMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.width > 1160
                        CircEQ {
                            anchors.centerIn: parent
                            size: 196
                            bars: 54
                            inner: 0.66
                            mode: root.s.viz_mode % 3
                            // HOME is page 5. This said 0, so the ring on the
                            // home stage only ticked while the playlist page
                            // was open: it was painted once at launch and then
                            // stayed frozen for the whole session.
                            live: root.currentPage === 5
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: 98; height: 98; radius: 49
                            color: root.rgba(th.bg, 0.5)
                            border.width: 1; border.color: root.rgba(th.accent, 0.28)
                            Column {
                                anchors.centerIn: parent
                                spacing: 2
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "AETHER"
                                    color: root.rgba(th.dim, 0.8)
                                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.letterSpacing: 2; font.bold: true
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: (root.s.viz_mode === 1 ? "BLOOM" : root.s.viz_mode === 2 ? "WAVE" : "RING")
                                    color: th.accent
                                    font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: true; font.letterSpacing: 1.4
                                }
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.playTap(); root.hit("/mode?m=" + ((root.s.viz_mode + 1) % 3)) }
                        }
                    }
                }

                // ---------------- index ----------------
                // Five doors, no frames. Nothing is boxed; the hover is a pool
                // of light under the words instead of a card around them.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: 26

                    Repeater {
                        model: [
                            { icon: "cloud", label: "PLAYLIST", sub: root.lib.stream_count + " songs", pg: 0 },
                            { icon: "folder", label: "LOCAL", sub: root.lib.local_count + " files", pg: 1 },
                            { icon: "wave", label: "VIBE", sub: "live lyrics", pg: 2 },
                            { icon: "palette", label: "THEMES", sub: (root.themeCards.length || 20) + " worlds", pg: 4 },
                            { icon: "gear", label: "SETTINGS", sub: "tune it", pg: 6 }
                        ]
                        delegate: Item {
                            id: portal
                            Layout.fillWidth: true
                            implicitHeight: 50

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width * 0.82; height: 42; radius: 21
                                color: root.rgba(th.accent, portalMa.containsMouse ? 0.075 : 0)
                                Behavior on color { ColorAnimation { duration: 220 } }
                            }

                            Row {
                                anchors.left: parent.left; anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 11
                                NavIcon {
                                    width: 16; height: 16; kind: modelData.icon
                                    anchors.verticalCenter: parent.verticalCenter
                                    col: portalMa.containsMouse ? th.accent : root.rgba(th.dim, 0.72)
                                    scale: portalMa.containsMouse ? 1.12 : 1
                                    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                                    Behavior on col { ColorAnimation { duration: 180 } }
                                }
                                // one line per door. The label carries the name,
                                // the count rides beside it in a quieter size - no
                                // second line, so the strip reads as a legend
                                // above the shelf instead of five stacked cards.
                                Row {
                                    spacing: 7
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        text: modelData.label
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: portalMa.containsMouse ? th.text : root.rgba(th.text, 0.80)
                                        font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 1.5
                                        Behavior on color { ColorAnimation { duration: 160 } }
                                    }
                                    Text {
                                        text: modelData.sub
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: root.rgba(th.dim, portalMa.containsMouse ? 0.86 : 0.52)
                                        font.family: root.tf; font.pixelSize: (8) * root.ts
                                        Behavior on color { ColorAnimation { duration: 160 } }
                                    }
                                }
                            }
                            NavIcon {
                                anchors.right: parent.right
                                anchors.rightMargin: Math.round(parent.width * 0.09) + 9
                                anchors.verticalCenter: parent.verticalCenter
                                width: 12; height: 12; kind: "chev"
                                col: root.rgba(th.accent, portalMa.containsMouse ? 0.9 : 0)
                                x: portalMa.containsMouse ? 0 : -5
                                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                Behavior on col { ColorAnimation { duration: 180 } }
                            }
                            MouseArea {
                                id: portalMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); root.gotoPage(modelData.pg); }
                            }
                        }
                    }
                }

                // ---------------- jump back in ----------------
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Text { text: "JUMP BACK IN"; color: root.rgba(th.text, 0.9); font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: true; font.letterSpacing: 2 }
                    Text { text: "the last few rooms you opened"; color: root.rgba(th.dim, 0.65); font.family: root.tf; font.pixelSize: (9) * root.ts }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "ALL RECENT"
                        color: root.rgba(th.accent, 0.8)
                        font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.gotoPage(3) } }
                    }
                }

                Flickable {
                    id: recentFlick
                    Layout.fillWidth: true
                    height: 146
                    contentWidth: recentRow.width
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    // No edge scrim here. The row sits on a moving 3D room, so
                    // any opaque fade band reads as a dark rectangle pasted
                    // over the world. A clean clip is quieter than a box.

                    Row {
                        id: recentRow
                        spacing: 13
                        Repeater {
                            model: root.recentIds(9)
                            delegate: Item {
                                id: recentCard
                                readonly property var track: root.trackById(modelData)
                                readonly property bool isCur: root.s.track_id === modelData
                                width: 108; height: 146

                                Art {
                                    id: recentArt
                                    x: 2; y: 2
                                    width: 104; height: 104
                                    corner: 16
                                    seed: modelData
                                    source: recentCard.track && recentCard.track.cover && recentCard.track.cover.length > 4 ? recentCard.track.cover : ""
                                    scale: recentMa.pressed ? 0.96 : (recentMa.containsMouse ? 1.025 : 1)
                                    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
                                }
                                Rectangle {
                                    x: 2; y: 2; width: 104; height: 104; radius: 16
                                    color: root.rgba(th.bg, 0.22)
                                    opacity: recentMa.containsMouse ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 38; height: 38; radius: 19
                                        color: root.rgba(th.bg, 0.72)
                                        border.width: 1; border.color: root.rgba("#ffffff", 0.3)
                                        NavIcon { anchors.centerIn: parent; width: 14; height: 14; kind: "play"; col: "" + th.text }
                                    }
                                }
                                Rectangle {
                                    visible: isCur
                                    x: 2; y: 2; width: 104; height: 104; radius: 16
                                    color: "transparent"
                                    border.width: 1.5; border.color: th.accent
                                }
                                Text {
                                    x: 2; y: 112
                                    width: 104
                                    text: recentCard.track ? recentCard.track.title : ""
                                    color: isCur ? th.accent : th.text
                                    font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: isCur
                                    elide: Text.ElideRight
                                }
                                Text {
                                    x: 2; y: 128
                                    width: 104
                                    text: recentCard.track ? recentCard.track.artist : ""
                                    color: root.rgba(th.dim, 0.75)
                                    font.family: root.tf; font.pixelSize: (8) * root.ts
                                    elide: Text.ElideRight
                                }
                                MouseArea {
                                    id: recentMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.hit("/play?id=" + modelData) }
                                }
                            }
                        }
                    }
                }

                // ---------------- on repeat ----------------
                RowLayout {
                    Layout.fillWidth: true
                    visible: (root.playStats.top || []).length > 0
                    Layout.topMargin: 2
                    Text { text: "ON REPEAT"; color: root.rgba(th.text, 0.9); font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: true; font.letterSpacing: 2 }
                    Text { text: "the ones you keep coming back to"; color: root.rgba(th.dim, 0.65); font.family: root.tf; font.pixelSize: (9) * root.ts }
                    Item { Layout.fillWidth: true }
                }
                Flickable {
                    Layout.fillWidth: true
                    height: 50
                    visible: (root.playStats.top || []).length > 0
                    contentWidth: repeatRow.width
                    clip: true
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    Row {
                        id: repeatRow
                        spacing: 8
                        Repeater {
                            model: root.playStats.top || []
                            delegate: Rectangle {
                                id: repeatPill
                                readonly property var track: root.trackById(modelData.id)
                                width: repeatContent.width + 24
                                height: 46
                                radius: 0
                                color: "transparent"
                                border.width: 0
                                Rectangle {
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                                    height: 1; color: rpMa.containsMouse ? root.rgba(th.accent, 0.35) : root.rgba(th.text, 0.05)
                                    Behavior on color { ColorAnimation { duration: 160 } }
                                }
                                Row {
                                    id: repeatContent
                                    anchors.centerIn: parent
                                    spacing: 8
                                    Art {
                                        width: 30; height: 30; corner: 9
                                        seed: modelData.id
                                        source: repeatPill.track && repeatPill.track.cover && repeatPill.track.cover.length > 4 ? repeatPill.track.cover : ""
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Column {
                                        spacing: 0
                                        anchors.verticalCenter: parent.verticalCenter
                                        Text {
                                            text: repeatPill.track ? repeatPill.track.title : "?"
                                            color: th.text; font.family: root.tf; font.pixelSize: (10) * root.ts
                                            elide: Text.ElideRight
                                            width: Math.min(150, implicitWidth)
                                        }
                                        Text {
                                            text: modelData.plays + " plays"
                                            color: root.rgba(th.dim, 0.65); font.family: root.tf; font.pixelSize: (8) * root.ts
                                        }
                                    }
                                }
                                MouseArea {
                                    id: rpMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.hit("/play?id=" + modelData.id) }
                                }
                            }
                        }
                    }
                }

                // ---------------- vault ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 3
                        height: 132
                        radius: 0
                        color: "transparent"
                        border.width: 0
                        RowLayout {
                            anchors.fill: parent
                            anchors.topMargin: 8; anchors.bottomMargin: 8
                            anchors.leftMargin: 2; anchors.rightMargin: 10
                            spacing: 14
                            Art {
                                width: 74; height: 74; corner: 16
                                seed: 1
                                source: root.libCover()
                                Layout.alignment: Qt.AlignVCenter
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 2
                                Text { text: "YOUR PLAYLIST"; color: root.rgba(th.dim, 0.65); font.family: root.tf; font.pixelSize: (7) * root.ts; font.letterSpacing: 1.8; font.bold: true }
                                Text {
                                    text: root.readable(root.lib.playlist_name)
                                    color: th.text; font.family: root.tf; font.pixelSize: (16) * root.ts; font.bold: true
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                                Text {
                                    text: (root.lib.playlist_owner || "you") + " · " + root.lib.total + " tracks · " + root.lib.playable + " playable"
                                    color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (9) * root.ts
                                }
                                RowLayout {
                                    spacing: 7
                                    Text {
                                        visible: root.convertStatus.running
                                        text: "CONVERTING " + root.convertStatus.done + "/" + root.convertStatus.total
                                        color: th.accent; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true
                                    }
                                    Text {
                                        visible: !root.convertStatus.running && root.convertStatus.done > 0
                                        text: root.convertStatus.done + " converted" + (root.convertStatus.failed > 0 ? " · " + root.convertStatus.failed + " unmatched" : "")
                                        color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts
                                    }
                                }
                            }
                            ColumnLayout {
                                spacing: 6
                                Layout.alignment: Qt.AlignVCenter
                                GlowButton {
                                    label: "OPEN"
                                    bh: 30
                                    onClicked: { root.gotoPage(0) }
                                }
                                GlowButton {
                                    label: "OPEN LOCAL"
                                    bh: 30
                                    glow: th.bar
                                    onClicked: { root.gotoPage(1) }
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 2
                        height: 132
                        radius: 0
                        color: "transparent"
                        border.width: 0
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: 8; anchors.bottomMargin: 8
                            anchors.leftMargin: 4; anchors.rightMargin: 2
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Text { text: "THE ENGINE"; color: root.rgba(th.dim, 0.65); font.family: root.tf; font.pixelSize: (7) * root.ts; font.letterSpacing: 1.8; font.bold: true }
                                Item { Layout.fillWidth: true }
                                Rectangle {
                                    width: 6; height: 6; radius: 3
                                    color: root.s.streaming ? th.accent : root.rgba(th.dim, 0.6)
                                    Layout.alignment: Qt.AlignVCenter
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Repeater {
                                    model: [
                                        { k: "TRACKS", v: root.lib.total },
                                        { k: "READY", v: root.lib.playable },
                                        { k: "RAM", v: root.engine.ram_mb !== undefined ? root.engine.ram_mb + "M" : "\u2014" }
                                    ]
                                    delegate: Column {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.v; color: th.text; font.family: root.tf; font.pixelSize: (15) * root.ts; font.bold: true }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.k; color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (7) * root.ts; font.letterSpacing: 1.2 }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true; Layout.preferredHeight: 6 }
                            Text {
                                Layout.fillWidth: true
                                text: root.s.streaming ? "STREAM SESSION LIVE" : "LOCAL SOVEREIGN MODE"
                                color: root.s.streaming ? th.accent : root.rgba(th.dim, 0.8)
                                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4
                            }
                            Text {
                                Layout.fillWidth: true
                                text: root.s.underruns > 0 ? (root.s.underruns + " underruns · engine v" + (root.engine.version || "0.5")) : ("clean signal · engine v" + (root.engine.version || "0.5"))
                                color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (8) * root.ts
                            }
                        }
                    }
                }

                Item { height: 4 }
            }
        }
    }

    // PAGE 6: SETTINGS
    Item {
        id: page6
        property int pageIndex: 6
        anchors.left: contentArea.right; anchors.right: parent.right
        anchors.top: topbar.bottom; anchors.bottom: bar.top
        visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
        z: pageIndex === root.currentPage ? 2 : 1
        clip: true
        readonly property var tv: root.trFor(pageIndex)
        opacity: page6.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page6.tv.rz
        transform: [
            Translate { x: page6.tv.x; y: page6.tv.y },
            Rotation { origin.x: page6.width / 2; origin.y: page6.height / 2; axis { x: 0; y: 1; z: 0 } angle: page6.tv.ry },
            Scale { origin.x: page6.width / 2; origin.y: page6.height / 2; xScale: page6.tv.s; yScale: page6.tv.s }
        ]

        Flickable {
            anchors.fill: parent
            anchors.leftMargin: 30; anchors.rightMargin: 30
            anchors.topMargin: 10; anchors.bottomMargin: 10
            contentHeight: setCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: GlassScroll { }

            ColumnLayout {
                id: setCol
                width: parent.width
                spacing: 16

                // ---------------- header ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 18
                    ColumnLayout {
                        spacing: 3
                        Text { text: "SETTINGS"; color: th.text; font.family: root.tf; font.pixelSize: (26) * root.ts; font.bold: true; font.letterSpacing: -0.3 }
                        Text { text: "shape the engine, the surface, the way time passes in here"; color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (10) * root.ts }
                    }
                    Item { Layout.fillWidth: true }
                    RowLayout {
                        spacing: 9
                        Rectangle {
                            width: engineBadge.width + 20; height: 28; radius: 14
                            color: root.rgba(th.bg, 0.32)
                            border.width: 1; border.color: root.rgba("#ffffff", 0.13)
                            Row {
                                id: engineBadge
                                anchors.centerIn: parent
                                spacing: 6
                                Rectangle { width: 5; height: 5; radius: 2.5; color: root.s.streaming ? th.accent : root.rgba(th.dim, 0.7); anchors.verticalCenter: parent.verticalCenter }
                                Text { text: (root.s.streaming ? "STREAM LIVE" : "LOCAL ENGINE") + " · v" + (root.engine.version || "0.5"); color: root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1 }
                            }
                        }
                        GlowButton { label: "STUDIO"; bh: 28; glow: th.accent; onClicked: { root.openStudio(0) } }
                        GlowButton { label: "OPEN LOCAL VAULT"; bh: 28; glow: th.bar; onClicked: { root.gotoPage(1) } }
                    }
                }


                // ---------------- two columns ----------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 34

                    // ================= LEFT: surface + engine =================
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 14

                        // surface
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "SURFACE"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Rectangle { width: 5; height: 5; radius: 2.5; color: th.accent; Layout.alignment: Qt.AlignVCenter }
                            Text { text: "in the room  ·  " + (root.tc.name || "Frutiger"); color: root.rgba(th.accent, 0.9); font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true }
                            GlowButton { label: "GALLERY"; bh: 24; glow: th.accent; onClicked: { root.gotoPage(4) } }
                        }

                        Flow {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 54
                            spacing: 0
                            Repeater {
                                model: root.themeCards
                                delegate: Item {
                                    readonly property bool on: root.tc.name === modelData.name
                                    width: chipName.width + 18
                                    height: 27
                                    Text {
                                        id: chipName
                                        anchors.left: parent.left
                                        anchors.leftMargin: 9
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 8
                                        text: modelData.name
                                        color: on ? th.accent : (chipMa.containsMouse ? th.text : root.rgba(th.text, tc.light ? 0.72 : 0.52))
                                        font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: on
                                        Behavior on color { ColorAnimation { duration: 160 } }
                                    }
                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 9
                                        anchors.bottom: parent.bottom
                                        width: on ? chipName.width : 0; height: 1.5; radius: 1
                                        color: modelData.accent
                                        Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                    }
                                    MouseArea {
                                        id: chipMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.setTheme(modelData.id, modelData.name); }
                                    }
                                }
                            }
                        }


                        // engine / eq
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "ENGINE"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                width: 84; height: 26; radius: 13
                                color: root.eqOn ? root.rgba(th.accent, 0.16) : (tc.light ? "#10000000" : "#0bffffff")
                                border.width: 1; border.color: root.eqOn ? root.rgba(th.accent, 0.5) : root.rgba("#ffffff", 0.16)
                                Text { anchors.centerIn: parent; text: root.eqOn ? "EQ ON" : "EQ OFF"; color: root.eqOn ? th.accent : root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.eqOn = !root.eqOn; root.pushEq(); } }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 16

                            // the analyser jewel
                            Item {
                                width: 152; height: 176
                                Layout.alignment: Qt.AlignBottom
                                Canvas {
                                    id: eqRing
                                    anchors.top: parent.top
                                    anchors.topMargin: 30
                                    width: 152; height: 144
                                    onPaint: {
                                        var ctx = getContext("2d");
                                        ctx.reset();
                                        var cx = 76, cy = 72, r0 = 39, n = 44;
                                        var lv = root.s.levels || [];
                                        var rot = root.eqPhase * 0.35;
                                        var bass = 0;
                                        for (var b = 0; b < 4 && b < lv.length; b++) bass += lv[b];
                                        bass = Math.min(1, bass / 2.5);
                                        ctx.lineCap = "round";
                                        ctx.strokeStyle = root.rgba(th.accent, 0.05 + bass * 0.1);
                                        ctx.lineWidth = 10 + bass * 8;
                                        ctx.beginPath(); ctx.arc(cx, cy, r0 + 15, 0, Math.PI * 2); ctx.stroke();
                                        for (var i = 0; i < n; i++) {
                                            var idx = Math.floor(i * lv.length / n);
                                            var v = lv[Math.min(idx, lv.length - 1)] || 0;
                                            var a = (i / n) * Math.PI * 2 + rot;
                                            var len = 4 + v * 23;
                                            ctx.strokeStyle = root.rgba(root.mixColor(th.accent, root.accent2(), i / n), 0.22 + v * 0.75);
                                            ctx.lineWidth = 3.2;
                                            ctx.beginPath();
                                            ctx.moveTo(cx + Math.cos(a) * r0, cy + Math.sin(a) * r0);
                                            ctx.lineTo(cx + Math.cos(a) * (r0 + len), cy + Math.sin(a) * (r0 + len));
                                            ctx.stroke();
                                        }
                                        ctx.strokeStyle = root.rgba(th.bar, 0.3);
                                        ctx.lineWidth = 1;
                                        ctx.beginPath(); ctx.arc(cx, cy, r0 - 12, 0, Math.PI * 2); ctx.stroke();
                                        ctx.fillStyle = root.rgba(th.text, 0.9);
                                        ctx.font = "600 8px sans-serif";
                                        ctx.textAlign = "center";
                                        ctx.fillText(root.eqOn ? "DSP LIVE" : "BYPASS", cx, cy + 3);
                                    }
                                    Timer { interval: 33; running: root.currentPage === 6 && root.s.playing; repeat: true; onTriggered: eqRing.requestPaint() }
                                }
                                Column {
                                    anchors.top: parent.top
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 1
                                    Text { text: "GRAPHIC EQ"; color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.6; anchors.horizontalCenter: parent.horizontalCenter }
                                    Text { text: "FIVE BANDS"; color: root.rgba(th.text, 0.78); font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignBottom
                                spacing: 10
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 8
                                    EqSlider { id: eq0; label: "60Hz"; Layout.alignment: Qt.AlignBottom; onMoved: root.pushEq() }
                                    EqSlider { id: eq1; label: "250Hz"; Layout.alignment: Qt.AlignBottom; onMoved: root.pushEq() }
                                    EqSlider { id: eq2; label: "1kHz"; Layout.alignment: Qt.AlignBottom; onMoved: root.pushEq() }
                                    EqSlider { id: eq3; label: "4kHz"; Layout.alignment: Qt.AlignBottom; onMoved: root.pushEq() }
                                    EqSlider { id: eq4; label: "12kHz"; Layout.alignment: Qt.AlignBottom; onMoved: root.pushEq() }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: [
                                            { n: "FLAT", g: [0, 0, 0, 0, 0] },
                                            { n: "BASS", g: [7, 4, 0, -1, 1] },
                                            { n: "VOCAL", g: [-2, 1, 4, 3, 0] },
                                            { n: "CLUB", g: [6, 2, -2, 3, 5] },
                                            { n: "AIR", g: [-1, -1, 1, 4, 6] }
                                        ]
                                        delegate: Rectangle {
                                            width: prText.width + 16; height: 23; radius: 11.5
                                            color: prMa.containsMouse ? root.rgba(th.accent, 0.14) : (tc.light ? "#10000000" : "#0bffffff")
                                            border.width: 1; border.color: prMa.containsMouse ? root.rgba(th.accent, 0.4) : root.rgba("#ffffff", 0.13)
                                            Text { id: prText; anchors.centerIn: parent; text: modelData.n; color: root.rgba(th.text, 0.82); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 0.7 }
                                            MouseArea {
                                                id: prMa
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap();
                                                    eq0.value = modelData.g[0]; eq1.value = modelData.g[1]; eq2.value = modelData.g[2];
                                                    eq3.value = modelData.g[3]; eq4.value = modelData.g[4];
                                                    root.pushEq();
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }


                        // time
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 9
                            Text { text: "SLEEP TIMER"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Text {
                                visible: (root.s.sleep_ms || 0) > 0
                                text: root.fmtSleep()
                                color: th.accent; font.family: "Consolas"; font.pixelSize: (9) * root.ts
                            }
                            Repeater {
                                model: ["15", "30", "60", "off"]
                                delegate: GlowButton {
                                    label: modelData === "off" ? "OFF" : modelData + "M"
                                    bh: 24
                                    glow: th.accent
                                    onClicked: { root.setSleep(modelData === "off" ? 0 : parseInt(modelData)) }
                                }
                            }
                        }

                        // system-wide keys: they answer while another window has
                        // the focus, which is the whole point of them
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 9
                            Text { text: "GLOBAL KEYS"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Text {
                                text: "ctrl+alt+space  \u00b7  \u2190 \u2192  \u00b7  \u2191 \u2193 volume"
                                color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (8) * root.ts
                            }
                            Item { Layout.fillWidth: true }
                            GlowButton {
                                label: root.s.hotkeys ? "ON" : "OFF"
                                bh: 24
                                glow: root.s.hotkeys ? th.accent : th.bar
                                onClicked: { root.toggleHotkeys() }
                            }
                        }
                    }


                    // ================= RIGHT: words + vault + library =================
                    ColumnLayout {
                        Layout.preferredWidth: 470
                        Layout.alignment: Qt.AlignTop
                        spacing: 14

                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "LYRIC TEXTURE"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Text { text: root.s.title.length > 0 ? ("for " + root.s.title) : "for every song"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts; elide: Text.ElideRight; Layout.maximumWidth: 180 }
                            Text { text: "±" + (root.s.lyric_offset_ms !== undefined ? root.s.lyric_offset_ms : 0) + "ms"; color: root.rgba(th.accent, 0.85); font.family: root.tf; font.pixelSize: (8) * root.ts }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "COLOR"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; Layout.alignment: Qt.AlignVCenter }
                            Repeater {
                                model: ["accent", "solid", "gradient", "rainbow"]
                                delegate: Rectangle {
                                    width: lsText.width + 14; height: 22; radius: 11
                                    color: root.lyricStyle.pattern === modelData ? root.rgba(th.accent, 0.16) : (tc.light ? "#10000000" : "#0bffffff")
                                    border.width: 1; border.color: root.lyricStyle.pattern === modelData ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.13)
                                    Text { id: lsText; anchors.centerIn: parent; text: modelData.toUpperCase(); color: root.lyricStyle.pattern === modelData ? th.accent : root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.lyricStyle = ({ pattern: modelData, anim: root.lyricStyle.anim, emphasis: root.lyricStyle.emphasis }); root.applyLyricStyle(); }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "REVEAL"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; Layout.alignment: Qt.AlignVCenter }
                            Repeater {
                                model: ["rise", "fade", "glow", "typewriter"]
                                delegate: Rectangle {
                                    width: laText.width + 14; height: 22; radius: 11
                                    color: root.lyricStyle.anim === modelData ? root.rgba(th.accent, 0.16) : (tc.light ? "#10000000" : "#0bffffff")
                                    border.width: 1; border.color: root.lyricStyle.anim === modelData ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.13)
                                    Text { id: laText; anchors.centerIn: parent; text: modelData.toUpperCase(); color: root.lyricStyle.anim === modelData ? th.accent : root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.lyricStyle = ({ pattern: root.lyricStyle.pattern, anim: modelData, emphasis: root.lyricStyle.emphasis }); root.applyLyricStyle(); }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "EMPHASIS"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; Layout.alignment: Qt.AlignVCenter }
                            Repeater {
                                model: ["glow", "scale", "bold"]
                                delegate: Rectangle {
                                    width: leText.width + 14; height: 22; radius: 11
                                    color: root.lyricStyle.emphasis === modelData ? root.rgba(th.accent, 0.16) : (tc.light ? "#10000000" : "#0bffffff")
                                    border.width: 1; border.color: root.lyricStyle.emphasis === modelData ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.13)
                                    Text { id: leText; anchors.centerIn: parent; text: modelData.toUpperCase(); color: root.lyricStyle.emphasis === modelData ? th.accent : root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.lyricStyle = ({ pattern: root.lyricStyle.pattern, anim: root.lyricStyle.anim, emphasis: modelData }); root.applyLyricStyle(); }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                width: glText.width + 14; height: 22; radius: 11
                                color: root.lyricStyleGlobal ? root.rgba(th.accent, 0.16) : (tc.light ? "#10000000" : "#0bffffff")
                                border.width: 1; border.color: root.lyricStyleGlobal ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.13)
                                Text { id: glText; anchors.centerIn: parent; text: "ALL SONGS"; color: root.lyricStyleGlobal ? th.accent : root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.lyricStyleGlobal = !root.lyricStyleGlobal } }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text { text: "NUDGE"; color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; Layout.alignment: Qt.AlignVCenter }
                            Repeater {
                                model: [{ "l": "−200", "d": -200 }, { "l": "−50", "d": -50 }, { "l": "+50", "d": 50 }, { "l": "+200", "d": 200 }]
                                delegate: Rectangle {
                                    width: nudgeText.width + 14; height: 22; radius: 11
                                    color: tc.light ? "#10000000" : "#0bffffff"
                                    border.width: 1; border.color: root.rgba("#ffffff", 0.13)
                                    Text { id: nudgeText; anchors.centerIn: parent; text: modelData.l; color: root.rgba(th.accent, 0.85); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.playTap(); root.hit("/lyricoffset?ms=" + ((root.s.lyric_offset_ms !== undefined ? root.s.lyric_offset_ms : 0) + modelData.d)) }
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.currentLyric().length > 0 ? ("\u201c" + root.currentLyric() + "\u201d") : "\u201cthe room remembers you\u201d"
                                color: root.rgba(th.accent, 0.75)
                                font.family: root.tf; font.pixelSize: (10) * root.ts; font.italic: true
                                elide: Text.ElideRight
                                Layout.maximumWidth: 178
                            }
                        }


                        // your libraries
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "YOUR LIBRARIES"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Text { text: root.lib.stream_count + " in playlist  ·  " + (root.lib.local_count !== undefined ? root.lib.local_count : "—") + " local"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Rectangle {
                                Layout.fillWidth: true
                                height: 32; radius: 16
                                color: tc.light ? "#10000000" : "#0bffffff"
                                border.width: 1; border.color: plInput.activeFocus ? root.rgba(th.accent, 0.55) : root.rgba("#ffffff", 0.15)
                                TextField {
                                    Keys.onPressed: function(ev) {
                                        if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                            root.typeKey();
                                    }
                                    id: plInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    placeholderText: "paste a spotify playlist link to switch catalogs"
                                    color: th.text
                                    placeholderTextColor: root.rgba(th.dim, 0.55)
                                    font.family: root.tf; font.pixelSize: (10) * root.ts
                                    selectByMouse: true
                                    background: Item { }
                                }
                            }
                            GlowButton {
                                label: "SWITCH"
                                bh: 32
                                onClicked: { if (plInput.text.length < 10) { syncToast.show("paste a playlist link first"); return; }
                                    root.fetchJson("/playlist/set?url=" + encodeURIComponent(plInput.text), function(r) {
                                        syncToast.show(r.ok ? "playlist switched - syncing" : "bad playlist link");
                                    });
                                }
                            }
                            GlowButton {
                                label: "SYNC"
                                bh: 32
                                glow: th.bar
                                onClicked: { syncToast.show("syncing playlist...");
                                    root.fetchJson("/catalog/sync", function(r) {
                                        if (r.added > 0) syncToast.show("+" + r.added + " new track" + (r.added === 1 ? "" : "s"));
                                        else syncToast.show("catalog up to date");
                                    });
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "PLAYLIST · " + root.readable(root.lib.playlist_name) + " · by " + (root.lib.playlist_owner || "you")
                            color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.1
                            elide: Text.ElideRight
                        }
                        // connect: add songs from anywhere
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 9
                            Text { text: "CONNECT"; color: root.rgba(th.dim, 0.62); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.9 }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: root.searchResults.length > 0 ? "SEARCH RESULTS" : (root.suggestResults.length > 0 ? "SUGGESTED" : "search, or pull what is playing")
                                color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.letterSpacing: 0.8
                            }
                            GlowButton {
                                label: "FULL ACCESS"
                                bh: 24
                                glow: th.accent
                                onClicked: { root.hit("/oauth/grant");
                                    syncToast.show("browser opening - re-authorize, then restart the app");
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Rectangle {
                                Layout.fillWidth: true
                                height: 32; radius: 16
                                color: tc.light ? "#10000000" : "#0bffffff"
                                border.width: 1; border.color: spotSearch.activeFocus ? root.rgba(th.accent, 0.55) : root.rgba("#ffffff", 0.15)
                                NavIcon { x: 12; width: 13; height: 13; anchors.verticalCenter: parent.verticalCenter; kind: "search"; col: root.rgba(th.dim, 0.8) }
                                TextField {
                                    Keys.onPressed: function(ev) {
                                        if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                            root.typeKey();
                                    }
                                    id: spotSearch
                                    anchors.left: parent.left; anchors.leftMargin: 32
                                    anchors.right: parent.right; anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    placeholderText: "any song, then add it here"
                                    color: th.text
                                    placeholderTextColor: root.rgba(th.dim, 0.55)
                                    font.family: root.tf; font.pixelSize: (10) * root.ts
                                    selectByMouse: true
                                    background: Item { }
                                    onAccepted: root.fetchJson("/spotify/search?q=" + encodeURIComponent(text), function(r) { root.searchResults = r.tracks || [] });
                                }
                            }
                            GlowButton { label: "FIND"; bh: 32; onClicked: { root.fetchJson("/spotify/search?q=" + encodeURIComponent(spotSearch.text), function(r) { root.searchResults = r.tracks || [] }) } }
                            GlowButton { label: "SUGGESTED"; bh: 32; onClicked: { root.fetchJson("/spotify/suggest", function(r) { root.suggestResults = r.tracks || [] }) } }
                            GlowButton { label: "LIKED"; bh: 32; onClicked: { root.fetchJson("/spotify/library", function(r) { root.searchResults = r.tracks || [] }) } }
                        }

                        Flickable {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 98
                            contentHeight: resultCol.height
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: GlassScroll { }
                            ColumnLayout {
                                id: resultCol
                                width: parent.width
                                spacing: 3
                                Repeater {
                                    model: root.searchResults.length > 0 ? root.searchResults : root.suggestResults
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        height: 42
                                        radius: 12
                                        color: resMa.containsMouse ? (tc.light ? "#12000000" : "#10ffffff") : "transparent"
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 7; anchors.rightMargin: 7
                                            spacing: 10
                                            Art {
                                                width: 30; height: 30; corner: 8
                                                Layout.alignment: Qt.AlignVCenter
                                                seed: index
                                                source: modelData.cover && modelData.cover.length > 4 ? root.art(modelData.cover) : ""
                                            }
                                            ColumnLayout {
                                                spacing: 0
                                                Layout.fillWidth: true
                                                Text { text: modelData.title; color: th.text; font.family: root.tf; font.pixelSize: (10) * root.ts; elide: Text.ElideRight; Layout.fillWidth: true }
                                                Text { text: modelData.artist; color: root.rgba(th.dim, 0.75); font.family: root.tf; font.pixelSize: (9) * root.ts; elide: Text.ElideRight; Layout.fillWidth: true }
                                            }
                                            Rectangle {
                                                width: 26; height: 26; radius: 13
                                                color: resAddMa.containsMouse ? th.accent : (tc.light ? "#16000000" : "#0effffff")
                                                border.width: 1; border.color: root.rgba("#ffffff", 0.16)
                                                Text { anchors.centerIn: parent; text: "+"; color: resAddMa.containsMouse ? root.rgba(th.bg, 1) : th.accent; font.family: root.tf; font.pixelSize: (14) * root.ts; font.bold: true }
                                                MouseArea {
                                                    id: resAddMa
                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.playTap();
                                                        syncToast.show("adding '" + modelData.title + "'...");
                                                        root.fetchJson("/spotify/add?uri=" + encodeURIComponent(modelData.uri), function(r) {
                                                            syncToast.show(r.ok ? "added to your playlist - syncing" : (r.error || "add failed"));
                                                        });
                                                    }
                                                }
                                            }
                                        }
                                        MouseArea { id: resMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                                    }
                                }
                                Text {
                                    visible: root.searchResults.length === 0 && root.suggestResults.length === 0
                                    text: "search a song, or pull suggestions from what is playing - anything you add lands in this playlist"
                                    color: root.rgba(th.dim, 0.45); font.family: root.tf; font.pixelSize: (9) * root.ts
                                    Layout.fillWidth: true
                                }
                            }
                        }

                    }
                }


                Item { height: 4 }
            }
        }
    }

    // EXTENSION PAGES (user-provided QML, loaded live)
    Repeater {
        model: root.exts
        delegate: Item {
            property int pageIndex: 7 + index
            anchors.left: contentArea.right; anchors.right: parent.right
            anchors.top: topbar.bottom; anchors.bottom: bar.top
            visible: pageIndex === root.currentPage || pageIndex === root.leavingPage
            z: pageIndex === root.currentPage ? 2 : 1
                clip: true
            readonly property var tv: root.trFor(pageIndex)
            opacity: page6.tv.o * (root.themeWorldOpen ? 0 : 1)
        rotation: page6.tv.rz
            transform: [
                Translate { x: page6.tv.x; y: page6.tv.y },
                Rotation { origin.x: page6.width / 2; origin.y: page6.height / 2; axis { x: 0; y: 1; z: 0 } angle: page6.tv.ry },
                Scale { origin.x: page6.width / 2; origin.y: page6.height / 2; xScale: page6.tv.s; yScale: page6.tv.s }
            ]
            Loader {
                anchors.fill: parent
                source: "file:///" + (modelData.path || "").replace(/\\/g, "/")
            }
        }
    }

    // ---------------- bottom bar ----------------
    // ---------------- immersive now-playing overlay ----------------
    Item {
        id: np
        z: 50
        anchors.fill: parent
        visible: npSlide > 0.002
        property real npSlide: 0
        property int lastLyricId: -1

        function open() {
            if (s.track_id !== null && (lyricsData.lines.length === 0 || lastLyricId !== s.track_id)) {
                fetchLyrics(s.track_id);
                lastLyricId = s.track_id;
            }
            // the stage opens through a drop, not a slide
            root.dyeAt(0.5, 0.46);
            npAnim.duration = 560;
            npAnim.easing.type = Easing.OutQuint;
            npAnim.to = 1;
            npAnim.restart();
        }
        function close() {
            npAnim.duration = 280;
            npAnim.easing.type = Easing.InCubic;
            npAnim.to = 0;
            npAnim.restart();
        }
        NumberAnimation {
            id: npAnim
            target: np
            property: "npSlide"
            from: np.npSlide
            duration: 520
            easing.type: Easing.OutCubic
        }

        // The cover becomes the room. It is the dominant surface, not a tint.
        Image {
            id: npBackdrop
            anchors.fill: parent
            source: root.nowCover()
            fillMode: Image.PreserveAspectCrop
            scale: 1.12
            // fully opaque at rest: the page underneath must never ghost
            // through the stage
            opacity: np.npSlide
            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 0.52
                blurMax: 72
                saturation: 0.85
                brightness: -0.02
            }
            // a long, slow breath so the artwork feels alive behind the type
            NumberAnimation on scale {
                from: 1.10; to: 1.22; duration: 26000
                loops: Animation.Infinite
                easing.type: Easing.InOutSine
            }
        }
        Rectangle {
            anchors.fill: parent
            color: root.rgba(th.bg, 0.30 * np.npSlide)
        }
        Rectangle {
            anchors.fill: parent
            opacity: np.npSlide
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(th.bg, 0.58) }
                GradientStop { position: 0.32; color: root.rgba(th.bg, 0.12) }
                GradientStop { position: 0.68; color: root.rgba(th.bg, 0.30) }
                GradientStop { position: 1; color: root.rgba(th.bg, 0.84) }
            }
        }
        // a directional scrim: keep the artwork alive on the left, give the
        // words and controls a quiet dark room on the right
        Rectangle {
            anchors.fill: parent
            opacity: np.npSlide
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: root.rgba(th.bg, 0.18) }
                GradientStop { position: 0.28; color: root.rgba(th.bg, 0.04) }
                GradientStop { position: 0.52; color: root.rgba(th.bg, 0.38) }
                GradientStop { position: 1; color: root.rgba(th.bg, 0.72) }
            }
        }
        // a soft pool of shade behind the type: no edge, just gravity
        Rectangle {
            x: parent.width * 0.27; y: parent.height * 0.14
            width: parent.width * 0.64; height: parent.height * 0.66
            radius: 120
            color: root.rgba(th.bg, 0.52)
            opacity: np.npSlide
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 84 }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.ArrowCursor
            onClicked: { root.playTap(); np.close() }
        }

        // close control
        Rectangle {
            x: parent.width - width - 22; y: 20
            width: closeText.width + 30; height: 32; radius: 16
            color: closeMa.containsMouse ? root.rgba(th.accent, 0.18) : root.rgba(th.bg, 0.4)
            border.width: 1
            border.color: closeMa.containsMouse ? root.rgba(th.accent, 0.5) : root.rgba("#ffffff", 0.2)
            opacity: np.npSlide
            Behavior on color { ColorAnimation { duration: 150 } }
            Text { id: closeText; anchors.centerIn: parent; text: "CLOSE  \u00b7  ESC"; color: closeMa.containsMouse ? th.accent : root.rgba(th.text, 0.8); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
            MouseArea {
                id: closeMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.playTap(); np.close() }
            }
        }

        RowLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 100, 1080)
            spacing: 48
            opacity: np.npSlide
            transform: Translate { y: (1 - np.npSlide) * 44 }

            // ---------------- artefact ----------------
            Item {
                readonly property real stage: Math.min(np.height * 0.52, 360)
                Layout.preferredWidth: stage
                Layout.preferredHeight: stage
                Layout.alignment: Qt.AlignVCenter

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.94; height: width
                    radius: width / 2
                    color: root.rgba(th.accent, root.s.playing ? 0.10 + root.bassLevel * 0.08 : 0.04)
                    Behavior on color { ColorAnimation { duration: 120 } }
                }
                CircEQ {
                    anchors.centerIn: parent
                    size: parent.width * 0.96
                    mode: root.s.viz_mode % 3
                    bars: 84
                    inner: 0.66
                    live: np.npSlide > 0.05
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.62; height: width
                    radius: 28
                    color: root.rgba(th.bg, 0.45)
                    border.width: 1; border.color: root.rgba("#ffffff", 0.18)
                }
                Art {
                    id: npArt
                    anchors.centerIn: parent
                    width: parent.width * 0.6; height: width
                    corner: 28
                    seed: root.s.track_id === null ? 0 : root.s.track_id
                    source: root.nowCover()
                    scale: npArtMa.pressed ? 0.97 : (npArtMa.containsMouse ? 1.02 : 1)
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack } }
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.6; height: width
                    radius: 28
                    color: "transparent"
                    border.width: 1; border.color: root.rgba("#ffffff", 0.24)
                }
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.6; height: width
                    radius: 28
                    color: root.rgba(th.bg, npArtMa.containsMouse ? 0.22 : 0)
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 54; height: 54; radius: 27
                        color: root.rgba(th.bg, 0.66)
                        border.width: 1; border.color: root.rgba("#ffffff", 0.28)
                        opacity: npArtMa.containsMouse ? 1 : 0
                        NavIcon { anchors.centerIn: parent; width: 20; height: 20; kind: "shuffle"; col: "" + th.text; visible: false }
                        NavIcon { anchors.centerIn: parent; width: 20; height: 20; kind: "play"; col: "" + th.text; visible: root.s.playing }
                        NavIcon { anchors.centerIn: parent; width: 20; height: 20; kind: "pause"; col: "" + th.text; visible: !root.s.playing }
                    }
                }
                MouseArea {
                    id: npArtMa
                    anchors.centerIn: parent
                    width: parent.width * 0.6; height: width
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.hit("/toggle") }
                }
            }

            // ---------------- words + controls ----------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 10

                RowLayout {
                    spacing: 8
                    Rectangle { width: 6; height: 6; radius: 3; color: th.accent }
                    Text { text: "NOW PLAYING"; color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2.2 }
                    Text { visible: root.s.origin && root.s.origin.length > 0; text: "· " + (root.s.origin || "").toUpperCase(); color: root.rgba(th.accent, 0.8); font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4 }
                }
                Text {
                    Layout.fillWidth: true
                    text: root.s.title.length > 0 ? root.s.title : "nothing playing"
                    color: tc.light ? "#12161b" : "#f4ffff"
                    font.family: root.tf; font.pixelSize: (42) * root.ts; font.bold: true; font.letterSpacing: -1.0
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.s.artist.length > 0 ? root.s.artist : "\u2014"
                    color: tc.light ? "#232b33" : root.rgba("#ffffff", 0.82)
                    font.family: root.tf; font.pixelSize: (17) * root.ts
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.s.album && root.s.album.length > 0 ? root.s.album : (root.tc.scene || "")
                    color: tc.light ? root.rgba("#12161b", 0.55) : root.rgba("#ffffff", 0.52)
                    font.family: root.tf; font.pixelSize: (10) * root.ts
                    elide: Text.ElideRight
                }

                Item { Layout.fillWidth: true; Layout.preferredHeight: 6 }

                // current lyric, the emotional centre
                ColumnLayout {
                    id: npLyricCol
                    property real lyricRise: 0
                    Layout.fillWidth: true
                    spacing: 3
                    Text {
                        id: npLyric
                        Layout.fillWidth: true
                        visible: root.currentLyric().length > 0
                        text: root.currentLyric()
                        color: th.accent
                        font.family: root.tf; font.pixelSize: (21) * root.ts; font.bold: true
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        // each new line lifts into place instead of blinking over
                        transform: Translate { y: npLyricCol.lyricRise }
                    }
                    ParallelAnimation {
                        id: npLyricIn
                        NumberAnimation { target: npLyric; property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.OutCubic }
                        NumberAnimation { target: npLyricCol; property: "lyricRise"; from: 9; to: 0; duration: 420; easing.type: Easing.OutQuint }
                    }
                    Connections {
                        target: root
                        function onLyricLineChanged() { npLyricIn.restart(); }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.lyricsData.synced && root.lyricsData.lines.length > root.lyricLine + 1
                        text: visible ? root.lyricsData.lines[root.lyricLine + 1].text : ""
                        color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (12) * root.ts
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.lyricsData.lines.length === 0
                        text: "no lyrics for this one \u2014 just the room and the sound"
                        color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (10) * root.ts; font.italic: true
                    }
                }

                Item { Layout.fillWidth: true; Layout.preferredHeight: 4 }

                ScrubBar {
                    Layout.fillWidth: true
                    height: 24
                    thickness: 4
                    value: root.posMs
                    max: Math.max(1, root.s.duration_ms)
                    onSeek: function(p) { root.seekTo(p * root.s.duration_ms); }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: root.fmt(root.posMs); color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts; font.family: "Consolas" }
                    Item { Layout.fillWidth: true }
                    Text { text: root.fmt(root.s.duration_ms); color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts; font.family: "Consolas" }
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 22
                    Item {
                        width: 38; height: 38
                        NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "shuffle"; col: root.s.shuffle ? th.accent : root.rgba(th.dim, 0.8); opacity: root.s.shuffle ? 1 : 0.7 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/shuffle?s=" + (root.s.shuffle ? 0 : 1)) } }
                    }
                    Item {
                        width: 46; height: 46
                        Rectangle { anchors.fill: parent; radius: 23; color: npPrevMa.containsMouse ? root.rgba(th.accent, 0.14) : root.rgba("#ffffff", 0.06); border.width: 1; border.color: root.rgba("#ffffff", 0.18); Behavior on color { ColorAnimation { duration: 150 } } }
                        NavIcon { anchors.centerIn: parent; width: 18; height: 18; kind: "prev"; col: "" + th.text }
                        MouseArea { id: npPrevMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/prev") } }
                    }
                    Item {
                        width: 66; height: 66
                        Rectangle {
                            anchors.centerIn: parent
                            width: 72; height: 72; radius: 36
                            color: root.rgba(th.accent, 0.2)
                            scale: root.s.playing ? 1 + root.bassLevel * 0.12 : 0.9
                            opacity: root.s.playing ? 0.6 : 0.12
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 33
                            gradient: Gradient {
                                orientation: Gradient.Vertical
                                GradientStop { position: 0; color: root.mixColor(th.accent, "#ffffff", 0.18) }
                                GradientStop { position: 1; color: root.accent2() }
                            }
                            scale: npPlayMa.pressed ? 0.92 : (npPlayMa.containsMouse ? 1.04 : 1)
                            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                            NavIcon { anchors.centerIn: parent; width: 26; height: 26; kind: root.s.playing ? "pause" : "play"; col: tc.light ? "#ffffff" : "#04121f" }
                        }
                        MouseArea { id: npPlayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/toggle") } }
                    }
                    Item {
                        width: 46; height: 46
                        Rectangle { anchors.fill: parent; radius: 23; color: npNextMa.containsMouse ? root.rgba(th.accent, 0.14) : root.rgba("#ffffff", 0.06); border.width: 1; border.color: root.rgba("#ffffff", 0.18); Behavior on color { ColorAnimation { duration: 150 } } }
                        NavIcon { anchors.centerIn: parent; width: 18; height: 18; kind: "next"; col: "" + th.text }
                        MouseArea { id: npNextMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/next") } }
                    }
                    Item {
                        width: 38; height: 38
                        NavIcon { anchors.centerIn: parent; width: 17; height: 17; kind: "repeat"; col: root.s.repeat > 0 ? th.accent : root.rgba(th.dim, 0.8); opacity: root.s.repeat > 0 ? 1 : 0.7 }
                        Text { visible: root.s.repeat === 2; text: "1"; color: th.accent; font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; x: 25; y: 4 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/repeat?r=" + ((root.s.repeat + 1) % 3)) } }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "click outside or press esc to return"
                    color: root.rgba(th.dim, 0.42)
                    font.family: root.tf; font.pixelSize: (8) * root.ts
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }

    // ---------------- theme world: full immersion in the 3D room ----------------
    Item {
        id: themeWorld
        z: 58
        anchors.fill: parent
        visible: worldSlide > 0.002
        property real worldSlide: 0
        opacity: worldSlide
        Behavior on worldSlide { NumberAnimation { duration: 620; easing.type: Easing.OutCubic } }
        Connections {
            target: root
            function onThemeWorldOpenChanged() { themeWorld.worldSlide = root.themeWorldOpen ? 1 : 0; }
        }

        function step(dir) {
            if (root.themeCards.length === 0) return;
            var at = -1;
            for (var i = 0; i < root.themeCards.length; i++) {
                if (root.themeCards[i].name === root.tc.name) at = i;
            }
            if (at < 0) at = 0;
            var n = (at + dir + root.themeCards.length) % root.themeCards.length;
            root.setTheme(root.themeCards[n].id, root.themeCards[n].name);
            root.exciteWorld();
        }

        Rectangle {
            anchors.fill: parent
            color: root.rgba(th.bg, 0.10 * themeWorld.worldSlide)
        }
        Rectangle {
            anchors.fill: parent
            opacity: themeWorld.worldSlide
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(th.bg, 0.34) }
                GradientStop { position: 0.34; color: root.rgba(th.bg, 0.02) }
                GradientStop { position: 0.72; color: root.rgba(th.bg, 0.08) }
                GradientStop { position: 1; color: root.rgba(th.bg, 0.70) }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            property real lx: 0
            property real ly: 0
            property bool moved: false
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: { lx = mouse.x; ly = mouse.y; moved = false; }
            onPositionChanged: {
                if (!pressed) return;
                var dx = mouse.x - lx, dy = mouse.y - ly;
                if (Math.abs(dx) + Math.abs(dy) > 1.5) moved = true;
                lx = mouse.x; ly = mouse.y;
                root.orbitWorld(-dx * 0.8, dy * 0.8);
            }
            onReleased: if (!moved) root.exciteWorld()
            onWheel: function(w) { root.zoomWorld(w.angleDelta.y > 0 ? -0.05 : 0.05); }
            onDoubleClicked: root.resetWorld()
        }

        // top line: where you are, not a window frame
        Row {
            x: 34; y: 26
            spacing: 12
            Rectangle { width: 5; height: 5; radius: 2.5; color: th.accent; anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: "THEME WORLD"
                color: root.rgba(th.accent, 0.88)
                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2.4
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: (root.tc.name || "").toUpperCase()
                color: root.rgba(th.text, 0.85)
                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.6
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 32
            y: 26
            spacing: 16
            Text {
                text: "DRAG  ·  SCROLL  ·  CLICK"
                color: root.rgba(th.dim, 0.55); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.5
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                id: twClose
                text: "LEAVE  \u00b7  ESC"
                color: twCloseMa.containsMouse ? th.accent : root.rgba(th.text, 0.7)
                font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4
                anchors.verticalCenter: parent.verticalCenter
                MouseArea {
                    id: twCloseMa
                    anchors.fill: parent; anchors.margins: -10
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.leaveThemeWorld() }
                }
            }
        }

        // bottom: the world speaks quietly
        Column {
            x: 34
            anchors.bottom: parent.bottom; anchors.bottomMargin: 30
            width: Math.min(560, parent.width - 300)
            spacing: 8
            Text {
                text: (root.tc.tag || "WORLD").toUpperCase() + "  ·  " + root.materialFor().toUpperCase()
                color: root.rgba(th.accent, 0.9)
                font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
            }
            Text {
                width: parent.width
                text: root.tc.name || "Frutiger"
                color: th.text
                font.family: root.tf; font.pixelSize: (46) * root.ts; font.bold: true; font.letterSpacing: -1.2
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.tc.mood || root.tc.line || ""
                color: root.rgba(th.text, 0.72); font.family: root.tf; font.pixelSize: (12) * root.ts; font.italic: true
                elide: Text.ElideRight
            }
            Row {
                spacing: 5
                Repeater {
                    model: root.tc.palette || [root.tc.bg, root.tc.panel, root.tc.accent, root.accent2(), root.tc.bar]
                    delegate: Rectangle {
                        width: 42; height: 3; radius: 1.5
                        color: modelData
                        opacity: index === 0 ? 0.5 : 0.95
                    }
                }
            }
        }

        // world stepping: two quiet arrows, one hairline between
        Row {
            anchors.right: parent.right; anchors.rightMargin: 40
            anchors.bottom: parent.bottom; anchors.bottomMargin: 34
            spacing: 18
            Text {
                text: "\u2190"
                color: twPrevMa.containsMouse ? th.accent : root.rgba(th.text, 0.55)
                font.family: root.tf; font.pixelSize: (24) * root.ts
                MouseArea {
                    id: twPrevMa
                    anchors.fill: parent; anchors.margins: -12
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); themeWorld.step(-1) }
                }
            }
            Rectangle { width: 1; height: 22; color: root.rgba(th.text, 0.16); anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: "\u2192"
                color: twNextMa.containsMouse ? th.accent : root.rgba(th.text, 0.55)
                font.family: root.tf; font.pixelSize: (24) * root.ts
                MouseArea {
                    id: twNextMa
                    anchors.fill: parent; anchors.margins: -12
                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); themeWorld.step(1) }
                }
            }
        }
    }

    // ---------------- add music sheet ----------------
    Item {
        id: addSheet
        z: 56
        anchors.fill: parent
        visible: addSlide > 0.002
        property real addSlide: 0
        property int tab: 0
        function open() {
            addAnim.duration = 440; addAnim.easing.type = Easing.OutQuint;
            addAnim.to = 1;
            addAnim.restart();
            root.refreshAddState();
            Qt.callLater(function() { if (addSearch) addSearch.forceActiveFocus(); });
        }
        function openNew() {
            open();
            Qt.callLater(function() { if (newNameField) newNameField.forceActiveFocus(); });
        }
        function close() {
            addAnim.duration = 240; addAnim.easing.type = Easing.InCubic;
            addAnim.to = 0;
            addAnim.restart();
            Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus(); });
        }
        NumberAnimation {
            id: addAnim
            target: addSheet
            property: "addSlide"
            duration: 380
            easing.type: Easing.OutCubic
        }

        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.66 * addSheet.addSlide)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); addSheet.close() } }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 60, 700)
            height: Math.min(parent.height - 50, 580)
            radius: 26
            color: "transparent"
            opacity: addSheet.addSlide
            scale: 0.96 + 0.04 * addSheet.addSlide
            transform: Translate { y: (1 - addSheet.addSlide) * 28 }

            MultiEffect {
                anchors.fill: parent
                source: glassCapture
                blurEnabled: true
                blur: 1.0
                blurMax: 44
                saturation: 1.15
            }
            Rectangle {
                anchors.fill: parent
                radius: 26
                color: root.rgba(th.bg, 0.94)
                border.width: 1
                border.color: root.rgba("#ffffff", tc.light ? 0.45 : 0.15)
            }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                height: 1; radius: 1; color: root.rgba("#ffffff", 0.32)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text { text: "ADD MUSIC"; color: th.text; font.family: root.tf; font.pixelSize: (20) * root.ts; font.bold: true; font.letterSpacing: 0.4 }
                    Rectangle {
                        height: 20; width: addPlName.width + 16; radius: 10
                        color: root.rgba(th.accent, 0.12)
                        border.width: 1; border.color: root.rgba(th.accent, 0.3)
                        Text { id: addPlName; anchors.centerIn: parent; text: root.readable(root.lib.playlist_name); color: root.rgba(th.accent, 0.9); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.ytAddState.running
                        Layout.maximumWidth: 320
                        text: {
                            var nm = (root.ytAddState.current_title || "").length > 0
                                     ? root.ytAddState.current_title : root.ytAddState.current;
                            if (nm.length > 46) nm = nm.substring(0, 46) + "…";
                            var q = (root.ytAddState.queued || 0) > 0 ? ("  +" + root.ytAddState.queued) : "";
                            return "PULLING AUDIO  ·  " + nm + q;
                        }
                        elide: Text.ElideRight
                        color: th.accent; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1
                    }
                    Rectangle {
                        width: 30; height: 30; radius: 15
                        color: closeAddMa.containsMouse ? root.rgba(th.accent, 0.18) : root.rgba("#ffffff", 0.07)
                        border.width: 1; border.color: root.rgba("#ffffff", 0.16)
                        Text { anchors.centerIn: parent; text: "✕"; color: th.text; font.family: root.tf; font.pixelSize: (11) * root.ts }
                        MouseArea { id: closeAddMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); addSheet.close() } }
                    }
                }

                // new playlist
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 7
                    Rectangle {
                        Layout.fillWidth: true
                        height: 32; radius: 16
                        color: tc.light ? "#10000000" : "#0cffffff"
                        border.width: 1; border.color: newNameField.activeFocus ? root.rgba(th.accent, 0.55) : root.rgba("#ffffff", 0.14)
                        TextField {
                            Keys.onPressed: function(ev) {
                                if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                    root.typeKey();
                            }
                            id: newNameField
                            anchors.fill: parent
                            anchors.leftMargin: 13; anchors.rightMargin: 13
                            placeholderText: "start a new playlist — name it, then create"
                            color: th.text
                            placeholderTextColor: root.rgba(th.dim, 0.55)
                            font.family: root.tf; font.pixelSize: (10) * root.ts
                            selectByMouse: true
                            background: Item { }
                            onAccepted: { root.createPlaylist(text); text = ""; }
                        }
                    }
                    GlowButton { label: "CREATE PLAYLIST"; bh: 32; glow: th.bar; onClicked: { root.createPlaylist(newNameField.text); newNameField.text = ""; } }
                }

                // search + tabs
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        height: 36; radius: 18
                        color: tc.light ? "#14000000" : "#10ffffff"
                        border.width: 1; border.color: addSearch.activeFocus ? root.rgba(th.accent, 0.6) : root.rgba("#ffffff", 0.16)
                        NavIcon { x: 13; width: 13; height: 13; anchors.verticalCenter: parent.verticalCenter; kind: "search"; col: root.rgba(th.dim, 0.8) }
                        TextField {
                            Keys.onPressed: function(ev) {
                                if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                    root.typeKey();
                            }
                            id: addSearch
                            anchors.left: parent.left; anchors.leftMargin: 34
                            anchors.right: parent.right; anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            placeholderText: addSheet.tab === 0 ? "search youtube + soundcloud — song, artist, or a vibe" : "search your downloaded songs"
                            color: th.text
                            placeholderTextColor: root.rgba(th.dim, 0.55)
                            font.family: root.tf; font.pixelSize: (10) * root.ts
                            selectByMouse: true
                            background: Item { }
                            onTextChanged: if (addSheet.tab === 1) localFilter = text
                            onAccepted: { if (addSheet.tab === 0) root.searchYoutube(text); }
                            Keys.onEscapePressed: addSheet.close()
                        }
                    }
                    GlowButton {
                        label: addSheet.tab === 0 ? (root.ytSearching ? "SEARCHING" : "SEARCH") : "FILTER"
                        bh: 36
                        glow: th.accent
                        onClicked: { if (addSheet.tab === 0) root.searchYoutube(addSearch.text); else localFilter = addSearch.text; }
                    }
                    Rectangle {
                        width: ytTab.width + 18; height: 36; radius: 18
                        color: addSheet.tab === 0 ? root.rgba(th.accent, 0.16) : root.rgba("#ffffff", 0.05)
                        border.width: 1; border.color: addSheet.tab === 0 ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.14)
                        Text { id: ytTab; anchors.centerIn: parent; text: "YOUTUBE"; color: addSheet.tab === 0 ? th.accent : root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); addSheet.tab = 0; } }
                    }
                    Rectangle {
                        width: localTab.width + 18; height: 36; radius: 18
                        color: addSheet.tab === 1 ? root.rgba(th.accent, 0.16) : root.rgba("#ffffff", 0.05)
                        border.width: 1; border.color: addSheet.tab === 1 ? root.rgba(th.accent, 0.45) : root.rgba("#ffffff", 0.14)
                        Text { id: localTab; anchors.centerIn: parent; text: "LOCAL"; color: addSheet.tab === 1 ? th.accent : root.rgba(th.dim, 0.85); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); addSheet.tab = 1; } }
                    }
                }

                // paste link
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.fillWidth: true
                        height: 32; radius: 16
                        color: tc.light ? "#0c000000" : "#08ffffff"
                        border.width: 1; border.color: addLinkField.activeFocus ? root.rgba(th.accent, 0.5) : root.rgba("#ffffff", 0.12)
                        TextField {
                            Keys.onPressed: function(ev) {
                                if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                                    root.typeKey();
                            }
                            id: addLinkField
                            anchors.fill: parent
                            anchors.leftMargin: 13; anchors.rightMargin: 13
                            placeholderText: "or paste a youtube / soundcloud link, a spotify track, or a local audio path"
                            color: th.text
                            placeholderTextColor: root.rgba(th.dim, 0.5)
                            font.family: root.tf; font.pixelSize: (9) * root.ts
                            selectByMouse: true
                            background: Item { }
                            onAccepted: { root.addLink(text); text = ""; }
                            Keys.onEscapePressed: addSheet.close()
                        }
                    }
                    GlowButton { label: "ADD LINK"; bh: 32; glow: th.accent; onClicked: { root.addLink(addLinkField.text); addLinkField.text = ""; } }
                }

                // stream or keep: the difference is disk and delay, not quality
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        text: "ADD AS"
                        color: root.rgba(th.dim, 0.55)
                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                    }
                    Repeater {
                        model: [ { k: "stream", l: "STREAM" }, { k: "file", l: "SAVE OFFLINE" } ]
                        delegate: AChip {
                            label: modelData.l
                            sel: root.addMode === modelData.k
                            glow: th.accent
                            onClicked: root.setAddMode(modelData.k)
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.addMode === "stream"
                              ? "plays from the page - no download, no disk cost"
                              : "downloads once, then plays with no network"
                        color: root.rgba(th.dim, 0.45)
                        font.family: root.tf; font.pixelSize: (8) * root.ts
                        elide: Text.ElideRight
                        Layout.maximumWidth: 300
                    }
                }

                Item { height: 3 }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: addList.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: GlassScroll { }

                    ColumnLayout {
                        id: addList
                        width: parent.width
                        spacing: 3

                        // youtube results
                        Repeater {
                            model: addSheet.tab === 0 ? root.ytResults : root.localAddRows()
                            delegate: Rectangle {
                                Layout.fillWidth: true
                                height: 52
                                radius: 12
                                color: addRowMa.containsMouse ? (tc.light ? "#12000000" : "#0fffffff") : "transparent"
                                Behavior on color { ColorAnimation { duration: 120 } }
                                // the row surface sits UNDER the content: declared
                                // after it, it swallowed every "+" press and the
                                // sheet looked like it simply did nothing
                                MouseArea { id: addRowMa; anchors.fill: parent; hoverEnabled: true }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6; anchors.rightMargin: 8
                                    spacing: 10
                                    Art {
                                        width: 40; height: 40; corner: 9
                                        Layout.alignment: Qt.AlignVCenter
                                        seed: index + 3
                                        source: addSheet.tab === 0 ? (modelData.thumb || "") : (modelData.cover || "")
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.title
                                            color: th.text; font.family: root.tf; font.pixelSize: (11) * root.ts
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: (modelData.artist || "") + (addSheet.tab === 0
                                                  ? ("  ·  " + root.fmt(modelData.duration_ms || 0)
                                                     + "  ·  " + ("" + (modelData.source || "youtube")).toUpperCase())
                                                  : ("  ·  local"))
                                            color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (9) * root.ts
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Item {
                                        // the press answers in the same frame: the
                                        // download itself runs on the worker thread
                                        id: addBtn
                                        readonly property string st: addSheet.tab === 0 ? root.ytState(modelData.url || "") : ""
                                        readonly property bool busy: st === "queued"
                                        width: 30; height: 30
                                        Rectangle {
                                            anchors.fill: parent; radius: 15
                                            color: addBtn.busy ? root.rgba(th.accent, 0.24)
                                                 : (addBtn.st === "done" ? root.rgba(th.accent, 0.9)
                                                    : (addBtnMa.containsMouse ? th.accent : (tc.light ? "#16000000" : "#0effffff")))
                                            border.width: 1
                                            border.color: addBtn.busy || addBtn.st === "done" ? root.rgba(th.accent, 0.9)
                                                        : (addBtnMa.containsMouse ? th.accent : root.rgba("#ffffff", 0.18))
                                            scale: addBtnMa.pressed ? 0.88 : (addBtn.busy ? 0.96 : 1)
                                            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
                                            Behavior on color { ColorAnimation { duration: 160 } }
                                            Text {
                                                anchors.centerIn: parent
                                                text: addBtn.busy ? "···" : (addBtn.st === "done" ? "\u2713" : "+")
                                                color: addBtn.st === "done" ? root.rgba(th.bg, 1)
                                                     : (addBtnMa.containsMouse && !addBtn.busy ? root.rgba(th.bg, 1) : th.accent)
                                                font.family: root.tf; font.pixelSize: (addBtn.busy ? 13 : 16) * root.ts; font.bold: true
                                            }
                                            // a quiet halo while the worker owns this row
                                            Rectangle {
                                                anchors.centerIn: parent
                                                width: parent.width; height: parent.height; radius: width / 2
                                                color: "transparent"
                                                border.width: 1; border.color: root.rgba(th.accent, 0.5)
                                                visible: addBtn.busy
                                                scale: 1
                                                SequentialAnimation on scale {
                                                    running: addBtn.busy
                                                    loops: Animation.Infinite
                                                    NumberAnimation { from: 1.0; to: 1.5; duration: 900; easing.type: Easing.OutCubic }
                                                    NumberAnimation { from: 1.5; to: 1.0; duration: 0 }
                                                }
                                                SequentialAnimation on opacity {
                                                    running: addBtn.busy
                                                    loops: Animation.Infinite
                                                    NumberAnimation { from: 0.7; to: 0; duration: 900; easing.type: Easing.OutCubic }
                                                    NumberAnimation { from: 0; to: 0.7; duration: 0 }
                                                }
                                            }
                                        }
                                        MouseArea {
                                            id: addBtnMa
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.playTap();
                                                if (addSheet.tab === 0) {
                                                    root.addYoutube(modelData.url);
                                                } else {
                                                    var path = modelData.path || "";
                                                    root.fetchJson("/playlist/add_local?path=" + encodeURIComponent(path), function(r) {
                                                        syncToast.show(r.ok ? ("added to " + root.lib.playlist_name) : (r.error || "add failed"));
                                                        if (r.ok) root.lastLibVer = -1;
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            visible: (addSheet.tab === 0 ? root.ytResults.length : root.localAddRows().length) === 0
                            Layout.fillWidth: true
                            spacing: 8
                            Item { height: 26 }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: addSheet.tab === 0 ? (root.ytSearching ? "searching youtube…" : "search youtube, then press + to keep the song") : "every downloaded file lives here"
                                color: root.rgba(th.dim, 0.7); font.family: root.tf; font.pixelSize: (11) * root.ts
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                visible: root.ytAddState.running
                                text: "downloading  ·  " + ((root.ytAddState.current_title || "").length > 0 ? root.ytAddState.current_title : root.ytAddState.current)
                                      + ((root.ytAddState.queued || 0) > 0 ? ("   (+" + root.ytAddState.queued + " queued)") : "")
                                color: th.accent; font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true
                                elide: Text.ElideRight
                                width: Math.min(parent.width, 360)
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: root.ytAddState.last_error.length > 0 ? ("last error: " + root.ytAddState.last_error) : (root.ytAddState.last_title.length > 0 ? ("last added: " + root.ytAddState.last_title) : "youtube songs are downloaded once, tagged, then stay in your library forever")
                        color: root.ytAddState.last_error.length > 0 ? root.rgba("#ff8a8a", 0.9) : root.rgba(th.dim, 0.6)
                        font.family: root.tf; font.pixelSize: (8) * root.ts
                        elide: Text.ElideRight
                    }
                    Text { text: root.playlistRows.length + " PLAYLISTS"; color: root.rgba(th.dim, 0.45); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1 }
                }
            }
        }
    }


    // volume HUD: a quiet number in the air, gone as soon as the hand moves on
    Item {
        id: volHudBox
        z: 40
        width: 172; height: 42
        anchors.right: bar.right
        anchors.rightMargin: 26
        anchors.bottom: bar.top
        anchors.bottomMargin: 14
        opacity: root.volHudOn ? 1 : 0
        visible: opacity > 0.005
        enabled: false
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        transform: Translate { y: (root.volHudOn ? 0 : 10) }
        Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

        Rectangle {
            anchors.fill: parent
            radius: 21
            color: root.rgba(th.bg, 0.78)
            border.width: 1
            border.color: root.rgba("#ffffff", 0.16)
        }
        Row {
            anchors.fill: parent
            anchors.leftMargin: 14; anchors.rightMargin: 14
            spacing: 9
            Item {
                width: 16; height: 16
                anchors.verticalCenter: parent.verticalCenter
                NavIcon { anchors.centerIn: parent; width: 15; height: 15; kind: "volume"; col: root.volShown > 0 ? th.accent : root.rgba(th.dim, 0.7) }
            }
            Item {
                width: parent.width - 62; height: 6
                anchors.verticalCenter: parent.verticalCenter
                Rectangle { anchors.fill: parent; radius: 3; color: root.rgba(th.text, 0.14) }
                Rectangle {
                    width: parent.width * (root.volShown / 100)
                    height: parent.height; radius: 3
                    color: th.accent
                    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                text: root.volShown
                color: root.rgba(th.text, 0.92)
                font.pixelSize: (10) * root.ts; font.bold: true; font.family: "Consolas"
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ---------------- liquid glass dock ----------------
    Rectangle {
        id: bar
        z: 6
        height: 94
        opacity: root.themeWorldOpen ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        anchors.left: parent.left; anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 0; anchors.rightMargin: 0
        anchors.bottomMargin: 0
        radius: 0
        color: "transparent"
        // entering/leaving the app carries the dock with it
        transform: Translate { y: (1 - root.uiIn) * 26 }

        // no pane, no edge, no rule: the dock is simply the bottom of the room.
        // A single breath of the background rises from the window edge and
        // reaches zero alpha before it can draw a line anywhere.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: root.rgba(th.bg, 0) }
                GradientStop { position: 0.42; color: root.rgba(th.bg, tc.light ? 0.06 : 0.09) }
                GradientStop { position: 0.78; color: root.rgba(th.bg, tc.light ? 0.14 : 0.20) }
                GradientStop { position: 1; color: root.rgba(th.bg, tc.light ? 0.24 : 0.32) }
            }
        }

        // the track thread is a quiet floor inside the dock, not a line across
        // the window. it only becomes bright under the hand.
        ScrubBar {
            id: dockSeek
            anchors.bottom: parent.bottom; anchors.bottomMargin: 9
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 30; anchors.rightMargin: 30
            height: 7
            thickness: 1.5
            value: root.posMs
            max: Math.max(1, root.s.duration_ms)
            // never a rule across the window: the thread appears under the hand
            opacity: dockSeekHover.hovered ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            HoverHandler { id: dockSeekHover }
            onSeek: function(p) { root.seekTo(p * root.s.duration_ms); }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: function(w) {
                var v = root.s.volume + (w.angleDelta.y > 0 ? 4 : -4);
                root.setVolume(v);
            }
        }

        // ---------------- left: the song in your hand ----------------
        Item {
            id: dockNow
            anchors.left: parent.left; anchors.leftMargin: 18
            anchors.top: parent.top; anchors.topMargin: 24
            anchors.bottom: parent.bottom; anchors.bottomMargin: 10
            width: Math.min(300, parent.width * 0.28)

            // (the accent plate that used to sit behind this cover is gone: the
            // dock thumbnail now floats on the dock's own breath)
            Art {
                id: dockArt
                width: 50; height: 50
                corner: 13
                seed: root.s.track_id === null ? 0 : root.s.track_id
                source: root.s.cover_url && root.s.cover_url.length > 4 ? root.s.cover_url : ""
                anchors.verticalCenter: parent.verticalCenter
                scale: dockArtMa.pressed ? 0.94 : (dockArtMa.containsMouse ? 1.045 : 1)
                Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
            }
            MouseArea {
                id: dockArtMa
                anchors.fill: dockArt
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.playTap(); np.open() }
            }
            Column {
                anchors.left: dockArt.right; anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                spacing: 3
                Text {
                    width: parent.width
                    text: root.s.title.length > 0 ? root.s.title : "nothing playing"
                    color: th.text
                    font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.s.artist.length > 0 ? root.s.artist : "pick a track"
                    color: root.rgba(th.dim, 0.95)
                    font.family: root.tf; font.pixelSize: (10) * root.ts
                    elide: Text.ElideRight
                }
                Row {
                    spacing: 5
                    Rectangle {
                        width: 5; height: 5; radius: 2.5
                        color: root.s.playing ? th.accent : th.dim
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: root.s.playing ? "PLAYING" : "PAUSED"
                        color: root.rgba(th.dim, 0.8)
                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        visible: root.s.origin && root.s.origin.length > 0
                        text: "· " + (root.s.origin || "").toUpperCase()
                        color: root.rgba(th.accent, 0.8)
                        font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        // ---------------- center: transport jewel ----------------
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 7
            spacing: 11

            Item {
                width: 30; height: 30
                anchors.verticalCenter: parent.verticalCenter
                scale: dockShufMa.pressed ? 0.86 : (dockShufMa.containsMouse ? 1.10 : 1)
                Behavior on scale { NumberAnimation { duration: dockShufMa.pressed ? 90 : 240; easing.type: Easing.OutBack } }
                NavIcon {
                    anchors.centerIn: parent
                    width: 17; height: 17; kind: "shuffle"
                    col: root.s.shuffle ? th.accent : root.rgba(th.dim, 0.85)
                    opacity: root.s.shuffle ? 1 : (dockShufMa.containsMouse ? 1 : 0.75)
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                }
                Rectangle {
                    visible: root.s.shuffle
                    anchors.bottom: parent.bottom; anchors.bottomMargin: -2
                    width: 10; height: 2; radius: 1; anchors.horizontalCenter: parent.horizontalCenter
                    color: th.accent; opacity: 0.8
                }
                MouseArea {
                    id: dockShufMa
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.hit("/shuffle?s=" + (root.s.shuffle ? 0 : 1)) }
                }
            }
            Item {
                width: 34; height: 34
                anchors.verticalCenter: parent.verticalCenter
                scale: dockPrevMa.pressed ? 0.86 : (dockPrevMa.containsMouse ? 1.12 : 1)
                Behavior on scale { NumberAnimation { duration: dockPrevMa.pressed ? 90 : 240; easing.type: Easing.OutBack } }
                NavIcon { anchors.centerIn: parent; width: 19; height: 19; kind: "prev"; col: dockPrevMa.containsMouse ? th.accent : th.text }
                MouseArea { id: dockPrevMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/prev") } }
            }            Item {
                width: 52; height: 52
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.centerIn: parent
                    width: 52; height: 52; radius: 26
                    color: root.rgba(th.accent, 0.16)
                    scale: root.s.playing ? 1 + root.bassLevel * 0.12 : 0.9
                    opacity: root.s.playing ? 0.7 : 0.15
                    Behavior on scale { NumberAnimation { duration: 130 } }
                }
                // the song's own clock, drawn around the jewel
                Canvas {
                    id: dockRing
                    anchors.centerIn: parent
                    width: 70; height: 70
                    opacity: dockPlayMa.containsMouse ? 1 : 0.7
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.reset();
                        var c = 35, r = 31.5;
                        ctx.lineCap = "round";
                        ctx.strokeStyle = root.rgba(th.text, tc.light ? 0.16 : 0.12);
                        ctx.lineWidth = 1.6;
                        ctx.beginPath(); ctx.arc(c, c, r, 0, Math.PI * 2); ctx.stroke();
                        var p = root.s.duration_ms > 0 ? Math.max(0, Math.min(1, root.posMs / root.s.duration_ms)) : 0;
                        if (p > 0.001) {
                            ctx.strokeStyle = root.rgba(root.accent2(), 0.95);
                            ctx.lineWidth = 1.6;
                            ctx.beginPath(); ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p); ctx.stroke();
                        }
                    }
                    Timer { interval: 240; running: root.s.playing; repeat: true; onTriggered: dockRing.requestPaint() }
                }
                Rectangle {
                    id: dockPlay
                    anchors.fill: parent
                    radius: 26
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: root.mixColor(th.accent, "#ffffff", 0.16) }
                        GradientStop { position: 1; color: root.accent2() }
                    }
                    scale: dockPlayMa.pressed ? 0.9 : (dockPlayMa.containsMouse ? 1.045 : 1)
                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
                    NavIcon {
                        anchors.centerIn: parent
                        width: 21; height: 21
                        kind: root.s.playing ? "pause" : "play"
                        col: tc.light ? "#ffffff" : "#04121f"
                    }
                    Rectangle {
                        anchors.fill: parent; radius: 26
                        color: "transparent"
                        border.width: 1; border.color: root.rgba("#ffffff", 0.35)
                    }
                }
                MouseArea { id: dockPlayMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/toggle") } }
            }
            Item {
                width: 34; height: 34
                anchors.verticalCenter: parent.verticalCenter
                scale: dockNextMa.pressed ? 0.86 : (dockNextMa.containsMouse ? 1.12 : 1)
                Behavior on scale { NumberAnimation { duration: dockNextMa.pressed ? 90 : 240; easing.type: Easing.OutBack } }
                NavIcon { anchors.centerIn: parent; width: 19; height: 19; kind: "next"; col: dockNextMa.containsMouse ? th.accent : th.text }
                MouseArea { id: dockNextMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.hit("/next") } }
            }
            Item {
                width: 30; height: 30
                anchors.verticalCenter: parent.verticalCenter
                NavIcon {
                    anchors.centerIn: parent
                    width: 17; height: 17; kind: "repeat"
                    col: root.s.repeat > 0 ? th.accent : root.rgba(th.dim, 0.85)
                    opacity: root.s.repeat > 0 ? 1 : 0.75
                }
                Text {
                    visible: root.s.repeat === 2
                    text: "1"
                    color: th.accent
                    font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true
                    x: parent.width / 2 + 5; y: 3
                }
                MouseArea {
                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.playTap(); root.hit("/repeat?r=" + ((root.s.repeat + 1) % 3)) }
                }
            }
        }

        // ---------------- right: time, air, spectrum ----------------
        Row {
            anchors.right: parent.right; anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 7
            spacing: 12

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text {
                    text: root.fmt(root.posMs)
                    color: root.rgba(th.text, 0.9)
                    font.pixelSize: (9) * root.ts; font.family: "Consolas"
                    anchors.right: parent.right
                }
                Text {
                    text: "-" + root.fmt(Math.max(0, root.s.duration_ms - root.posMs))
                    color: root.rgba(th.dim, 0.8)
                    font.pixelSize: (8) * root.ts; font.family: "Consolas"
                    anchors.right: parent.right
                }
            }
            Rectangle {
                width: 1; height: 26; radius: 1
                color: tc.light ? "#22000000" : "#1effffff"
                anchors.verticalCenter: parent.verticalCenter
            }
            Row {
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                NavIcon {
                    width: 15; height: 15; kind: "volume"
                    col: root.rgba(th.dim, 0.9)
                    anchors.verticalCenter: parent.verticalCenter
                }
                ScrubBar {
                    width: 74
                    height: 20
                    thickness: 3.5
                    value: root.s.volume
                    max: 100
                    col: th.dim
                    col2: th.accent
                    anchors.verticalCenter: parent.verticalCenter
                    onSeek: function(p) { root.setVolume(p * 100); }
                }
            }
            Rectangle {
                width: 1; height: 26; radius: 1
                color: tc.light ? "#22000000" : "#1effffff"
                anchors.verticalCenter: parent.verticalCenter
                visible: root.width > 1180
            }
            Canvas {
                id: miniViz
                width: 70; height: 26
                visible: root.width > 1180
                anchors.verticalCenter: parent.verticalCenter
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    var levels = root.smoothLevels;
                    var peaks = root.smoothPeaks;
                    var n = Math.min(20, levels.length);
                    if (n === 0) return;
                    var bw = width / n;
                    for (var i = 0; i < n; i++) {
                        var h = Math.max(1.5, levels[i] * height * 1.15);
                        var t = i / n;
                        // the chosen pair, or the two colours this little
                        // meter has always used when no choice has been made
                        var cA = root.eqAOn ? root.eqA : th.accent;
                        var cB = root.eqBOn ? root.eqB : root.accent2();
                        ctx.fillStyle = root.mixColor(cA, cB, t);
                        ctx.globalAlpha = 0.3 + levels[i] * 0.7;
                        ctx.fillRect(i * bw + 0.5, height - h, bw - 1.6, h);
                        var ph = Math.max(1.5, (peaks[i] || 0) * height * 1.15);
                        ctx.globalAlpha = 0.6;
                        ctx.fillRect(i * bw + 0.5, height - ph - 2, bw - 1.6, 1.3);
                    }
                ctx.globalAlpha = 1;
                }
            }
        }
    }


    // ---------------- track context menu ----------------
    // Right-click is where a player earns its keep: send the song next, to the
    // back of the queue, or straight into a different playlist without
    // switching the room you are standing in.
    Item {
        id: ctxMenu
        z: 110
        anchors.fill: parent
        visible: root.ctxOpenState
        enabled: root.ctxOpenState

        property real appear: root.ctxOpenState ? 1 : 0
        Behavior on appear { NumberAnimation { duration: root.ctxOpenState ? 180 : 130; easing.type: root.ctxOpenState ? Easing.OutQuint : Easing.InCubic } }

        MouseArea { anchors.fill: parent; onClicked: { root.playTap(); root.closeCtx() } }

        Rectangle {
            id: ctxPanel
            x: root.ctxX
            y: root.ctxY + (1 - ctxMenu.appear) * 8
            width: 216
            height: ctxCol.height + 18
            radius: 16
            color: "transparent"
            opacity: ctxMenu.appear
            scale: 0.96 + 0.04 * ctxMenu.appear

            GlassSurface {
                anchors.fill: parent
                corner: 16
                tintAlpha: tc.light ? 0.5 : 0.34
                blurAmt: 0.9
                blurMax: 30
                saturation: 1.05
                sheen: 0.05
                haloAmt: 0
                shadowAmt: 0.6
            }

            Column {
                id: ctxCol
                x: 0; y: 9
                width: parent.width

                Row {
                    x: 13; width: parent.width - 26
                    spacing: 9
                    Art {
                        width: 30; height: 30; corner: 8
                        seed: root.ctxTrack ? root.ctxTrack.id : 0
                        source: root.ctxTrack && root.ctxTrack.cover && ("" + root.ctxTrack.cover).length > 4 ? root.ctxTrack.cover : ""
                    }
                    Column {
                        width: parent.width - 40
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            width: parent.width
                            text: root.ctxTrack ? root.ctxTrack.title : ""
                            color: th.text; font.family: root.tf; font.pixelSize: (10) * root.ts; font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            width: parent.width
                            text: root.ctxTrack ? (root.ctxTrack.artist || "") : ""
                            color: root.rgba(th.dim, 0.8); font.family: root.tf; font.pixelSize: (8) * root.ts
                            elide: Text.ElideRight
                        }
                    }
                }

                Item { width: 1; height: 12 }

                // page 1: actions
                Column {
                    width: parent.width
                    visible: root.ctxMode === 0
                    Repeater {
                        model: root.ctxActions()
                        delegate: Rectangle {
                            width: ctxPanel.width
                            height: 30
                            color: cma.containsMouse ? root.rgba(th.accent, 0.14) : "transparent"
                            Behavior on color { ColorAnimation { duration: 110 } }
                            Row {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10
                                NavIcon {
                                    width: 13; height: 13; kind: modelData.mark
                                    anchors.verticalCenter: parent.verticalCenter
                                    col: cma.containsMouse ? th.accent : root.rgba(th.dim, 0.85)
                                }
                                Text {
                                    text: modelData.label
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: cma.containsMouse ? th.text : root.rgba(th.text, 0.82)
                                    font.family: root.tf; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                }
                            }
                            MouseArea {
                                id: cma
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap();
                                    var trk = root.ctxTrack;
                                    if (!trk) { root.closeCtx(); return; }
                                    var act = modelData.id;
                                    if (act === "play") {
                                        root.hit("/play?id=" + trk.id);
                                        toastNow("playing " + trk.title);
                                        root.closeCtx();
                                    } else if (act === "next") {
                                        root.hit("/queue/playnext?id=" + trk.id);
                                        toastNow("up next: " + trk.title);
                                        root.closeCtx();
                                    } else if (act === "queue") {
                                        root.hit("/queue/add?id=" + trk.id);
                                        toastNow("queued at the end");
                                        root.closeCtx();
                                    } else if (act === "addpl") {
                                        root.ctxMode = 1;
                                        root.loadPlaylists();
                                    } else if (act === "lyrics") {
                                        root.gotoPage(2);
                                        root.closeCtx();
                                    } else if (act === "like") {
                                        root.toggleLike(trk);
                                        root.closeCtx();
                                    } else if (act === "info") {
                                        root.showTrackInfo(trk);
                                        root.closeCtx();
                                    } else if (act === "save") {
                                        root.fetchJson("/track/save?id=" + trk.id, function(r) {
                                            syncToast.show(r && r.ok ? "saving - it plays offline when it lands" : "could not save that song");
                                        });
                                        root.closeCtx();
                                    } else if (act === "reveal") {
                                        root.fetchJson("/track/reveal?id=" + trk.id, function(r) {
                                            if (!r || !r.ok) syncToast.show("no file behind this row");
                                        });
                                        root.closeCtx();
                                    } else if (act === "remove") {
                                        root.removeTrackFromPlaylist(trk);
                                        root.closeCtx();
                                    } else {
                                        root.closeCtx();
                                    }
                                }
                            }
                        }
                    }
                }

                // page 2: which playlist
                Column {
                    width: parent.width
                    visible: root.ctxMode === 1
                    Item { width: 1; height: 2 }
                    Rectangle {
                        x: 12; width: parent.width - 24; height: 26; radius: 13
                        color: root.rgba(th.accent, 0.1)
                        Row {
                            x: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                            Text { text: "\u2039"; color: th.accent; font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true }
                            Text { text: "ADD TO WHICH PLAYLIST"; color: th.accent; font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.playTap(); root.ctxMode = 0 }
                        }
                    }
                    Item { width: 1; height: 4 }
                    Repeater {
                        model: root.playlistRows
                        delegate: Rectangle {
                            width: ctxPanel.width
                            height: 28
                            color: pma.containsMouse ? root.rgba(th.accent, 0.14) : "transparent"
                            Behavior on color { ColorAnimation { duration: 110 } }
                            Text {
                                x: 14
                                width: parent.width - 52
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name
                                color: modelData.active ? th.accent : root.rgba(th.text, 0.85)
                                font.family: root.tf; font.pixelSize: (9) * root.ts
                                elide: Text.ElideRight
                            }
                            Text {
                                anchors.right: parent.right; anchors.rightMargin: 13
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.total
                                color: root.rgba(th.dim, 0.6); font.family: root.tf; font.pixelSize: (8) * root.ts
                            }
                            MouseArea {
                                id: pma
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); root.ctxAppend(modelData.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------------- command palette ----------------
    // one keystroke for everything: songs, rooms, themes, transport. the
    // fastest surface in the app, so it gets the fastest motion.
    Item {
        id: palette
        z: 120
        anchors.fill: parent
        property real slideP: 0
        visible: slideP > 0.001
        enabled: root.palOpen

        Connections {
            target: root
            function onPalOpenChanged() {
                palette.slideP = root.palOpen ? 1 : 0;
                if (root.palOpen) {
                    root.palQ = "";
                    root.palSel = 0;
                    root.palRows = root.buildPalette();
                    palField.text = "";
                    palField.forceActiveFocus();
                }
            }
        }
        Behavior on slideP { NumberAnimation { duration: 240; easing.type: Easing.OutQuint } }

        Rectangle {
            anchors.fill: parent
            color: root.rgba(root.tc.bg, 0.42 * palette.slideP)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); root.closePalette() } }
        }

        Rectangle {
            id: palPanel
            width: Math.min(660, parent.width - 120)
            height: 468
            anchors.horizontalCenter: parent.horizontalCenter
            y: 88 + (1 - palette.slideP) * -16
            radius: 24
            color: "transparent"
            opacity: palette.slideP
            scale: 0.975 + palette.slideP * 0.025

            GlassSurface {
                anchors.fill: parent
                corner: 22
                tintAlpha: root.tc.light ? 0.55 : 0.62
                blurAmt: 0.62
                blurMax: 48
                saturation: 1.15
                sheen: 0.03
                haloAmt: 0.03
                shadowAmt: 0.6
            }
            Rectangle {
                anchors.fill: parent
                radius: 24
                color: root.rgba(th.bg, 0.86)
            }
            Rectangle {
                anchors.fill: parent
                radius: 24
                color: "transparent"
                border.width: 1
                border.color: root.rgba("#ffffff", 0.16)
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    NavIcon { width: 15; height: 15; kind: "search"; col: root.rgba(th.accent, 0.9) }
                    TextField {
                        id: palField
                        Layout.fillWidth: true
                        placeholderText: "search songs, rooms, themes, actions…"
                        color: th.text
                        placeholderTextColor: root.rgba(th.dim, 0.55)
                        font.family: root.tf; font.pixelSize: (17) * root.ts
                        selectByMouse: true
                        background: Item { }
                        onTextChanged: {
                            root.palQ = text;
                            root.palSel = 0;
                            root.palRows = root.buildPalette();
                        }
                        Keys.onPressed: function(ev) {
                            // every field has a keyboard: arrows and Enter stay
                            // silent, letters and space strike a key
                            if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                                    && ev.key !== Qt.Key_Down && ev.key !== Qt.Key_Up
                                    && ev.key !== Qt.Key_Return && ev.key !== Qt.Key_Enter
                                    && ev.key !== Qt.Key_Escape)
                                root.typeKey();
                            if (ev.key === Qt.Key_Down) {
                                root.palSel = Math.min(root.palRows.length - 1, root.palSel + 1);
                                ev.accepted = true;
                            } else if (ev.key === Qt.Key_Up) {
                                root.palSel = Math.max(0, root.palSel - 1);
                                ev.accepted = true;
                            } else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
                                if (root.palRows.length > 0) root.palRun(root.palRows[Math.max(0, Math.min(root.palSel, root.palRows.length - 1))]);
                                ev.accepted = true;
                            } else if (ev.key === Qt.Key_Escape) {
                                root.closePalette();
                                ev.accepted = true;
                            }
                        }
                    }
                    Rectangle {
                        width: 34; height: 22; radius: 11
                        color: root.rgba(th.accent, 0.14)
                        border.width: 1; border.color: root.rgba(th.accent, 0.4)
                        Text { anchors.centerIn: parent; text: "ESC"; color: th.accent; font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.closePalette() } }
                    }
                }

                Item { Layout.fillWidth: true; Layout.preferredHeight: 4 }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: palCol.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: GlassScroll { }

                    ColumnLayout {
                        id: palCol
                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: root.palRows
                            delegate: Rectangle {
                                Layout.fillWidth: true
                                height: 46
                                radius: 12
                                readonly property bool on: index === root.palSel
                                color: on ? root.rgba(th.accent, 0.14) : (palRowMa.containsMouse ? (tc.light ? "#10000000" : "#0affffff") : "transparent")
                                border.width: on ? 1 : 0
                                border.color: root.rgba(th.accent, 0.34)
                                Behavior on color { ColorAnimation { duration: 120 } }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    spacing: 12

                                    Rectangle {
                                        width: 44; height: 18; radius: 9
                                        color: root.rgba(modelData.kind === "track" ? th.accent2() : th.accent, on ? 0.22 : 0.1)
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData.kind === "track" ? "SONG" : (modelData.kind === "go" ? "ROOM" : (modelData.kind === "theme" ? "THEME" : "DO"))
                                            color: root.rgba(modelData.kind === "track" ? th.accent2() : th.accent, 0.95)
                                            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            color: on ? th.text : root.rgba(th.text, 0.86)
                                            font.family: root.tf; font.pixelSize: (12) * root.ts
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.sub
                                            color: root.rgba(th.dim, 0.7)
                                            font.family: root.tf; font.pixelSize: (9) * root.ts
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Text {
                                        visible: on
                                        text: "↵"
                                        color: th.accent
                                        font.family: root.tf; font.pixelSize: (13) * root.ts; font.bold: true
                                    }
                                }
                                MouseArea {
                                    id: palRowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: root.palSel = index
                                    onClicked: { root.playTap(); root.palRun(modelData) }
                                }
                            }
                        }

                        Text {
                            visible: root.palRows.length === 0
                            Layout.topMargin: 18
                            Layout.alignment: Qt.AlignHCenter
                            text: "nothing matches “" + root.palQ + "”"
                            color: root.rgba(th.dim, 0.6)
                            font.family: root.tf; font.pixelSize: (11) * root.ts
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 16
                    Text { text: "↑ ↓  MOVE"; color: root.rgba(th.dim, 0.5); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                    Text { text: "↵  OPEN"; color: root.rgba(th.dim, 0.5); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                    Text { text: "CTRL K  ANYWHERE"; color: root.rgba(th.accent, 0.65); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                    Item { Layout.fillWidth: true }
                    Text { text: root.palRows.length + " RESULTS"; color: root.rgba(th.dim, 0.45); font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                }
            }
        }
    }

    // ---------------- the shell's own entrance / exit ----------------
    // a curtain of the room's own colour: the app is never a rectangle that
    // pops into existence, it is a room whose lights come up.
    Item {
        id: curtain
        z: 900
        anchors.fill: parent
        visible: root.uiIn < 0.999
        opacity: 1 - root.uiIn
        enabled: false

        Rectangle {
            anchors.fill: parent
            color: root.rgba(root.tc.bg, 1)
        }
        // aperture: a ring of light opens as the room comes up
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height) * 0.62
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: root.rgba(root.tc.accent, 0.35 * (1 - root.uiIn))
            scale: 0.7 + root.uiIn * 0.5
            opacity: Math.max(0, 1 - root.uiIn * 1.6)
        }
        // the seam closes when the room goes dark
        Rectangle {
            anchors.centerIn: parent
            width: 1
            height: parent.height * Math.max(0, 1 - root.uiIn)
            opacity: Math.max(0, 1 - root.uiIn) * 0.65
            color: root.rgba(root.tc.accent, 0.8)
        }
        Rectangle {
            anchors.fill: parent
            opacity: 0.65
            gradient: Gradient {
                GradientStop { position: 0; color: root.rgba(root.tc.accent, 0.10) }
                GradientStop { position: 0.5; color: root.rgba(root.tc.bg, 0) }
                GradientStop { position: 1; color: root.rgba(root.tc.accent2 ? root.tc.accent2 : root.tc.bar, 0.12) }
            }
        }
        Column {
            anchors.centerIn: parent
            spacing: 14
            opacity: Math.max(0, Math.min(1, (1 - root.uiIn) * 1.7))
            scale: 0.94 + root.uiIn * 0.08
            Image {
                source: Qt.resolvedUrl("../assets/icon.png")
                anchors.horizontalCenter: parent.horizontalCenter
                width: 46; height: 46
                smooth: true; mipmap: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "AetherMix"
                color: root.rgba(root.tc.text, 0.92)
                font.family: root.tf; font.pixelSize: (17) * root.ts; font.bold: true; font.letterSpacing: 0.6
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 120; height: 1.5; radius: 1
                color: root.rgba(root.tc.accent, 0.30)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.uiIn * 1.25))
                    height: parent.height; radius: 1
                    color: root.rgba(root.tc.accent, 0.85)
                }
            }
        }
    }

    // ================= STUDIO: type, wallpaper, per-tab worlds, accounts =================
    // one surface for everything that changes the look. it floats over the real
    // room, so every slider is judged against the living interface, not a swatch.
    component ASlider : Item {
        id: sl
        property string label: ""
        property string suffix: ""
        property real value: 0
        property real min: 0
        property real max: 1
        property real step: 0.01
        property int decimals: 2
        property bool pct: false
        signal moved(real v)
        width: 200
        height: 40
        readonly property real frac: Math.max(0, Math.min(1, (value - min) / Math.max(0.00001, max - min)))
        function labelText() {
            if (sl.pct) return Math.round(sl.value * 100) + "%";
            var v = Math.round(sl.value * Math.pow(10, sl.decimals)) / Math.pow(10, sl.decimals);
            return "" + v + (sl.suffix.length > 0 ? " " + sl.suffix : "");
        }
        Text {
            text: sl.label.toUpperCase()
            color: root.rgba(th.dim, 0.75)
            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
        }
        Text {
            anchors.right: parent.right
            text: sl.labelText()
            color: root.rgba(th.text, 0.9)
            font.pixelSize: (9) * root.ts; font.bold: true; font.family: "Consolas"
        }
        Rectangle {
            x: 0; y: 24; width: parent.width; height: 3; radius: 1.5
            color: root.rgba(th.text, 0.13)
            Rectangle {
                width: parent.width * sl.frac; height: 3; radius: 1.5
                color: th.accent
            }
        }
        Rectangle {
            x: Math.max(0, Math.min(sl.width - 12, sl.width * sl.frac - 6))
            y: 18; width: 12; height: 12; radius: 6
            color: th.text
            border.width: 2; border.color: root.rgba(th.accent, slMa.containsMouse || slMa.pressed ? 1 : 0.55)
            scale: slMa.pressed ? 1.25 : (slMa.containsMouse ? 1.1 : 1)
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
        }
        MouseArea {
            id: slMa
            x: 0; y: 12; width: parent.width; height: 28
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            function apply(px) {
                var f = Math.max(0, Math.min(1, px / Math.max(1, sl.width)));
                var v = sl.min + f * (sl.max - sl.min);
                if (sl.step > 0) v = Math.round(v / sl.step) * sl.step;
                sl.moved(v);
            }
            onPressed: apply(mouse.x)
            onPositionChanged: if (pressed) apply(mouse.x)
        }
    }

    component ASwatch : Rectangle {
        id: sw
        property string col: "#ffffff"
        property bool sel: false
        width: 20; height: 20; radius: 10
        color: sw.col
        border.width: sel ? 2 : 1
        border.color: sel ? th.text : root.rgba("#ffffff", 0.22)
        scale: swMa.containsMouse ? 1.14 : 1
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
        Behavior on border.width { NumberAnimation { duration: 120 } }
        signal picked(string c)
        MouseArea {
            id: swMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.playTap(); sw.picked(sw.col) }
        }
    }

    component AField : Rectangle {
        id: af
        property alias text: afInput.text
        property alias input: afInput
        property string placeholder: ""
        signal accepted(string v)
        height: 34; radius: 17
        color: tc.light ? "#12000000" : "#0effffff"
        border.width: 1
        border.color: afInput.activeFocus ? root.rgba(th.accent, 0.7) : root.rgba("#ffffff", tc.light ? 0.18 : 0.15)
        implicitWidth: 180
        TextField {
            Keys.onPressed: function(ev) {
                if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
                    root.typeKey();
            }
            id: afInput
            anchors.fill: parent
            anchors.leftMargin: 13; anchors.rightMargin: 13
            placeholderText: af.placeholder
            color: th.text
            font.family: root.tf
            font.pixelSize: (10) * root.ts
            selectByMouse: true
            background: Item { }
            onAccepted: af.accepted(text)
        }
    }

    component AChip : Rectangle {
        id: ac
        property string label: ""
        property bool sel: false
        property color glow: th.accent
        // the repeater's index, copied onto the chip: `index` is a context
        // property and does not survive into a nested component's handler
        property int slot: -1
        // a chip whose job *is* a sound (the pack picker) plays that sound
        // itself: without this it struck the old voice and then went quiet
        property bool silent: false
        signal clicked()
        width: acText.width + 22; height: 26; radius: 13
        // no outline: the chip is a wash of the accent that deepens when it
        // is chosen or hovered, and the type inside it carries the weight
        color: ac.sel ? root.rgba(ac.glow, 0.26)
                      : (acMa.containsMouse ? root.rgba(ac.glow, 0.14)
                                            : root.rgba(th.text, 0.05))
        border.width: 0
        Behavior on color { ColorAnimation { duration: 140 } }
        Text {
            id: acText
            anchors.centerIn: parent
            text: ac.label
            color: ac.sel ? ac.glow : root.rgba(th.text, 0.78)
            font.family: root.tf; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.1
        }
        MouseArea {
            id: acMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { if (!ac.silent) root.playTap(); ac.clicked(); }
        }
    }

    // a soft switch: no hard track edges, the knob carries its own shadow
    component AToggle : Rectangle {
        id: tg
        property bool on: false
        signal toggled()
        width: 42; height: 22; radius: 11
        color: tg.on ? root.rgba(th.accent, 0.82) : root.rgba(th.text, 0.14)
        Behavior on color { ColorAnimation { duration: 180 } }
        Rectangle {
            x: tg.on ? tg.width - 18 : 2; y: 2; width: 18; height: 18; radius: 9
            color: root.rgba(tg.on ? th.bg : th.text, 0.92)
            scale: tgMa.pressed ? 1.16 : 1
            Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
        }
        MouseArea {
            id: tgMa
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.playTap(); tg.toggled(); }
        }
    }

    Item {
        id: studioPanel
        z: 94
        anchors.fill: parent
        visible: studioSlide > 0.002
        property real studioSlide: 0
        property bool closing: false
        function show() { closing = false; studioAnim.to = 1; studioAnim.restart(); }
        function hide() { closing = true; studioAnim.to = 0; studioAnim.restart(); }
        NumberAnimation {
            id: studioAnim
            target: studioPanel; property: "studioSlide"
            duration: studioPanel.closing ? 220 : 420
            easing.type: studioPanel.closing ? Easing.InCubic : Easing.OutQuint
        }
        opacity: studioSlide
        // the room dims but stays visible: every change is judged in place
        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.34 * studioPanel.studioSlide)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); root.closeStudio() } }
        }

        Rectangle {
            id: studioShell
            anchors.centerIn: parent
            width: Math.min(1120, root.width - 72)
            height: Math.min(724, root.height - 64)
            radius: 28
            color: "transparent"
            opacity: studioPanel.studioSlide
            scale: 0.965 + 0.035 * studioPanel.studioSlide
            transform: Translate { y: (1 - studioPanel.studioSlide) * 22 }

            GlassSurface {
                anchors.fill: parent
                corner: 28
                tintAlpha: 0.9
                blurAmt: 1.0
                blurMax: 84
                shadowAmt: 0.72
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 26
                spacing: 16

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14
                    ColumnLayout {
                        spacing: 2
                        Text {
                            text: "STUDIO"
                            color: th.text
                            font.pixelSize: (24) * root.ts; font.bold: true; font.letterSpacing: -0.2
                        }
                        Text {
                            text: "type, wallpaper and a different world for every tab"
                            color: root.rgba(th.dim, 0.8)
                            font.pixelSize: (10) * root.ts
                        }
                    }
                    Item { Layout.fillWidth: true }
                    AChip {
                        label: root.studio.page < 0 ? "ALL TABS" : (root.pageNameFor(root.studio.page) + " ONLY")
                        glow: th.bar
                        sel: root.studio.page >= 0
                        onClicked: { root.studioTab = 2 }
                    }
                    Rectangle {
                        width: 30; height: 30; radius: 15
                        color: studioCloseMa.containsMouse ? root.rgba(th.accent, 0.18) : "transparent"
                        Text {
                            anchors.centerIn: parent; text: "\u00d7"; color: root.rgba(th.text, 0.85)
                            font.pixelSize: (17) * root.ts
                        }
                        MouseArea {
                            id: studioCloseMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.playTap(); root.closeStudio() }
                        }
                    }
                }

                // ---------- rail + page ----------
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        id: studioRail
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 172
                        spacing: 4
                        Repeater {
                            model: [
                                { n: "TYPE", s: "font, size, ink" },
                                { n: "WALLPAPER", s: "media and grading" },
                                { n: "PER TAB", s: "a world per room" },
                                { n: "ACCOUNTS", s: "who is listening" },
                                { n: "MOTION", s: "speed, feel, sound" }
                            ]
                            delegate: Rectangle {
                                id: srail
                                Layout.fillWidth: true
                                height: 46; radius: 12
                                color: root.studioTab === index ? root.rgba(th.accent, 0.12) : (srailMa.containsMouse ? root.rgba(th.accent, 0.06) : "transparent")
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Rectangle {
                                    x: 0; width: 2; height: root.studioTab === index ? 22 : 0
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: th.accent
                                    Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                }
                                Column {
                                    x: 14; anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    Text {
                                        text: modelData.n
                                        color: root.studioTab === index ? th.text : root.rgba(th.text, 0.7)
                                        font.pixelSize: (10) * root.ts; font.bold: true; font.letterSpacing: 1.5
                                    }
                                    Text {
                                        text: modelData.s
                                        color: root.rgba(th.dim, root.studioTab === index ? 0.85 : 0.5)
                                        font.pixelSize: (8) * root.ts
                                    }
                                }
                                MouseArea {
                                    id: srailMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.studioTab = index; if (index === 2) root.loadAccounts(); }
                                }
                            }
                        }
                        Item { Layout.fillHeight: true; Layout.preferredHeight: 10 }
                        Text {
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            text: "changes save themselves.\nthe room is always the preview."
                            color: root.rgba(th.dim, 0.55)
                            font.family: root.tf; font.pixelSize: (8) * root.ts
                            lineHeight: 1.3
                        }
                    }

                    Flickable {
                        id: studioFlick
                        anchors.left: studioRail.right
                        anchors.leftMargin: 26
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        contentWidth: width
                        contentHeight: studioCol.height
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: GlassScroll { }

                        ColumnLayout {
                            id: studioCol
                            width: studioFlick.width - 14
                            spacing: 18

                            // ================= TYPE =================
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                visible: root.studioTab === 0

                                Text { text: "TYPEFACE"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 7
                                    Repeater {
                                        model: ["Segoe UI", "Bahnschrift", "Candara", "Corbel", "Georgia", "Palatino Linotype", "Trebuchet MS", "Franklin Gothic Book", "Constantia", "Consolas", "Cascadia Mono"]
                                        delegate: AChip {
                                            label: modelData
                                            sel: root.tf === modelData
                                            onClicked: { root.patchAppearance("font", "family", modelData) }
                                        }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    AField {
                                        Layout.fillWidth: true
                                        placeholder: "any installed family, then Enter"
                                        text: root.tf
                                        onAccepted: root.patchAppearance("font", "family", v)
                                    }
                                    Text {
                                        text: "the whole app follows at once"
                                        color: root.rgba(th.dim, 0.5); font.pixelSize: (8) * root.ts
                                    }
                                }

                                ASlider {
                                    Layout.fillWidth: true
                                    label: "type scale"
                                    pct: true
                                    min: 0.78; max: 1.45; step: 0.01
                                    value: root.appearance.font.scale !== undefined ? root.appearance.font.scale : 1
                                    onMoved: root.patchAppearance("font", "scale", v)
                                }

                                Text { Layout.topMargin: 2; text: "INK"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    ASwatch { col: "#ffffff"; sel: ((root.appearance.font || {}).color || "") === "#ffffff"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#f6efe2"; sel: ((root.appearance.font || {}).color || "") === "#f6efe2"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#d7f2ff"; sel: ((root.appearance.font || {}).color || "") === "#d7f2ff"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#ffd9e8"; sel: ((root.appearance.font || {}).color || "") === "#ffd9e8"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#ffe3ad"; sel: ((root.appearance.font || {}).color || "") === "#ffe3ad"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#c9ffdf"; sel: ((root.appearance.font || {}).color || "") === "#c9ffdf"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#dcd0ff"; sel: ((root.appearance.font || {}).color || "") === "#dcd0ff"; onPicked: root.patchAppearance("font", "color", c) }
                                    ASwatch { col: "#12151a"; sel: ((root.appearance.font || {}).color || "") === "#12151a"; onPicked: root.patchAppearance("font", "color", c) }
                                    AChip {
                                        label: "THEME INK"
                                        sel: ((root.appearance.font || {}).color || "") === ""
                                        onClicked: { root.patchAppearance("font", "color", "") }
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    AField {
                                        Layout.preferredWidth: 170
                                        placeholder: "#d7f2ff"
                                        text: (root.appearance.font || {}).color || ""
                                        onAccepted: root.patchAppearance("font", "color", v)
                                    }
                                    Text { text: "hex, or pick a swatch"; color: root.rgba(th.dim, 0.5); font.pixelSize: (8) * root.ts }
                                }

                                // live specimen
                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    height: 150; radius: 18
                                    color: root.rgba(th.panel, 0.40)
                                    border.width: 1; border.color: root.rgba(th.text, 0.08)
                                    Column {
                                        anchors.fill: parent
                                        anchors.margins: 18
                                        spacing: 7
                                        Text {
                                            text: "THE ROOM, IN THIS HAND"
                                            color: root.rgba(th.dim, 0.7)
                                            font.family: root.tf; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                        }
                                        Text {
                                            width: parent.width
                                            text: "Every line of this interface is set in " + root.tf + "."
                                            color: th.text
                                            font.family: root.tf; font.pixelSize: (19) * root.ts; font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            width: parent.width
                                            text: "Lyrics, titles, the tiny labels that tell you where you are: one typeface, one scale, chosen here."
                                            color: root.rgba(th.dim, 0.9)
                                            font.family: root.tf; font.pixelSize: (10) * root.ts
                                            wrapMode: Text.WordWrap
                                        }
                                        Row {
                                            spacing: 10
                                            Text { text: "01:24"; color: root.rgba(th.dim, 0.75); font.pixelSize: (9) * root.ts; font.family: "Consolas" }
                                            Rectangle { width: 60; height: 2; radius: 1; color: root.rgba(th.accent, 0.8); anchors.verticalCenter: parent.verticalCenter }
                                            Text { text: "LOCAL ENGINE"; color: th.accent; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                                        }
                                    }
                                }
                            }

                            // ================= WALLPAPER =================
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                visible: root.studioTab === 1

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text { text: "SCOPE"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: root.studio.page < 0 ? "applies to every tab without its own look" : ("only " + root.pageNameFor(root.studio.page))
                                        color: root.rgba(th.accent, 0.85); font.pixelSize: (8) * root.ts; font.bold: true
                                    }
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 7
                                    AChip {
                                        label: "ALL TABS"
                                        sel: root.studio.page < 0
                                        onClicked: { root.studioSelectPage(-1) }
                                    }
                                    Repeater {
                                        model: 7
                                        delegate: AChip {
                                            slot: index
                                            label: root.pageNameFor(slot)
                                            sel: root.studio.page === slot
                                            glow: th.bar
                                            onClicked: { root.studioSelectPage(slot) }
                                        }
                                    }
                                }

                                // A tab's own world has two halves: the wallpaper
                                // below, and the palette the room is built from. The
                                // palette picker only existed under PER TAB, so anyone
                                // customising a single tab looked here and found
                                // wallpaper controls with no way to change the theme.
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: root.studio.page >= 0
                                    Text {
                                        text: "THEME"
                                        color: root.rgba(th.dim, 0.62)
                                        font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                    }
                                    Item { Layout.fillWidth: true }
                                    AChip {
                                        label: "MATCH APP"
                                        sel: ("" + (root.tabOverride(root.studio.page).theme || "")).length < 2
                                        onClicked: { root.patchTab(root.studio.page, "theme", "") }
                                    }
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    visible: root.studio.page >= 0
                                    spacing: 6
                                    Repeater {
                                        model: root.themeCards
                                        delegate: AChip {
                                            label: modelData.name
                                            sel: ("" + (root.tabOverride(root.studio.page).theme || "")) === modelData.id
                                            glow: modelData.accent || th.accent
                                            onClicked: { root.patchTab(root.studio.page, "theme", modelData.id) }
                                        }
                                    }
                                }

                                Text { Layout.topMargin: 2; text: "SOURCE"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 7
                                    Repeater {
                                        model: [
                                            { k: "theme", l: "THEME WORLD" },
                                            { k: "image", l: "IMAGE" },
                                            { k: "gif", l: "GIF" },
                                            { k: "video", l: "VIDEO" },
                                            { k: "youtube", l: "LINK" },
                                            { k: "cover", l: "COVER ART" }
                                        ]
                                        delegate: AChip {
                                            label: modelData.l
                                            sel: root.lookVal("kind", "theme") === modelData.k
                                            onClicked: { root.studioSet("kind", modelData.k) }
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    visible: root.lookVal("kind", "theme") !== "theme" && root.lookVal("kind", "theme") !== "cover"
                                    AField {
                                        Layout.fillWidth: true
                                        placeholder: root.lookVal("kind", "") === "youtube" ? "paste a youtube or video link" : "path to a file, or use BROWSE"
                                        text: root.lookVal("source", "")
                                        onAccepted: {
                                            root.studioSet("source", v);
                                            if (root.lookVal("kind", "") === "youtube") root.prepareBackdrop(v);
                                        }
                                    }
                                    GlowButton {
                                        label: "BROWSE"
                                        bh: 34
                                        onClicked: { mediaPick.open() }
                                    }
                                    GlowButton {
                                        label: root.ytBackdrop.running ? "FETCHING" : "FETCH"
                                        bh: 34
                                        glow: th.bar
                                        visible: root.lookVal("kind", "") === "youtube"
                                        onClicked: { root.prepareBackdrop(root.lookVal("source", "")) }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    visible: root.lookVal("kind", "") === "youtube"
                                    text: root.ytBackdrop.running
                                          ? "pulling the clip at 720p - it is cached, so it only happens once"
                                          : (root.ytBackdrop.error && root.ytBackdrop.error.length > 1
                                             ? ("failed: " + root.ytBackdrop.error)
                                             : (root.ytBackdrop.path && root.ytBackdrop.path.length > 2
                                                ? "clip cached and looping"
                                                : "youtube links are fetched into the backdrop cache, then played from disk"))
                                    color: (root.ytBackdrop.error && root.ytBackdrop.error.length > 1) ? "#ff9a8b" : root.rgba(th.dim, 0.65)
                                    font.pixelSize: (8) * root.ts
                                    wrapMode: Text.WordWrap
                                }

                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Repeater {
                                        model: [
                                            { k: "theme", t: "theme world", s: "the 3D scene" },
                                            { k: "image", t: "a photograph", s: "still and drifting" },
                                            { k: "gif", t: "a loop", s: "gif, always moving" },
                                            { k: "video", t: "a film", s: "mp4, muted and looped" },
                                            { k: "youtube", t: "a link", s: "cached once, then local" },
                                            { k: "cover", t: "the record", s: "artwork of what plays" }
                                        ]
                                        delegate: Rectangle {
                                            width: 150; height: 54; radius: 13
                                            color: root.rgba(th.panel, 0.4)
                                            border.width: 1
                                            border.color: root.lookVal("kind", "theme") === modelData.k ? root.rgba(th.accent, 0.6) : root.rgba(th.text, 0.08)
                                            Column {
                                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2
                                                Text { text: modelData.t; color: th.text; font.pixelSize: (10) * root.ts; font.bold: true }
                                                Text { text: modelData.s; color: root.rgba(th.dim, 0.6); font.pixelSize: (8) * root.ts }
                                            }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.studioSet("kind", modelData.k) } }
                                        }
                                    }
                                }

                                // the collapsed window shares the palette's one choice:
                                // the room it came out of, or the record it is playing
                                // one collapsed window, one choice: these two belong to the
                                // app, not to a tab, so they only show on ALL TABS
                                Text { Layout.topMargin: 4; visible: root.studio.page < 0; text: "MINI BAR"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: root.studio.page < 0
                                    spacing: 8
                                    Repeater {
                                        model: [
                                            { k: "theme", t: "THEME WORLD", s: "the scene behind the room" },
                                            { k: "song", t: "THE RECORD", s: "artwork of what plays" }
                                        ]
                                        delegate: Rectangle {
                                            Layout.fillWidth: true; height: 54; radius: 13
                                            color: root.rgba(th.panel, 0.4)
                                            border.width: 1
                                            border.color: root.miniBackdrop === modelData.k ? root.rgba(th.accent, 0.6) : root.rgba(th.text, 0.08)
                                            Column {
                                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2
                                                Text { text: modelData.t; color: th.text; font.pixelSize: (9) * root.ts; font.bold: true; font.letterSpacing: 1 }
                                                Text { text: modelData.s; color: root.rgba(th.dim, 0.6); font.pixelSize: (8) * root.ts }
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap(); root.patchAppearance("mini", "bg", modelData.k) }
                                            }
                                        }
                                    }
                                }

                                // grading
                                Text { Layout.topMargin: 4; text: "GRADING"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 22
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "opacity"; pct: true; min: 0; max: 1; step: 0.01
                                            value: root.lookVal("opacity", 0.75)
                                            onMoved: root.studioSet("opacity", v)
                                        }
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "blur"; pct: true; min: 0; max: 1; step: 0.01
                                            value: root.lookVal("blur", 0.22)
                                            onMoved: root.studioSet("blur", v)
                                        }
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "saturation"; min: 0; max: 2; step: 0.01
                                            value: root.lookVal("sat", 1)
                                            onMoved: root.studioSet("sat", v)
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "hue shift"; suffix: "\u00b0"; min: -180; max: 180; step: 1; decimals: 0
                                            value: root.lookVal("hue", 0)
                                            onMoved: root.studioSet("hue", v)
                                        }
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "brightness"; min: 0.35; max: 1.7; step: 0.01
                                            value: root.lookVal("bright", 1)
                                            onMoved: root.studioSet("bright", v)
                                        }
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "zoom"; min: 0.7; max: 1.8; step: 0.01
                                            value: root.lookVal("zoom", 1)
                                            onMoved: root.studioSet("zoom", v)
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "drift"; pct: true; min: 0; max: 1; step: 0.01
                                            value: root.lookVal("drift", 0.35)
                                            onMoved: root.studioSet("drift", v)
                                        }
                                        ASlider {
                                            Layout.fillWidth: true
                                            label: "tint"; pct: true; min: 0; max: 1; step: 0.01
                                            value: root.lookVal("tintAmt", 0)
                                            onMoved: root.studioSet("tintAmt", v)
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Repeater {
                                                model: ["#04121f", "#1a0b24", "#2a0f0b", "#06210f", "#101a33", "#241a05", "#000000"]
                                                delegate: ASwatch {
                                                    col: modelData
                                                    sel: ("" + root.lookVal("tint", "")) === modelData
                                                    onPicked: root.studioSet("tint", c)
                                                }
                                            }
                                        }
                                        // an equaliser is a meter, not wallpaper, but this is
                                        // where colour lives and the room behind the panel is
                                        // the live preview. THEME hands the meter back to the
                                        // palette it was born with.
                                        Item { Layout.fillWidth: true; Layout.preferredHeight: 8 }
                                        Text {
                                            text: "EQUALIZER COLOURS"
                                            color: root.rgba(th.dim, 0.62)
                                            font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Text {
                                                Layout.preferredWidth: 34
                                                text: "bars"
                                                color: root.rgba(th.dim, 0.72); font.pixelSize: (8) * root.ts
                                            }
                                            Repeater {
                                                model: ["#00ffa3", "#7ff0ff", "#7aa2ff", "#ff5a4d", "#ff9de2", "#ffd166", "#ffffff"]
                                                delegate: ASwatch {
                                                    col: modelData
                                                    sel: ("" + root.lookVal("eqA", "")) === modelData
                                                    onPicked: root.studioSet("eqA", c)
                                                }
                                            }
                                            AChip {
                                                label: "THEME"
                                                sel: ("" + root.lookVal("eqA", "")).length < 4
                                                onClicked: root.studioSet("eqA", "")
                                            }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Text {
                                                Layout.preferredWidth: 34
                                                text: "peaks"
                                                color: root.rgba(th.dim, 0.72); font.pixelSize: (8) * root.ts
                                            }
                                            Repeater {
                                                model: ["#00ffa3", "#7ff0ff", "#7aa2ff", "#ff5a4d", "#ff9de2", "#ffd166", "#ffffff"]
                                                delegate: ASwatch {
                                                    col: modelData
                                                    sel: ("" + root.lookVal("eqB", "")) === modelData
                                                    onPicked: root.studioSet("eqB", c)
                                                }
                                            }
                                            AChip {
                                                label: "THEME"
                                                sel: ("" + root.lookVal("eqB", "")).length < 4
                                                onClicked: root.studioSet("eqB", "")
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: "bars is the body of every meter, peaks is the tip and the floating dots"
                                            color: root.rgba(th.dim, 0.5); font.pixelSize: (8) * root.ts
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                                Item { Layout.fillWidth: true; Layout.preferredHeight: 4 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        Layout.fillWidth: true
                                        text: root.studio.page < 0
                                              ? "this wallpaper is the fallback: any tab with its own look overrides it"
                                              : "this wallpaper belongs to this tab only"
                                        color: root.rgba(th.dim, 0.55); font.pixelSize: (8) * root.ts
                                        wrapMode: Text.WordWrap
                                    }
                                    GlowButton {
                                        label: "RESET LOOK"
                                        bh: 30
                                        visible: root.studio.page < 0
                                        // a reset is about the *look*: the sound pack, the
                                        // motion speed, the typing switch and the mini bar's
                                        // floor are preferences and have to survive it
                                        onClicked: { var a = root.appearance || {};
                                            root.appearance = { font: a.font,
                                                                backdrop: { kind: "theme", source: "", opacity: 0.75, blur: 0.22,
                                                                            tint: "#050f1c", tintAmt: 0, hue: 0, sat: 1,
                                                                            bright: 1, zoom: 1, drift: 0.35,
                                                                            eqA: "", eqB: "" },
                                                                tabs: a.tabs,
                                                                motion: a.motion,
                                                                mini: a.mini,
                                                                // a reset rebuilds this object from
                                                                // scratch, so a section left out of it
                                                                // is dropped - the habits ride along
                                                                library: a.library };
                                            root.applyMotion();
                                            root.refreshLook();
                                            appearanceSave.restart();
                                        }
                                    }
                                    GlowButton {
                                        label: "THIS TAB: THEME WORLD"
                                        bh: 30
                                        glow: th.bar
                                        visible: root.studio.page >= 0
                                        onClicked: { root.studioSet("kind", "theme"); root.patchTab(root.studio.page, "enabled", false); }
                                    }
                                }
                            }

                            // ================= PER TAB =================
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                visible: root.studioTab === 2

                                Text {
                                    Layout.fillWidth: true
                                    text: "Each room can keep its own world. A tab with CUSTOM LOOK uses its own theme and wallpaper; every other tab follows the app theme."
                                    color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts
                                    wrapMode: Text.WordWrap
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 2
                                    columnSpacing: 12
                                    rowSpacing: 12
                                    Repeater {
                                        model: 7
                                        delegate: Rectangle {
                                            id: tabCard
                                            Layout.fillWidth: true
                                            height: 132; radius: 18
                                            // a plain property: the buttons below are nested
                                            // components, and they cannot read the repeater's
                                            // context-provided index from inside one
                                            readonly property int slot: index
                                            readonly property var ov: root.tabOverride(slot)
                                            readonly property bool custom: ov.enabled === true
                                            readonly property color spine: {
                                                var id = tabCard.ov.theme || "";
                                                for (var i = 0; i < root.themeCards.length; i++)
                                                    if (root.themeCards[i].id === id) return root.themeCards[i].accent;
                                                return th.accent;
                                            }
                                            color: custom ? root.rgba(th.panel, 0.42) : root.rgba(th.panel, 0.22)
                                            // the card is a pool of its room's light, not a rectangle
                                            border.width: 0
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                            // each room gets a breath of its own palette, so a row of
                                            // cards reads as seven different worlds at a glance
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: 18
                                                opacity: custom ? 1 : 0.4
                                                gradient: Gradient {
                                                    orientation: Gradient.Horizontal
                                                    GradientStop { position: 0; color: root.rgba(tabCard.spine, custom ? 0.20 : 0.06) }
                                                    GradientStop { position: 0.7; color: root.rgba(tabCard.spine, 0) }
                                                }
                                            }
                                            Rectangle {
                                                x: 0; y: 16; width: custom ? 3 : 1
                                                height: parent.height - 32; radius: 1.5
                                                color: root.rgba(tabCard.spine, custom ? 0.85 : 0.2)
                                                Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                                            }
                                            ColumnLayout {
                                                anchors.fill: parent
                                                anchors.margins: 14
                                                spacing: 5
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    Text {
                                                        text: root.pageNameFor(tabCard.slot)
                                                        color: th.text
                                                        font.pixelSize: (12) * root.ts; font.bold: true; font.letterSpacing: 1.4
                                                    }
                                                    Item { Layout.fillWidth: true }
                                                    Rectangle {
                                                        width: 30; height: 16; radius: 8
                                                        color: tabCard.custom ? root.rgba(th.accent, 0.8) : root.rgba(th.text, 0.16)
                                                        Rectangle {
                                                            x: tabCard.custom ? parent.width - 14 : 2
                                                            y: 2; width: 12; height: 12; radius: 6
                                                            color: tabCard.custom ? th.bg : root.rgba(th.text, 0.7)
                                                            Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                                        }
                                                        MouseArea {
                                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                            onClicked: { root.playTap(); root.patchTab(tabCard.slot, "enabled", !tabCard.custom) }
                                                        }
                                                    }
                                                }
                                                Text {
                                                    text: tabCard.custom
                                                          ? ((tabCard.ov.theme && tabCard.ov.theme.length > 2) ? tabCard.ov.theme.toUpperCase() : "APP THEME")
                                                          : "FOLLOWS THE APP"
                                                    color: tabCard.custom ? th.accent : root.rgba(th.dim, 0.55)
                                                    font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.3
                                                }
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 5
                                                    Text {
                                                        text: "WALLPAPER"
                                                        color: root.rgba(th.dim, 0.5); font.pixelSize: (7) * root.ts; font.letterSpacing: 1
                                                    }
                                                    Text {
                                                        text: (tabCard.ov.kind || (tabCard.custom ? "theme" : "app")).toUpperCase()
                                                        color: root.rgba(th.text, 0.75); font.pixelSize: (8) * root.ts; font.bold: true
                                                    }
                                                }
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 6
                                                    GlowButton {
                                                        label: "EDIT"
                                                        bh: 24
                                                        onClicked: { root.studioSelectPage(tabCard.slot);
                                                            root.studioTab = 1;
                                                        }
                                                    }
                                                    GlowButton {
                                                        label: "THEMES"
                                                        bh: 24
                                                        glow: th.bar
                                                        // the picker lives at the bottom of this same
                                                        // page: select the room *and* go to it, or the
                                                        // button looks like it does nothing
                                                        onClicked: { root.studioSelectPage(tabCard.slot);
                                                            root.studioTab = 2;
                                                            // flick clamps this: asking for the end
                                                            // lands exactly on the theme list
                                                            studioFlick.contentY = studioFlick.contentHeight;
                                                        }
                                                    }
                                                    GlowButton {
                                                        label: "OPEN"
                                                        bh: 24
                                                        onClicked: { root.studioVisitPage(tabCard.slot) }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // theme picker for the selected tab
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    visible: root.studio.page >= 0
                                    spacing: 8
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            text: "THEME FOR " + root.pageNameFor(root.studio.page)
                                            color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                        }
                                        Item { Layout.fillWidth: true }
                                        GlowButton {
                                            label: "MATCH APP"
                                            bh: 24
                                            onClicked: { root.patchTab(root.studio.page, "theme", "");
                                                root.patchTab(root.studio.page, "enabled", false);
                                            }
                                        }
                                        GlowButton {
                                            label: "OPEN TAB"
                                            bh: 24
                                            glow: th.bar
                                            onClicked: { root.studioVisitPage(root.studio.page) }
                                        }
                                    }
                                    Flow {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Repeater {
                                            model: root.themeCards
                                            delegate: AChip {
                                                label: modelData.name
                                                sel: ("" + (root.tabOverride(root.studio.page).theme || "")) === modelData.id
                                                glow: modelData.accent || th.accent
                                                onClicked: { root.patchTab(root.studio.page, "theme", modelData.id) }
                                            }
                                        }
                                    }
                                }
                            }

                            // ================= ACCOUNTS =================
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                visible: root.studioTab === 3

                                Text {
                                    Layout.fillWidth: true
                                    text: "Who is listening. YouTube accounts are sessions the app borrows from your browser (or a cookies file); nothing is typed into AetherMix, and no password is ever stored here."
                                    color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts
                                    wrapMode: Text.WordWrap
                                }

                                // ---- the phone gateway ----------------------
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 78; radius: 16
                                    color: root.phoneOpen ? root.rgba(th.accent, 0.10) : root.rgba(th.panel, 0.28)
                                    border.width: 1
                                    border.color: root.phoneOpen ? root.rgba(th.accent, 0.40) : root.rgba(th.text, 0.08)
                                    Behavior on color { ColorAnimation { duration: 240 } }
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 15
                                        spacing: 12
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 3
                                            Text {
                                                text: "PHONE GATEWAY"
                                                color: th.text
                                                font.pixelSize: (11) * root.ts; font.bold: true; font.letterSpacing: 1.5
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: root.phoneOpen
                                                      ? "open for this network  ·  " + (root.phoneURL.length > 6 ? root.phoneURL : "address shown when the bridge is up")
                                                      : "closed  ·  nothing on the network can reach this machine"
                                                color: root.phoneOpen ? root.rgba(th.accent, 0.88) : root.rgba(th.dim, 0.62)
                                                font.pixelSize: (8.5) * root.ts
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Rectangle {
                                            width: 48; height: 27; radius: 14
                                            color: root.phoneOpen ? root.rgba(th.accent, 0.85) : root.rgba(th.text, 0.16)
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                            Rectangle {
                                                x: root.phoneOpen ? parent.width - 25 : 2
                                                y: 2; width: 23; height: 23; radius: 12
                                                color: root.phoneOpen ? th.bg : root.rgba(th.text, 0.72)
                                                Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                            }
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.playTap(); root.setPhone(!root.phoneOpen) }
                                            }
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    GlowButton { label: "SIGN IN TO YOUTUBE"; bh: 32; onClicked: { root.signIn("youtube") } }
                                    GlowButton { label: "TEST ACTIVE"; bh: 32; glow: th.bar; onClicked: { root.testAccount() } }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: "sessions are read by yt-dlp"
                                        color: root.rgba(th.dim, 0.45); font.pixelSize: (8) * root.ts
                                    }
                                }

                                Repeater {
                                    model: root.accountsData.accounts || []
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        height: 62; radius: 15
                                        color: modelData.active ? root.rgba(th.accent, 0.10) : root.rgba(th.panel, 0.28)
                                        border.width: 1
                                        border.color: modelData.active ? root.rgba(th.accent, 0.42) : root.rgba(th.text, 0.08)
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            spacing: 12
                                            Rectangle {
                                                width: 34; height: 34; radius: 17
                                                color: root.rgba(th.accent, 0.18)
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: ("" + (modelData.label || "?")).charAt(0).toUpperCase()
                                                    color: th.accent; font.pixelSize: (13) * root.ts; font.bold: true
                                                }
                                            }
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 1
                                                Text { text: modelData.label; color: th.text; font.pixelSize: (11) * root.ts; font.bold: true }
                                                Text {
                                                    text: modelData.cookies && modelData.cookies.length > 0 ? modelData.cookies : "public session (no cookies)"
                                                    color: root.rgba(th.dim, 0.65); font.pixelSize: (8) * root.ts
                                                    elide: Text.ElideMiddle; Layout.fillWidth: true
                                                }
                                            }
                                            Rectangle {
                                                visible: modelData.active === true
                                                width: 52; height: 20; radius: 10
                                                color: root.rgba(th.accent, 0.16)
                                                Text { anchors.centerIn: parent; text: "ACTIVE"; color: th.accent; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                                            }
                                            GlowButton {
                                                label: "USE"
                                                bh: 24
                                                visible: modelData.active !== true
                                                onClicked: { root.activateAccount(modelData.id) }
                                            }
                                            GlowButton {
                                                label: "REMOVE"
                                                bh: 24
                                                visible: (root.accountsData.accounts || []).length > 1
                                                onClicked: { root.removeAccount(modelData.id) }
                                            }
                                        }
                                    }
                                }

                                Item { Layout.fillWidth: true; Layout.preferredHeight: 2 }
                                Text { text: "ADD A SESSION"; color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 9
                                    AField {
                                        id: accName
                                        Layout.preferredWidth: 190
                                        placeholder: "account name"
                                        text: root.newAccLabel
                                    }
                                    AField {
                                        id: accCookies
                                        Layout.fillWidth: true
                                        placeholder: "browser:chrome  ·  browser:firefox  ·  C:/path/cookies.txt"
                                        text: root.newAccCookies
                                    }
                                    GlowButton {
                                        label: "ADD"
                                        bh: 34
                                        onClicked: { root.addAccount(accName.text, accCookies.text) }
                                    }
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: ["chrome", "edge", "firefox", "brave", "opera", "vivaldi", "chromium"]
                                        delegate: AChip {
                                            label: modelData.toUpperCase()
                                            glow: th.bar
                                            sel: accCookies.text === ("browser:" + modelData)
                                            onClicked: { accCookies.text = "browser:" + modelData; root.newAccCookies = accCookies.text; }
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "Pick the browser you are signed in with, name the session, then ADD. Chrome, Edge and Firefox keep their sessions in different places; yt-dlp reads them directly. If a browser is open with a locked cookie store, close it once and test again."
                                    color: root.rgba(th.dim, 0.55); font.pixelSize: (8) * root.ts
                                    wrapMode: Text.WordWrap
                                }

                                Item { Layout.fillWidth: true; Layout.preferredHeight: 2 }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 12
                                    Rectangle {
                                        width: 34; height: 34; radius: 17
                                        color: "#1DB954"
                                        Text { anchors.centerIn: parent; text: "\u266b"; color: "#04140a"; font.pixelSize: (16) * root.ts; font.bold: true }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text { text: "SPOTIFY"; color: th.text; font.pixelSize: (11) * root.ts; font.bold: true }
                                        Text {
                                            text: root.accountsData.spotify && root.accountsData.spotify.granted
                                                  ? "session linked - search, playlists and streaming are live"
                                                  : "not linked - search and playback need a granted session"
                                            color: root.rgba(th.dim, 0.65); font.pixelSize: (8) * root.ts
                                        }
                                    }
                                    GlowButton {
                                        label: (root.accountsData.spotify && root.accountsData.spotify.granted) ? "RE-AUTHORIZE" : "LINK WITH BROWSER"
                                        bh: 28
                                        glow: "#1DB954"
                                        onClicked: { root.signIn("spotify") }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: "Apple Music has no public desktop search or playback API, so it is not wired. SoundCloud search works through yt-dlp with no account at all."
                                    color: root.rgba(th.dim, 0.48); font.pixelSize: (8) * root.ts
                                    wrapMode: Text.WordWrap
                                }
                            }

                            // ================= MOTION =================
                            // the reference settings panel's most human idea:
                            // speed and feel are yours, and the app has a voice
                            // you choose, not one it imposes.
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 14
                                visible: root.studioTab === 4

                                Text {
                                    Layout.fillWidth: true
                                    text: "Motion is a preference, not a personality. Slow it down for calm, speed it up for pace, or ask for almost none and the rooms will still change - they will simply do it politely."
                                    color: root.rgba(th.dim, 0.72); font.pixelSize: (9) * root.ts
                                    wrapMode: Text.WordWrap
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 58; radius: 18
                                    color: root.rgba(th.panel, 0.24)
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 16
                                        spacing: 14
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            Text { text: "ANIMATIONS"; color: th.text; font.pixelSize: (11) * root.ts; font.bold: true; font.letterSpacing: 1.2 }
                                            Text { text: "page moves, the world rising, the dye wash"; color: root.rgba(th.dim, 0.62); font.pixelSize: (8) * root.ts }
                                        }
                                        AToggle {
                                            on: root.motionEnabled
                                            onToggled: root.patchAppearance("motion", "enabled", !root.motionEnabled)
                                        }
                                    }
                                }

                                ASlider {
                                    Layout.fillWidth: true
                                    label: "MOTION SPEED"
                                    value: root.motionSpeed
                                    min: 0.6; max: 1.6; step: 0.05; decimals: 2; suffix: "x"
                                    onMoved: root.patchAppearance("motion", "speed", v)
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text {
                                        text: "FEEL"
                                        color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                    }
                                    Item { Layout.fillWidth: true }
                                    Repeater {
                                        model: [
                                            { id: "smooth", n: "SMOOTH" },
                                            { id: "snappy", n: "SNAPPY" },
                                            { id: "minimal", n: "MINIMAL" }
                                        ]
                                        delegate: AChip {
                                            label: modelData.n
                                            sel: root.motionStyle === modelData.id
                                            onClicked: { root.patchAppearance("motion", "style", modelData.id) }
                                        }
                                    }
                                }

                                Item { Layout.fillWidth: true; Layout.preferredHeight: 2 }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text {
                                        text: "BUTTON SOUND"
                                        color: root.rgba(th.dim, 0.62); font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 2
                                    }
                                    Item { Layout.fillWidth: true }
                                    Repeater {
                                        model: [
                                            { id: "off", n: "OFF" },
                                            { id: "tap", n: "TAP" },
                                            { id: "double", n: "DOUBLE" }
                                        ]
                                        delegate: AChip {
                                            label: modelData.n
                                            sel: root.soundPack === modelData.id
                                            silent: true
                                            onClicked: {
                                                root.patchAppearance("motion", "sound", modelData.id);
                                                root.playPack(modelData.id);
                                            }
                                        }
                                    }
                                }

                                ASlider {
                                    Layout.fillWidth: true
                                    label: "SOUND VOLUME"
                                    value: root.soundVolume
                                    min: 0; max: 1; step: 0.01; pct: true
                                    onMoved: root.patchAppearance("motion", "volume", v)
                                }

                                // the keyboard is its own switch: it follows the pack
                                // (all of it drops out at OFF), but it can also be
                                // silenced alone without giving up the taps
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 58; radius: 18
                                    color: root.rgba(th.panel, 0.24)
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 16
                                        spacing: 14
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            Text {
                                                text: "TYPING SOUND"
                                                color: th.text; font.pixelSize: (9) * root.ts
                                                font.bold: true; font.letterSpacing: 1.4
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: "a key strike as you search, name a room or tag a track"
                                                color: root.rgba(th.dim, 0.6); font.pixelSize: (8) * root.ts
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                        AToggle {
                                            on: root.typingOn
                                            onToggled: root.patchAppearance("motion", "typing", !root.typingOn)
                                        }
                                    }
                                }

                                // ---- audition: hear the voice and watch the drop
                                // before committing to them. The left card runs the
                                // real DyeWash shader; the right one keeps every pack
                                // loaded so the tap you hear is the tap you chose.
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    spacing: 12

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 158
                                        radius: 18
                                        clip: true
                                        color: root.rgba(th.panel, 0.34)

                                        Rectangle {
                                            anchors.fill: parent
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: root.rgba(th.accent, 0.12) }
                                                GradientStop { position: 1.0; color: root.rgba(th.bg, 0.55) }
                                            }
                                        }
                                        DyeWash {
                                            anchors.fill: parent
                                            progress: root.dyeAmt
                                            origin: Qt.vector2d(0.5, 0.5)
                                            inkA: th.accent
                                            inkB: th.bg
                                            seed: root.dyeSeed
                                            strength: 0.9
                                        }
                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 16
                                            spacing: 2
                                            Text {
                                                text: "THE DROP"
                                                color: th.text; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: "ink meeting water - every room change starts here"
                                                color: root.rgba(th.dim, 0.62); font.pixelSize: (8) * root.ts
                                                wrapMode: Text.WordWrap
                                            }
                                            Item { Layout.fillHeight: true }
                                            Rectangle {
                                                width: 108; height: 30; radius: 15
                                                color: dropMa.containsMouse ? root.rgba(th.accent, 0.30) : root.rgba(th.accent, 0.16)
                                                border.width: 1
                                                border.color: root.rgba(th.accent, 0.32)
                                                Behavior on color { ColorAnimation { duration: 160 } }
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: "DROP INK"
                                                    color: th.text; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4
                                                }
                                                MouseArea {
                                                    id: dropMa
                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: { root.dyeAt(0.5, 0.52); root.playTap(); }
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 158
                                        radius: 18
                                        color: root.rgba(th.panel, 0.34)
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 18
                                            gradient: Gradient {
                                                GradientStop { position: 0.0; color: root.rgba(th.bar, 0.12) }
                                                GradientStop { position: 1.0; color: root.rgba(th.bg, 0.30) }
                                            }
                                        }
                                        ColumnLayout {
                                            anchors.fill: parent
                                            anchors.margins: 16
                                            spacing: 2
                                            Text {
                                                text: "THE VOICE"
                                                color: th.text; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 2
                                            }
                                            RowLayout {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 10
                                                spacing: 8
                                                Repeater {
                                                    model: [
                                                        { id: "off", n: "OFF" },
                                                        { id: "tap", n: "TAP" },
                                                        { id: "double", n: "DOUBLE" }
                                                    ]
                                                    delegate: Rectangle {
                                                        Layout.fillWidth: true
                                                        height: 44; radius: 12
                                                        color: root.soundPack === modelData.id
                                                             ? root.rgba(th.accent, 0.20)
                                                             : (tapMa.containsMouse ? root.rgba(th.text, 0.08) : root.rgba(th.bg, 0.30))
                                                        border.width: root.soundPack === modelData.id ? 1 : 0
                                                        border.color: root.rgba(th.accent, 0.35)
                                                        Behavior on color { ColorAnimation { duration: 160 } }
                                                        Text {
                                                            anchors.centerIn: parent
                                                            text: modelData.n
                                                            color: root.soundPack === modelData.id ? th.accent : root.rgba(th.dim, 0.92)
                                                            font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.2
                                                        }
                                                        MouseArea {
                                                            id: tapMa
                                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                root.patchAppearance("motion", "sound", modelData.id);
                                                                root.playPack(modelData.id);
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 8
                                                text: "the chosen tap rings through every room, every chip, every door"
                                                color: root.rgba(th.dim, 0.55); font.pixelSize: (8) * root.ts
                                                wrapMode: Text.WordWrap
                                            }
                                            Item { Layout.fillHeight: true }
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: "Sounds are generated locally - no assets are downloaded, nothing is sampled from the reference app."
                                    color: root.rgba(th.dim, 0.45); font.pixelSize: (8) * root.ts
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: studioPanel.studioSlide > 0.4
            onActivated: root.closeStudio()
        }
        FileDialog {
            id: mediaPick
            title: "Choose a backdrop"
            nameFilters: ["Media (*.mp4 *.webm *.mov *.mkv *.gif *.png *.jpg *.jpeg *.webp *.bmp)"]
            onAccepted: {
                var p = ("" + selectedFile).replace("file:///", "");
                root.studioSet("source", p);
                var l = p.toLowerCase();
                var k = (l.indexOf(".gif") >= 0) ? "gif"
                      : (l.indexOf(".mp4") >= 0 || l.indexOf(".webm") >= 0 || l.indexOf(".mov") >= 0 || l.indexOf(".mkv") >= 0) ? "video"
                      : "image";
                root.studioSet("kind", k);
            }
        }
    }

    // ================= TRACK INFO: one row, in full =================
    Item {
        id: infoPanel
        z: 96
        anchors.fill: parent
        visible: root.infoOpen
        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.42)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); root.closeInfo() } }
        }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(500, root.width - 60)
            height: infoCol.height + 40
            radius: 20
            color: root.rgba(th.panel, 0.97)
            border.width: 1; border.color: root.rgba("#ffffff", 0.10)
            property real progress: 0
            scale: 0.97 + 0.03 * progress
            opacity: progress
            NumberAnimation on progress { id: infoIn; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic; running: root.infoOpen }
            Column {
                id: infoCol
                x: 22; y: 20; width: parent.width - 44
                spacing: 8
                Text {
                    width: parent.width
                    text: root.trackInfo ? root.trackInfo.title : ""
                    color: th.text; font.family: root.tf; font.pixelSize: (16) * root.ts; font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.trackInfo
                          ? ((root.trackInfo.artist || "") + (root.trackInfo.album && root.trackInfo.album.length > 0 ? ("  \u00b7  " + root.trackInfo.album) : ""))
                          : ""
                    color: root.rgba(th.dim, 0.9); font.family: root.tf; font.pixelSize: (10) * root.ts
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.trackInfo
                          ? (root.fmt(root.trackInfo.duration_ms || 0)
                             + "  \u00b7  " + (root.trackInfo.plays || 0) + " plays"
                             + "  \u00b7  " + (root.trackInfo.liked ? "liked" : "not liked")
                             + "  \u00b7  " + (root.trackInfo.format && root.trackInfo.format.length > 0 ? root.trackInfo.format : (root.trackInfo.streamable ? "STREAM" : "CATALOG"))
                             + (root.trackInfo.size > 0 ? ("  \u00b7  " + (root.trackInfo.size / 1048576).toFixed(1) + " MB") : ""))
                          : ""
                    color: root.rgba(th.accent, 0.9); font.family: root.tf; font.pixelSize: (8.5) * root.ts
                    wrapMode: Text.WordWrap
                }
                Text {
                    width: parent.width
                    text: root.trackInfo ? (root.trackInfo.path && root.trackInfo.path.length > 2 ? root.trackInfo.path : "streamed from the catalog - nothing on disk") : ""
                    color: root.rgba(th.dim, 0.65); font.family: "Consolas"; font.pixelSize: (8) * root.ts
                    wrapMode: Text.WrapAnywhere
                }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    GlowButton {
                        label: "SHOW IN FOLDER"; bh: 26
                        visible: root.trackInfo && root.trackInfo.exists
                        onClicked: { root.revealTrack() }
                    }
                    GlowButton {
                        label: "LIKE / UNLIKE"; bh: 26
                        glow: th.accent
                        onClicked: { root.toggleLike(root.trackInfo) }
                    }
                    GlowButton {
                        label: "PLAY"; bh: 26; glow: th.accent
                        onClicked: { if (root.trackInfo) root.hit("/play?id=" + root.trackInfo.id); root.closeInfo(); }
                    }
                    Item { Layout.fillWidth: true }
                    GlowButton { label: "CLOSE"; bh: 26; onClicked: { root.closeInfo() } }
                }
            }
        }
    }

    // ================= WATCH: a screen, no ads, no browser =================
    Item {
        id: watchPanel
        z: 97
        anchors.fill: parent
        visible: watchSlide > 0.002
        property real watchSlide: 0
        property bool closing: false
        function show() {
            closing = false;
            // reopening a sheet that is already open must not replay the
            // entrance animation: restarting it snaps the panel back to zero
            // for a frame, which - with the film's lifetime now tied to the
            // panel's visibility - tore the film down under the viewer and
            // left a loaded, paused, never-started player
            if (watchSlide <= 0.002) {
                watchAnim.to = 1; watchAnim.restart();
            }
            watchFocus.restart();
            root.dyeAt(0.78, 0.34);
        }
        function hide() { closing = true; watchAnim.to = 0; watchAnim.restart(); }
        onVisibleChanged: {
            if (!visible && closing) {
            // only a real close tears the film down - a sheet that is already
            // open can flicker its visibility while it re-enters, and that
            // must not cancel what the viewer asked for
                watchStart.stop();
                watchPlayer.wantPlay = false;
                watchPlayer.stop();
            }
        }
        Timer { id: watchFocus; interval: 140; onTriggered: watchField.input.forceActiveFocus() }
        NumberAnimation {
            id: watchAnim
            target: watchPanel; property: "watchSlide"
            duration: watchPanel.closing ? 200 : 380
            easing.type: Easing.OutQuint
        }
        opacity: watchSlide
        Timer { id: watchPoll; interval: 1000; repeat: true; onTriggered: root.pollWatch() }

        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.72 * watchPanel.watchSlide)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); watchPanel.hide() } }
        }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(1120, root.width - 48)
            height: Math.min(720, root.height - 48)
            radius: 26
            color: root.rgba(th.panel, 0.96)
            // no outline: the shadow and the film's own light hold the edge
            border.width: 0
            opacity: watchPanel.watchSlide
            scale: 0.975 + 0.025 * watchPanel.watchSlide
            transform: Translate { y: (1 - watchPanel.watchSlide) * 18 }
            clip: true
            RectangularShadow {
                anchors.fill: parent; radius: 26; blur: 60; spread: 2
                offset: Qt.vector2d(0, 20)
                color: root.rgba("#000000", 0.55)
            }

            // -------- the film --------
            // inset rather than masked: the panel's corners are rounded, so a
            // stage that touched the edge needed a per-frame shader mask to
            // round its own - and that pass ran while the panel was animating
            // its opacity, which is where the flash came from. Sitting 12px in
            // keeps every square corner inside the rounding, for free.
            Rectangle {
                id: watchStage
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.topMargin: 12
                anchors.bottomMargin: 86
                radius: 16
                color: "transparent"
                clip: true
                visible: root.watch.path.length > 3
                VideoOutput {
                    id: watchOut
                    anchors.fill: parent
                    anchors.margins: 2
                    fillMode: VideoOutput.PreserveAspectFit
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.playTap(); watchPlayer.playbackState === MediaPlayer.PlayingState ? watchPlayer.pressPause() : watchPlayer.pressPlay() }
                    }
                }
                Image {
                    anchors.centerIn: parent
                    width: 74; height: 74
                    source: Qt.resolvedUrl("../assets/icon.png")
                    opacity: 0.10
                    visible: watchPlayer.playbackState === MediaPlayer.PausedState
                }
            }

            // -------- empty / preparing state --------
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 26
                anchors.bottomMargin: 74
                spacing: 14
                visible: root.watch.path.length <= 3

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text { text: "WATCH"; color: th.text; font.pixelSize: (20) * root.ts; font.bold: true; font.letterSpacing: 3 }
                    Text {
                        text: "videos play from the file itself \u00b7 no player chrome, no ads, nothing tracking you"
                        color: root.rgba(th.dim, 0.55); font.pixelSize: (8) * root.ts
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 30; height: 30; radius: 15
                        color: watchCloseMa.containsMouse ? root.rgba(th.accent, 0.2) : "transparent"
                        Text { anchors.centerIn: parent; text: "\u00d7"; color: root.rgba(th.text, 0.85); font.pixelSize: (17) * root.ts }
                        MouseArea { id: watchCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); watchPanel.hide() } }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 9
                    AField {
                        id: watchField
                        Layout.fillWidth: true
                        placeholder: "a video link, or type what you want to watch"
                        text: root.watchQuery
                        onTextChanged: root.watchQuery = text
                        onAccepted: root.searchWatch(text)
                    }
                    GlowButton {
                        label: root.watch.running ? "FETCHING" : (root.watchUrlLooksLikeLink() ? "WATCH" : "SEARCH")
                        bh: 34; glow: th.accent
                        onClicked: { if (root.watchUrlLooksLikeLink()) root.watchThis(watchField.text);
                            else root.searchWatch(watchField.text);
                        }
                    }
                    GlowButton { label: "CLOSE"; bh: 34; onClicked: { watchPanel.hide() } }
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.watch.running || root.watch.error.length > 1
                    text: root.watch.running
                          ? ("pulling the film at 720p  \u00b7  " + (root.watch.note || "working")
                             + ((root.watch.pct || 0) > 0 ? ("  \u00b7  " + root.watch.pct + "%") : "")
                             + "  \u00b7  cached, so revisiting is instant")
                          : ("could not play that: " + root.watch.error)
                    color: root.watch.running ? th.accent : "#ff9a8b"
                    font.pixelSize: (9) * root.ts
                    wrapMode: Text.WordWrap
                }
                Column {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: root.watchRows.length === 0 && !root.watchBusy && !root.watch.running
                    spacing: 8
                    Layout.alignment: Qt.AlignHCenter
                    Item { width: 1; height: 40 }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "no ads, no player, no browser"
                        color: root.rgba(th.text, 0.82); font.pixelSize: (15) * root.ts; font.bold: true
                    }
                    Text {
                        width: Math.min(460, parent.width)
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "search for a video above, or paste a youtube link. the film is fetched once at 720p and played from disk; the ad breaks, overlays and trackers never arrive."
                        color: root.rgba(th.dim, 0.9); font.pixelSize: (9) * root.ts
                        wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["music videos", "live sessions", "visualizers"]
                        delegate: AChip {
                            label: modelData.toUpperCase()
                            glow: th.bar
                            onClicked: { root.watchQuery = modelData; watchField.text = modelData; root.searchWatch(modelData); }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text { visible: root.watchBusy; text: "SEARCHING"; color: th.bar; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4 }
                }
                ListView {
                    id: watchList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.watchRows
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: GlassScroll { }
                    delegate: Rectangle {
                        width: watchList.width
                        height: 62
                        radius: 13
                        color: watchRowMa.containsMouse ? root.rgba(th.accent, 0.10) : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 12
                            Art {
                                width: 82; height: 46; corner: 9
                                seed: index
                                source: root.art(modelData.thumb || "")
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text { Layout.fillWidth: true; text: modelData.title || ""; color: th.text; font.pixelSize: (11) * root.ts; font.bold: true; elide: Text.ElideRight }
                                Text {
                                    text: (modelData.artist || "") + (modelData.duration_ms > 0 ? ("  \u00b7  " + root.fmt(modelData.duration_ms)) : "")
                                    color: root.rgba(th.dim, 0.7); font.pixelSize: (8.5) * root.ts
                                }
                            }
                            Rectangle {
                                width: 66; height: 26; radius: 13
                                color: playMa.containsMouse ? root.rgba(th.accent, 0.30) : root.rgba(th.accent, 0.16)
                                border.width: 1; border.color: root.rgba(th.accent, 0.45)
                                Behavior on color { ColorAnimation { duration: 130 } }
                                Text { anchors.centerIn: parent; text: "WATCH"; color: th.accent; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1 }
                                MouseArea {
                                    id: playMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.watchThis(modelData.url || modelData.id, modelData.title) }
                                }
                            }
                        }
                        // hover only: a stray click must never start a two hour
                        // download. acceptedButtons: NoButton is the important
                        // part - a MouseArea with no handler still sits on top
                        // and eats the WATCH button's clicks underneath it.
                        MouseArea {
                            id: watchRowMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.NoButton
                        }
                    }
                }
            }

            // -------- transport --------
            Item {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: 74
                visible: root.watch.path.length > 3
                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 22; anchors.rightMargin: 22
                    anchors.topMargin: 6; anchors.bottomMargin: 12
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14
                        Text {
                            Layout.fillWidth: true
                            text: root.watch.title || ""
                            color: th.text; font.pixelSize: (11) * root.ts; font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: watchPlayer.errorString.length > 0
                            text: watchPlayer.errorString
                            color: "#ff9a8b"; font.pixelSize: (8) * root.ts
                        }
                        Text {
                            text: root.fmt(watchPlayer.position) + "  /  " + root.fmt(watchPlayer.duration)
                            color: root.rgba(th.dim, 0.8); font.pixelSize: (8.5) * root.ts; font.family: "Consolas"
                        }
                        GlowButton { label: "\u2039 BROWSE"; bh: 24; onClicked: { root.watchBrowse() } }
                        GlowButton { label: "CLOSE"; bh: 24; onClicked: { watchPanel.hide() } }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 14
                        Rectangle {
                            width: 34; height: 34; radius: 17
                            color: root.rgba(th.accent, 0.18)
                            border.width: 1; border.color: root.rgba(th.accent, 0.5)
                            Text {
                                anchors.centerIn: parent
                                text: watchPlayer.playbackState === MediaPlayer.PlayingState ? "\u23f8" : "\u25b6"
                                color: th.accent; font.pixelSize: (13) * root.ts
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: { root.playTap(); watchPlayer.playbackState === MediaPlayer.PlayingState ? watchPlayer.pressPause() : watchPlayer.pressPlay() }
                            }
                        }
                        Item {
                            Layout.fillWidth: true
                            height: 18
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width; height: 3; radius: 1.5
                                color: root.rgba(th.text, 0.14)
                                Rectangle {
                                    height: parent.height; radius: 1.5
                                    width: watchPlayer.duration > 0 ? parent.width * (watchPlayer.position / watchPlayer.duration) : 0
                                    color: th.accent
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(m) {
                                    root.playTap();
                                    if (watchPlayer.duration > 0)
                                        watchPlayer.setPosition(Math.max(0, Math.min(1, m.x / width)) * watchPlayer.duration);
                                }
                            }
                        }
                    }
                }
            }
        }
        // (the film's rounded-corner mask is gone: the stage now sits inside
        //  the shell's rounding, so there is nothing left to mask)
        MediaPlayer {
            id: watchPlayer
            // what the viewer asked for, kept apart from what the decoder is
            // doing: a re-buffer may only resume a film that is meant to be
            // playing, never one the viewer just paused
            property bool wantPlay: false
            property bool userPaused: false
            // the decoder is only attached while the sheet is on screen: a
            // closed panel used to keep the whole film's buffers resident.
            // tied to the panel's own visibility threshold so the film never
            // unloads part-way through the fade-out
            source: (watchPanel.visible && root.watch.path.length > 3)
                    ? ("file:///" + root.watch.path.replace(/\\/g, "/")) : ""
            audioOutput: AudioOutput { volume: 1.0 }
            videoOutput: watchOut
            onMediaStatusChanged: {
                if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) {
                    if (wantPlay && !userPaused) play();
                }
            }
            onSourceChanged: {
                userPaused = false;
                wantPlay = source.toString().length > 8;
                if (wantPlay) watchStart.restart(); else watchStart.stop();
            }
            function pressPlay() { userPaused = false; wantPlay = true; play(); }
            function pressPause() { userPaused = true; wantPlay = false; pause(); }
            onErrorOccurred: if (source.toString().length > 8) root.watch.error = errorString
        }
        Timer {
            id: watchStart
            interval: 260
            onTriggered: {
                if (watchPlayer.wantPlay && !watchPlayer.userPaused) watchPlayer.play();
            }
        }
        Shortcut { sequence: "Escape"; enabled: watchPanel.watchSlide > 0.4; onActivated: watchPanel.hide() }
    }

    // ================= IMPORT: a link becomes a room =================
    Item {
        id: importPanel
        z: 96
        anchors.fill: parent
        visible: importSlide > 0.002
        property real importSlide: 0
        property bool closing: false
        function show() {
            closing = false; importAnim.to = 1; importAnim.restart();
            importFocus.restart();
            root.dyeAt(0.5, 0.5);
        }
        function hide() { closing = true; importAnim.to = 0; importAnim.restart(); }
        NumberAnimation {
            id: importAnim
            target: importPanel; property: "importSlide"
            duration: importPanel.closing ? 200 : 380
            easing.type: importPanel.closing ? Easing.InCubic : Easing.OutQuint
        }
        opacity: importSlide
        Timer { id: importFocus; interval: 120; onTriggered: importField.input.forceActiveFocus() }
        Timer { id: importPoll; interval: 1400; repeat: true; onTriggered: root.pollImport() }
        Component.onCompleted: fetchJson("/playlist/import/status", function(d) {
            if (d && d.running) { root.importStatus = d; importPoll.restart(); }
        })

        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.46 * importPanel.importSlide)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); importPanel.hide() } }
        }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(780, root.width - 80)
            height: Math.min(620, root.height - 84)
            radius: 26
            color: "transparent"
            opacity: importPanel.importSlide
            scale: 0.97 + 0.03 * importPanel.importSlide
            transform: Translate { y: (1 - importPanel.importSlide) * 22 }

            GlassSurface { anchors.fill: parent; corner: 26; tintAlpha: 0.94; blurAmt: 1.0; blurMax: 80; shadowAmt: 0.7 }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 13

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    ColumnLayout {
                        spacing: 2
                        Text { text: "IMPORT A PLAYLIST"; color: th.text; font.pixelSize: (18) * root.ts; font.bold: true; font.letterSpacing: 1.6 }
                        Text {
                            text: "paste a youtube, soundcloud or spotify playlist link - every song and the cover art come with it"
                            color: root.rgba(th.dim, 0.7); font.pixelSize: (8.5) * root.ts
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 28; height: 28; radius: 14
                        color: impCloseMa.containsMouse ? root.rgba(th.accent, 0.18) : "transparent"
                        Text { anchors.centerIn: parent; text: "\u00d7"; color: root.rgba(th.text, 0.8); font.pixelSize: (16) * root.ts }
                        MouseArea { id: impCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); importPanel.hide() } }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 9
                    AField {
                        id: importField
                        Layout.fillWidth: true
                        placeholder: "https://open.spotify.com/playlist/...   ·   youtube.com/playlist?list=...   ·   soundcloud.com/.../sets/..."
                        text: root.importLink
                        onTextChanged: root.importLink = text
                        onAccepted: root.readImportLink()
                    }
                    GlowButton {
                        label: root.importBusy ? "READING" : "READ LINK"
                        bh: 34; glow: th.bar
                        onClicked: { root.readImportLink() }
                    }
                }

                // the other direction: a room as a file, and a file as a room
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    GlowButton { label: "EXPORT THIS ROOM .M3U8"; bh: 30; glow: th.accent; onClicked: { root.exportM3u() } }
                    Item { Layout.fillWidth: true }
                    AField {
                        id: m3uField
                        Layout.preferredWidth: 330
                        placeholder: "import an .m3u8: C:/Users/Owner/Music/list.m3u8"
                        onAccepted: root.importM3u(text)
                    }
                    GlowButton { label: "IMPORT"; bh: 30; glow: th.bar; onClicked: { root.importM3u(m3uField.text) } }
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.importError.length > 1
                    text: root.importError
                    color: "#ff9a8b"; font.pixelSize: (9) * root.ts; wrapMode: Text.WordWrap
                }

                // ---------- preview ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14
                    visible: root.importPreview !== null
                    Art {
                        width: 98; height: 98; corner: 14
                        seed: 7
                        source: (root.importPreview && root.importPreview.cover) ? root.art(root.importPreview.cover) : ""
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3
                        Text {
                            Layout.fillWidth: true
                            text: (root.importPreview && root.importPreview.name) ? root.importPreview.name : ""
                            color: th.text; font.pixelSize: (16) * root.ts; font.bold: true
                            elide: Text.ElideRight
                        }
                        Text {
                            text: ((root.importPreview && root.importPreview.source) ? ("" + root.importPreview.source).toUpperCase() : "")
                                  + "  \u00b7  " + ((root.importPreview && root.importPreview.count) || 0) + " songs  \u00b7  "
                                  + ((root.importPreview && root.importPreview.source === "spotify") ? "streams instantly" : "downloads in the background")
                            color: th.accent; font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "the playlist is created straight away with its own cover; each song lands as it is fetched. anything unavailable is listed here by name."
                            color: root.rgba(th.dim, 0.6); font.pixelSize: (8) * root.ts; wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            spacing: 8
                            GlowButton {
                                label: root.importBusy ? "WORKING" : "IMPORT"
                                bh: 30; glow: th.accent
                                onClicked: { root.startImport() }
                            }
                            GlowButton {
                                label: "OPEN THE ROOM"
                                bh: 30; glow: th.bar
                                visible: (root.importStatus.file || "").length > 4
                                onClicked: { root.openImported(); importPanel.hide(); }
                            }
                        }
                    }
                }

                // ---------- the room before the link arrives ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 12
                    visible: root.importPreview === null && root.importStatus.total === 0

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: ["youtube", "spotify", "soundcloud", "apple music"]
                            delegate: AChip {
                                label: ("" + modelData).toUpperCase()
                                glow: index === 1 ? th.accent : th.bar
                                onClicked: { root.importLink = index === 0 ? "https://www.youtube.com/playlist?list="
                                                   : index === 1 ? "https://open.spotify.com/playlist/"
                                                   : index === 2 ? "https://soundcloud.com/"
                                                   : "https://music.apple.com/";
                                    importField.input.forceActiveFocus();
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: "a link is all it needs"
                            color: root.rgba(th.dim, 0.55); font.pixelSize: (8) * root.ts
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Column {
                            anchors.centerIn: parent
                            width: Math.min(560, root.width - 160)
                            spacing: 13
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                text: "a playlist is a room. give it an address."
                                color: th.text; font.pixelSize: (15) * root.ts; font.bold: true
                            }
                            Text {
                                width: parent.width
                                text: "paste a playlist link and aethermix rebuilds it here: the name, the cover art, the running order, and every song it can fetch. nothing is guessed - songs that cannot be found are listed by name when the build finishes."
                                color: root.rgba(th.dim, 0.78); font.pixelSize: (9) * root.ts
                                wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                                lineHeight: 1.35
                            }
                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 26
                                Repeater {
                                    model: ["01  paste the link", "02  read it over", "03  build the room"]
                                    delegate: Text {
                                        text: modelData
                                        color: root.rgba(th.accent, 0.72)
                                        font.pixelSize: (7.5) * root.ts; font.bold: true; font.letterSpacing: 1.3
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- progress + the honest list ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: root.importStatus.total > 0
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: root.importStatus.running ? ("FETCHING " + root.importStatus.done + " / " + root.importStatus.total) : ("BUILT  " + root.importStatus.total + " SONGS")
                            color: root.importStatus.running ? th.bar : th.accent
                            font.pixelSize: (8) * root.ts; font.bold: true; font.letterSpacing: 1.4
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            visible: (root.importStatus.failed || []).length > 0
                            text: (root.importStatus.failed || []).length + " not found"
                            color: "#ff9a8b"; font.pixelSize: (8) * root.ts; font.bold: true
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 3; radius: 1.5
                        color: root.rgba(th.text, 0.10)
                        Rectangle {
                            height: parent.height; radius: 1.5
                            width: parent.width * (root.importStatus.total > 0 ? Math.min(1, root.importStatus.done / root.importStatus.total) : 0)
                            color: th.bar
                            Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                        }
                    }
                    ListView {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(120, Math.max(0, (root.importStatus.failed || []).length * 22))
                        visible: (root.importStatus.failed || []).length > 0
                        model: root.importStatus.failed || []
                        clip: true
                        delegate: RowLayout {
                            width: ListView.view.width
                            spacing: 8
                            Text { text: "\u00b7"; color: "#ff9a8b"; font.pixelSize: (11) * root.ts }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.title || "?"
                                color: root.rgba(th.text, 0.85); font.pixelSize: (9) * root.ts
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.preferredWidth: 220
                                text: modelData.error || "not found"
                                color: root.rgba(th.dim, 0.7); font.pixelSize: (7.5) * root.ts
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
                Text {
                    Layout.fillWidth: true
                    text: "large lists keep downloading after you close this panel - the shelf shows the count."
                    color: root.rgba(th.dim, 0.42); font.pixelSize: (8) * root.ts
                }
            }
        }
        Shortcut { sequence: "Escape"; enabled: importPanel.importSlide > 0.4; onActivated: importPanel.hide() }
    }

    // ================= FIND: one bar over youtube, soundcloud and spotify =================
    Item {
        id: findPanel
        z: 95
        anchors.fill: parent
        visible: findSlide > 0.002
        property real findSlide: 0
        property bool closing: false
        function show() {
            closing = false;
            findAnim.to = 1; findAnim.restart();
            // the field is not visible on the frame the panel opens, and an
            // invisible item cannot take focus: ask again once it is on screen
            findFocus.restart();
        }
        function hide() { closing = true; findAnim.to = 0; findAnim.restart(); }
        NumberAnimation {
            id: findAnim
            target: findPanel; property: "findSlide"
            duration: findPanel.closing ? 180 : 340
            easing.type: findPanel.closing ? Easing.InCubic : Easing.OutQuint
        }
        opacity: findSlide
        onVisibleChanged: if (visible) findFocus.restart()
        Timer { id: findFocus; interval: 90; onTriggered: findInput.input.forceActiveFocus() }

        Rectangle {
            anchors.fill: parent
            color: root.rgba("#000000", 0.42 * findPanel.findSlide)
            MouseArea { anchors.fill: parent; onClicked: { root.playTap(); root.closeFind() } }
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(760, root.width - 80)
            height: Math.min(612, root.height - 84)
            radius: 24
            color: "transparent"
            opacity: findPanel.findSlide
            scale: 0.97 + 0.03 * findPanel.findSlide
            transform: Translate { y: (1 - findPanel.findSlide) * 20 }

            GlassSurface { anchors.fill: parent; corner: 24; tintAlpha: 0.92; blurAmt: 1.0; blurMax: 80; shadowAmt: 0.68 }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: "FIND"
                        color: th.text; font.pixelSize: (17) * root.ts; font.bold: true; font.letterSpacing: 2
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "enter plays the first result"
                        color: root.rgba(th.dim, 0.5); font.pixelSize: (8) * root.ts
                    }
                    Rectangle {
                        width: 28; height: 28; radius: 14
                        color: findCloseMa.containsMouse ? root.rgba(th.accent, 0.18) : "transparent"
                        Text { anchors.centerIn: parent; text: "\u00d7"; color: root.rgba(th.text, 0.8); font.pixelSize: (16) * root.ts }
                        MouseArea { id: findCloseMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.playTap(); root.closeFind() } }
                    }
                }

                AField {
                    id: findInput
                    Layout.fillWidth: true
                    placeholder: "a song, an artist, a link to a playlist..."
                    text: root.findQ
                    onTextChanged: findDebounce.restart()
                    onAccepted: {
                        root.runSearch(findInput.text);
                        if (root.findRows.length > 0) root.useResult(root.findRows[0]);
                    }
                }
                Timer {
                    id: findDebounce
                    interval: 480
                    onTriggered: { root.findQ = findInput.text; root.runSearch(findInput.text); }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: [
                            { k: "all", l: "ALL SOURCES" },
                            { k: "youtube", l: "YOUTUBE" },
                            { k: "soundcloud", l: "SOUNDCLOUD" },
                            { k: "spotify", l: "SPOTIFY" }
                        ]
                        delegate: AChip {
                            label: modelData.l + ((modelData.k !== "all" && root.findCounts[modelData.k] > 0)
                                                  ? "  " + root.findCounts[modelData.k] : "")
                            sel: root.findSrc === modelData.k
                            glow: root.findSrc === modelData.k ? th.accent : th.text
                            onClicked: { root.findSrc = modelData.k; root.runSearch(findInput.text); }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.findBusy
                        text: "LISTENING..."
                        color: th.accent; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.4
                    }
                }

                Item { Layout.fillWidth: true; Layout.preferredHeight: 2 }

                ListView {
                    id: findList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.findRows
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: GlassScroll { }

                    delegate: Rectangle {
                        id: findRow
                        width: findList.width
                        height: 58
                        radius: 12
                        color: findRowMa.containsMouse ? root.rgba(th.accent, 0.09) : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            spacing: 11
                            Art {
                                width: 40; height: 40; corner: 9
                                seed: index
                                source: root.art(modelData.thumb || "")
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.title || ""
                                    color: th.text; font.pixelSize: (11) * root.ts; font.bold: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: (modelData.artist || "") + (modelData.duration_ms > 0 ? ("  \u00b7  " + root.fmt(modelData.duration_ms)) : "")
                                    color: root.rgba(th.dim, 0.7); font.pixelSize: (9) * root.ts
                                    elide: Text.ElideRight
                                }
                            }
                            Rectangle {
                                width: srcLbl.width + 14; height: 19; radius: 9.5
                                color: root.rgba(modelData.source === "spotify" ? "#1DB954" : (modelData.source === "soundcloud" ? "#ff7700" : "#ff4444"), 0.16)
                                Text {
                                    id: srcLbl
                                    anchors.centerIn: parent
                                    text: ("" + modelData.source).toUpperCase()
                                    color: modelData.source === "spotify" ? "#3ee37a" : (modelData.source === "soundcloud" ? "#ffa05c" : "#ff8a80")
                                    font.pixelSize: (6.5) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                }
                            }
                            Rectangle {
                                width: 46; height: 24; radius: 12
                                color: findPlayMa.containsMouse ? root.rgba(th.accent, 0.28) : root.rgba(th.accent, 0.14)
                                border.width: 1; border.color: root.rgba(th.accent, 0.5)
                                Text {
                                    anchors.centerIn: parent
                                    text: "PLAY"
                                    color: th.accent; font.pixelSize: (7) * root.ts; font.bold: true; font.letterSpacing: 1.1
                                }
                                MouseArea {
                                    id: findPlayMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.useResult(modelData) }
                                }
                            }
                            Rectangle {
                                width: 26; height: 24; radius: 12
                                color: findAddMa.containsMouse ? root.rgba(th.text, 0.14) : "transparent"
                                border.width: 1; border.color: root.rgba(th.text, 0.18)
                                Text {
                                    anchors.centerIn: parent; text: "+"; color: root.rgba(th.text, 0.8)
                                    font.pixelSize: (13) * root.ts; font.bold: true
                                }
                                MouseArea {
                                    id: findAddMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.playTap(); root.importResult(modelData) }
                                }
                            }
                        }
                        MouseArea {
                            id: findRowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            z: -1
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: !root.findBusy && root.findRows.length === 0 && findInput.text.length > 0
                    text: root.findError.length > 1 ? root.findError : "nothing yet - try a different spelling, or another source"
                    color: root.rgba(th.dim, 0.6); font.pixelSize: (9) * root.ts
                    wrapMode: Text.WordWrap
                }
                Text {
                    Layout.fillWidth: true
                    text: root.ytAddState.running
                          ? "adding " + (root.ytAddState.current_title || "a song") + "  \u00b7  " + (root.ytAddState.done || 0) + " done"
                          : "youtube and soundcloud results are fetched at full quality, tagged, then played locally"
                    color: root.ytAddState.running ? th.accent : root.rgba(th.dim, 0.42)
                    font.pixelSize: (8) * root.ts
                    elide: Text.ElideRight
                }
            }
        }
        Shortcut {
            sequence: "Escape"
            enabled: findPanel.findSlide > 0.4
            onActivated: root.closeFind()
        }
    }

    // viewport masks for the scrolling surfaces (never painted)
    FadeMask { id: listMask; width: listFlick.width; height: listFlick.height; topFade: 0.05; bottomFade: 0.12 }
    FadeMask { id: localMask; width: localFlick.width; height: localFlick.height; topFade: 0.04; bottomFade: 0.12 }
    FadeMask { id: lyricMask; width: lyricFlick.width; height: lyricFlick.height; topFade: 0.10; bottomFade: 0.16 }
    FadeMask { id: queueMask; width: qFlick.width; height: qFlick.height; topFade: 0.04; bottomFade: 0.14 }
    FadeMask { id: homeMask; width: homeFlick.width; height: homeFlick.height; topFade: 0; bottomFade: 0.05 }

}
