import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import ImageIO

// One engine, two sources. A row from the desktop is an AVPlayer on
// /audio?id=; a row imported into the phone is an AVAudioPlayer on a file.
// Lock screen controls and the audio session are shared, so the listener never
// has to know which one is speaking.
@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    @Published var remote = PlayerState.empty
    @Published var connected = false
    @Published var failure: String?
    @Published var localTitle: String = ""
    @Published var localArtist: String = ""
    @Published var localArtwork: UIImage?
    @Published var localPlaying = false
    @Published var localDuration: Double = 0
    @Published var localPosition: Double = 0
    @Published var localActive = false
    @Published private(set) var currentLocal: LocalTrack?
    @Published private(set) var streamingDesktop = false
    @Published var lyrics: [LyricLine] = []
    @Published var loading = false
    @Published var remoteStamp = Date()
    @Published var localStamp = Date()
    @Published var lyricOffsetMs = 0
    private var wasPlayingAtInterruption = false

    private var poller: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var remotePlayer: AVPlayer?
    private var localPlayer: AVAudioPlayer?
    private var remoteID: Int?
    private var streamID: Int?
    private var lyricsID: Int?
    private var artworkCache: [String: UIImage] = [:]
    private var endObserver: NSObjectProtocol?
    private var scrobblePlayed = false
    var localURL: (@MainActor (String) -> URL)?
    // the shelf owns its order. true means "a new song is already playing",
    // false means there was nothing after this one.
    var nextLocal: (@MainActor () -> Bool)?

    override init() {
        super.init()
        configureSession()
        configureRemoteCommands()
        startPolling()
    }

    // ------------------------------------------------------------------ setup
    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                            options: [.allowAirPlay, .allowBluetoothA2DP])
            // do not take audio focus at launch: an app that has not been asked
            // to play anything must not pause what is already playing
        } catch {
            failure = "audio session: \(error.localizedDescription)"
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func interrupted(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended { resumeAfterInterruption() }
        else { wasPlayingAtInterruption = localActive ? localPlaying : remote.playing; pauseLocal(sendRemote: false) }
    }

    private func resumeAfterInterruption() {
        try? AVAudioSession.sharedInstance().setActive(true)
        guard wasPlayingAtInterruption else { return }
        wasPlayingAtInterruption = false
        if localActive { taskPlayLocal() } else { Task { await play() } }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func taskPlayLocal() {
        remotePlayer?.play()
        localPlayer?.play()
        localPlaying = true
        updateNowPlaying()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in await self?.seek(seconds: e.positionTime) }
            return .success
        }
    }

    // ------------------------------------------------------------------- poll
    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // twice a second keeps the extrapolated clock within ~1 frame
                // of the desktop, which is what the words are timed against.
                // an unreachable bridge must not be hammered with 4 s timeouts.
                let up = await MainActor.run { [weak self] in self?.connected ?? false }
                try? await Task.sleep(nanoseconds: up ? 750_000_000 : 3_000_000_000)
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickLocal()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func refresh() async {
        do {
            let next = try await Bridge.shared.state()
            connected = true
            failure = nil
            // do not let a stale answer pull the room backwards while a local
            // file owns the speakers
            // a stream borrowed from the PC still needs the bridge's clock and
            // queue; a file on the phone does not
            if !localActive || streamingDesktop { remote = next; remoteStamp = Date() }
            // words belong to the row that is audible. A stream the phone
            // borrowed keeps the phone's id even after the desktop moves on.
            let wanted: Int?
            if streamingDesktop { wanted = streamID }
            else if localActive { wanted = nil }
            else { wanted = next.track_id }
            if let id = wanted, id != lyricsID,
               streamingDesktop || next.duration_ms > 0 {
                lyricsID = id
                await loadLyrics(id: id)
            }
            updateNowPlaying()
        } catch {
            connected = false
            failure = error.localizedDescription
        }
    }

    private func loadLyrics(id: Int) async {
        lyrics = []
        do {
            let l = try await Bridge.shared.lyrics(id: id)
            guard l.synced == true, !l.lyrics.isEmpty else { return }
            lyrics = parseLRC(l.lyrics)
        } catch { /* an instrumental has no words; that is not an error */ }
    }

    // A real LRC file is not one stamp per line: repeated stamps put the same
    // words on a chorus, [offset:...] shifts the whole file, [ar:]/[ti:] are
    // metadata, and enhanced files wrap words in <mm:ss.xx>. Reading only the
    // first stamp is what made the words drift and repeat.
    private func parseLRC(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var offset = 0
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let r = normalised.range(of: "\\[offset:\\s*[+-]?\\d+\\]",
                                   options: .regularExpression) {
            let digits = normalised[r].filter { $0.isNumber || $0 == "-" }
            offset = Int(digits) ?? 0
        }
        let meta: Set<String> = ["ar", "ti", "al", "by", "re", "ve", "length", "offset"]
        for raw in normalised.split(separator: "\n") {
            var rest = String(raw).trimmingCharacters(in: .whitespaces)
            var stamps: [Int] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...])
                let key = inner.lowercased()
                if meta.contains(where: { key == $0 || key.hasPrefix($0 + ":") }) { continue }
                if let ms = lrcStamp(inner) { stamps.append(ms) }
            }
            // enhanced LRC: <00:12.34> per word; the words themselves are text
            let body = rest.replacingOccurrences(of: "<[^>]+>", with: "",
                                                 options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !stamps.isEmpty else { continue }
            for ms in stamps {
                out.append(LyricLine(at: max(0, ms - offset), text: body))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    private func lrcStamp(_ raw: String) -> Int? {
        let parts = raw.replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let a = Double(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let b = Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let msb = Int((b * 1000).rounded())
        if parts.count == 2 { return Int(a * 60_000) + msb }
        let third = parts[2].trimmingCharacters(in: .whitespaces)
        let c = Double(third) ?? 0
        if third.contains(".") {
            // hh:mm:ss.xx
            return Int(a * 3_600_000) + Int(b * 60_000) + Int((c * 1000).rounded())
        }
        // mm:ss:xx with centiseconds (older editors write it this way)
        return Int(a * 60_000) + msb + Int((c * 10).rounded())
    }

    // -------------------------------------------------------------- transports
    func playDesktop(track: Track, pos: Int = 0) async {
        stopLocal(keepPublished: false)
        lyricsID = nil
        do {
            if pos > 0 { try await Bridge.shared.play(id: track.id); try await Bridge.shared.seek(ms: pos) }
            else { try await Bridge.shared.play(id: track.id) }
            await refresh()
            updateNowPlaying()
        } catch { failure = error.localizedDescription }
    }

    func streamOnPhone(track: Track) {
        startStream(id: track.id, title: track.title, artist: track.artist,
                    cover: track.cover, durationMs: track.duration_ms)
        streamingDesktop = true
        currentLocal = nil
    }

    // one streamer for both paths: a library row or the row the desktop just
    // advanced to, so "next" can keep playing on the phone
    private func startStream(id: Int, title: String, artist: String, cover: String, durationMs: Int) {
        guard let url = Bridge.shared.mediaURL(id: id) else { return }
        stopLocal(keepPublished: false)
        activateSession()
        streamID = id
        localActive = true
        localPlaying = true
        localTitle = title
        localArtist = artist
        localDuration = Double(durationMs) / 1000.0
        localPosition = 0
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        remotePlayer = player
        player.play()
        // never inherit the previous song's words while the new fetch is out
        lyrics = []
        lyricsID = id
        Task { await loadLyrics(id: id) }
        loadArtwork(cover)
        updateNowPlaying()
        observeRemoteEnd(item)
    }

    func playLocal(_ track: LocalTrack) {
        guard let url = localURL?(track.fileName) else { return }
        do {
            stopLocal(keepPublished: false)
            activateSession()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            localPlayer = p
            localActive = true
            localPlaying = true
            currentLocal = track
            streamingDesktop = false
            lyrics = []
            lyricsID = nil
            // the words this phone can time are the ones next to the file
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
                lyrics = parseLRC(text)
            }
            localStamp = Date()
            localTitle = track.title
            localArtist = track.artist
            localDuration = p.duration
            localPosition = p.currentTime
            if let data = try? Data(contentsOf: url),
               let art = embeddedArtwork(data) {
                localArtwork = art
            } else {
                localArtwork = nil
            }
            updateNowPlaying()
        } catch {
            failure = "cannot read that file: \(error.localizedDescription)"
        }
    }

    private func observeRemoteEnd(_ item: AVPlayerItem) {
        // one observer for the current item: a new stream must not leave the old
        // token behind, or a finished song can advance the queue twice
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.localPlaying = false
                await self?.next()
            }
        }
    }

    func play() async {
        if localActive {
            if let p = remotePlayer { p.play() }
            localPlayer?.play()
            localPlaying = true
        } else {
            try? await Bridge.shared.hit("/resume")
            // the bridge confirms the new state on the next poll; flipping it
            // here keeps the button honest for the half second in between
            remote.playing = true
            remoteStamp = Date()
        }
        updateNowPlaying()
    }

    func pause() async {
        if localActive {
            remotePlayer?.pause()
            localPlayer?.pause()
            localPlaying = false
        } else {
            try? await Bridge.shared.hit("/pause")
            remote.playing = false
        }
        updateNowPlaying()
    }

    func pauseLocal(sendRemote: Bool) {
        remotePlayer?.pause()
        localPlayer?.pause()
        localPlaying = false
        updateNowPlaying()
    }

    func toggle() async {
        if localActive {
            localPlaying ? await pause() : await play()
        } else if remote.playing {
            await pause()
        } else {
            await play()
        }
    }

    func next() async {
        // a borrowed stream asks the room first: the phone's own shelf must
        // never hijack the queue the listener is inside
        if streamingDesktop {
            try? await Bridge.shared.next()
            await refresh()
            if let id = remote.track_id, id != streamID, remote.duration_ms > 0 {
                startStream(id: id, title: remote.title, artist: remote.artist,
                            cover: remote.cover_url, durationMs: remote.duration_ms)
                streamingDesktop = true
            } else {
                failure = "end of the room"
                stopLocal(keepPublished: false)
            }
            return
        }
        if localActive {
            // an empty shelf keeps the current song instead of going silent
            _ = nextLocal?()
            return
        }
        try? await Bridge.shared.next()
        lyricsID = nil
        await refresh()
    }

    func previous() async {
        if streamingDesktop {
            try? await Bridge.shared.previous()
            await refresh()
            if let id = remote.track_id, remote.duration_ms > 0 {
                startStream(id: id, title: remote.title, artist: remote.artist,
                            cover: remote.cover_url, durationMs: remote.duration_ms)
                streamingDesktop = true
            }
            return
        }
        if localActive { localPosition = 0; localPlayer?.currentTime = 0; return }
        try? await Bridge.shared.previous()
        lyricsID = nil
        await refresh()
    }

    func seek(seconds: Double) async {
        if localActive {
            localPlayer?.currentTime = seconds
            await remotePlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            localPosition = seconds
            localStamp = Date()
        } else {
            try? await Bridge.shared.seek(ms: Int(seconds * 1000))
            // rebase the UI clock on the target: the next poll will confirm it,
            // but the scrubber must not keep extrapolating from the old anchor
            remote.position_ms = Int(max(0, seconds) * 1000)
            remoteStamp = Date()
        }
    }

    // --------------------------------------------------------------- local tick
    private func tickLocal() async {
        guard localActive else { return }
        // a row that only exists as a web stream has no file for /audio; AVPlayer
        // reports .failed and the room must say so instead of spinning forever
        if let item = remotePlayer?.currentItem, item.status == .failed {
            failure = "this row has no file to stream - play it on the desktop"
            stopLocal(keepPublished: false)
            return
        }
        if let p = localPlayer {
            localPosition = p.currentTime
            localPlaying = p.isPlaying
        } else if let p = remotePlayer {
            localPosition = p.currentTime().seconds.isFinite ? p.currentTime().seconds : localPosition
            localPlaying = p.rate > 0
        }
        localStamp = Date()
        updateNowPlaying()
    }

    private func stopLocal(keepPublished: Bool) {
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
            endObserver = nil
        }
        remotePlayer?.pause()
        remotePlayer = nil
        localPlayer?.stop()
        localPlayer = nil
        localActive = false
        localPlaying = false
        if !keepPublished {
            currentLocal = nil
            streamingDesktop = false
            streamID = nil
            localTitle = ""
            localArtist = ""
            localArtwork = nil
            localPosition = 0
            localDuration = 0
        }
    }

    func stopEverything() async {
        stopLocal(keepPublished: false)
        // `hit` is async, so a bare try? inside a sync body does not compile;
        // the bridge call is fire-and-forget but still has to be awaited
        _ = try? await Bridge.shared.hit("/stop")
    }

    // ------------------------------------------------------------- now playing
    private var nowTitle: String { localActive ? localTitle : remote.title }
    private var nowArtist: String { localActive ? localArtist : remote.artist }
    private var nowDuration: Double { localActive ? localDuration : Double(remote.duration_ms) / 1000 }
    private var nowPosition: Double { localActive ? localPosition : Double(remote.position_ms) / 1000 }
    private var nowPlaying: Bool { localActive ? localPlaying : remote.playing }

    private func updateNowPlaying() {
        guard !nowTitle.isEmpty else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowTitle,
            MPMediaItemPropertyArtist: nowArtist,
            MPMediaItemPropertyPlaybackDuration: nowDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: nowPosition,
            MPNowPlayingInfoPropertyPlaybackRate: nowPlaying ? 1.0 : 0.0
        ]
        if let art = localActive ? localArtwork : artworkCache[remote.cover_url] {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: String) {
        guard !url.isEmpty, artworkCache[url] == nil else { return }
        guard let u = Bridge.shared.coverURL(url) else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: u),
               let img = UIImage(data: data) {
                artworkCache[url] = img
                if localActive { localArtwork = img }
                updateNowPlaying()
            }
        }
    }

    private func embeddedArtwork(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    // A smooth clock for the UI. The bridge reports position twice a second;
    // drawing straight from that makes the scrubber and the words step. The
    // view asks this function on the frame clock instead, and the position is
    // extrapolated from the last report while the song is playing.
    func displayPosition(at date: Date = Date()) -> Double {
        if localActive {
            let base = localPosition
            guard localPlaying else { return base }
            let live = base + date.timeIntervalSince(localStamp)
            // a duration of 0 means "not known yet"; clamping to it would pin
            // the scrubber and the words to 0:00
            return localDuration > 0 ? min(localDuration, max(0, live)) : max(0, live)
        }
        let base = Double(remote.position_ms) / 1000
        guard remote.playing else { return base }
        let live = base + date.timeIntervalSince(remoteStamp)
        let known = Double(remote.duration_ms) / 1000
        return known > 0 ? min(known, max(0, live)) : max(0, live)
    }

    func displayDuration() -> Double {
        localActive ? localDuration : Double(remote.duration_ms) / 1000
    }

    func nudgeLyrics(by ms: Int) {
        lyricOffsetMs = max(-30_000, min(30_000, lyricOffsetMs + ms))
        guard !localActive, let id = remote.track_id else { return }
        Task { try? await Bridge.shared.hit("/lyricoffset?id=\(id)&ms=\(lyricOffsetMs)") }
    }

    // lyric line for a given ms, for the immersive room
    func lyricIndex(at ms: Int) -> Int {
        guard !lyrics.isEmpty else { return -1 }
        var lo = 0, hi = lyrics.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics[mid].at <= ms { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}

extension PlayerEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.localPlaying = false
            await self.next()
        }
    }
}
