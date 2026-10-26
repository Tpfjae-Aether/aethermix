// lang: QML, file: MiniBar.qml
// The room in your pocket: when the shell is minimized the song keeps playing,
// so it needs a body on the desktop. This is a separate frameless window shown
// only while the main window is minimized (Main.qml owns its lifetime), with
// what a transport actually needs - art, title, skip, play, volume - and the
// smallest possible edge: one breathing card, no title bar, no menu.
//
// It talks to the shell through `host`, the ApplicationWindow that created it,
// so it reads the same state (and the same theme) and calls the same endpoints:
// nothing is duplicated, and the two windows can never disagree about the song.
import QtQuick
import QtQuick.Window
import QtQuick.Effects

Window {
    id: mini

    // the ApplicationWindow that created this window; null-safe everywhere
    property var host: null
    // the shell's clock is parked while minimized, so the mini keeps its own
    property real pos: 0
    // 0 = sunk below the desktop edge, 1 = at rest. The whole card rides this
    // one number, so arriving and leaving are the same motion played backwards.
    property real appear: 0

    NumberAnimation {
        id: riseAnim
        target: mini; property: "appear"
        to: 1; duration: 320; easing.type: Easing.OutQuint
    }
    SequentialAnimation {
        id: sinkAnim
        NumberAnimation {
            target: mini; property: "appear"
            to: 0; duration: 210; easing.type: Easing.InCubic
        }
        ScriptAction { script: mini.visible = false }
    }

    width: 488
    height: 84
    visible: false
    color: "transparent"
    title: "AetherMix"
    // DoesNotAcceptFocus: minimizing the room must not pull the keyboard away
    // from whatever the person switched to.
    flags: Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
           | Qt.WindowDoesNotAcceptFocus

    // Bottom right of the screen the app is on, not of the virtual desktop.
    // A new window with no parent can be handed the wrong monitor by the
    // window manager (it landed on the second display here), so the corner is
    // computed from the host's screen and written in screen coordinates.
    readonly property var hostScreen: (host && host.screen) ? host.screen : Screen
    function place() {
        var scr = hostScreen;
        // This Windows/Qt pair reports the whole virtual desktop in
        // desktopAvailableWidth (3840 for a 1920 panel), so take the smaller of
        // the screen's own size and the desktop area that follows its origin.
        var sw = Math.max(640, Math.min(scr.width, scr.desktopAvailableWidth - scr.virtualX));
        var sh = Math.max(480, Math.min(scr.height, scr.desktopAvailableHeight - scr.virtualY));
        x = Math.round(scr.virtualX + sw - width - 18);
        y = Math.round(scr.virtualY + sh - height - 18);
    }
    Component.onCompleted: place()

    readonly property color ink: (host && host.th) ? host.th.text : "#ffffff"
    readonly property color dim: (host && host.th) ? host.th.dim : "#9aa3b2"
    readonly property color accent: (host && host.th) ? host.th.accent : "#7cf0c0"
    readonly property color room: (host && host.th) ? host.th.bg : "#07080c"
    readonly property color accent2: (host && host.th) ? host.th.bar : "#69e7ff"
    readonly property string family: (host && host.tf) ? host.tf : "Segoe UI"
    readonly property real ts: (host && host.ts) ? host.ts : 1
    readonly property var song: (host && host.s) ? host.s : ({})
    readonly property real duration: song.duration_ms || 0
    readonly property bool playing: song.playing === true
    readonly property real volume: (song.volume || 0) / 100
    readonly property bool hasArt: song.cover_url !== undefined && song.cover_url !== null && song.cover_url.length > 4

    // The collapsed window carries the room with it. Studio chooses which part:
    // the scene the app lives in (its accent blooming into its floor), or the
    // record on the platter (the sleeve, spread under the glass). Both are the
    // same card; only the floor changes, and it cross-fades rather than swaps.
    readonly property string back: (host && host.miniBackdrop) ? host.miniBackdrop : "theme"
    // a plain property, not readonly: a Behavior cannot animate a read-only
    // binding, and the failure aborts the whole component
    property real bgMix: (back === "song" && hasArt) ? 1 : 0
    Behavior on bgMix { NumberAnimation { duration: 460; easing.type: Easing.InOutCubic } }

    // a 25 Hz clock is enough for a 3 px line at this size, and it costs nothing
    // while the window is hidden
    Timer {
        interval: 40
        repeat: true
        running: mini.visible && mini.playing && mini.duration > 0
        onTriggered: {
            var p = (mini.host.anchorPos || 0) + (Date.now() - (mini.host.anchorAt || 0));
            mini.pos = Math.max(0, Math.min(mini.duration, p));
        }
    }
    onVisibleChanged: if (visible) {
        if (visibility === Window.Minimized) showNormal();
        place();
        if (host) mini.pos = host.posMs;
    }

    // Windows minimizes owned tool windows along with their owner, so a bar
    // that was hidden once and shown again comes back iconic (160x28 in the
    // corner). Summoning forces the windowed state after it is made visible.
    function summon() {
        sinkAnim.stop();
        visible = true;
        if (visibility === Window.Minimized) showNormal();
        place();
        if (appear > 0.98) return;
        appear = 0;
        riseAnim.restart();
    }
    // leave the way it arrived: the card slides back under the edge and fades.
    // The window is hidden at the end of the motion, not at its start, so the
    // bar and the returning room overlap for a beat instead of cutting.
    function dismiss() {
        if (!visible) return;
        riseAnim.stop();
        sinkAnim.restart();
    }

    function restore() {
        if (!mini.host) { mini.dismiss(); return; }
        // the room is already on its way back under the bar, and the bar
        // dissolves on top of it: one hand-off, not two cuts
        mini.host.showNormal();
        mini.host.raise();
        mini.host.requestActivate();
        mini.dismiss();
    }

    // ---------------- the card ----------------
    Rectangle {
        id: card
        anchors.fill: parent
        anchors.margins: 6
        radius: 22
        opacity: mini.appear
        scale: 0.975 + mini.appear * 0.025
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.10)
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.90) }
            GradientStop { position: 1; color: Qt.rgba(mini.room.r * 0.7, mini.room.g * 0.7, mini.room.b * 0.7, 0.94) }
        }

        // ---------------- the floor: theme world or sleeve ----------------
        // One masked layer holds the whole backdrop so it takes the card's own
        // corner radius; the mask is the same trick the sleeve uses.
        Item {
            id: face
            anchors.fill: parent
            anchors.margins: 1
            layer.enabled: true
            layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask }

            // the room's air: accent on the left, its floor on the right
            Rectangle {
                anchors.fill: parent
                opacity: 1 - mini.bgMix
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: Qt.rgba(mini.accent.r, mini.accent.g, mini.accent.b, 0.46) }
                    GradientStop { position: 0.34; color: Qt.rgba(mini.accent2.r, mini.accent2.g, mini.accent2.b, 0.20) }
                    GradientStop { position: 0.62; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.88) }
                    GradientStop { position: 1.00; color: Qt.rgba(mini.room.r * 0.55, mini.room.g * 0.55, mini.room.b * 0.68, 0.96) }
                }
            }
            // a light from above, so the bar has a top and a bottom
            Rectangle {
                anchors.fill: parent
                opacity: 1 - mini.bgMix
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                    GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.0) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.22) }
                }
            }

            // the record: the sleeve itself, spread wide and softened by scale
            Image {
                anchors.fill: parent
                visible: mini.hasArt
                source: mini.hasArt ? mini.song.cover_url : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize.width: 512
                scale: 1.04
                opacity: mini.bgMix * 0.80
            }
            // and a wash over it, heaviest under the words and the transport
            Rectangle {
                anchors.fill: parent
                opacity: mini.bgMix
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.00; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.30) }
                    GradientStop { position: 0.34; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.60) }
                    GradientStop { position: 0.72; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.86) }
                    GradientStop { position: 1.00; color: Qt.rgba(mini.room.r, mini.room.g, mini.room.b, 0.94) }
                }
            }
        }
        Rectangle { id: faceMask; anchors.fill: face; radius: 21; visible: false; layer.enabled: true }

        // a single sheen along the top edge: glass, not a panel
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: 1
            height: 20; radius: 21
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.12) }
                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
            }
        }

        // drag the bar anywhere that is not a control, double-click to go back
        // the card itself is the thing that arrives, so it also carries the
        // lift: a 26 px rise reads as the bar coming up from the desktop edge
        transform: Translate { y: (1 - mini.appear) * 26 }

        MouseArea {
            anchors.fill: parent
            onPressed: mini.startSystemMove()
            onDoubleClicked: mini.restore()
            onWheel: function(w) {
                if (!mini.host) return;
                mini.host.setVolume((mini.song.volume || 0) + (w.angleDelta.y > 0 ? 4 : -4));
            }
        }

        // ---------------- art ----------------
        Item {
            id: artBox
            x: 14; anchors.verticalCenter: parent.verticalCenter
            width: 48; height: 48
            layer.enabled: true
            layer.effect: MultiEffect { maskEnabled: true; maskSource: artMask }
            Rectangle {
                anchors.fill: parent
                radius: 13
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(mini.accent.r, mini.accent.g, mini.accent.b, 0.50) }
                    GradientStop { position: 1; color: Qt.rgba(mini.accent.r * 0.2, mini.accent.g * 0.2, mini.accent.b * 0.3, 0.9) }
                }
            }
            Image {
                anchors.fill: parent
                visible: mini.hasArt
                source: mini.hasArt ? mini.song.cover_url : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize.width: 192
            }
        }
        Rectangle { id: artMask; anchors.fill: artBox; radius: 13; visible: false; layer.enabled: true }

        // ---------------- title, artist, thread ----------------
        Column {
            x: 74
            width: parent.width - 74 - 244
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                text: (mini.song.title && mini.song.title.length) ? mini.song.title : "nothing playing"
                color: mini.ink
                font.family: mini.family; font.pixelSize: 13 * mini.ts; font.bold: true
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: (mini.song.artist && mini.song.artist.length) ? mini.song.artist : "pick a track"
                color: Qt.rgba(mini.dim.r, mini.dim.g, mini.dim.b, 0.85)
                font.family: mini.family; font.pixelSize: 10 * mini.ts
                elide: Text.ElideRight
            }
            Item { width: 1; height: 4 }
            // the thread: how far the song has come, drawn to the pixel
            Item {
                width: parent.width; height: 3
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 3; radius: 1.5
                    color: Qt.rgba(1, 1, 1, 0.10)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * (mini.duration > 0 ? Math.max(0, Math.min(1, mini.pos / mini.duration)) : 0)
                    height: 3; radius: 1.5
                    antialiasing: true
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: mini.accent }
                        GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0.85) }
                    }
                }
            }
        }

        // ---------------- controls: one row, measured right to left ----------------
        Row {
            id: transport
            anchors.right: parent.right; anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            // volume
            Item {
                width: 46; height: 26
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width; height: 3; radius: 1.5
                    color: Qt.rgba(1, 1, 1, volMa.containsMouse || volMa.pressed ? 0.22 : 0.11)
                    Behavior on color { ColorAnimation { duration: 130 } }
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width * Math.max(0, Math.min(1, mini.volume))
                    height: 3; radius: 1.5
                    antialiasing: true
                    color: Qt.rgba(mini.ink.r, mini.ink.g, mini.ink.b, 0.62)
                }
                Rectangle {
                    visible: volMa.containsMouse || volMa.pressed
                    width: 8; height: 8; radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    x: Math.max(0, Math.min(parent.width - width, parent.width * Math.max(0, Math.min(1, mini.volume)) - width / 2))
                    color: mini.ink
                    border.width: 1
                    border.color: Qt.rgba(0, 0, 0, 0.35)
                }
                MouseArea {
                    id: volMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    function apply(x) {
                        if (!mini.host) return;
                        mini.host.setVolume(Math.max(0, Math.min(1, x / width)) * 100);
                    }
                    onPressed: function(m) { mini.host.playTap(); apply(m.x); }
                    onPositionChanged: if (pressed) apply(mouse.x)
                }
            }

            Item { width: 2; height: 1 }

            // previous
            Item {
                width: 24; height: 28
                opacity: prevMa.containsMouse ? 1 : 0.72
                Behavior on opacity { NumberAnimation { duration: 130 } }
                MiniGlyph { anchors.centerIn: parent; kind: "prev"; col: mini.ink; size: 13 }
                MouseArea {
                    id: prevMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { mini.host.playTap(); mini.host.hit("/prev"); }
                }
            }

            // play / pause, the one solid object in the bar
            Item {
                width: 38; height: 38
                Rectangle {
                    anchors.fill: parent
                    radius: 19
                    color: Qt.rgba(mini.accent.r, mini.accent.g, mini.accent.b, playMa.containsMouse ? 0.34 : 0.22)
                    border.width: 1
                    border.color: Qt.rgba(mini.accent.r, mini.accent.g, mini.accent.b, playMa.containsMouse ? 0.75 : 0.45)
                    Behavior on color { ColorAnimation { duration: 130 } }
                }
                Item {
                    anchors.centerIn: parent
                    width: 13; height: 13
                    // two shapes, no font: the pause marks carry the same weight
                    // as the triangle, so the button never changes size
                    Canvas {
                        anchors.fill: parent
                        visible: mini.playing
                        onPaint: {
                            var c = getContext("2d");
                            c.reset();
                            var w = width, h = height;
                            c.fillStyle = mini.ink;
                            c.fillRect(w * 0.14, h * 0.10, w * 0.24, h * 0.80);
                            c.fillRect(w * 0.62, h * 0.10, w * 0.24, h * 0.80);
                        }
                        Connections { target: mini; function onPlayingChanged() { parent.requestPaint() } }
                    }
                    Canvas {
                        anchors.fill: parent
                        visible: !mini.playing
                        onPaint: {
                            var c = getContext("2d");
                            c.reset();
                            var w = width, h = height;
                            c.fillStyle = mini.ink;
                            c.beginPath();
                            c.moveTo(w * 0.18, h * 0.08);
                            c.lineTo(w * 0.94, h * 0.50);
                            c.lineTo(w * 0.18, h * 0.92);
                            c.closePath();
                            c.fill();
                        }
                    }
                }
                MouseArea {
                    id: playMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { mini.host.playTap(); mini.host.hit("/toggle"); }
                }
            }

            // next
            Item {
                width: 24; height: 28
                opacity: nextMa.containsMouse ? 1 : 0.72
                Behavior on opacity { NumberAnimation { duration: 130 } }
                MiniGlyph { anchors.centerIn: parent; kind: "next"; col: mini.ink; size: 13 }
                MouseArea {
                    id: nextMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { mini.host.playTap(); mini.host.hit("/next"); }
                }
            }

            // bring the room back
            Item {
                width: 26; height: 26
                Rectangle {
                    anchors.fill: parent
                    radius: 13
                    color: Qt.rgba(1, 1, 1, restMa.containsMouse ? 0.13 : 0.05)
                    border.width: 1
                    border.color: Qt.rgba(1, 1, 1, restMa.containsMouse ? 0.24 : 0.09)
                    Behavior on color { ColorAnimation { duration: 130 } }
                }
                MiniGlyph { anchors.centerIn: parent; kind: "up"; col: Qt.rgba(mini.ink.r, mini.ink.g, mini.ink.b, 0.85); size: 10 }
                MouseArea {
                    id: restMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mini.restore()
                }
            }
        }
    }

    // a 1.5 px stroke icon set, drawn rather than typed: no font can drift
    component MiniGlyph : Canvas {
        id: g
        property string kind: "play"
        property color col: "#ffffff"
        property real size: 12
        width: size; height: size
        onKindChanged: requestPaint()
        onColChanged: requestPaint()
        onPaint: {
            var c = getContext("2d");
            c.reset();
            var w = width, h = height;
            c.strokeStyle = g.col;
            c.fillStyle = g.col;
            c.lineWidth = Math.max(1.2, w * 0.11);
            c.lineCap = "round";
            c.lineJoin = "round";
            if (g.kind === "prev" || g.kind === "next") {
                var dir = g.kind === "prev" ? -1 : 1;
                c.beginPath();
                c.moveTo(w * (0.62 - dir * 0.20), h * 0.16);
                c.lineTo(w * (0.62 + dir * 0.24), h * 0.50);
                c.lineTo(w * (0.62 - dir * 0.20), h * 0.84);
                c.closePath();
                c.fill();
                c.beginPath();
                c.moveTo(w * (0.22 - dir * 0.06), h * 0.16);
                c.lineTo(w * (0.22 - dir * 0.06), h * 0.84);
                c.stroke();
            } else if (g.kind === "up") {
                c.beginPath();
                c.moveTo(w * 0.22, h * 0.62);
                c.lineTo(w * 0.50, h * 0.34);
                c.lineTo(w * 0.78, h * 0.62);
                c.stroke();
            }
        }
    }
}
