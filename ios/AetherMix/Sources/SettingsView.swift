import SwiftUI
import Foundation

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.look) private var look
    @State private var host = Bridge.shared.host
    @State private var checking = false

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Text("STUDIO")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(look.theme.textColor)
                    .padding(.top, 10)

                connection
                themes
                atmosphere
                shelf
                about
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 44)
        }
        .fadeEdges(top: 8, bottom: 44)
    }

    // ------------------------------------------------------------- connection
    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "THE DESKTOP")
            HStack(spacing: 8) {
                TextField("192.168.1.20:3690", text: $host)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(look.theme.textColor)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .glass(radius: 14, strength: 0.7)
                Button {
                    checking = true
                    Bridge.shared.host = host
                    host = Bridge.shared.host
                    Task {
                        await app.store.refresh(force: true)
                        await app.engine.refresh()
                        checking = false
                    }
                } label: {
                    Text(checking ? "..." : "LINK")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Capsule().fill(look.theme.accentColor.opacity(0.9)))
                        .foregroundStyle(look.theme.bgColor)
                }
                .buttonStyle(.plain)
            }
            Text(app.store.connected
                 ? "linked  ·  \(app.store.roomTracks.count) in the room  ·  \(app.store.remotePlaylists.count) rooms"
                 : "not linked. start AetherMix on the desktop, then use the PC's LAN address (ipconfig). Both devices must be on the same network. If the address is right and this still fails, Windows is blocking the bridge: on the PC run    netsh advfirewall firewall delete rule name=aethermix    as administrator, then relaunch AetherMix and Allow it on private networks.")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(app.store.connected ? look.theme.dimColor.opacity(0.7) : Color.orange.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ----------------------------------------------------------------- themes
    private var themes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "THEME")
                Button {
                    Task { await app.loadThemes() }
                } label: {
                    Text("SYNC")
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(look.theme.dimColor)
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(app.themes) { t in
                    let on = t.id == look.theme.id
                    Button { app.apply(t) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .bottomLeading) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(LinearGradient(colors: [t.bgColor, t.panelColor],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                HStack(spacing: 3) {
                                    Circle().fill(t.accentColor).frame(width: 7, height: 7)
                                    Circle().fill(t.barColor).frame(width: 7, height: 7)
                                    Circle().fill(t.secondColor).frame(width: 7, height: 7)
                                }
                                .padding(8)
                            }
                            .aspectRatio(1.25, contentMode: .fit)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(on ? t.accentColor : .white.opacity(0.08),
                                                  lineWidth: on ? 1.4 : 0.6)
                            }
                            Text(t.name.uppercased())
                                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(on ? look.theme.accentColor : look.theme.dimColor)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("these are the desktop's own worlds. a theme made in the desktop Studio appears here after SYNC.")
                .font(.system(size: 8.5, design: .rounded))
                .foregroundStyle(look.theme.dimColor.opacity(0.55))
        }
    }

    // -------------------------------------------------------------- atmosphere
    private var atmosphere: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "ATMOSPHERE")
            slider("bloom", value: Binding(
                get: { app.look.blur },
                set: { app.look.blur = $0 }), range: 0...80)
            slider("tint", value: Binding(
                get: { app.look.tint },
                set: { app.look.tint = $0 }), range: 0...0.6)
            slider("word size", value: Binding(
                get: { app.look.fontScale },
                set: { app.look.fontScale = $0 }), range: 0.8...1.5)
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(look.theme.dimColor)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(look.theme.dimColor.opacity(0.65))
            }
            Slider(value: value, in: range)
                .tint(look.theme.accentColor)
        }
    }

    // ------------------------------------------------------------------- shelf
    private var shelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "ON THIS PHONE")
            Text("\(app.shelf.tracks.count) songs  ·  \(app.shelf.playlists.count) rooms")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(look.theme.textColor)
            Text("Imported audio lives in Documents/AetherMix. It is visible in the Files app under On My iPhone → AetherMix, so a song can be dropped in from Finder or iCloud without reinstalling.")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(look.theme.dimColor.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Button { app.showImporter = true } label: {
                Text("IMPORT AUDIO")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .glass(radius: 16, strength: 0.6)
                    .foregroundStyle(look.theme.textColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "ABOUT")
            Text("AetherMix Pocket 1.0")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(look.theme.textColor)
            Text("A second window onto the desktop library. Playback continues with the screen off; the lock screen and headphone controls are wired to the same engine.")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(look.theme.dimColor.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
