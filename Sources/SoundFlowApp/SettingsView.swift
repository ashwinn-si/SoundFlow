import AppKit
import SwiftUI

struct SettingsView: View {
    let engine: MixerEngine

    @AppStorage(Preferences.hideDockIconKey) private var hideDockIcon = false

    var body: some View {
        Form {
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
    }
}
