import SwiftUI
import Foundation
import UIKit

// The room behind everything. Not an image: four slow light fields and a thin
// dust of motes, all derived from the theme, so every palette gets its own
// weather. It runs at 30fps and stops when the system asks for less motion.
struct Atmosphere: View {
    @Environment(\.look) private var look
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: calm)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    look.theme.bgColor
                    blob(look.theme.accentColor, size: w * 1.05,
                         at: CGPoint(x: w * (0.30 + 0.06 * sin(t * 0.11)),
                                     y: h * (0.24 + 0.05 * cos(t * 0.09))),
                         opacity: 0.24)
                    blob(look.theme.barColor, size: w * 0.95,
                         at: CGPoint(x: w * (0.74 + 0.05 * cos(t * 0.08 + 1)),
                                     y: h * (0.38 + 0.06 * sin(t * 0.07))),
                         opacity: 0.20)
                    blob(look.theme.secondColor, size: w * 1.25,
                         at: CGPoint(x: w * (0.52 + 0.07 * sin(t * 0.05 + 2)),
                                     y: h * (0.82 + 0.04 * cos(t * 0.06))),
                         opacity: 0.18)
                    // the studio's tint and bloom are part of the weather
                    Rectangle()
                        .fill(look.theme.barColor)
                        .opacity(look.tint * 0.14)
                        .blendMode(.softLight)
                        .allowsHitTesting(false)
                    // a low vignette keeps the glass reading as glass
                    RadialGradient(colors: [.clear, look.theme.bgColor.opacity(0.78)],
                                   center: .center, startRadius: w * 0.30, endRadius: w * 1.1)
                        .blendMode(.multiply)
                    motes(t: t, size: geo.size)
                }
            }
            .ignoresSafeArea()
        }
    }

    // A light field, not a blurred disc. A real gaussian blur on a view this
    // large re-rasterises every frame and leaves the after-image banding the
    // desktop had; a radial gradient with the theme's bloom folded into its
    // falloff is smooth at any size and costs one fill.
    private func blob(_ color: Color, size: CGFloat, at p: CGPoint, opacity: Double) -> some View {
        let falloff = CGFloat(0.42 + look.blur / 320.0)
        let o = opacity * (look.theme.light == true ? 0.7 : 1)
        return Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: color.opacity(o), location: 0),
                    .init(color: color.opacity(o * 0.55), location: min(0.9, falloff)),
                    .init(color: color.opacity(0), location: 1)
                ],
                center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .position(p)
            .blendMode(.plusLighter)
    }

    private func motes(t: Double, size: CGSize) -> some View {
        Canvas { ctx, canvas in
            let count = 26
            let w = canvas.width
            let h = canvas.height
            for i in 0..<count {
                let seed = Double(i) * 12.9898
                let x = CGFloat(sin(seed) * 0.5 + 0.5) * w
                let span = Double(h) + 80
                let drift = CGFloat((t * (4 + Double(i % 5)) + seed * 30)
                    .truncatingRemainder(dividingBy: span))
                let y = h + 40 - drift
                let r = CGFloat(0.6 + (sin(seed * 3) * 0.5 + 0.5) * 1.6)
                let col = i % 3 == 0 ? look.theme.barColor : look.theme.accentColor
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(col.opacity(0.10 + 0.06 * sin(t + seed))))
            }
        }
        .allowsHitTesting(false)
    }
}

// Cover art with the disc sliding out from behind it. Tap the sleeve to open
// the immersive room; the disc keeps spinning while the record plays.
struct VinylSleeve: View {
    @Environment(\.look) private var look
    var title: String
    var artist: String
    var cover: String?
    var playing: Bool
    var onOpen: () -> Void = {}

    @State private var out = false

    var body: some View {
        ZStack(alignment: .leading) {
            // the disc. only this subtree re-renders on the frame clock, so the
            // sleeve and its artwork keep their cached image
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { timeline in
                let t = timeline.date.timeIntervalSince1970
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.92))
                    ForEach(0..<7) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.05), lineWidth: 0.6)
                            .padding(CGFloat(10 + i * 7))
                    }
                    artwork
                        .clipShape(Circle())
                        .padding(58)
                    Circle()
                        .fill(look.theme.bgColor)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 232, height: 232)
                .rotationEffect(.degrees((t * 22).truncatingRemainder(dividingBy: 360)))
            }
            .offset(x: out ? 116 : 44)
            .opacity(out ? 1 : 0.0)
            .scaleEffect(out ? 1 : 0.86)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)

            // the sleeve
            artwork
                .frame(width: 214, height: 214)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.55), radius: 26, y: 16)
        }
        .frame(height: 250)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) { out = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) by \(artist). Open immersive player.")
    }

    private var artwork: some View {
        Group {
            if let s = cover, let u = Bridge.shared.coverURL(s) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else {
                        ZStack {
                            look.theme.panelColor
                            Image(systemName: "music.note")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(look.theme.dimColor)
                        }
                    }
                }
            } else {
                ZStack {
                    look.theme.panelColor
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(look.theme.dimColor)
                }
            }
        }
    }
}

struct Equalizer: View {
    @Environment(\.look) private var look
    var levels: [Double]
    var active: Bool
    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSince1970
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<16, id: \.self) { i in
                    let src = levels.isEmpty ? 0 : levels[min(i, levels.count - 1)]
                    let wobble = active ? 0.18 * (0.5 + 0.5 * sin(t * 2.2 + Double(i) * 0.7)) : 0
                    let h = CGFloat(4 + (src * 0.85 + wobble) * 28)
                    Capsule()
                        .fill(LinearGradient(colors: [look.theme.accentColor, look.theme.barColor],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(width: 2.5, height: max(3, min(34, h)))
                }
            }
            .frame(height: 40, alignment: .bottom)
            .opacity(active ? 1 : 0.35)
        }
    }
}

// The bottom dock. Nothing is outlined; the selected room is a brighter piece
// of glass that slides between icons.
struct GlassDock: View {
    @Environment(\.look) private var look
    @Binding var room: SourceRoom
    @Namespace private var ns
    var onPick: (SourceRoom) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SourceRoom.allCases) { r in
                let on = r == room
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        room = r
                        onPick(r)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: r.glyph)
                            .font(.system(size: 17, weight: on ? .semibold : .regular))
                        Text(r.rawValue)
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                    }
                    .foregroundStyle(on ? look.theme.textColor : look.theme.dimColor.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(look.theme.accentColor.opacity(0.16))
                                .matchedGeometryEffect(id: "dock", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glass(radius: 26, strength: 1.25)
        .padding(.horizontal, 14)
    }
}

// A scroll that dissolves at both ends instead of being clipped by a line.
struct FadeEdges: ViewModifier {
    var top: CGFloat = 18
    var bottom: CGFloat = 22
    func body(content: Content) -> some View {
        content.mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: top / 320),
                .init(color: .black, location: 1 - bottom / 320),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

extension View {
    func fadeEdges(top: CGFloat = 18, bottom: CGFloat = 22) -> some View {
        modifier(FadeEdges(top: top, bottom: bottom))
    }
}

struct SectionLabel: View {
    @Environment(\.look) private var look
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(look.theme.dimColor.opacity(0.62))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
