import SwiftUI
import Foundation

// A theme is the same document the desktop writes into themes/*.json, so the
// two apps wear the same worlds. Only the fields the phone can use are decoded;
// the rest stay in the JSON and are ignored.
struct Theme: Codable, Identifiable, Equatable {
    var name: String
    var bg: String
    var panel: String
    var text: String
    var dim: String
    var accent: String
    var bar: String
    var accent2: String?
    var glow: String?
    var light: Bool?
    var tag: String?
    var line: String?
    var scene: String?
    var custom: Bool?

    // The bridge answers every theme with the file name it came from (`id`),
    // which is the only safe key to send back: a theme's display name is free
    // text ("Aurora", "My World"), while the id is the slug on disk.
    var key: String? = nil

    var id: String {
        if let k = key, !k.isEmpty { return k }
        return Theme.slug(name)
    }

    enum CodingKeys: String, CodingKey {
        case name, bg, panel, text, dim, accent, bar, accent2, glow, light,
             tag, line, scene, custom
        case key = "id"
    }

    var bgColor: Color { Color(hex: bg) }
    var panelColor: Color { Color(hex: panel) }
    var textColor: Color { Color(hex: text) }
    var dimColor: Color { Color(hex: dim) }
    var accentColor: Color { Color(hex: accent) }
    var barColor: Color { Color(hex: bar) }
    var secondColor: Color { Color(hex: accent2 ?? bar) }

    static func slug(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            if c.isLetter || c.isNumber { out.append(c) }
            else if c == " " || c == "-" || c == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static let aurora = Theme(
        name: "Aurora", bg: "#04070f", panel: "#0a1220", text: "#ffffff",
        dim: "#9fb3c8", accent: "#00ffa3", bar: "#0fd3c4", accent2: "#7aa2ff",
        glow: "#a6ffe4", light: false, tag: "NORDIC DUSK",
        line: "charged curtains over black snow", scene: "polar sky ribbons", custom: false)

    static let ink = Theme(
        name: "Ink", bg: "#0d0b09", panel: "#17130f", text: "#f4ede3",
        dim: "#a8988a", accent: "#c9a227", bar: "#e0b84c", accent2: "#8f6b3a",
        glow: "#ffe9b0", light: false, tag: "PAPER AND SOOT",
        line: "gold leaf on wet black paper", scene: "silk curtains in a dark room", custom: false)

    static let chrome = Theme(
        name: "Chrome", bg: "#080b10", panel: "#121821", text: "#f2f7ff",
        dim: "#93a4b8", accent: "#8ad8ff", bar: "#5fb8ff", accent2: "#c9d6e6",
        glow: "#d9f2ff", light: false, tag: "COLD LIGHT",
        line: "polished metal under a north window", scene: "orbital rings", custom: false)

    static let vapor = Theme(
        name: "Vapor", bg: "#160d24", panel: "#241437", text: "#ffe9fb",
        dim: "#c39fd0", accent: "#ff5bd0", bar: "#7b5bff", accent2: "#4de1ff",
        glow: "#ffa8ea", light: false, tag: "AFTER HOURS",
        line: "neon bleeding into an ocean haze", scene: "palm silhouettes and chrome", custom: false)

    static let silk = Theme(
        name: "Silk", bg: "#070c0d", panel: "#0f1a1c", text: "#f1fbf9",
        dim: "#9cc4bd", accent: "#7cf2d2", bar: "#45c7b0", accent2: "#d9fff6",
        glow: "#c7fff2", light: false, tag: "SALT AIR",
        line: "thin cloth moving over water", scene: "veils in a sea cave", custom: false)

    static let ember = Theme(
        name: "Ember", bg: "#120705", panel: "#21100a", text: "#fff2e8",
        dim: "#c9a08c", accent: "#ff8a3d", bar: "#ff5b2e", accent2: "#ffcf6b",
        glow: "#ffc9a1", light: false, tag: "LOW FIRE",
        line: "coals breathing in a black grate", scene: "embers climbing a chimney", custom: false)

    static let builtIns: [Theme] = [.aurora, .ink, .chrome, .vapor, .silk, .ember]
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// Every surface in the app reads these numbers, so a theme change is one
// assignment and the whole room re-dresses.
struct Look: Equatable {
    var theme: Theme = .aurora
    var blur: Double = 26
    var tint: Double = 0.12
    var fontScale: Double = 1.0
    var minimizeBackdrop: Bool = true
}

extension EnvironmentValues {
    var look: Look {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
}

private struct LookKey: EnvironmentKey {
    static let defaultValue = Look()
}

struct Glass: ViewModifier {
    @Environment(\.look) private var look
    var radius: CGFloat = 24
    var strength: Double = 1.0

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.55 * strength)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(look.theme.bgColor.opacity(0.28 * strength))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.16), .white.opacity(0.02)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 0.6)
                    }
            }
    }
}

extension View {
    func glass(radius: CGFloat = 24, strength: Double = 1.0) -> some View {
        modifier(Glass(radius: radius, strength: strength))
    }
}
