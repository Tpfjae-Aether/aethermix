import Foundation
import AVFoundation
import UIKit
import Combine

// ---------------------------------------------------------------------------
// The phone's own shelf. Imported audio lives in Documents/AetherMix, which is
// visible in Files (UIFileSharingEnabled) and survives an app update. Free-team
// signing has no App Group, so everything the phone owns is kept here.
// ---------------------------------------------------------------------------
@MainActor
final class LocalShelf: ObservableObject {
    @Published var tracks: [LocalTrack] = []
    @Published var playlists: [LocalPlaylist] = []

    private let folder: URL
    private let tracksFile: URL
    private let playlistsFile: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("AetherMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tracksFile = folder.appendingPathComponent("shelf.json")
        playlistsFile = folder.appendingPathComponent("rooms.json")
        load()
    }

    func fileURL(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: tracksFile),
           let t = try? dec.decode([LocalTrack].self, from: d) { tracks = t }
        if let d = try? Data(contentsOf: playlistsFile),
           let p = try? dec.decode([LocalPlaylist].self, from: d) { playlists = p }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(tracks) { try? d.write(to: tracksFile, options: .atomic) }
        if let d = try? enc.encode(playlists) { try? d.write(to: playlistsFile, options: .atomic) }
    }

    // ---------------------------------------------------------------- importing
    func importFile(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = uniqueName(url.lastPathComponent)
        let dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        // a 60 MB import copied on the main actor freezes the room; the copy
        // is pure file I/O and belongs off it
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: dest)
        }.value
        // the sidecar words travel with the song, or the phone cannot time it
        let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let lrcDest = folder.appendingPathComponent(
                (name as NSString).deletingPathExtension + ".lrc")
            try? FileManager.default.removeItem(at: lrcDest)
            try? await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: sidecar, to: lrcDest)
            }.value
        }

        let asset = AVURLAsset(url: dest)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Imported"
        if let meta = try? await asset.load(.commonMetadata) {
            for item in meta {
                guard let key = item.commonKey else { continue }
                // load returns String? and try? wraps it again; the double
                // coalesce keeps this correct whichever the SDK declares
                guard let v = (try? await item.load(.stringValue)) ?? nil,
                      !v.isEmpty else { continue }
                if key == .commonKeyTitle { title = v }
                if key == .commonKeyArtist { artist = v }
            }
        }
        tracks.insert(LocalTrack(id: UUID(), title: title, artist: artist,
                                 fileName: name, duration: duration, addedAt: Date()), at: 0)
        persist()
    }

    private func uniqueName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }

    func delete(_ track: LocalTrack) {
        try? FileManager.default.removeItem(at: fileURL(track.fileName))
        tracks.removeAll { $0.id == track.id }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { $0 == track.id } }
        persist()
    }

    // ---------------------------------------------------------------- playlists
    @discardableResult
    func createPlaylist(named name: String) -> LocalPlaylist {
        let p = LocalPlaylist(id: UUID(), name: name, trackIDs: [], createdAt: Date(), coverName: nil)
        playlists.append(p)
        persist()
        return p
    }

    func deletePlaylist(_ p: LocalPlaylist) {
        playlists.removeAll { $0.id == p.id }
        persist()
    }

    func add(_ track: LocalTrack, to playlist: LocalPlaylist) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if !playlists[i].trackIDs.contains(track.id) { playlists[i].trackIDs.append(track.id) }
        if playlists[i].coverName == nil { playlists[i].coverName = track.fileName }
        persist()
    }

    func remove(_ track: LocalTrack, from playlist: LocalPlaylist) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].trackIDs.removeAll { $0 == track.id }
        persist()
    }

    func playlistTracks(_ p: LocalPlaylist) -> [LocalTrack] {
        p.trackIDs.compactMap { id in tracks.first { $0.id == id } }
    }
}

// ---------------------------------------------------------------------------
// Everything a screen needs, in one place. The desktop is the source of truth
// while it answers; when it does not, the room does not go dark - it falls back
// to the folder the phone owns.
// ---------------------------------------------------------------------------
@MainActor
final class LibraryStore: ObservableObject {
    @Published var remoteTracks: [Track] = []
    // the active room's own rows, without the PC's local vault that /library
    // also reports. The room card, the room sheet and this list must agree.
    @Published var roomTracks: [Track] = []
    @Published var remotePlaylists: [PlaylistRow] = []
    @Published var activePlaylist = ""
    @Published var connected = false
    @Published var loading = false
    @Published var errorText: String?
    @Published var query = ""
    @Published var source: SourceFilter = .room

    enum SourceFilter: String, CaseIterable, Identifiable {
        case room = "THE ROOM"
        case vault = "PC FILES"
        case phone = "ON PHONE"
        var id: String { rawValue }
    }

    /// rows that exist only on the PC's disk - not any room's arrangement
    var vaultTracks: [Track] { remoteTracks.filter { $0.origin == "local" } }

    private var lastVersion = -1

    var filtered: [Track] {
        guard !query.isEmpty else { return remoteTracks }
        let q = query.lowercased()
        return remoteTracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    func refresh(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let lib = try await Bridge.shared.library()
            connected = true
            errorText = nil
            if force || lib.version != lastVersion {
                remoteTracks = lib.tracks
                lastVersion = lib.version
            }
            activePlaylist = lib.playlist_name
            // the room is a second request because /library is the whole
            // library; a failure here must not blank the desktop list
            if let scoped = try? await Bridge.shared.library(playlistOnly: true) {
                roomTracks = scoped.tracks
            }
            let pls = try await Bridge.shared.playlists()
            remotePlaylists = pls.playlists
        } catch {
            connected = false
            errorText = error.localizedDescription
        }
    }

    @discardableResult
    func switchPlaylist(_ p: PlaylistRow) async -> Bool {
        do {
            try await Bridge.shared.switchPlaylist(p.id)
            activePlaylist = p.name
            await refresh(force: true)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func createRemotePlaylist(named name: String) async {
        do {
            try await Bridge.shared.createPlaylist(named: name)
            await refresh(force: true)
        } catch { errorText = error.localizedDescription }
    }

    func append(_ track: Track, to p: PlaylistRow) async {
        do {
            try await Bridge.shared.append(playlist: p.id, track: track.id)
            // the card shows the new count as soon as the sheet closes
            if let i = remotePlaylists.firstIndex(where: { $0.id == p.id }) {
                remotePlaylists[i].total += 1
            }
            await refresh(force: true)
        } catch { errorText = error.localizedDescription }
    }

    func remove(_ track: Track) async {
        do {
            try await Bridge.shared.remove(track: track.id)
            remoteTracks.removeAll { $0.id == track.id }
            await refresh(force: true)
        } catch { errorText = error.localizedDescription }
    }
}
