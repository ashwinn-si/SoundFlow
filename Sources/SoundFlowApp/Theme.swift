import SwiftUI

/// An accent preset.
///
/// One colour, applied through SwiftUI's `tint` so sliders, stars, toggles and
/// selection states all follow it without every view having to know about
/// theming. Values are mid-tones picked to stay legible on both the light and
/// dark system backgrounds — a colour that reads well on white usually washes
/// out on charcoal, so nothing here sits at the extremes of lightness.
struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    /// `nil` means "whatever the user picked in System Settings".
    private let color: Color?

    init(id: String, name: String, color: Color?) {
        self.id = id
        self.name = name
        self.color = color
    }

    var accent: Color { color ?? .accentColor }

    /// The swatch shown in Settings. The system theme has no fixed colour of
    /// its own, so it borrows the live accent.
    var swatch: Color { accent }
}

enum Themes {

    static let system = Theme(id: "system", name: "System", color: nil)

    static let all: [Theme] = [
        system,
        Theme(id: "ocean",    name: "Ocean",    color: Color(.sRGB, red: 0.18, green: 0.55, blue: 0.78)),
        Theme(id: "forest",   name: "Forest",   color: Color(.sRGB, red: 0.24, green: 0.62, blue: 0.42)),
        Theme(id: "sunset",   name: "Sunset",   color: Color(.sRGB, red: 0.93, green: 0.44, blue: 0.32)),
        Theme(id: "violet",   name: "Violet",   color: Color(.sRGB, red: 0.52, green: 0.40, blue: 0.85)),
        Theme(id: "graphite", name: "Graphite", color: Color(.sRGB, red: 0.45, green: 0.47, blue: 0.50))
    ]

    /// Falls back to the system theme, so a stored id from a future build (or a
    /// removed preset) degrades quietly instead of losing the accent entirely.
    static func theme(id: String) -> Theme {
        all.first { $0.id == id } ?? system
    }
}

// MARK: - Environment

/// The resolved accent, for the few places that need the raw `Color` rather
/// than the inherited tint — custom-drawn bars and meters.
private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}
