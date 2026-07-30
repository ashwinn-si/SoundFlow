import Foundation
import ServiceManagement

/// Registers SoundFlow as a login item.
///
/// `SMAppService.mainApp` is the modern replacement for the deprecated
/// `SMLoginItemSetEnabled` and needs no helper bundle — macOS registers the
/// main bundle itself and lists it under System Settings → General → Login
/// Items, where the user can override the choice.
///
/// There is no stored preference: `SMAppService` *is* the source of truth. A
/// mirrored `UserDefaults` flag would drift the moment the user toggles the
/// item in System Settings.
enum LaunchAtLogin {

    /// `true` when macOS will start SoundFlow at login.
    ///
    /// `.requiresApproval` means the user disabled it in System Settings, which
    /// is reported honestly as off — the app will not launch.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration fails for an unsigned or quarantined bundle, so the caller
    /// has to surface the error rather than assume success.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Set when the user has to finish the job in System Settings.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
