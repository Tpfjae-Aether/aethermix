// lang: QML, file: DyeWash.qml
// A room change is a drop of ink in water, not a slide. The wash blooms from
// the point you travelled from, curls into filaments, dyes the room in the
// incoming palette and is gone by the time the new page has settled.
//
// It is deliberately *not* a snapshot/refraction pass: capturing a 1280x760
// screen every transition costs more than the effect is worth on this GPU.
// Instead the shader paints soft, turbulence-warped ink over the living UI at
// a low alpha, so the interface reads *through* the dye.
//
// Qt 6 does not accept inline GLSL: `fragmentShader` is a URL to a .qsb baked
// with the Qt shader tools. The source lives in shaders/dye.frag and the body
// is the same wash this file used to carry as a string.
import QtQuick

ShaderEffect {
    id: dye
    property real progress: 0.0
    property real seed: 0.37
    property vector2d origin: Qt.vector2d(0.5, 0.5)
    property color inkA: "#00ffa3"
    property color inkB: "#041018"
    property real strength: 1.0
    property real grain: 0.55

    // the wash is purely additive colour in alpha; no depth, no texture reads
    blending: true
    visible: progress > 0.001

    fragmentShader: "shaders/dye.frag.qsb"
}
