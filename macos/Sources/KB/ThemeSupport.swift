import AppKit
import KBCore
import SwiftUI

extension Color {
    /// `#RRGGBB`; nil when empty or not a colour.
    init?(hex: String) {
        guard let c = AppTheme.rgb(hex) else { return nil }
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    var hex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return AppTheme.hex(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

enum ThemeStore {
    static let key = "appTheme"

    static var current: AppTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.decode) ?? .standard
    }
}

private struct KBThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.standard
}

extension EnvironmentValues {
    var kbTheme: AppTheme {
        get { self[KBThemeKey.self] }
        set { self[KBThemeKey.self] = newValue }
    }
}

extension AppTheme {
    var sidebarIconColor: Color { Color(hex: sidebarIcon) ?? .blue }
    var selectionColor: Color { Color(hex: selection) ?? .accentColor }
}

/// Puts the chosen theme on a window's content: its accent, text colour and backgrounds.
struct ThemedWindow: ViewModifier {
    @AppStorage(ThemeStore.key) private var raw = ""

    func body(content: Content) -> some View {
        let theme = AppTheme.decode(raw) ?? .standard
        content
            .environment(\.kbTheme, theme)
            .tint(Color(hex: theme.accent))
            .modifier(OptionalForeground(color: Color(hex: theme.text)))
            .modifier(ThemedBackground(color: Color(hex: theme.contentBackground)))
            .onChange(of: raw) { _, _ in AppAppearance.apply() }
    }
}

private struct OptionalForeground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

/// A theme with its own background lets every list and form show it instead of the system's.
private struct ThemedBackground: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color {
            content.scrollContentBackground(.hidden).background(color)
        } else {
            content
        }
    }
}

/// A sidebar's own background, when the theme has one.
struct ThemedSidebar: ViewModifier {
    @Environment(\.kbTheme) private var theme

    func body(content: Content) -> some View {
        sidebar(content).tint(Color(hex: theme.selection) ?? Color(hex: theme.accent))
    }

    @ViewBuilder
    private func sidebar(_ content: Content) -> some View {
        if let bg = Color(hex: theme.sidebarBackground) {
            content.scrollContentBackground(.hidden).background(bg)
                .modifier(OptionalForeground(color: Color(hex: theme.sidebarText)))
        } else {
            content.modifier(OptionalForeground(color: Color(hex: theme.sidebarText)))
        }
    }
}

extension View {
    func themedWindow() -> some View { modifier(ThemedWindow()) }
    func themedSidebar() -> some View { modifier(ThemedSidebar()) }
}

/// A small picture of a theme: a sidebar with a selected row, and content with text and a button.
struct ThemePreview: View {
    let theme: AppTheme
    var large = false

    var body: some View {
        let dark = AppTheme.isDark(theme.contentBackground) ?? AppTheme.isDark(theme.sidebarBackground)
        let text = Color(hex: theme.text) ?? (dark == true ? .white : dark == false ? .black : .primary)
        let side = Color(hex: theme.sidebarBackground) ?? Color(nsColor: .underPageBackgroundColor)
        let sideText = Color(hex: theme.sidebarText) ?? text
        let main = Color(hex: theme.contentBackground) ?? Color(nsColor: .textBackgroundColor)
        let accent = Color(hex: theme.accent) ?? .accentColor
        let icon = theme.sidebarIconColor
        let selection = theme.selectionColor
        let unit: CGFloat = large ? 1.6 : 1
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5 * unit) {
                ForEach(0..<4) { i in
                    HStack(spacing: 4 * unit) {
                        Circle().fill(i == 1 ? Color.white : icon).frame(width: 6 * unit, height: 6 * unit)
                        Capsule().fill((i == 1 ? Color.white : sideText).opacity(0.75)).frame(width: CGFloat(18 + i * 5) * unit, height: 3.5 * unit)
                    }
                    .padding(.horizontal, 4 * unit)
                    .padding(.vertical, 3 * unit)
                    .background(i == 1 ? selection : .clear, in: RoundedRectangle(cornerRadius: 3 * unit))
                }
                Spacer(minLength: 0)
            }
            .padding(6 * unit)
            .frame(width: 58 * unit)
            .frame(maxHeight: .infinity)
            .background(side)
            VStack(alignment: .leading, spacing: 5 * unit) {
                Capsule().fill(text.opacity(0.85)).frame(width: 50 * unit, height: 5 * unit)
                Capsule().fill(text.opacity(0.4)).frame(width: 70 * unit, height: 3.5 * unit)
                Capsule().fill(text.opacity(0.4)).frame(width: 60 * unit, height: 3.5 * unit)
                Spacer(minLength: 0)
                Capsule().fill(accent).frame(width: 32 * unit, height: 9 * unit)
            }
            .padding(8 * unit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(main)
        }
        .frame(height: 74 * unit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .environment(\.colorScheme, dark == true ? .dark : dark == false ? .light : .dark)
    }
}

/// Settings → Appearance: light or dark, a theme from the list, or your own colours.
struct AppearanceSettingsView: View {
    @AppStorage(AppSettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(ThemeStore.key) private var raw = ""

    private var theme: AppTheme { AppTheme.decode(raw) ?? .standard }

    var body: some View {
        Form {
            Section("Look") {
                Picker("Light or dark", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, _ in AppAppearance.apply() }
                if theme.hasBackgrounds {
                    Text("\(theme.name) has its own backgrounds, so it picks light or dark itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Themes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(AppTheme.presets) { preset in
                        Button { raw = preset.encoded() } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ThemePreview(theme: preset)
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(theme.name == preset.name ? Color.accentColor : Color.secondary.opacity(0.25),
                                                      lineWidth: theme.name == preset.name ? 2.5 : 1))
                                Text(preset.name).font(.callout.weight(theme.name == preset.name ? .semibold : .regular))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                ThemePreview(theme: theme, large: true)
                ForEach(AppTheme.Token.allCases) { token in tokenRow(token) }
            } header: {
                HStack {
                    Text("Your colours" + (AppTheme.presets.contains(theme) ? "" : " (custom)"))
                    Spacer()
                    Button("Reset to Mindmill") { raw = AppTheme.standard.encoded() }
                        .buttonStyle(.link)
                }
            } footer: {
                Text("Changing a colour makes a custom theme from the one you started with. Default uses the system's colour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .multilineTextAlignment(.leading)
        .frame(width: 600, height: 640)
    }

    private func tokenRow(_ token: AppTheme.Token) -> some View {
        LabeledContent(token.title) {
            HStack(spacing: 8) {
                if theme[token].isEmpty {
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                }
                ColorPicker(token.title, selection: Binding(
                    get: { Color(hex: theme[token]) ?? (token == .sidebarIcon ? .blue : .gray) },
                    set: { c in edit(token, c.hex) }), supportsOpacity: false)
                    .labelsHidden()
                Button { edit(token, "") } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .disabled(theme[token].isEmpty)
                    .help("Back to the default")
            }
        }
    }

    private func edit(_ token: AppTheme.Token, _ value: String) {
        var t = theme
        guard t[token] != value else { return }
        t[token] = value
        if AppTheme.presets.contains(where: { $0.name == t.name }) && !AppTheme.presets.contains(t) { t.name = "Custom" }
        raw = t.encoded()
    }
}
