import AppKit
import SwiftUI

/// The surfaces of the main window.
///
/// Three of these are filters over the same app list rather than different
/// screens — which is the point of the rail over the old top pills: a counted
/// "Starred 3" says something a star-shaped toggle in every row does not.
enum MixerTab: String, CaseIterable, Identifiable {
    case allApps
    case starred
    case playing
    case devices
    case developer
    case version

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allApps:   "All Apps"
        case .starred:   "Starred"
        case .playing:   "Playing"
        case .devices:   "Devices"
        case .developer: "Developer"
        case .version:   "Version"
        }
    }

    var symbol: String {
        switch self {
        case .allApps:   "slider.vertical.3"
        case .starred:   "star.fill"
        case .playing:   "waveform"
        case .devices:   "hifispeaker.and.homepod"
        case .developer: "person.crop.circle"
        case .version:   "tag"
        }
    }
}

/// Left navigation for the main window.
///
/// Carries more than navigation: the settings that used to fill a whole tab —
/// theme, the two startup switches, reset — sit here inline, because each is one
/// control and a tab per control is a tab wasted.
struct Sidebar: View {
    let engine: MixerEngine
    @Binding var selection: MixerTab

    @AppStorage(Preferences.hideDockIconKey) private var hideDockIcon = false
    @AppStorage(Preferences.themeKey) private var themeID = Themes.system.id

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    /// The value of a programmatic toggle write whose `onChange` has not fired
    /// yet, so it can be recognised and ignored.
    ///
    /// A plain `isSyncing` flag set and cleared around the assignment does not
    /// work: `onChange` runs on the next view update, by which point the flag is
    /// already back to `false`. The result was that a failed `register()` reset
    /// the toggle, which then read as a user edit and fired an `unregister()`.
    @State private var pendingProgrammaticValue: Bool?

    @Environment(\.themeAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                label("Mixer")
                item(.allApps, count: engine.apps.count)
                item(.starred, count: engine.favoriteApps.count)
                item(.playing, count: engine.playingApps.count)

                label("System")
                item(.devices)

                label("Settings")
                themeRow
                launchToggle
                dockToggle
                resetButton

                label("About")
                item(.developer)
                item(.version)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(width: 158)
        .scrollContentBackground(.hidden)
        // No colour of its own: a neutral dim plus the divider separates the
        // rail without interrupting the accent wash that crosses both halves.
        .background(Color.black.opacity(0.05))
        .overlay(alignment: .trailing) { Divider() }
        // The user can flip the login item in System Settings, so re-read the
        // real state rather than trusting the last value shown.
        .onAppear { syncLaunchToggle(to: LaunchAtLogin.isEnabled) }
    }

    // MARK: - Navigation

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func item(_ tab: MixerTab, count: Int? = nil) -> some View {
        let isSelected = selection == tab

        return Button {
            selection = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Settings

    /// A menu rather than the swatch row the old Settings tab used: at 158pt
    /// six swatches plus their selection rings do not fit, and the menu shows
    /// the current theme by name for free.
    private var themeRow: some View {
        HStack(spacing: 8) {
            Text("Theme")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("Theme", selection: $themeID) {
                ForEach(Themes.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var launchToggle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: launchAtLogin) { _, enabled in
                    if pendingProgrammaticValue == enabled {
                        pendingProgrammaticValue = nil
                        return
                    }
                    pendingProgrammaticValue = nil
                    applyLaunchAtLogin(enabled)
                }

            if let launchError {
                hint(launchError)
            } else if launchAtLogin && LaunchAtLogin.needsApproval {
                hint("Approve in System Settings → General → Login Items.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var dockToggle: some View {
        Toggle("Hide Dock icon", isOn: $hideDockIcon)
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .onChange(of: hideDockIcon) { _, hidden in
                // .accessory removes the Dock icon and the menu bar entry stays
                // as the only way in.
                NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    /// Tinted red rather than plain: it discards every saved level, and that is
    /// worth signalling before the click rather than after.
    private var resetButton: some View {
        Button {
            engine.resetAll()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text("Reset Volumes")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.red.opacity(0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.red.opacity(0.28), lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sets every application back to 100% and clears saved levels. "
              + "Stars and custom names are kept.")
        .padding(.top, 5)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Launch at login

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
        pendingProgrammaticValue = value
        launchAtLogin = value
    }
}
