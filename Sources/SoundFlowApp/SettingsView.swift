import AppKit
import SwiftUI

struct SettingsView: View {
    let engine: MixerEngine

    @AppStorage(Preferences.hideDockIconKey) private var hideDockIcon = false

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    /// Suppresses `onChange` while the toggle is being reset programmatically,
    /// so a failed registration cannot bounce back into another attempt.
    @State private var isSyncingLaunchToggle = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard !isSyncingLaunchToggle else { return }
                        applyLaunchAtLogin(enabled)
                    }

                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if launchAtLogin && LaunchAtLogin.needsApproval {
                    Text("Approve SoundFlow in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Starts SoundFlow automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Hide Dock icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, hidden in
                        // .accessory removes the Dock icon and the menu bar
                        // entry stays as the only way in.
                        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
                    }
                Text("SoundFlow stays available from the menu bar either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset All Volumes") {
                    engine.resetAll()
                }
                Text("Sets every application back to 100% and clears saved levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        // The user can flip the login item in System Settings, so re-read the
        // real state rather than trusting the last value shown.
        .onAppear { syncLaunchToggle(to: LaunchAtLogin.isEnabled) }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            syncLaunchToggle(to: LaunchAtLogin.isEnabled)
        }
    }

    private func syncLaunchToggle(to value: Bool) {
        guard launchAtLogin != value else { return }
        isSyncingLaunchToggle = true
        launchAtLogin = value
        isSyncingLaunchToggle = false
    }
}
