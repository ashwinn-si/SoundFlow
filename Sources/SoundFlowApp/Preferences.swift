import Foundation

/// Per-application settings, remembered across launches.
///
/// Keyed by bundle identifier rather than pid, so "Teams at 20%" survives both
/// quitting Teams and restarting SoundFlow.
struct AppPreference: Codable, Equatable {
    var volume: Float
    var isMuted: Bool

    static let `default` = AppPreference(volume: 1.0, isMuted: false)
}

/// Stores per-app volume in `UserDefaults` as a single JSON blob.
enum Preferences {

    private static let storeKey = "SoundFlow.appPreferences"
    private static let favoritesKey = "SoundFlow.favoriteApps"
    private static let customNamesKey = "SoundFlow.customNames"
    private static let iconStylesKey = "SoundFlow.appIconStyles"
    static let hideDockIconKey = "SoundFlow.hideDockIcon"
    static let themeKey = "SoundFlow.theme"

    static func load() -> [String: AppPreference] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: AppPreference].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ preferences: [String: AppPreference]) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - Favourites

    /// Bundle ids the user starred. Kept out of the `AppPreference` blob on
    /// purpose: adding a field there would break decoding of every existing
    /// blob (synthesised `Codable` ignores property defaults for missing keys),
    /// and `clear()` would drop the stars along with the volumes.
    static func loadFavorites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
    }

    static func saveFavorites(_ favorites: Set<String>) {
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    // MARK: - Custom names

    /// User-chosen display names, keyed by bundle id. The system name for an
    /// audio helper process is often meaningless ("Browser Helper",
    /// "callservicesd"), so the user can label it something recognisable.
    /// Stored separately from the volume blob for the same reason as favourites.
    static func loadCustomNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: customNamesKey) as? [String: String] ?? [:]
    }

    static func saveCustomNames(_ names: [String: String]) {
        UserDefaults.standard.set(names, forKey: customNamesKey)
    }

    // MARK: - Icon styles

    /// How each app is drawn: its own icon, or a generated tile with a chosen
    /// colour and letters. Only apps the user actually customised appear here —
    /// everything else falls back to `AppIconStyle.default`.
    ///
    /// A fourth separate key rather than a field on `AppPreference`, for the
    /// same reason as favourites and custom names: one more property in that
    /// blob breaks decoding of every saved one, and `clear()` would take the
    /// icons down with the volumes.
    static func loadIconStyles() -> [String: AppIconStyle] {
        guard let data = UserDefaults.standard.data(forKey: iconStylesKey),
              let decoded = try? JSONDecoder().decode([String: AppIconStyle].self, from: data)
        else { return [:] }
        return decoded
    }

    static func saveIconStyles(_ styles: [String: AppIconStyle]) {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        UserDefaults.standard.set(data, forKey: iconStylesKey)
    }
}
