import SwiftUI
import Foundation
import Combine
import UIKit

@MainActor
struct NowPlayingView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = true
    @State private var dragging = false
    @State private var dragValue: Double = 0

    private var e: PlayerEngine { app.engine }
    private var isLocal: Bool { e.localActive }
    private var title: String { isLocal ? e.localTitle : (e.remote.title.isEmpty ? "nothing playing" : e.remote.title) }
    private var artist: String { isLocal ? e.localArtist : e.remote.artist }
    private var playing: Bool { isLocal ? e.localPlaying : e.remote.playing }
    private var duration: Double { e.displayDuration() }
    private var cover: URL? {
        if isLocal { return nil }
        return e.remote.coverURL
    }
    // a stream the phone borrowed already decoded its cover; the URL path is
    // empty for it, which is why the room used to show a grey disc
    private var localArt: UIImage? { isLocal ? e.localArtwork : nil }

    var body: some View {
        ZStack {
            backdrop
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    topRow
                    artwork
                    titleBlock
                    scrubber
                    transport
                    if showLyrics {
                        LyricsPanel(engine: e, isLocal: isLocal)
                    }
                    colourFoot
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
            .fadeEdges(top: 6, bottom: 40)
        }
        .background(look.theme.bgColor)
        .statusBarHidden(false)
    }

    // ---------------------------------------------------------------- backdrop
    @ViewBuilder private var backdrop: some View {
        ZStack {
            if let art = localArt {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .overlay(look.theme.bgColor.opacity(0.55))
            } else if let u = cover {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                            .blur(radius: 60)
                            .overlay(look.theme.bgColor.opacity(0.55))
                    } else { Atmosphere() }
                }
            } else {
                Atmosphere()
            }
            LinearGradient(colors: [look.theme.bgColor.opacity(0.30), look.theme.bgColor.opacity(0.94), look.theme.bgColor],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // ------------------------------------------------------------------- top
    private var topRow: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glass(radius: 18, strength: 0.7)
                    .foregroundStyle(look.theme.textColor)
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("THE ROOM")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(look.theme.dimColor)
                Text(isLocal
                     ? (e.streamingDesktop ? "FROM THE DESKTOP" : "ON THIS PHONE")
                     : (e.remote.origin.isEmpty ? "DESKTOP" : e.remote.origin.uppercased()))
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(look.theme.accentColor.opacity(0.9))
            }
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } } label: {
                Image(systemName: showLyrics ? "text.alignleft" : "textformat")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glass(radius: 18, strength: 0.7)
                    .foregroundStyle(look.theme.textColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(look.theme.panelColor.opacity(0.4))
            if let art = localArt {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ArtworkView(url: cover)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if cover == nil && localArt == nil {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 54, weight: .ultraLight))
                    .foregroundStyle(look.theme.accentColor.opacity(0.45))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
        .padding(.horizontal, 6)
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(artist.isEmpty ? " " : artist)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(look.theme.dimColor)
                .lineLimit(1)
        }
    }

    // --------------------------------------------------------------- scrubber
    private var scrubber: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing || dragging)) { tl in
            let live = dragging ? dragValue : e.displayPosition(at: tl.date)
            let pct = duration > 0 ? min(1, max(0, live / duration)) : 0
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                        Capsule()
                            .fill(LinearGradient(colors: [look.theme.accentColor, look.theme.barColor],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(pct), height: 4)
                        Circle()
                            .fill(look.theme.textColor)
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, geo.size.width * CGFloat(pct) - 4.5))
                            .shadow(color: look.theme.accentColor.opacity(0.8), radius: 5)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                dragging = true
                                let f = min(1, max(0, g.location.x / max(1, geo.size.width)))
                                dragValue = Double(f) * duration
                            }
                            .onEnded { _ in
                                let target = dragValue
                                dragging = false
                                Task { await e.seek(seconds: target) }
                            }
                    )
                }
                .frame(height: 20)
                HStack {
                    Text(time(live))
                    Spacer()
                    Text("-" + time(max(0, duration - live)))
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(look.theme.dimColor.opacity(0.8))
            }
        }
    }

    private func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    // -------------------------------------------------------------- transport
    private var transport: some View {
        HStack(spacing: 26) {
            Button { Task { await e.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 19, weight: .semibold))
            }
            Button { Task { await e.toggle() } } label: {
                ZStack {
                    Circle().fill(look.theme.textColor)
                        .frame(width: 66, height: 66)
                        .shadow(color: look.theme.accentColor.opacity(0.35), radius: 18)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(look.theme.bgColor)
                        .offset(x: playing ? 0 : 1.5)
                }
            }
            Button { Task { await e.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 19, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(look.theme.textColor)
    }

    private var colourFoot: some View {
        HStack(spacing: 8) {
            Circle().fill(look.theme.accentColor).frame(width: 5, height: 5)
            Text(look.theme.name.uppercased())
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(look.theme.dimColor.opacity(0.6))
            if !isLocal && !e.remote.status.isEmpty {
                Text("·").foregroundStyle(look.theme.dimColor.opacity(0.4))
                Text(e.remote.status)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundStyle(look.theme.dimColor.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.top, 6)
    }
}

// The words own their clock. Re-rendering the artwork and the backdrop four
// times a second just to move a highlight made the room feel like it was
// stepping; here only this scroll redraws, and the index it follows is read
// from the same extrapolated position as the scrubber.
struct LyricsPanel: View {
    @ObservedObject var engine: PlayerEngine
    @Environment(\.look) private var look
    var isLocal: Bool

    @State private var idx = -1
    @State private var tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("WORDS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(look.theme.dimColor.opacity(0.7))
                Spacer()
                if !engine.lyrics.isEmpty && !isLocal {
                    HStack(spacing: 4) {
                        Text("\(engine.lyricOffsetMs > 0 ? "+" : "")\(engine.lyricOffsetMs) ms")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(look.theme.dimColor.opacity(0.8))
                        Button { engine.nudgeLyrics(by: -250) } label: { Image(systemName: "minus") }
                        Button { engine.nudgeLyrics(by: 250) } label: { Image(systemName: "plus") }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(look.theme.accentColor)
                    .buttonStyle(.plain)
                }
            }
            if engine.lyrics.isEmpty {
                Text(isLocal ? "drop an .lrc beside the file and the words follow it"
                             : "no timed words for this song")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(look.theme.dimColor.opacity(0.6))
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(engine.lyrics.enumerated()), id: \.element.id) { i, line in
                                Text(line.text)
                                    .font(.system(size: CGFloat(i == idx ? 18 : 14) * CGFloat(look.fontScale),
                                                  weight: i == idx ? .semibold : .regular,
                                                  design: .rounded))
                                    .foregroundStyle(i == idx ? look.theme.textColor
                                                              : look.theme.dimColor.opacity(i < idx ? 0.35 : 0.6))
                                    .blur(radius: i == idx ? 0 : 0.6)
                                    .animation(.easeOut(duration: 0.28), value: idx)
                                    .id(i)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .onTapGesture {
                                        Task { await engine.seek(seconds: Double(line.at) / 1000) }
                                    }
                            }
                        }
                        .padding(.vertical, 30)
                    }
                    .frame(height: 210)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.18),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .onReceive(tick) { _ in
                        let ms = Int(engine.displayPosition() * 1000) + engine.lyricOffsetMs
                        let i = engine.lyricIndex(at: ms)
                        if i != idx { idx = i }
                    }
                    .onChange(of: idx) { v in
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(v, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}
