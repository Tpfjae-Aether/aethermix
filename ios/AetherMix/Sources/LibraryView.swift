import SwiftUI
import Foundation

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var remote: [Track] {
        let base = app.store.source == .vault ? app.store.vaultTracks : app.store.roomTracks
        let q = search.lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }
    private var local: [LocalTrack] {
        let q = search.lowercased()
        guard !q.isEmpty else { return app.shelf.tracks }
        return app.shelf.tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            searchBar
            chips
            if app.store.source == .phone {
                localList
            } else {
                remoteList
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("LIBRARY")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
            Spacer()
            Text(app.store.source == .room
                 ? "\(app.store.roomTracks.count) in the room"
                 : app.store.source == .vault
                 ? "\(app.store.vaultTracks.count) pc files"
                 : "\(app.shelf.tracks.count) files")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(look.theme.dimColor.opacity(0.8))
        }
        .padding(.horizontal, 22)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(look.theme.dimColor)
            TextField("search every song", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(look.theme.textColor)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(look.theme.dimColor.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(radius: 18, strength: 0.8)
        .padding(.horizontal, 20)
    }

    private var chips: some View {
        HStack(spacing: 7) {
            ForEach(LibraryStore.SourceFilter.allCases) { f in
                let on = app.store.source == f
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { app.store.source = f }
                } label: {
                    Text(f.rawValue)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Capsule().fill(on ? look.theme.accentColor.opacity(0.20) : .white.opacity(0.05)))
                        .foregroundStyle(on ? look.theme.accentColor : look.theme.dimColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { app.showImporter = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .glass(radius: 14, strength: 0.6)
                    .foregroundStyle(look.theme.textColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }

    private var remoteList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(remote) { t in
                    RemoteRow(track: t)
                        .onTapGesture { app.stream(t) }
                        .contextMenu {
                            if !t.path.isEmpty {
                                Button { app.stream(t, open: true) } label: { Label("Stream on this phone", systemImage: "iphone") }
                            }
                            Button { app.play(t) } label: { Label("Play on the desktop", systemImage: "desktopcomputer") }
                            Button { app.addTrack = t } label: { Label("Add to a room", systemImage: "text.badge.plus") }
                            if t.isStream {
                                Button {
                                    Task { try? await Bridge.shared.saveOffline(track: t.id) }
                                } label: { Label("Save for offline", systemImage: "arrow.down.circle") }
                            }
                            Button(role: .destructive) {
                                Task { await app.store.remove(t) }
                            } label: { Label("Remove from room", systemImage: "trash") }
                        }
                }
                if remote.isEmpty {
                    empty(search.isEmpty
                          ? (app.store.source == .room
                             ? "this room is empty - add songs from PC FILES"
                             : "no local files on the PC yet")
                          : "nothing matches")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .fadeEdges(top: 12, bottom: 46)
    }

    private var localList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(local) { t in
                    Button { app.playLocal(t) } label: {
                        HStack(spacing: 11) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(look.theme.panelColor.opacity(0.7))
                                Image(systemName: "waveform")
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(look.theme.accentColor.opacity(0.8))
                            }
                            .frame(width: 38, height: 38)
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
                            Text(String(format: "%d:%02d", Int(t.duration) / 60, Int(t.duration) % 60))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(look.theme.dimColor.opacity(0.7))
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            app.addLocalTrack = t
                        } label: { Label("Add to a room", systemImage: "text.badge.plus") }
                        Button(role: .destructive) {
                            app.shelf.delete(t)
                        } label: { Label("Remove from phone", systemImage: "trash") }
                    }
                }
                if local.isEmpty {
                    empty("no files yet - import some above")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .fadeEdges(top: 12, bottom: 46)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(look.theme.dimColor.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }
}

struct RemoteRow: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    var track: Track

    private var isCurrent: Bool {
        !app.engine.localActive && app.engine.remote.track_id == track.id
    }

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                ArtworkView(url: track.coverURL)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                if isCurrent {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: 40, height: 40)
                    Image(systemName: app.engine.remote.playing ? "waveform" : "pause.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(look.theme.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isCurrent ? look.theme.accentColor : look.theme.textColor)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "unknown artist" : track.artist)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(look.theme.dimColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if track.isStream {
                Circle().fill(look.theme.barColor.opacity(0.85)).frame(width: 4, height: 4)
            }
            Text(track.durationText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(look.theme.dimColor.opacity(0.7))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
