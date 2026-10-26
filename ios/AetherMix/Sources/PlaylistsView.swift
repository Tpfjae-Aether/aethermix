import SwiftUI
import Foundation

@MainActor
struct PlaylistsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @State private var openRemote: PlaylistRow?
    @State private var openLocal: LocalPlaylist?

    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !app.store.remotePlaylists.isEmpty {
                    SectionLabel(text: "ON THE DESKTOP")
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(app.store.remotePlaylists) { p in
                            RoomCard(name: p.name, sub: "\(p.total) songs",
                                     cover: p.coverURL, covers: (p.covers ?? []).compactMap { Bridge.shared.coverURL($0) },
                                     active: p.active) {
                                Task {
                                    if await app.store.switchPlaylist(p) {
                                        openRemote = p
                                    }
                                }
                            }
                        }
                    }
                }
                SectionLabel(text: "ON THIS PHONE")
                LazyVGrid(columns: cols, spacing: 12) {
                    Button {
                        app.createOnPhone = true
                        app.showCreateRoom = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .light))
                            Text("A NEW ROOM")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .tracking(1.5)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 132)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.white.opacity(0.14),
                                              style: StrokeStyle(lineWidth: 0.7, dash: [5, 6]))
                        }
                        .foregroundStyle(look.theme.dimColor)
                    }
                    .buttonStyle(.plain)

                    ForEach(app.shelf.playlists) { p in
                        RoomCard(name: p.name, sub: "\(p.trackIDs.count) songs",
                                 cover: nil,
                                 covers: [], active: false) {
                            openLocal = p
                        }
                        .contextMenu {
                            Button(role: .destructive) { app.shelf.deletePlaylist(p) } label: {
                                Label("Delete room", systemImage: "trash")
                            }
                        }
                    }
                }
                if app.store.remotePlaylists.isEmpty && app.shelf.playlists.isEmpty {
                    Text("paste a playlist link into the desktop's BROWSE room and it appears here")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(look.theme.dimColor.opacity(0.6))
                        .padding(.top, 4)
                }
                Button {
                    app.showImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("IMPORT AUDIO FROM FILES")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .tracking(1.4)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .glass(radius: 18, strength: 0.55)
                    .foregroundStyle(look.theme.textColor.opacity(0.9))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .fadeEdges(top: 10, bottom: 44)
        .sheet(item: $openRemote) { p in
            RemotePlaylistView(playlist: p)
                .environmentObject(app)
                .environment(\.look, look)
        }
        .sheet(item: $openLocal) { p in
            LocalPlaylistView(playlistID: p.id)
                .environmentObject(app)
                .environment(\.look, look)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("ROOMS")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
            Spacer()
            Text("\(app.store.remotePlaylists.count + app.shelf.playlists.count) ROOMS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(look.theme.dimColor.opacity(0.75))
        }
    }
}

struct RoomCard: View {
    @Environment(\.look) private var look
    var name: String
    var sub: String
    var cover: URL?
    var covers: [URL]
    var active: Bool
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(look.theme.panelColor.opacity(0.55))
                    if covers.count >= 4 {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                            ForEach(Array(covers.prefix(4).enumerated()), id: \.offset) { _, u in
                                AsyncImage(url: u) { ph in
                                    if let img = ph.image { img.resizable().scaledToFill() }
                                    else { look.theme.panelColor }
                                }
                                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                                .clipped()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if let cover {
                        AsyncImage(url: cover) { ph in
                            if let img = ph.image { img.resizable().scaledToFill() }
                            else { look.theme.panelColor }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 30, weight: .ultraLight))
                            .foregroundStyle(look.theme.dimColor.opacity(0.55))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if active {
                        Circle().fill(look.theme.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(9)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(look.theme.textColor)
                        .lineLimit(1)
                    Text(sub.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(look.theme.dimColor.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct RemotePlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    var playlist: PlaylistRow

    // the room's own rows, not the desktop library (which also carries the
    // local vault). Loaded here so the card's song count and the list agree.
    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Atmosphere().opacity(0.7)
                VStack(spacing: 0) {
                    header
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(tracks) { t in
                                RemoteRow(track: t)
                                    .onTapGesture { app.stream(t) }
                                    .contextMenu {
                                        Button { app.play(t) } label: { Label("Play on the desktop", systemImage: "desktopcomputer") }
                                        Button(role: .destructive) {
                                            Task {
                                                await app.store.remove(t)
                                                await load()
                                            }
                                        } label: { Label("Remove from room", systemImage: "minus.circle") }
                                    }
                            }
                            if tracks.isEmpty && !loading {
                                Text(loadError ?? "this room is empty - add songs from the library")
                                    .font(.system(size: 10.5, design: .rounded))
                                    .foregroundStyle(look.theme.dimColor.opacity(0.65))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 50)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 40)
                    }
                    .fadeEdges(top: 12, bottom: 36)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(look.theme.textColor)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .environment(\.look, look)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            tracks = try await Bridge.shared.library(playlistOnly: true).tracks
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playlist.name)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
                .lineLimit(2)
            Text("\(tracks.count) SONGS")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(look.theme.dimColor)
            HStack(spacing: 8) {
                Button {
                    if let first = tracks.first { app.stream(first, open: true) }
                } label: {
                    Label("PLAY", systemImage: "play.fill")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(look.theme.accentColor.opacity(0.9)))
                        .foregroundStyle(look.theme.bgColor)
                }
                .buttonStyle(.plain)
                Button {
                    let all = tracks.shuffled()
                    if let first = all.first { app.stream(first, open: true) }
                } label: {
                    Label("SHUFFLE", systemImage: "shuffle")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glass(radius: 18, strength: 0.6)
                        .foregroundStyle(look.theme.textColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

struct LocalPlaylistView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    var playlistID: UUID

    // read through the shelf every time: a copy captured when the sheet opened
    // would ignore a song added from the library while it is on screen
    private var live: LocalPlaylist? {
        app.shelf.playlists.first(where: { $0.id == playlistID })
    }
    private var tracks: [LocalTrack] {
        guard let p = live else { return [] }
        return app.shelf.playlistTracks(p)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Atmosphere().opacity(0.7)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(live?.name ?? "room")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(look.theme.textColor)
                        Text("\(tracks.count) SONGS ON THIS PHONE")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(1.6)
                            .foregroundStyle(look.theme.dimColor)
                        ForEach(tracks) { t in
                            Button {
                                // let the sheet finish closing before the
                                // full-screen room is presented
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    app.playLocal(t)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(look.theme.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.title).font(.system(size: 12, design: .rounded))
                                            .foregroundStyle(look.theme.textColor).lineLimit(1)
                                        Text(t.artist).font(.system(size: 9.5, design: .rounded))
                                            .foregroundStyle(look.theme.dimColor).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let p = live { app.shelf.remove(t, from: p) }
                                } label: { Label("Remove from room", systemImage: "minus.circle") }
                            }
                        }
                        if tracks.isEmpty {
                            Text("empty room. long-press a song in the library to add one.")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(look.theme.dimColor.opacity(0.6))
                                .padding(.top, 20)
                        }
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(look.theme.textColor)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .environment(\.look, look)
    }
}
