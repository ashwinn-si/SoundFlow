import AppKit
import CoreAudio
import SwiftUI
import SoundFlowCore

/// The mixer.
///
/// Two layouts from one view. The main window gets a nav bar and three tabs;
/// the menu bar popover stays a single lean list, because a dropdown is for a
/// two-second adjustment and tabs would make it a chore.
///
/// Colour comes from exactly one place: the theme accent, applied once as a
/// `tint` at the root so sliders, stars and toggles inherit it. Everything else
/// is system material and automatic light/dark.
struct MixerView: View {
    let engine: MixerEngine
    /// Trimmed layout for the menu bar popover.
    var compact = false

    @AppStorage(Preferences.themeKey) private var themeID = Themes.system.id
    @State private var tab: MixerTab = .mixer
    @Environment(\.openWindow) private var openWindow

    private var theme: Theme { Themes.theme(id: themeID) }

    var body: some View {
        Group {
            if compact {
                compactLayout
            } else {
                windowLayout
            }
        }
        .tint(theme.accent)
        .environment(\.themeAccent, theme.accent)
        .frame(minWidth: compact ? 300 : 400,
               minHeight: compact ? 260 : 420)
        .frame(width: compact ? 320 : nil)
    }

    // MARK: - Main window

    @ViewBuilder
    private var windowLayout: some View {
        if engine.permission == .denied {
            PermissionView(engine: engine)
        } else {
            VStack(spacing: 0) {
                NavBar(selection: $tab)
                Divider()

                switch tab {
                case .mixer:
                    mixerTab
                case .devices:
                    DevicesView(engine: engine)
                case .settings:
                    SettingsView(engine: engine)
                }
            }
        }
    }

    /// The master level stays here rather than moving to Devices with the
    /// pickers — it is adjusted constantly, and burying it a tab away would be
    /// a downgrade. Only device *selection* moved.
    private var mixerTab: some View {
        VStack(spacing: 0) {
            if engine.hasMasterVolumeControl {
                masterRow
                Divider()
            }
            appList
        }
    }

    private var masterRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(engine.outputDeviceName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("\(Int(engine.masterVolume * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(engine.masterVolume) },
                        set: { engine.masterVolume = Float($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Menu bar

    private var compactLayout: some View {
        VStack(spacing: 0) {
            if engine.permission == .denied {
                PermissionView(engine: engine)
            } else {
                compactHeader
                Divider()
                appList
            }

            Divider()
            footer
        }
    }

    /// Output device and master level only. Input lives in the Devices tab —
    /// switching a microphone is not a menu bar errand.
    private var compactHeader: some View {
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
                LevelSlider(
                    symbol: "speaker.fill",
                    value: Binding(
                        get: { Double(engine.masterVolume) },
                        set: { engine.masterVolume = Float($0) }
                    )
                )
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

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "main")
                // Needed in .accessory mode, where opening a window does not
                // bring the app forward on its own.
                NSApp.activate()
            } label: {
                Text("Open SoundFlow")
                    .font(.system(size: 12, weight: .medium))
            }
            // Not .link: that style hardcodes the system blue and ignores tint,
            // which left the footer off-theme.
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)

            Spacer(minLength: 0)

            Button {
                // Routes through applicationWillTerminate, which destroys every
                // tap. Anything less leaves apps muted.
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .help("Quit SoundFlow")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Matched on device id, not name: two identical USB interfaces report the
    /// same name, and a name lookup then selects whichever came first — or
    /// nothing at all when the name reads "Unknown", leaving the picker blank.
    private var outputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.outputDeviceID },
            set: { newID in
                if let device = engine.outputDevices.first(where: { $0.id == newID }) {
                    engine.selectOutputDevice(device)
                }
            }
        )
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
