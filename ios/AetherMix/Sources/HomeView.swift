import SwiftUI
import Foundation

@MainActor
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look

    private var track: Track? {
        if let id = app.engine.remote.track_id, !app.engine.localActive {
            if let t = app.store.roomTracks.first(where: { $0.id == id }) { return t }
        }
        return app.store.roomTracks.first
    }
    private var title: String {
        app.engine.localActive ? app.engine.localTitle : (app.engine.remote.title.isEmpty ? (track?.title ?? "nothing yet") : app.engine.remote.title)
    }
    private var artist: String {
        app.engine.localActive ? app.engine.localArtist : (app.engine.remote.artist.isEmpty ? (track?.artist ?? "") : app.engine.remote.artist)
    }
    private var cover: String? {
        if app.engine.localActive { return nil }
        if !app.engine.remote.cover_url.isEmpty { return app.engine.remote.cover_url }
        return track?.cover
    }
    private var playing: Bool { app.engine.localActive ? app.engine.localPlaying : app.engine.remote.playing }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                sleeve
                transportRow
                doors
                recent
                footer
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .fadeEdges(top: 10, bottom: 40)
        .refreshable { await app.store.refresh(force: true) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(greeting)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(2.6)
                .foregroundStyle(look.theme.dimColor.opacity(0.7))
            Text(app.store.activePlaylist.isEmpty ? "AetherMix" : app.store.activePlaylist)
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
                .lineLimit(1)
            Text("\(app.store.roomTracks.count) in the room  ·  \(app.shelf.tracks.count) on this phone")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(look.theme.dimColor.opacity(0.75))
        }
        .padding(.top, 12)
    }

    private var sleeve: some View {
        VStack(alignment: .leading, spacing: 8) {
            VinylSleeve(title: title, artist: artist, cover: cover, playing: playing) {
                app.immersive = true
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.leading, 18)

            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(look.theme.textColor)
                        .lineLimit(2)
                    Text(artist.isEmpty ? "tap the sleeve to open the room" : artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(look.theme.dimColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Equalizer(levels: app.engine.localActive ? [] : app.engine.remote.levels,
                          active: playing)
                    .frame(width: 84)
            }
            .padding(.top, 2)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                if app.engine.localActive { Task { await app.engine.toggle() } }
                else if let t = track { app.stream(t) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                    Text(playing ? "PAUSE" : "PLAY")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.8)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Capsule().fill(look.theme.accentColor.opacity(0.92)))
                .foregroundStyle(look.theme.bgColor)
            }
            Button {
                app.immersive = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text("THE ROOM")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.8)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .glass(radius: 22, strength: 0.9)
                .foregroundStyle(look.theme.textColor)
            }
            Spacer()
            Button {
                Task { await app.engine.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .glass(radius: 21, strength: 0.7)
                    .foregroundStyle(look.theme.textColor)
            }
        }
        .buttonStyle(.plain)
    }

    private var doors: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                door("IMPORT", "square.and.arrow.down") { app.showImporter = true }
                door("NEW ROOM", "plus") {
                    app.createOnPhone = false
                    app.showCreateRoom = true
                }
                door("SHUFFLE", "shuffle") {
                    if let t = app.store.roomTracks.randomElement() { app.stream(t) }
                }
                door("STUDIO", "slider.horizontal.3") { app.room = .settings }
            }
            .padding(.vertical, 2)
        }
    }

    private func door(_ label: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(1.6)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glass(radius: 18, strength: 0.65)
            .foregroundStyle(look.theme.textColor.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "IN THIS ROOM")
            VStack(spacing: 2) {
                ForEach(app.store.roomTracks.prefix(6)) { t in
                    Button { app.stream(t) } label: {
                        HStack(spacing: 10) {
                            ArtworkView(url: t.coverURL)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(look.theme.textColor)
                                    .lineLimit(1)
                                Text(t.artist)
                                    .font(.system(size: 9.5, design: .rounded))
                                    .foregroundStyle(look.theme.dimColor)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if t.isStream {
                                Text("STREAM")
                                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
                                    .tracking(1)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Capsule().fill(look.theme.barColor.opacity(0.16)))
                                    .foregroundStyle(look.theme.barColor)
                            }
                            Text(t.durationText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(look.theme.dimColor.opacity(0.7))
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        Text(app.store.connected
             ? "linked to the desktop  ·  \(app.engine.remote.status)"
             : "offline  ·  playing what this phone holds")
            .font(.system(size: 8.5, design: .rounded))
            .foregroundStyle(look.theme.dimColor.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 { return "LATE NIGHT" }
        if h < 12 { return "MORNING" }
        if h < 18 { return "AFTERNOON" }
        return "EVENING"
    }
}
