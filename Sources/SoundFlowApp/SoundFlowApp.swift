import AppKit
import SwiftUI

/// SoundFlow: per-application output volume for macOS.
///
/// A regular windowed app with a Dock icon, plus a menu bar companion showing
/// the same mixer. Both are driven by one shared `MixerEngine`.
@main
struct SoundFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SoundFlow", id: "main") {
            MixerView(engine: delegate.engine)
        }
        .defaultSize(width: 420, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("SoundFlow", systemImage: "slider.horizontal.3") {
            MixerView(engine: delegate.engine, compact: true)
        }
        .menuBarExtraStyle(.window)

        // No `Settings` scene: settings live in the main window as a tab. With
        // the Dock icon hidden there is no app menu, so a separate settings
        // scene would be unreachable.
    }
}

/// Owns the engine, and handles startup, teardown and the Dock-icon preference.
///
/// The engine deliberately lives here rather than in a `@State` on the `App`
/// struct started from the main window's `.task`. That start never ran when the
/// window was not restored at launch — the common case for "hide Dock icon" plus
/// "launch at login" — so saved levels were not applied, the menu bar was empty,
/// and `applicationWillTerminate` had no engine to tear taps down with.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = MixerEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: Preferences.hideDockIconKey) {
            NSApp.setActivationPolicy(.accessory)
        }
        engine.start()
    }

    /// Returning from System Settings should update the permission state — and
    /// build the route — without needing a relaunch. Handled here rather than in
    /// the main window so it still works when only the menu bar is open.
    func applicationDidBecomeActive(_ notification: Notification) {
        engine.refreshPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroys every tap and aggregate device. Without this, taps outlive
        // the app and leave the apps they were muting silent.
        engine.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
