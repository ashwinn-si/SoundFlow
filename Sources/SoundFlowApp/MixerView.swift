import AppKit
import CoreAudio
import SwiftUI
import SoundFlowCore

/// The mixer: output device, master volume, and one row per audio application.
///
/// Deliberately plain — system materials, system accent colour, automatic
/// light/dark. No gradients or hardcoded colours anywhere.
struct MixerView: View {
    let engine: MixerEngine
    /// Trimmed layout for the menu bar popover.
    var compact = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if engine.permission == .denied {
                PermissionView(engine: engine)
            } else {
                header
                Divider()
                appList
            }

            // The menu bar is the only way back to the app when the Dock icon
            // is hidden, so it carries the window and quit actions.
            if compact {
                Divider()
                footer
            }
        }
        .frame(minWidth: compact ? 300 : 380,
               minHeight: compact ? 260 : 360)
        .frame(width: compact ? 320 : nil)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Output")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Output", selection: outputSelection) {
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Spacer(minLength: 0)
            }

            if engine.hasMasterVolumeControl {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Slider(
                        value: Binding(
                            get: { Double(engine.masterVolume) },
                            set: { engine.masterVolume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)

                    Text("\(Int(engine.masterVolume * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            if let error = engine.routeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var outputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.outputDevices.first { $0.name == engine.outputDeviceName }?.id ?? 0 },
            set: { newID in
                if let device = engine.outputDevices.first(where: { $0.id == newID }) {
                    engine.selectOutputDevice(device)
                }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open SoundFlow") {
                openWindow(id: "main")
                // Needed in .accessory mode, where opening a window does not
                // bring the app forward on its own.
                NSApp.activate()
            }
            .buttonStyle(.link)

            Spacer(minLength: 0)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                // Routes through applicationWillTerminate, which destroys every
                // tap. Anything less leaves apps muted.
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Quit SoundFlow")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Apps

    /// The main window lists everything. The menu bar lists only starred apps —
    /// unless nothing is starred yet, in which case it shows everything rather
    /// than an empty popover.
    private var visibleApps: [AppMix] {
        guard compact else { return engine.apps }
        let favorites = engine.favoriteApps
        return favorites.isEmpty ? engine.apps : favorites
    }

    @ViewBuilder
    private var appList: some View {
        if visibleApps.isEmpty {
            ContentUnavailableView(
                "No Audio Apps",
                systemImage: "speaker.slash",
                description: Text("Applications appear here once they start using audio.")
            )
        } else {
            List(visibleApps) { app in
                AppRowView(app: app, engine: engine, showsFavoriteToggle: !compact)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(compact ? .hidden : .automatic)
        }
    }
}
