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
    static let hideDockIconKey = "SoundFlow.hideDockIcon"

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
}
