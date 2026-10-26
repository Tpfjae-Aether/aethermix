// lang: QML, file: MediaBackdrop.qml
// the room's wallpaper when it is not a theme: a still, a gif, a film or a
// clip pulled from a link. one item, one half-resolution capture, one shader
// pass: blur, hue rotation, saturation, brightness and tint all happen in the
// same draw, so a 1440p film as a backdrop still costs less than the 3D world.

import QtQuick
import QtMultimedia

Item {
    id: bd

    // { kind, source, opacity, blur, tint, tintAmt, hue, sat, bright, zoom, drift }
    property var look: ({})
    property string kind: "theme"
    property string mediaSource: ""
    property bool failed: false
    property string lastError: ""

    readonly property real amt: (look.opacity !== undefined) ? look.opacity : 0.72
    readonly property real blurAmt: (look.blur !== undefined) ? look.blur : 0.25
    readonly property real hueAmt: (look.hue !== undefined) ? look.hue : 0
    readonly property real satAmt: (look.sat !== undefined) ? look.sat : 1
    readonly property real brightAmt: (look.bright !== undefined) ? look.bright : 1
    readonly property real tintAmt: (look.tintAmt !== undefined) ? look.tintAmt : 0
    readonly property real zoomAmt: (look.zoom !== undefined) ? look.zoom : 1
    readonly property real driftAmt: (look.drift !== undefined) ? look.drift : 0.3

    readonly property bool isVideo: kind === "video"
    readonly property bool isGif: kind === "gif"
    readonly property bool isStill: kind === "image" || kind === "cover"
    readonly property bool on: kind !== "theme" && mediaSource.length > 3

    opacity: on ? amt : 0
    // `visible: on` was a cut, not a fade: leaving a tab tore the wallpaper
    // out of the frame while the 620ms fade-out was still starting, so the
    // room snapped back to bare 3D and then the wash underneath it moved. The
    // item now stays visible while it has any opacity left, so it fades out.
    visible: opacity > 0.004
    Behavior on opacity { NumberAnimation { duration: 620; easing.type: Easing.OutCubic } }
    // 0..1: how much of the wallpaper is actually in the room right now. The
    // page's own scrim reads this instead of toggling on a bool, so a tab
    // change carries the wash with the picture.
    readonly property real presence: (on && amt > 0.02) ? Math.min(1, opacity / amt) : 0

    // the wallpaper we are actually loading. a new picture fades the old one
    // down first, swaps behind the dark, and rises - never a hard cut
    property string shownSource: ""
    property real srcFade: 1
    onMediaSourceChanged: {
        if (mediaSource === shownSource) return;
        if ((shownSource || "").length < 4) { shownSource = mediaSource; srcFade = 1; return; }
        swapAnim.restart();
    }
    SequentialAnimation {
        id: swapAnim
        NumberAnimation { target: bd; property: "srcFade"; to: 0; duration: 150; easing.type: Easing.InCubic }
        PropertyAction { target: bd; property: "shownSource"; value: bd.mediaSource }
        NumberAnimation { target: bd; property: "srcFade"; to: 1; duration: 560; easing.type: Easing.OutCubic }
    }
    Component.onCompleted: if ((shownSource || "").length < 4) shownSource = mediaSource

    // a slow tide: even a still frame should breathe, or it reads as a screenshot
    property real phase: 0
    Timer {
        interval: 50; repeat: true; running: bd.visible
        onTriggered: bd.phase = (bd.phase + 0.008) % (Math.PI * 4)
    }

    Item {
        id: stage
        anchors.fill: parent
        opacity: bd.srcFade
        scale: bd.zoomAmt * (1 + bd.driftAmt * 0.012 * Math.sin(bd.phase))
        x: bd.driftAmt * 10 * Math.sin(bd.phase * 0.6)
        y: bd.driftAmt * 6 * Math.cos(bd.phase * 0.8)

        Image {
            anchors.fill: parent
            visible: bd.isStill
            source: bd.isStill && bd.visible ? bd.shownSource : ""
            fillMode: Image.PreserveAspectCrop
            // a 4K wallpaper decoded at 4K is 64 MB of texture for a blurred
            // background: decode to the window's width, not the file's
            sourceSize.width: Math.max(320, Math.round(bd.width * 1.05))
            asynchronous: true
            cache: false
            smooth: true
            mipmap: true
            onStatusChanged: if (status === Image.Error) bd.failed = true
        }

        AnimatedImage {
            anchors.fill: parent
            visible: bd.isGif
            source: bd.isGif && bd.visible ? bd.shownSource : ""
            fillMode: Image.PreserveAspectCrop
            playing: bd.visible
            cache: false
            onStatusChanged: if (status === AnimatedImage.Error) bd.failed = true
        }

        VideoOutput {
            id: videoOut
            anchors.fill: parent
            visible: bd.isVideo
            fillMode: VideoOutput.PreserveAspectCrop
        }
    }

    // a wallpaper has no voice: the film is routed to a silent sink
    AudioOutput { id: bgAudio; muted: true; volume: 0 }
    MediaPlayer {
        id: player
        source: (bd.isVideo && bd.visible) ? bd.shownSource : ""
        videoOutput: videoOut
        audioOutput: bgAudio
        loops: MediaPlayer.Infinite
        onMediaStatusChanged: {
            if (!bd.isVideo) return;
            if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia)
                play();
        }
        onErrorOccurred: if (bd.isVideo) { bd.failed = true; bd.lastError = errorString; }
    }

    // the graded image: a half-res capture is plenty under this much blur
    ShaderEffectSource {
        id: cap
        anchors.fill: parent
        sourceItem: stage
        hideSource: true
        live: bd.visible && !bd.isGif
        recursive: false
        textureSize: Qt.size(Math.max(64, Math.round(bd.width / 2)), Math.max(64, Math.round(bd.height / 2)))
        // a still frame is captured once; a gif needs its own clock
        onSourceItemChanged: scheduleUpdate()
    }
    // A gif is the only case the capture cannot be live: it needs its own
    // texture refresh. For a still or a film the capture is already live, so
    // this timer was forcing a second, synchronous render of the wallpaper
    // 25 times a second - a stutter you could set a watch by.
    Timer {
        interval: 40; repeat: true; running: bd.visible && bd.isGif
        onTriggered: cap.scheduleUpdate()
    }

    ShaderEffect {
        anchors.fill: parent
        property variant source: cap
        property real hueShift: bd.hueAmt
        property real sat: bd.satAmt
        property real bright: bd.brightAmt
        property color tintCol: (bd.look.tint && bd.look.tint.length > 3) ? bd.look.tint : "#000000"
        property real tintAmt: bd.tintAmt
        property real blurPx: bd.blurAmt * 26 * (bd.height / 760.0)
        property vector2d texel: Qt.vector2d(1.0 / Math.max(2, bd.width), 1.0 / Math.max(2, bd.height))
        // baked with qsb: hue, saturation, brightness, tint and a 12-tap blur in
        // one pass, so a film wallpaper costs less than a second layer
        fragmentShader: "shaders/grade.frag.qsb"
    }
}
