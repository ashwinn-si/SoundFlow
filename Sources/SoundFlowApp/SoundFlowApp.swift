import AppKit
import SwiftUI

/// SoundFlow: per-application output volume for macOS.
///
/// A regular windowed app with a Dock icon, plus a menu bar companion showing
/// the same mixer. Both are driven by one shared `MixerEngine`.
@main
struct SoundFlowApp: App {
    @State private var engine = MixerEngine()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SoundFlow", id: "main") {
            MixerView(engine: engine)
                .task {
                    delegate.engine = engine
                    engine.start()
                }
                // Returning from System Settings should update the permission
                // state without needing a relaunch.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    engine.refreshPermission()
                }
        }
        .defaultSize(width: 420, height: 560)
        .windowResizability(.contentMinSize)

        MenuBarExtra("SoundFlow", systemImage: "slider.horizontal.3") {
            MixerView(engine: engine, compact: true)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(engine: engine)
        }
    }
}

/// Handles teardown and the Dock-icon preference.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: MixerEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: Preferences.hideDockIconKey) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroys every tap and aggregate device. Without this, taps outlive
        // the app and leave the apps they were muting silent.
        MainActor.assumeIsolated { engine?.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
