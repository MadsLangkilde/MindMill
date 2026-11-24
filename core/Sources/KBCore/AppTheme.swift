import Foundation

/// The app's colours. Each is a hex colour (`#RRGGBB`), a light and a dark one (`#RRGGBB/#RRGGBB`), or empty for the
/// system's own.
public struct AppTheme: Codable, Equatable, Sendable, Identifiable {
    public enum Token: String, CaseIterable, Sendable, Identifiable {
        case accent, selection, sidebarBackground, sidebarText, sidebarIcon, contentBackground, text

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .accent: return "Accent (buttons, links)"
            case .selection: return "Selected item"
            case .sidebarBackground: return "Sidebar background"
            case .sidebarText: return "Sidebar text"
            case .sidebarIcon: return "Sidebar icons"
            case .contentBackground: return "Content background"
            case .text: return "Text"
            }
        }
    }

    public var name: String
    public var accent = ""
    public var selection = ""
    public var sidebarBackground = ""
    public var sidebarText = ""
    public var sidebarIcon = ""
    public var contentBackground = ""
    public var text = ""

    public var id: String { name }

    public init(name: String, accent: String = "", selection: String = "", sidebarBackground: String = "", sidebarText: String = "",
                sidebarIcon: String = "", contentBackground: String = "", text: String = "") {
        self.name = name
        self.accent = accent
        self.selection = selection
        self.sidebarBackground = sidebarBackground
        self.sidebarText = sidebarText
        self.sidebarIcon = sidebarIcon
        self.contentBackground = contentBackground
        self.text = text
    }

    public subscript(token: Token) -> String {
        get {
            switch token {
            case .accent: return accent
            case .selection: return selection
            case .sidebarBackground: return sidebarBackground
            case .sidebarText: return sidebarText
            case .sidebarIcon: return sidebarIcon
            case .contentBackground: return contentBackground
            case .text: return text
            }
        }
        set {
            switch token {
            case .accent: accent = newValue
            case .selection: selection = newValue
            case .sidebarBackground: sidebarBackground = newValue
            case .sidebarText: sidebarText = newValue
            case .sidebarIcon: sidebarIcon = newValue
            case .contentBackground: contentBackground = newValue
            case .text: text = newValue
            }
        }
    }

    /// Whether the theme paints over the system's light or dark look: true when it sets its own backgrounds.
    public var hasBackgrounds: Bool { !sidebarBackground.isEmpty || !contentBackground.isEmpty }

    /// The logo's navy, as the phone app uses it: deep in light mode, a light tint of it in dark mode.
    public static let brand = "#1F3A6E/#B0C6FF"

    public static let standard = AppTheme(name: "Mindmill", accent: brand, sidebarIcon: brand)

    /// What the standard theme was before it took the logo's colour; a saved copy of it follows the new one.
    static let previousStandard = AppTheme(name: "Mindmill", sidebarIcon: "#0A84FF")

    public static let presets: [AppTheme] = [
        standard,
        AppTheme(name: "System"),
        AppTheme(name: "Ocean", accent: "#0E7490", selection: "#0E7490", sidebarBackground: "#0B2530", sidebarText: "#D7EEF5",
                 sidebarIcon: "#38BDF8", contentBackground: "#0F1E26", text: "#E6F1F5"),
        AppTheme(name: "Forest", accent: "#2F855A", selection: "#2F855A", sidebarBackground: "#13241B", sidebarText: "#DCEFE3",
                 sidebarIcon: "#68D391", contentBackground: "#17201B", text: "#E7F0EA"),
        AppTheme(name: "Sunset", accent: "#DD6B20", selection: "#C05621", sidebarBackground: "#2A1A14", sidebarText: "#F7E3D7",
                 sidebarIcon: "#F6AD55", contentBackground: "#221713", text: "#F5E9E2"),
        AppTheme(name: "Lavender", accent: "#7C3AED", selection: "#7C3AED", sidebarBackground: "#F3EEFC", sidebarText: "#2E1F4F",
                 sidebarIcon: "#7C3AED", contentBackground: "#FBF9FF", text: "#1F1533"),
        AppTheme(name: "Paper", accent: "#9A6B2F", selection: "#B7791F", sidebarBackground: "#F4EFE6", sidebarText: "#3B3127",
                 sidebarIcon: "#9A6B2F", contentBackground: "#FBF8F2", text: "#2B241C"),
        AppTheme(name: "Graphite", accent: "#6B7280", selection: "#4B5563", sidebarBackground: "", sidebarText: "",
                 sidebarIcon: "#9CA3AF", contentBackground: "", text: ""),
        AppTheme(name: "High Contrast", accent: "#FFD60A", selection: "#FFD60A", sidebarBackground: "#000000", sidebarText: "#FFFFFF",
                 sidebarIcon: "#FFD60A", contentBackground: "#000000", text: "#FFFFFF"),
    ]

    /// The light and dark halves of a colour; a single colour is both.
    public static func variants(_ value: String) -> (light: String, dark: String) {
        let parts = value.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? (parts[0], parts[1]) : (value, value)
    }

    /// `#RRGGBB` (or `RRGGBB`) as 0…1 components, the light half of a pair; nil for anything else.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = variants(hex).light.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Whether a background is dark enough that the system's dark look reads on it.
    public static func isDark(_ hex: String) -> Bool? {
        guard let c = rgb(hex) else { return nil }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5
    }

    public static func decode(_ json: String) -> AppTheme? {
        guard var theme = try? JSONDecoder().decode(AppTheme.self, from: Data(json.utf8)) else { return nil }
        if theme.name == "KB" { theme.name = standard.name }
        if theme == previousStandard { theme = standard }
        return theme
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
