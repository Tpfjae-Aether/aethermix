// lang: QML, file: Background3D.qml
// genuine 3D animated backgrounds - one scene per theme, parameterized.
//
// The rule of this file: nothing may look *placed*. Every object gets a halo,
// a contact shadow of light, or an atmospheric wash so it belongs to the air
// around it. Archetypes:
//   bubbles | veil | rain | orbit | drift | sunrings | prims | embers
//   grid | gyro | orb | silk | stained | streaks | vapor | gears | motes
import QtQuick
import QtQuick.Window
import QtQuick3D
import QtQuick3D.Helpers
import QtQuick3D.Particles3D

Item {
    id: bg
    property var pal: ({ accent: "#00ff7f", bar: "#00ffff", bg: "#010814", dim: "#8fc7e8" })
    property string archetype: "bubbles"
    property var cfg: ({})
    property real speed: 1.0
    property real intensity: 1.0
    property real flowDir: 1.0
    property real kick: 0
    property real yaw: 0
    property real pitch: 0
    property real zoom: 1.0
    property real excite: 0
    property real audio: 0
    // The shell's quality governor writes this once if a room cannot hold the
    // display's cadence. It only ever steps down, so a room cannot oscillate
    // between detail levels; 1.0 is the room as designed.
    property real quality: 1.0

    // the room is heavy: gestures and resets glide instead of stepping
    Behavior on yaw { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    Behavior on pitch { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    Behavior on zoom { NumberAnimation { duration: 360; easing.type: Easing.OutCubic } }

    // the world stops when the window is in the tray or minimised
    // the world stops when the window is in the tray, minimised, or behind
    // another app. a hidden 60fps 3D scene is the largest cost this file has,
    // and nothing is lost: the room resumes on the frame the window returns.
    readonly property bool awake: bg.Window.window
        ? (bg.Window.window.visible
           && bg.Window.window.visibility !== Window.Minimized
           && bg.Window.window.active)
        : true
    visible: awake

    function p(k, d) { return (cfg && cfg[k] !== undefined) ? cfg[k] : d; }
    readonly property bool light: pal.light === true
    readonly property color a1: pal.accent
    readonly property color a2: pal.bar
    readonly property color a3: pal.accent2 ? pal.accent2 : pal.bar
    // one breath drives every halo in the room, so the whole scene inhales
    // together instead of a dozen little loops drifting out of phase
    property real breath: 0.86
    SequentialAnimation on breath {
        loops: Animation.Infinite
        NumberAnimation { to: 1.06; duration: 6200 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
        NumberAnimation { to: 0.84; duration: 7600 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
    }

    // ---------------------------------------------------------------- textures
    readonly property string texDir: Qt.resolvedUrl("../assets").toString() + "/"

    // a soft billboard of light: the atmospheric brush every scene is painted
    // with. it always faces the lens, so orbiting never turns it into a card.
    component SoftGlow : Model {
        id: sgl
        property color tint: "#ffffff"
        property real w: 500
        property real h: 500
        property real strength: 0.4
        property string tex: "glow.png"
        property real spin: 0
        source: "#Rectangle"
        scale: Qt.vector3d(sgl.w / 100, sgl.h / 100, 1)
        eulerRotation.y: -bg.yaw
        eulerRotation.z: sgl.spin
        materials: PrincipledMaterial {
            lighting: PrincipledMaterial.NoLighting
            baseColor: sgl.tint
            baseColorMap: Texture { source: bg.texDir + sgl.tex }
            opacity: sgl.strength * bg.breath * (0.75 + 0.25 * bg.intensity)
            alphaMode: PrincipledMaterial.Blend
            cullMode: PrincipledMaterial.NoCulling
            depthDrawMode: Material.NeverDepthDraw
        }
    }

    // the painted vista: full-bleed, crisp, parallaxed by the camera
    Image {
        id: vista
        anchors.fill: parent
        anchors.margins: -22
        source: (cfg && cfg.backdrop) ? "file:///" + cfg.backdrop : ""
        visible: !!source && status === Image.Ready
        fillMode: Image.PreserveAspectCrop
        smooth: true
        mipmap: true
        opacity: Math.min(0.97, p("bdOp", 0.82) * 1.45)
        asynchronous: true
        cache: false
        x: -bg.yaw * 2.4
        y: -bg.pitch * 1.5
        scale: 1.06
        Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
    }
    Rectangle {
        anchors.fill: parent
        color: bg.pal.bg
        opacity: p("bdVeil", bg.light ? 0.30 : 0.04)
    }
    // a light wash from the top corner: every room has one source of daylight
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0; color: rootAlpha(bg.a1, bg.light ? 0.10 : 0.07) }
            GradientStop { position: 0.45; color: rootAlpha(bg.a1, 0.0) }
            GradientStop { position: 1; color: rootAlpha(bg.pal.bg, bg.light ? 0.24 : 0.15) }
        }
    }
    function rootAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // When a full-window overlay owns the screen (the immersive stage, the
    // film watcher) the room is covered but would keep rendering. Hiding the
    // view stops the whole 3D pass; the air layer stops with it.
    property bool paused: false

    View3D {
        id: view
        visible: !bg.paused
        anchors.fill: parent
        // Plain SceneEnvironment, not the extended one. ExtendedSceneEnvironment
        // runs its own full-screen post pass even when every effect in it is
        // switched off; the room does not need its tonemap, and the pass cost a
        // millisecond this frame could not spare.
        //
        // MSAA stays on: the room is full of hard-edged spheres, rings and
        // plates turning against a bright backdrop, and without it every one of
        // them crawls along its silhouette as it moves - which reads as shimmer
        // no matter how well the frames are paced. the governor is the only
        // thing allowed to turn it off, and only if the room really cannot run.
        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Transparent
            clearColor: bg.pal.bg
            antialiasingMode: bg.quality > 0.55 ? SceneEnvironment.MSAA : SceneEnvironment.NoAA
            antialiasingQuality: bg.quality > 0.8 ? SceneEnvironment.High : SceneEnvironment.Medium
        }

        PerspectiveCamera {
            id: cam
            readonly property real radius: Math.max(190, p("camZ", 400) / Math.max(0.62, bg.zoom))
            readonly property real orbitRad: bg.yaw * Math.PI / 180
            position: Qt.vector3d(
                Math.sin(orbitRad) * radius + p("camX", 0) + bg.kick * 10,
                p("camY", 70) + bg.pitch * 2.4 + bg.kick * 2.5,
                Math.cos(orbitRad) * radius + bg.kick * 8
            )
            eulerRotation.x: p("camTilt", -10) + bg.pitch * 0.7 + bg.kick * 1.2
            eulerRotation.y: -bg.yaw + bg.kick * 1.2
            SequentialAnimation on eulerRotation.z {
                loops: Animation.Infinite
                NumberAnimation { to: 1.2; duration: 11000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                NumberAnimation { to: -1.2; duration: 11000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
            }
            SequentialAnimation on position.y {
                loops: Animation.Infinite
                NumberAnimation { to: p("camY", 70) + 40; duration: 7000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                NumberAnimation { to: p("camY", 70); duration: 7000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
            }
        }

        DirectionalLight {
            eulerRotation.x: -32
            eulerRotation.y: 24
            brightness: p("sun", 1.6) * (1 + bg.excite * 0.22)
            color: bg.pal.bar
            ambientColor: bg.pal.bg
        }
        PointLight {
            position: Qt.vector3d(0, 180, 60)
            color: bg.pal.accent
            brightness: 0.3 + bg.audio * 2.2 + bg.excite * 1.6
            quadraticFade: 1.1
        }
        PointLight {
            id: pulseLight
            position: Qt.vector3d(p("lx", -160), p("ly", 150), p("lz", 190))
            color: bg.pal.accent
            brightness: p("lightB", 3.0)
            quadraticFade: 1.4
            SequentialAnimation on brightness {
                loops: Animation.Infinite
                NumberAnimation { to: p("lightB", 3.0) * 1.6; duration: 2400 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                NumberAnimation { to: p("lightB", 3.0) * 0.6; duration: 2400 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
            }
        }
        PointLight {
            position: Qt.vector3d(210, -60, 120)
            color: bg.pal.bar
            brightness: 2.2
            quadraticFade: 1.4
        }
        // rim: a cool light from behind the objects so their silhouettes lift
        // off the painting instead of sitting flat on it
        PointLight {
            position: Qt.vector3d(0, 60, -420)
            color: bg.a3
            brightness: p("rim", 2.4)
            quadraticFade: 1.0
        }

        // the room's air is painted into the world image now; the lens only
        // adds light where an object actually sits
        // ------------------------------------------------------------ bubbles
        Repeater3D {
            model: bg.archetype === "bubbles" ? Math.max(8, Math.round(p("count", 26) * (0.5 + 0.5 * bg.quality))) : 0
            delegate: Node {
                id: bubble
                readonly property real seed: index * 2.399
                readonly property real s: p("size", 0.22) + ((index * 53) % 100) / 100 * p("sizeVar", 0.3)
                x: Math.sin(seed) * p("spread", 330)
                z: Math.cos(seed * 1.7) * p("depth", 300) - 100
                y: ((index * 97) % 340) - 200
                // the glow sits behind the glass: a bubble carries its own light
                SoftGlow {
                    visible: index % 2 === 0
                    position: Qt.vector3d(0, 0, -26)
                    w: 120 + bubble.s * 260
                    h: 120 + bubble.s * 260
                    strength: 0.16 + bubble.s * 0.10
                    tint: index % 4 === 0 ? bg.a2 : bg.a1
                }
                Model {
                    source: "#Sphere"
                    scale: Qt.vector3d(bubble.s, bubble.s, bubble.s)
                    materials: PrincipledMaterial {
                        baseColor: bg.pal.accent
                        metalness: 0.04
                        roughness: 0.035
                        // the glass is the most expensive thing this room
                        // draws (a transmission pass over the whole scene);
                        // the governor trades it for a solid, still-shaded
                        // bubble before it gives up the frame rate.
                        transmissionFactor: bg.quality > 0.55 ? 0.9 : 0.0
                        thicknessFactor: 4
                        attenuationColor: bg.pal.bar
                        attenuationDistance: 12
                        clearcoatAmount: 1.0
                        clearcoatRoughnessAmount: 0.03
                        emissiveFactor: Qt.vector3d(0.10, 0.10, 0.10)
                    }
                }
                // the seed inside the glass: this is the detail that reads as
                // depth instead of a hollow ball
                Model {
                    source: "#Sphere"
                    scale: Qt.vector3d(bubble.s * 0.34, bubble.s * 0.34, bubble.s * 0.34)
                    x: bubble.s * 14
                    y: -bubble.s * 10
                    materials: PrincipledMaterial {
                        baseColor: bg.a2
                        roughness: 0.25
                        metalness: 0.55
                        emissiveFactor: Qt.vector3d(0.35, 0.35, 0.35)
                    }
                }
                SequentialAnimation on y {
                    loops: Animation.Infinite
                    NumberAnimation { to: ((index * 97) % 340) - 40; duration: (4600 + (index % 6) * 800) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: ((index * 97) % 340) - 280; duration: (4600 + (index % 5) * 700) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
                SequentialAnimation on x {
                    loops: Animation.Infinite
                    NumberAnimation { to: Math.sin(bubble.seed) * p("spread", 330) + 46; duration: (5200 + (index % 7) * 600) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: Math.sin(bubble.seed) * p("spread", 330) - 46; duration: (5600 + (index % 5) * 500) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
            }
        }

        // ------------------------------------------------------------ veil
        Repeater3D {
            model: bg.archetype === "veil" ? p("planes", 7) : 0
            delegate: Model {
                source: "#Rectangle"
                readonly property real zStep: index * p("zGap", -95)
                position: Qt.vector3d(
                    Math.sin(index * p("xWobble", 1.2)) * p("xOff", 60),
                    Math.cos(index * 0.9) * p("yOff", 40),
                    zStep
                )
                readonly property real pw: p("tall", 0) === 1 ? p("w", 3.2) : p("w", 7.5)
                scale: Qt.vector3d(pw + index * 0.5, p("h", 4.4) + index * 0.3, 1)
                eulerRotation.x: -90 + Math.sin(index) * p("tilt", 26)
                eulerRotation.y: Math.cos(index * 1.4) * p("yaw", 30)
                // the cloth never ends on a straight line: a feathered opacity
                // map eats every border, so planes dissolve into the air instead
                // of reading as translucent rectangles laid over the screen
                materials: PrincipledMaterial {
                    baseColorMap: Texture { source: cfg.panelTex ? "file:///" + cfg.panelTex : "" }
                    alphaMode: PrincipledMaterial.Blend
                    opacity: (p("op", 0.17) * 1.25 + (index % 3) * 0.035) * (0.86 + 0.14 * bg.breath)
                    metalness: 0.0
                    roughness: 1.0
                    opacityMap: Texture { source: bg.texDir + "feather.png" }
                    emissiveMap: Texture { source: cfg.panelTex ? "file:///" + cfg.panelTex : "" }
                    emissiveFactor: Qt.vector3d(1.5, 1.5, 1.5)
                    cullMode: PrincipledMaterial.NoCulling
                }
                SequentialAnimation on eulerRotation.y {
                    loops: Animation.Infinite
                    NumberAnimation { to: Math.cos(index * 1.4) * p("yaw", 30) + p("sway", 14); duration: (8000 + index * 1300) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: Math.cos(index * 1.4) * p("yaw", 30) - p("sway", 14); duration: (8000 + index * 1300) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
                SequentialAnimation on position.y {
                    loops: Animation.Infinite
                    NumberAnimation { to: Math.cos(index * 0.9) * p("yOff", 40) + p("bob", 34); duration: (9000 + index * 800) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: Math.cos(index * 0.9) * p("yOff", 40) - p("bob", 34); duration: (9000 + index * 800) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
            }
        }
        // veil gets real light shafts falling through the cloth
        Repeater3D {
            model: bg.archetype === "veil" ? 4 : 0
            delegate: SoftGlow {
                position: Qt.vector3d(-260 + index * 170, 40 + (index % 2) * 60, -120 - index * 40)
                w: 150 + index * 30
                h: 900
                strength: 0.10 + (index % 2) * 0.04
                tint: index % 2 === 0 ? bg.a1 : bg.a2
                tex: "shaft.png"
                spin: index % 2 === 0 ? 7 : -6
            }
        }

        // The sprite emitter that lived here is gone: its specks were moved
        // by the 3D renderer, so they stepped with the frame rate and carried
        // a soft halo that read as an after-image. The air is now drawn as a
        // time-driven 2D layer (MoteField, below) over the room: continuous at
        // any frame rate, one sprite per mote, no trail.

        // ------------------------------------------------------------ vapor
        SoftGlow {
            visible: bg.archetype === "vapor"
            position: Qt.vector3d(0, 150, -180)
            w: 900; h: 900
            strength: 0.34
            tint: bg.a2
        }
        Model {
            visible: bg.archetype === "vapor"
            source: "#Rectangle"
            position: Qt.vector3d(0, 150, -80)
            scale: Qt.vector3d(7, 7, 1)
            eulerRotation.x: -8
            materials: PrincipledMaterial {
                baseColorMap: Texture { source: Qt.resolvedUrl("../assets/themes/vapor_sun.png") }
                alphaMode: PrincipledMaterial.Blend
                emissiveMap: Texture { source: Qt.resolvedUrl("../assets/themes/vapor_sun.png") }
                emissiveFactor: Qt.vector3d(1.2, 1.2, 1.2)
                cullMode: PrincipledMaterial.NoCulling
                lighting: PrincipledMaterial.NoLighting
            }
            SequentialAnimation on position.y {
                loops: Animation.Infinite
                NumberAnimation { to: 170; duration: 9000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                NumberAnimation { to: 130; duration: 9000 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
            }
        }
        Repeater3D {
            model: bg.archetype === "vapor" ? 9 : 0
            delegate: Model {
                source: "#Rectangle"
                readonly property real rowZ: -120 - index * index * 6
                position: Qt.vector3d(0, -140, rowZ)
                scale: Qt.vector3d(14 + index * 3, 0.055, 1)
                eulerRotation.x: -90
                materials: PrincipledMaterial {
                    baseColor: bg.pal.bar
                    emissiveFactor: Qt.vector3d(1.1, 1.1, 1.1)
                    lighting: PrincipledMaterial.NoLighting
                }
                opacity: 0.85 - index * 0.08
            }
        }
        Repeater3D {
            model: bg.archetype === "vapor" ? 7 : 0
            delegate: Model {
                source: "#Rectangle"
                readonly property real lx: (index - 3) * 90
                position: Qt.vector3d(lx * 2.2, -140, 40)
                scale: Qt.vector3d(0.05, 1.0 + lx / 90, 1)
                eulerRotation.x: -90
                materials: PrincipledMaterial {
                    baseColor: bg.pal.accent
                    emissiveFactor: Qt.vector3d(0.9, 0.9, 0.9)
                    lighting: PrincipledMaterial.NoLighting
                }
                opacity: 0.5
            }
        }

        // ------------------------------------------------------------ gears
        Repeater3D {
            model: bg.archetype === "gears" ? p("gearCount", 3) : 0
            delegate: Node {
                readonly property real gs: p("gearSize", 4.4) - index * 1.1
                position: Qt.vector3d(p("gx0", -150) + index * p("gxStep", 170), p("gy0", 40) + (index % 2) * 60, -60 - index * 30)
                SoftGlow {
                    z: -40
                    w: 460 * gs
                    h: 460 * gs
                    strength: 0.12
                    tint: bg.a3
                }
                Model {
                    source: "#Rectangle"
                    scale: Qt.vector3d(gs, gs, 1)
                    eulerRotation.x: 18 + index * 9
                    materials: PrincipledMaterial {
                        baseColorMap: Texture { source: Qt.resolvedUrl("../assets/themes/clockwork_gear.png") }
                        alphaMode: PrincipledMaterial.Blend
                        emissiveMap: Texture { source: Qt.resolvedUrl("../assets/themes/clockwork_gear.png") }
                        emissiveFactor: Qt.vector3d(p("gearGlow", 0.35), p("gearGlow", 0.35), p("gearGlow", 0.35))
                        cullMode: PrincipledMaterial.NoCulling
                    }
                    NumberAnimation on eulerRotation.z {
                        loops: Animation.Infinite
                        from: 0
                        to: index % 2 === 0 ? 360 : -360
                        duration: (24000 + index * 11000) / Math.max(0.3, bg.speed) * (index % 2 === 0 ? 1 : 1.5)
                    }
                }
            }
        }

        // ------------------------------------------------------------ orbit
        Node {
            id: orbitRoot
            visible: bg.archetype === "orbit"
            position: Qt.vector3d(0, 20, -80)
            SoftGlow {
                w: 760; h: 760
                strength: 0.20
                tint: bg.a2
            }
            Repeater3D {
                model: bg.archetype === "orbit" ? p("bodies", 5) : 0
                delegate: Node {
                    readonly property real tilt: p("oTilt", 40) + index * 28
                    readonly property real rx: p("oRx", 200) + index * 40
                    readonly property real ry: p("oRy", 70) + index * 22
                    eulerRotation.x: tilt
                    NumberAnimation on eulerRotation.z {
                        loops: Animation.Infinite
                        from: 0; to: 360
                        duration: (26000 + index * 9000) / Math.max(0.3, bg.speed)
                    }
                    Node {
                        x: rx
                        Model {
                            source: "#Sphere"
                            readonly property real s: p("oSize", 0.5)
                            scale: Qt.vector3d(s, s, s)
                            materials: PrincipledMaterial {
                                baseColor: bg.pal.accent
                                metalness: p("oMetal", 0.95)
                                roughness: p("oRough", 0.12)
                                emissiveFactor: Qt.vector3d(0.08, 0.08, 0.08)
                            }
                        }
                        SoftGlow {
                            z: -30
                            w: 220
                            h: 220
                            strength: 0.16
                            tint: bg.a1
                        }
                    }
                    Node {
                        x: -rx * 0.8
                        Model {
                            source: "#Sphere"
                            readonly property real s2: p("oSize", 0.5) * 0.55
                            scale: Qt.vector3d(s2, s2, s2)
                            materials: PrincipledMaterial {
                                baseColor: bg.pal.bar
                                metalness: p("oMetal", 0.95)
                                roughness: 0.10
                            }
                        }
                        SoftGlow {
                            z: -20
                            w: 150; h: 150
                            strength: 0.12
                            tint: bg.a2
                        }
                    }
                }
            }
            Model {
                source: "#Sphere"
                scale: Qt.vector3d(p("cSize", 1.4), p("cSize", 1.4), p("cSize", 1.4))
                materials: PrincipledMaterial {
                    baseColor: bg.pal.bar
                    metalness: 0.9
                    roughness: 0.05
                    emissiveFactor: Qt.vector3d(0.2, 0.2, 0.2)
                }
            }
            SoftGlow {
                w: 420; h: 420
                strength: 0.24
                tint: bg.a3
            }
            // a halo ring around the core: the orbit itself becomes visible
            SoftGlow {
                w: 620; h: 620
                strength: 0.16
                tint: bg.a1
                tex: "glow_ring.png"
                spin: 12
            }
        }

        // ------------------------------------------------------------ prims
        // Bauhaus / low-poly used to be flat discs floating in a void. They are
        // now thin physical plates: a lit face, a dark edge, a halo of their own
        // colour, and a slow float that belongs to the composition.
        Repeater3D {
            model: bg.archetype === "prims" ? p("discs", 4) : 0
            delegate: Node {
                id: plate
                readonly property real s: p("dSize", 1.1) + (index % 3) * 0.5
                readonly property real halo: p("dHalo", 1)
                position: Qt.vector3d(
                    Math.sin(index * 2.4) * p("dSpread", 220),
                    Math.cos(index * 1.8) * 90,
                    -index * p("dDepth", 110)
                )
                eulerRotation.x: 60 + index * p("dTilt", 12)
                SoftGlow {
                    z: -60
                    w: 300 + plate.s * 220
                    h: 300 + plate.s * 220
                    strength: (bg.light ? 0.10 : 0.16) * plate.halo
                    tint: [bg.a1, bg.a2, bg.a3, bg.a1][index % 4]
                }
                Model {
                    source: "#Cylinder"
                    scale: Qt.vector3d(plate.s, p("dThick", 0.035), plate.s)
                    materials: PrincipledMaterial {
                        baseColor: [bg.pal.accent, bg.pal.bar, bg.pal.dim, bg.pal.accent][index % 4]
                        metalness: p("dMetal", 0.0)
                        roughness: p("dRough", 0.5)
                        emissiveFactor: Qt.vector3d(0.10, 0.10, 0.10)
                    }
                }
                // the rim catches the room light: a thin larger plate behind
                Model {
                    source: "#Cylinder"
                    scale: Qt.vector3d(plate.s * 1.06, 0.012, plate.s * 1.06)
                    y: -2
                    materials: PrincipledMaterial {
                        baseColor: [bg.a2, bg.a3, bg.a1, bg.a2][index % 4]
                        metalness: 0.3
                        roughness: 0.2
                        emissiveFactor: Qt.vector3d(0.35, 0.35, 0.35)
                    }
                }
                SequentialAnimation on eulerRotation.z {
                    loops: Animation.Infinite
                    NumberAnimation { to: 40; duration: (7000 + index * 2000) / Math.max(0.3, bg.speed); easing.type: Easing.InOutQuad }
                    NumberAnimation { to: -40; duration: (7000 + index * 2000) / Math.max(0.3, bg.speed); easing.type: Easing.InOutQuad }
                }
                SequentialAnimation on y {
                    loops: Animation.Infinite
                    NumberAnimation { to: Math.cos(index * 1.8) * 90 + 26; duration: (8200 + index * 900) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: Math.cos(index * 1.8) * 90 - 26; duration: (9000 + index * 700) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
            }
        }

        // ------------------------------------------------------------ grid
        Node {
            id: gridRoot
            visible: bg.archetype === "grid"
            position: Qt.vector3d(0, -120, -160)
            eulerRotation.x: p("gTilt", 24)
            SoftGlow {
                position: Qt.vector3d(0, 30, 0)
                w: 1100; h: 700
                strength: 0.14
                tint: bg.a2
                tex: "haze.png"
            }
            Repeater3D {
                model: bg.archetype === "grid" ? p("gx", 7) * p("gy", 5) : 0
                delegate: Model {
                    source: "#Sphere"
                    readonly property real s: p("gNode", 0.07)
                    scale: Qt.vector3d(s, s, s)
                    position: Qt.vector3d(
                        ((index % p("gx", 7)) - 3) * p("gGap", 90),
                        0,
                        (Math.floor(index / p("gx", 7)) - 2) * p("gGap", 90)
                    )
                    materials: PrincipledMaterial {
                        baseColor: bg.pal.bar
                        metalness: 0.4
                        roughness: 0.3
                        emissiveFactor: Qt.vector3d(0.3, 0.3, 0.3)
                    }
                }
            }
            SoftGlow {
                z: -30
                w: 260; h: 260
                strength: 0.18
                tint: bg.a1
            }
            Model {
                id: gridPulse
                source: "#Sphere"
                readonly property real ps: p("gPulse", 0.16)
                readonly property real gx3: 3 * p("gGap", 90)
                readonly property real gz2: 2 * p("gGap", 90)
                property real px: -gx3
                property real pz: -gz2
                position: Qt.vector3d(px, 0, pz)
                scale: Qt.vector3d(ps, ps, ps)
                materials: PrincipledMaterial {
                    baseColor: bg.pal.accent
                    emissiveFactor: Qt.vector3d(1.4, 1.4, 1.4)
                }
                SequentialAnimation on px {
                    loops: Animation.Infinite
                    PauseAnimation { duration: 300 }
                    NumberAnimation { to: gridPulse.gx3; duration: 900 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: -gridPulse.gx3; duration: 900 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: -gridPulse.gx3; duration: 700 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
                SequentialAnimation on pz {
                    loops: Animation.Infinite
                    PauseAnimation { duration: 300 }
                    NumberAnimation { to: -gridPulse.gz2; duration: 700 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: gridPulse.gz2; duration: 700 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: -gridPulse.gz2; duration: 900 / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
            }
        }

        // ------------------------------------------------------------ sunrings
        Node {
            id: gyroRoot
            visible: bg.archetype === "sunrings" || bg.archetype === "gyro"
            position: Qt.vector3d(0, p("gy0", 40), -60)
            // the core is a lamp: the halo is what makes the rings read as lit
            SoftGlow {
                w: p("coreHalo", 900); h: p("coreHalo", 900)
                strength: 0.28
                tint: bg.a1
            }
            SoftGlow {
                w: p("coreHalo", 900) * 1.6; h: p("coreHalo", 900) * 1.6
                strength: 0.12
                tint: bg.a2
            }
            Repeater3D {
                model: (bg.archetype === "sunrings" || bg.archetype === "gyro") ? p("rings", 3) : 0
                delegate: Node {
                    readonly property int ringIdx: index
                    readonly property real ringR: p("r0", 150) + index * p("rGap", 95)
                    eulerRotation.x: p("rTilt", 24) + index * 52
                    eulerRotation.z: index * 30
                    NumberAnimation on eulerRotation.y {
                        loops: Animation.Infinite
                        from: 0; to: 360
                        duration: (30000 + index * 11000) / Math.max(0.3, bg.speed)
                    }
                    Repeater3D {
                        model: p("nodes", 18)
                        delegate: Model {
                            source: "#Sphere"
                            readonly property real a: index * (Math.PI * 2 / p("nodes", 18))
                            position: Qt.vector3d(
                                Math.cos(a) * ringR,
                                Math.sin(a * 2.0) * 14,
                                Math.sin(a) * ringR
                            )
                            scale: Qt.vector3d(p("nSize", 0.09), p("nSize", 0.09), p("nSize", 0.09))
                            materials: PrincipledMaterial {
                                baseColor: ringIdx === 0 ? bg.pal.accent : (ringIdx === 1 ? bg.pal.bar : bg.pal.dim)
                                metalness: p("nMetal", 0.6)
                                roughness: 0.2
                                emissiveFactor: Qt.vector3d(p("nGlow", 0.85), p("nGlow", 0.85), p("nGlow", 0.85))
                            }
                        }
                    }
                }
            }
            Model {
                source: "#Sphere"
                scale: Qt.vector3d(p("coreR", 1.05), p("coreR", 1.05), p("coreR", 1.05))
                materials: PrincipledMaterial {
                    baseColor: bg.pal.accent
                    metalness: 0.1
                    roughness: 0.05
                    transmissionFactor: p("coreGlass", 0.9)
                    thicknessFactor: 9
                    attenuationColor: bg.pal.bar
                    attenuationDistance: 14
                    clearcoatAmount: 1.0
                    emissiveFactor: Qt.vector3d(p("coreGlow", 0.12), p("coreGlow", 0.12), p("coreGlow", 0.12))
                }
            }
        }

        // ------------------------------------------------------------ orb
        Repeater3D {
            model: bg.archetype === "orb" ? p("count", 9) : 0
            delegate: Node {
                readonly property real seed: index * 1.618
                readonly property real s: 0.32 + ((index * 37) % 100) / 100 * 0.42
                position: Qt.vector3d(
                    Math.sin(seed) * 320,
                    ((index * 61) % 160) - 60,
                    Math.cos(seed * 1.3) * 300 - 120
                )
                SoftGlow {
                    z: -40
                    w: 260 + s * 300
                    h: 260 + s * 300
                    strength: 0.14
                    tint: index % 2 === 0 ? bg.a1 : bg.a2
                }
                Model {
                    source: "#Sphere"
                    scale: Qt.vector3d(s, s, s)
                    materials: PrincipledMaterial {
                        baseColor: index % 3 === 0 ? bg.pal.accent : (index % 3 === 1 ? bg.pal.bar : bg.pal.dim)
                        metalness: index % 2 === 0 ? 0.15 : 0.75
                        roughness: index % 2 === 0 ? 0.08 : 0.28
                        transmissionFactor: index % 4 === 0 ? 0.75 : 0.0
                        thicknessFactor: 6
                        attenuationColor: bg.pal.accent
                        attenuationDistance: 18
                        clearcoatAmount: 1.0
                        clearcoatRoughnessAmount: 0.06
                        emissiveFactor: index % 2 === 0 ? Qt.vector3d(0.22, 0.22, 0.22) : Qt.vector3d(0.05, 0.05, 0.05)
                    }
                }
                SequentialAnimation on position.y {
                    loops: Animation.Infinite
                    NumberAnimation { to: ((index * 61) % 160) - 20; duration: (5200 + (index % 5) * 900) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                    NumberAnimation { to: ((index * 61) % 160) - 90; duration: (5200 + (index % 7) * 700) / Math.max(0.3, bg.speed); easing.type: Easing.InOutSine }
                }
                NumberAnimation on eulerRotation.y {
                    loops: Animation.Infinite
                    from: 0; to: 360
                    duration: (26000 + (index % 6) * 4000) / Math.max(0.3, bg.speed)
                }
            }
        }
    }

    // Air in front of the camera. Dust wanders, rain falls, embers rise warm;
    // one layer for every room, tuned by its weather rather than a second
    // particle engine per archetype.
    MoteField {
        anchors.fill: parent
        visible: !bg.paused
        kind: bg.archetype === "rain" ? "rain" : (bg.archetype === "embers" ? "embers" : "dust")
        speed: bg.speed * (bg.archetype === "streaks" ? 1.6 : 1.0)
        dir: bg.flowDir
        // the room's own light level: bright themes carry less visible dust
        intensity: (bg.light ? 0.62 : 1.0) * (0.78 + bg.audio * 0.35)
        seed: bg.archetype.length * 1.7 + bg.speed
    }
}
