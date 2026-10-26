import SwiftUI
import Foundation
import UIKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class AppModel: ObservableObject {
    let shelf = LocalShelf()
    let store = LibraryStore()
    let engine = PlayerEngine()

    @Published var look = Look()
    @Published var themes: [Theme] = Theme.builtIns
    @Published var room: SourceRoom = .home
    @Published var immersive = false
    @Published var showCreateRoom = false
    @Published var createOnPhone = false
    @Published var showImporter = false
    @Published var createTarget: PlaylistRow?
    @Published var addTrack: Track?
    @Published var addLocalTrack: LocalTrack?
    @Published var notice: String?
    private var bag = Set<AnyCancellable>()

    init() {
        // The screens observe AppModel, not the three engines inside it. Without
        // this forward the clock, the words and every play button would freeze
        // on the first frame: nested ObservableObjects do not republish.
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        shelf.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        let shelfRef = shelf
        engine.localURL = { name in shelfRef.fileURL(name) }
        engine.nextLocal = { [weak self] in
            guard let self else { return false }
            let list = self.shelf.tracks
            guard !list.isEmpty else { return false }
            let i: Int
            if let cur = self.engine.currentLocal,
               let j = list.firstIndex(where: { $0.id == cur.id }) {
                i = j
            } else {
                i = -1
            }
            let nxt = list[(i + 1) % list.count]
            self.engine.playLocal(nxt)
            return true
        }
        loadTheme()
    }

    func boot() async {
        // the three calls are independent; sequential they made an offline
        // launch wait 4 s per step before the room had any colour
        async let library: Void = store.refresh(force: true)
        async let themes: Void = loadThemes()
        async let state: Void = engine.refresh()
        _ = await (library, themes, state)
    }

    func loadThemes() async {
        if let t = try? await Bridge.shared.themeCurrent() {
            if UserDefaults.standard.string(forKey: "aether.theme") == nil {
                look.theme = t
            }
        }
        guard let names = try? await Bridge.shared.themes().themes, !names.isEmpty else { return }
        var out: [Theme] = []
        var seen = Set<String>()
        for n in names {
            if let t = try? await Bridge.shared.theme(named: n), seen.insert(t.id).inserted {
                out.append(t)
            }
        }
        if !out.isEmpty {
            // the desktop exports every world it owns; keep the phone's own
            // six behind them so an offline first paint still has colour
            for b in Theme.builtIns where !seen.contains(b.id) { out.append(b) }
            themes = out
            loadTheme()
        }
    }

    func apply(_ theme: Theme) {
        look.theme = theme
        UserDefaults.standard.set(theme.id, forKey: "aether.theme")
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        Task { try? await Bridge.shared.setTheme(theme.id) }
    }

    private func loadTheme() {
        guard let saved = UserDefaults.standard.string(forKey: "aether.theme") else { return }
        if let t = themes.first(where: { $0.id == saved || $0.name == saved }) {
            look.theme = t
        }
    }

    func play(_ t: Track) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await engine.playDesktop(track: t) }
    }

    // Tapping a row plays it HERE. The desktop speakers are a deliberate
    // second choice, because a phone with headphones should never be silent
    // while another room plays the song.
    func stream(_ t: Track, open: Bool = false) {
        // a web-only row has no file for /audio; the desktop decodes it and the
        // phone is the remote, which is the only honest answer on iOS
        if t.path.isEmpty {
            play(t)
            notice = "that row streams from the web - playing on the desktop"
            return
        }
        engine.streamOnPhone(track: t)
        if open { immersive = true }
    }

    func playLocal(_ t: LocalTrack) {
        engine.playLocal(t)
        immersive = true
    }

    func addLocal(_ t: LocalTrack, to room: LocalPlaylist) {
        shelf.add(t, to: room)
        notice = "added to \(room.name)"
    }

    func importFiles(_ urls: [URL]) {
        Task {
            var n = 0
            for u in urls {
                do { try await shelf.importFile(u); n += 1 }
                catch { notice = "could not import \(u.lastPathComponent)" }
            }
            if n > 0 { notice = "\(n) song\(n == 1 ? "" : "s") added to the phone" }
        }
    }
}

@MainActor
struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        ZStack {
            Atmosphere()
            VStack(spacing: 0) {
                TopBar()
                content
            }
        }
        .environmentObject(app)
        .environment(\.look, app.look)
        .safeAreaInset(edge: .bottom, spacing: 8) {
            VStack(spacing: 7) {
                MiniPlayer()
                GlassDock(room: $app.room) { r in
                    if r == .nowPlaying { app.immersive = true; app.room = .home }
                }
            }
            .padding(.bottom, 2)
        }
        .fullScreenCover(isPresented: $app.immersive) {
            NowPlayingView()
                .environmentObject(app)
                .environment(\.look, app.look)
        }
        .sheet(isPresented: $app.showCreateRoom) {
            CreateRoomSheet()
                .environmentObject(app)
                .environment(\.look, app.look)
                .presentationDetents([.height(300)])
        }
        .sheet(item: $app.addTrack) { t in
            AddToRoomSheet(track: t)
                .environmentObject(app)
                .environment(\.look, app.look)
                .presentationDetents([.medium])
        }
        .sheet(item: $app.addLocalTrack) { t in
            AddToLocalRoomSheet(track: t)
                .environmentObject(app)
                .environment(\.look, app.look)
                .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $app.showImporter,
                      allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.importFiles(urls) }
        }
        .overlay(alignment: .top) {
            if let n = app.notice {
                Text(n)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(radius: 16)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        withAnimation { app.notice = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.3), value: app.notice)
        .task { await app.boot() }
        .task(id: app.room) {
            // a tab change is the natural moment to pick up what the desktop
            // added since launch; boot already covered HOME
            if app.room != .home { await app.store.refresh() }
        }
    }

    @ViewBuilder private var content: some View {
        switch app.room {
        case .home: HomeView()
        case .library: LibraryView()
        case .playlists: PlaylistsView()
        case .nowPlaying: NowPlayingView()
        case .settings: SettingsView()
        }
    }
}

struct TopBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LinearGradient(colors: [look.theme.accentColor, look.theme.barColor],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 9, height: 9)
                .shadow(color: look.theme.accentColor.opacity(0.8), radius: 6)
            Text("AetherMix")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("·").foregroundStyle(look.theme.dimColor.opacity(0.5))
            Text(app.room.rawValue)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(look.theme.dimColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(app.store.connected ? look.theme.accentColor : Color.orange.opacity(0.8))
                    .frame(width: 5, height: 5)
                Text(app.store.connected ? "LINKED" : "OFFLINE")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(look.theme.dimColor.opacity(0.85))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .glass(radius: 12, strength: 0.6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .foregroundStyle(look.theme.textColor)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look

    private var hasSong: Bool { app.engine.localActive || !app.engine.remote.title.isEmpty }
    private var title: String { app.engine.localActive ? app.engine.localTitle : app.engine.remote.title }
    private var artist: String { app.engine.localActive ? app.engine.localArtist : app.engine.remote.artist }
    private var playing: Bool { app.engine.localActive ? app.engine.localPlaying : app.engine.remote.playing }
    var body: some View {
        if hasSong {
            VStack(spacing: 0) {
                MiniProgress()
                    .frame(height: 3)

                HStack(spacing: 11) {
                    ArtworkView(url: app.engine.localActive ? nil : app.engine.remote.coverURL)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Text(artist).font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(look.theme.dimColor).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button { Task { await app.engine.toggle() } } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    Button { Task { await app.engine.next() } } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 32)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(look.theme.textColor)
            }
            .glass(radius: 20, strength: 1.15)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture { app.immersive = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// The hairline above the mini player runs on the frame clock instead of the
// last network sample, so it glides rather than stepping every second.
struct MiniProgress: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look

    private var playing: Bool {
        app.engine.localActive ? app.engine.localPlaying : app.engine.remote.playing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !playing)) { tl in
            let d = app.engine.displayDuration()
            let live = app.engine.displayPosition(at: tl.date)
            let p = d > 0 ? min(1, max(0, live / d)) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10)).frame(height: 2)
                    Capsule()
                        .fill(LinearGradient(colors: [look.theme.accentColor, look.theme.barColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(p), height: 2)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

struct ArtworkView: View {
    @Environment(\.look) private var look
    var url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    look.theme.panelColor
                    Image(systemName: "opticaldisc")
                        .foregroundStyle(look.theme.dimColor.opacity(0.6))
                }
            }
        }
    }
}

struct CreateRoomSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var onPhone = false
    @State private var primed = false
    @State private var err: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A NEW ROOM")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(look.theme.dimColor)
            TextField("name it", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { create() }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.7)
            HStack(spacing: 6) {
                whereChip("ON THIS PHONE", on: onPhone) { onPhone = true }
                whereChip("ON THE DESKTOP", on: !onPhone) { onPhone = false }
                    .opacity(app.store.connected ? 1 : 0.4)
                    .disabled(!app.store.connected)
            }
            if let err {
                Text(err)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("the room starts empty. fill it from the library.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(look.theme.dimColor.opacity(0.8))
                Spacer()
                Button { create() } label: {
                    Text("CREATE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(look.theme.accentColor.opacity(0.9)))
                        .foregroundStyle(look.theme.bgColor)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .foregroundStyle(look.theme.textColor)
        .onAppear {
            // a room created from the phone shelf starts on the phone; the
            // Home door starts on the desktop when one is linked
            if !primed {
                onPhone = app.createOnPhone || !app.store.connected
                primed = true
            }
            focused = true
        }
    }

    private func whereChip(_ text: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(text)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .tracking(1.2)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Capsule().fill(on ? look.theme.accentColor.opacity(0.20) : .white.opacity(0.05)))
                .foregroundStyle(on ? look.theme.accentColor : look.theme.dimColor)
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            if onPhone || !app.store.connected {
                _ = app.shelf.createPlaylist(named: n)
            } else {
                await app.store.createRemotePlaylist(named: n)
                if let e = app.store.errorText {
                    // keep the sheet open and say why, in the sheet: the toast
                    // behind a presented sheet is invisible
                    err = "the desktop did not make the room: \(e)"
                    return
                }
            }
            dismiss()
        }
    }
}

// Adding a phone file to one of the phone's own rooms. Long-press is the only
// way in on iOS, so the row keeps a plain "Add to a room" action.
struct AddToLocalRoomSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    var track: LocalTrack

    var body: some View {
        NavigationStack {
            List {
                Section("ON THIS PHONE") {
                    if app.shelf.playlists.isEmpty {
                        Text("no rooms yet").foregroundStyle(look.theme.dimColor)
                    }
                    ForEach(app.shelf.playlists) { p in
                        Button {
                            app.addLocal(track, to: p)
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.name).foregroundStyle(look.theme.textColor)
                                Spacer()
                                Text("\(p.trackIDs.count)").foregroundStyle(look.theme.dimColor)
                            }
                        }
                    }
                }
                Section {
                    Button("New room with this song") {
                        let p = app.shelf.createPlaylist(named: "New room")
                        app.shelf.add(track, to: p)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.look, look)
    }
}

struct AddToRoomSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    var track: Track

    var body: some View {
        NavigationStack {
            List {
                Section("DESKTOP ROOMS") {
                    ForEach(app.store.remotePlaylists) { p in
                        Button {
                            Task { await app.store.append(track, to: p); dismiss() }
                        } label: {
                            HStack {
                                Text(p.name).foregroundStyle(look.theme.textColor)
                                Spacer()
                                Text("\(p.total)").foregroundStyle(look.theme.dimColor)
                            }
                        }
                    }
                }
                if !app.store.connected {
                    Text("the desktop is not connected")
                        .foregroundStyle(look.theme.dimColor)
                }
                Section {
                    // this route downloads the file onto the DESKTOP; the
                    // phone still streams it. Saying "on this phone" was a lie.
                    Button("Download to the desktop") {
                        Task { try? await Bridge.shared.saveOffline(track: track.id); dismiss() }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Add \(track.title)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.look, look)
    }
}
