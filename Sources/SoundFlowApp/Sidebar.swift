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
/// A `List` of `Section`s rather than a hand-built `VStack`. That is not a
/// stylistic preference: inside a `NavigationSplitView`, `List` supplies the
/// platform's own sidebar metrics — row height, inset, the gap between a
/// section header and its rows — and applies them to *every* row, including the
/// plain `Picker` and `Toggle` controls in Settings. Hand-rolling the stack
/// meant hand-rolling that rhythm too, and the Settings block ended up visibly
/// unevenly spaced against the navigation rows above it.
///
/// The rail also carries settings that used to occupy a whole tab. Each is one
/// control, and a tab per control is a tab wasted.
struct Sidebar: View {
    let engine: MixerEngine
    @Binding var selection: MixerTab

    @AppStorage(Preferences.hideDockIconKey) private var hideDockIcon = false
    @AppStorage(Preferences.themeKey) private var themeID = Themes.system.id

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var showResetAlert = false
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
        List {
            Section("Mixer") {
                row(.allApps, count: engine.apps.count)
                row(.starred, count: engine.favoriteApps.count)
                row(.playing, count: engine.playingApps.count)
            }

            Section("System") {
                row(.devices)
            }

            Section("Settings") {
                HStack(spacing: Self.glyphGap) {
                    glyph("paintpalette")
                    Picker(selection: $themeID) {
                        ForEach(Themes.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    } label: {
                        Text("Theme")
                    }
                    .controlSize(.small)
                }

                checkRow("Launch at login", isOn: $launchAtLogin)
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

                checkRow("Hide Dock icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, hidden in
                        // .accessory removes the Dock icon and the menu bar
                        // entry stays as the only way in.
                        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
                    }

                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    HStack(spacing: Self.glyphGap) {
                        glyph("arrow.counterclockwise")
                        Text("Reset Volumes")
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.red)
                    .contentShape(Rectangle())
                }
                // .plain, so it draws as a row like everything else. The
                // default button background made it a filled pill inset from
                // both margins, which broke the column on its own.
                .buttonStyle(.plain)
                // Confirmed rather than immediate: it discards every saved
                // level, and there is no undo.
                .alert("Reset all volumes?", isPresented: $showResetAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset", role: .destructive) { engine.resetAll() }
                } message: {
                    Text("Every application goes back to 100% and saved levels "
                         + "are cleared. Stars and custom names are kept.")
                }
            }

            Section("About") {
                row(.developer)
                row(.version)
            }
        }
        // Let the window's accent wash show through instead of the list's own
        // opaque backing.
        .scrollContentBackground(.hidden)
        // The user can flip the login item in System Settings, so re-read the
        // real state rather than trusting the last value shown.
        .onAppear { syncLaunchToggle(to: LaunchAtLogin.isEnabled) }
    }

    // MARK: - Shared column

    /// One leading column for the whole rail.
    ///
    /// `Label` will not do this: SF Symbols have different intrinsic widths
    /// (`paintpalette` is visibly wider than `arrow.counterclockwise`), so a
    /// rail built from `Label`s starts its text at a different x on nearly
    /// every row. A fixed frame is what makes the column a column.
    private static let glyphWidth: CGFloat = 18
    private static let glyphGap: CGFloat = 8

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12))
            .frame(width: Self.glyphWidth, alignment: .center)
    }

    /// A checkbox occupying the same leading slot as an icon.
    ///
    /// The checkbox has to be label-less to sit in that slot, which would
    /// normally cost the click target — a bare `Text` beside it toggles
    /// nothing. Wrapping the row in a button and making the checkbox
    /// transparent to hit-testing keeps the whole row clickable, which is how
    /// a checkbox is expected to behave.
    private func checkRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: Self.glyphGap) {
                Toggle("", isOn: isOn)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .frame(width: Self.glyphWidth, alignment: .center)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(title, isOn: isOn)
        }
    }

    // MARK: - Navigation rows

    /// A button rather than `List(selection:)`.
    ///
    /// macOS draws native sidebar selection in the *system* accent, which
    /// ignores the theme the user picked here. Tinting the row background by
    /// hand is what keeps selection on-theme.
    @ViewBuilder
    private func row(_ tab: MixerTab, count: Int? = nil) -> some View {
        let isSelected = selection == tab

        Button {
            selection = tab
        } label: {
            HStack(spacing: Self.glyphGap) {
                glyph(tab.symbol)
                Text(tab.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? accent.opacity(0.16) : .clear)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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
