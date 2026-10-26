import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var artist: String
    var album: String
    var duration_ms: Int
    var origin: String
    var playable: Bool
    var web: String
    var cover: String
    var path: String
    var liked: Bool?
    var plays: Int?
    var streamable: Bool?

    var isStream: Bool { !web.isEmpty }
    var durationText: String {
        let s = max(0, duration_ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    var coverURL: URL? { Bridge.shared.coverURL(cover) }
}

struct LibraryResponse: Codable {
    var version: Int
    var playlist_name: String
    var playlist_owner: String?
    var playlist_cover: String?
    var playlist_file: String?
    var total: Int
    var local_count: Int
    var stream_count: Int
    var tracks: [Track]
    var total_ms: Int?
}

struct PlaylistRow: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var total: Int
    var cover: String?
    var covers: [String]?
    var active: Bool

    var coverURL: URL? {
        guard let c = cover else { return nil }
        return Bridge.shared.coverURL(c)
    }
}

struct PlaylistsResponse: Codable {
    var playlists: [PlaylistRow]
    var active: String
}

struct PlayerState: Codable {
    var title: String
    var artist: String
    var album: String
    var cover_url: String
    var duration_ms: Int
    var position_ms: Int
    var playing: Bool
    var track_id: Int?
    var origin: String
    var status: String
    var levels: [Double]
    var volume: Int?
    var queue_len: Int?
    var queue_pos: Int?
    var shuffle: Bool?
    // `repeat` is a Swift keyword, so the property cannot carry the wire name
    // directly. CodingKeys maps it back; once CodingKeys exists every key must
    // be listed, or the others silently stop decoding.
    var repeatMode: Int?

    enum CodingKeys: String, CodingKey {
        case title, artist, album, cover_url, duration_ms, position_ms, playing
        case track_id, origin, status, levels, volume, queue_len, queue_pos, shuffle
        case repeatMode = "repeat"
    }

    static let empty = PlayerState(
        title: "", artist: "", album: "", cover_url: "", duration_ms: 0,
        position_ms: 0, playing: false, track_id: nil, origin: "", status: "",
        levels: Array(repeating: 0, count: 20), volume: 70,
        queue_len: 0, queue_pos: 0, shuffle: false, repeatMode: 1)

    var coverURL: URL? { Bridge.shared.coverURL(cover_url) }
}

struct LyricLine: Identifiable, Hashable {
    var id = UUID()
    var at: Int        // ms
    var text: String
}

struct LyricsResponse: Codable {
    var lyrics: String
    var synced: Bool?
}

struct ThemesResponse: Codable {
    var themes: [String]
}

struct OKResponse: Codable {
    var ok: Bool?
    var error: String?
    var id: Int?
    var name: String?
    var file: String?
    var title: String?
    var total: Int?
    var duplicate: Bool?
}

// One row in the phone's own shelf, independent of the desktop.
struct LocalTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    var fileName: String
    var duration: Double
    var addedAt: Date
}

struct LocalPlaylist: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var trackIDs: [UUID]
    var createdAt: Date
    var coverName: String?
}

enum SourceRoom: String, CaseIterable, Identifiable {
    case home = "HOME"
    case library = "LIBRARY"
    case playlists = "ROOMS"
    case nowPlaying = "VIBE"
    case settings = "STUDIO"
    var id: String { rawValue }

    var glyph: String {
        switch self {
        case .home: return "circle.grid.2x2"
        case .library: return "music.note.list"
        case .playlists: return "square.stack"
        case .nowPlaying: return "waveform"
        case .settings: return "slider.horizontal.3"
        }
    }
}
