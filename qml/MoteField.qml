import QtQuick

// Air, not sparks.
//
// The 3D sprite emitter let the scene renderer move each speck: under load the
// position only changes when a frame lands, so a mote steps across the glass
// and - because the sprite carries a soft halo - reads as a ghost copy of
// itself dragging behind. This layer draws the same air with plain Qt Quick:
// one soft dot per mote, moved by time-based float animations, so motion is
// sub-pixel and continuous at any frame rate. There is no second copy, no
// trail, and no sprite system to keep alive on the GPU.
//
// Depth is implied the old way: near specks are larger and travel faster than
// far ones. Edges fade with position, so nothing ever pops in or out.
Item {
    id: field
    anchors.fill: parent
    clip: true

    property string kind: "dust"     // dust | rain | embers
    property real speed: 1.0
    property real dir: 1.0
    property real intensity: 0.85
    property real seed: 1.0
    property int count: kind === "rain" ? 40 : (kind === "embers" ? 26 : 34)

    readonly property bool wet: kind === "rain"
    readonly property bool hot: kind === "embers"
    readonly property string dot: hot
        ? Qt.resolvedUrl("../assets/mote_ember.png")
        : Qt.resolvedUrl("../assets/mote.png")

    opacity: Math.max(0, Math.min(1, intensity))

    function frac(v) { return v - Math.floor(v) }
    // deterministic scatter: the same field every launch, no Math.random at
    // construction (which would reshuffle on every reload)
    function rnd(i, k) {
        return frac(Math.sin((i + 1) * (12.9898 + k * 4.1414) + seed * 78.233) * 43758.5453)
    }

    Repeater {
        model: field.count
        delegate: Item {
            id: holder
            readonly property real r0: field.rnd(index, 1)
            readonly property real r1: field.rnd(index, 2)
            readonly property real r2: field.rnd(index, 3)
            readonly property real r3: field.rnd(index, 4)
            readonly property real r4: field.rnd(index, 5)
            readonly property real r5: field.rnd(index, 6)

            readonly property real moteW: field.wet ? 1.4 + r0 * 1.8
                                                 : (field.hot ? 7 + r0 * 20 : 9 + r0 * r0 * 62)
            readonly property real moteH: field.wet ? 26 + r1 * 58 : moteW
            // a near speck is bigger and covers ground faster, so the air has
            // depth without a camera to prove it
            readonly property real dur: (field.wet ? 3200 + r2 * 2600
                                          : (field.hot ? 13000 + r2 * 9000
                                                       : 26000 + r2 * 32000))
                                        * (0.55 + moteW / 190)
                                        / Math.max(0.25, field.speed)
            readonly property bool up: !field.wet && field.dir > 0
            readonly property real trip: field.height + moteH * 2
            readonly property real y0: field.height * r3 - moteH * 0.5
            readonly property real yTo: up ? -moteH : field.height + moteH
            readonly property real edge: Math.min(1, Math.min((y + moteH) / 130, (field.height - y) / 150))

            width: moteW
            height: moteH
            x: r4 * (field.width + moteW) - moteW
            y: y0
            rotation: field.wet ? -7 : 0
            property real sway: 0
            transform: Translate { x: holder.sway }

            Image {
                anchors.fill: parent
                source: field.dot
                smooth: true
                fillMode: Image.PreserveAspectCrop
                opacity: (field.hot ? 0.5 + r5 * 0.45 : 0.30 + r5 * 0.55) * holder.edge
            }

            // One partial trip from a scattered start, then a seamless wrap:
            // the field is already populated on the first frame, and a mote
            // that leaves the top re-enters from the floor with no jump.
            NumberAnimation {
                id: rise
                target: holder; property: "y"
                from: holder.y0
                to: holder.yTo
                duration: holder.dur * Math.abs(holder.yTo - holder.y0) / holder.trip
                easing.type: Easing.Linear
                running: field.visible
                onFinished: {
                    rise.from = holder.up ? field.height + holder.moteH : -holder.moteH
                    rise.duration = holder.dur
                    rise.loops = Animation.Infinite
                    rise.restart()
                }
            }

            // dust and embers wander sideways; rain falls where it falls
            SequentialAnimation on sway {
                running: field.visible && !field.wet
                loops: Animation.Infinite
                NumberAnimation {
                    to: 18 + holder.r1 * 22
                    duration: 7000 + holder.r2 * 11000
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: -18 - holder.r2 * 22
                    duration: 7000 + holder.r1 * 11000
                    easing.type: Easing.InOutSine
                }
            }
        }
    }
}
