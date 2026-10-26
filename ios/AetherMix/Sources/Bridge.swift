import Foundation

// The phone is a second window onto the same library. Everything it shows comes
// from the desktop bridge on the LAN (or, offline, from the folder it owns).
// One small client keeps every call honest about timeouts and errors: a phone
// that hangs for 30s on a wrong IP feels broken, so the default is 4s.
final class Bridge {
    static let shared = Bridge()

    private let lock = NSLock()
    private var base: URL
    private let session: URLSession

    private init() {
        // loopback is never the desktop: a phone has to be pointed at the
        // PC's LAN address, so the default is the one the bridge printed at
        // boot on this network. It is editable in Studio and persisted.
        let stored = UserDefaults.standard.string(forKey: "aether.host") ?? "http://192.168.1.240:3690"
        base = URL(string: stored) ?? URL(string: "http://192.168.1.240:3690")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldUsePipelining = false
        session = URLSession(configuration: cfg)
    }

    var host: String {
        get { lock.lock(); defer { lock.unlock() }; return base.absoluteString }
        set {
            var trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // a trailing slash would turn every route into //state
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            guard let u = URL(string: withScheme) else { return }
            lock.lock(); base = u; lock.unlock()
            UserDefaults.standard.set(withScheme, forKey: "aether.host")
        }
    }

    func mediaURL(id: Int) -> URL? {
        lock.lock(); let b = base; lock.unlock()
        return URL(string: "\(b.absoluteString)/audio?id=\(id)")
    }

    // Artwork arrives from the bridge as file:///C:/... because that is what
    // the desktop draws. A phone cannot open the PC's disk, so the same path is
    // pointed at the bridge's /cover route, which serves only the cover cache.
    func coverURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("file:") {
            let cleaned = trimmed.replacingOccurrences(of: " ", with: "%20")
            guard let fileURL = URL(string: cleaned) else { return nil }
            var p = fileURL.path
            if p.hasPrefix("/") { p.removeFirst() }
            lock.lock(); let b = base; lock.unlock()
            var comps = URLComponents(string: b.absoluteString + "/cover")
            comps?.queryItems = [URLQueryItem(name: "path", value: p)]
            return comps?.url
        }
        return URL(string: trimmed.replacingOccurrences(of: " ", with: "%20"))
    }

    private func get(_ path: String, timeout: TimeInterval = 4) async throws -> Data {
        lock.lock(); let b = base; lock.unlock()
        guard let url = URL(string: b.absoluteString + path) else {
            throw BridgeError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BridgeError.status((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, timeout: TimeInterval = 4) async throws -> T {
        let data = try await get(path, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // ------------------------------------------------------------------ reads
    func state() async throws -> PlayerState {
        try await decode(PlayerState.self, "/state")
    }
    func library(playlistOnly: Bool = false) async throws -> LibraryResponse {
        // scope=playlist is one room's rows, without the local vault that the
        // desktop library mixes in
        try await decode(LibraryResponse.self,
                         playlistOnly ? "/library?scope=playlist" : "/library",
                         timeout: 10)
    }
    func playlists() async throws -> PlaylistsResponse {
        try await decode(PlaylistsResponse.self, "/playlists", timeout: 8)
    }
    func lyrics(id: Int) async throws -> LyricsResponse {
        try await decode(LyricsResponse.self, "/lyrics?id=\(id)", timeout: 8)
    }
    func themes() async throws -> ThemesResponse {
        try await decode(ThemesResponse.self, "/themes", timeout: 8)
    }
    func theme(named name: String) async throws -> Theme {
        let data = try await get("/theme?name=\(esc(name))&preview=1", timeout: 6)
        return try JSONDecoder().decode(Theme.self, from: data)
    }
    func themeCurrent() async throws -> Theme {
        let data = try await get("/theme/current", timeout: 6)
        return try JSONDecoder().decode(Theme.self, from: data)
    }

    // --------------------------------------------------------------- commands
    @discardableResult
    func hit(_ path: String, timeout: TimeInterval = 6) async throws -> OKResponse {
        let data = try await get(path, timeout: timeout)
        if let ok = try? JSONDecoder().decode(OKResponse.self, from: data) {
            return ok
        }
        return OKResponse(ok: true, error: nil, id: nil, name: nil, file: nil, title: nil, total: nil, duplicate: nil)
    }

    func play(id: Int) async throws { try await hit("/play?id=\(id)") }
    func toggle() async throws { try await hit("/toggle") }
    func next() async throws { try await hit("/next") }
    func previous() async throws { try await hit("/prev") }
    func seek(ms: Int) async throws { try await hit("/seek?ms=\(max(0, ms))") }
    func volume(_ v: Int) async throws { try await hit("/volume?v=\(max(0, min(100, v)))") }
    func switchPlaylist(_ id: String) async throws { try await hit("/playlist/switch?id=\(esc(id))", timeout: 12) }
    func append(playlist: String, track: Int) async throws { try await hit("/playlist/append?pl=\(esc(playlist))&id=\(track)") }
    func remove(track: Int) async throws { try await hit("/playlist/remove?id=\(track)") }
    func createPlaylist(named name: String) async throws { try await hit("/playlist/new?name=\(esc(name))") }
    func saveOffline(track: Int) async throws { try await hit("/track/save?id=\(track)", timeout: 10) }
    func resume() async throws { try await hit("/resume") }
    func pauseRemote() async throws { try await hit("/pause") }
    func setTheme(_ name: String) async throws { try await hit("/theme?name=\(esc(name))") }

    // Playlist ids are absolute paths with backslashes and spaces; the desktop
    // resolver expects them URL-encoded, not raw.
    private func esc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

enum BridgeError: LocalizedError {
    case badURL
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That address is not a URL."
        case .status(let c): return c == 0 ? "No answer from the desktop." : "The bridge answered \(c)."
        }
    }
}
