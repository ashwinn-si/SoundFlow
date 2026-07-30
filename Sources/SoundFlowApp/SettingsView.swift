import AppKit
import SwiftUI

/// Settings, rendered inside the main window as a tab rather than in a separate
/// scene. With the Dock icon hidden there is no app menu, so `Cmd+,` would be a
/// dead end — one window keeps everything reachable.
struct SettingsView: View {
    let engine: MixerEngine

    @AppStorage(Preferences.hideDockIconKey) private var hideDockIcon = false
    @AppStorage(Preferences.themeKey) private var themeID = Themes.system.id

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    /// Suppresses `onChange` while the toggle is being reset programmatically,
    /// so a failed registration cannot bounce back into another attempt.
    @State private var isSyncingLaunchToggle = false

    private static let githubURL = URL(string: "https://github.com/ashwinn-si")!

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                themeSection
                startupSection
                resetSection
                aboutSection
            }
            .padding(14)
        }
        // The user can flip the login item in System Settings, so re-read the
        // real state rather than trusting the last value shown.
        .onAppear { syncLaunchToggle(to: LaunchAtLogin.isEnabled) }
    }

    // MARK: - Theme

    private var themeSection: some View {
        section("Theme", symbol: "paintpalette") {
            HStack(spacing: 10) {
                ForEach(Themes.all) { theme in
                    swatch(for: theme)
                }
                Spacer(minLength: 0)
            }

            Text(Themes.theme(id: themeID).name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func swatch(for theme: Theme) -> some View {
        let isSelected: Bool = theme.id == themeID
        let ringOpacity: Double = isSelected ? 0.85 : 0

        return Button {
            withAnimation(.easeOut(duration: 0.15)) { themeID = theme.id }
        } label: {
            swatchBody(theme: theme, ringOpacity: ringOpacity)
        }
        .buttonStyle(.plain)
        .help(theme.name)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func swatchBody(theme: Theme, ringOpacity: Double) -> some View {
        // The ring sits outside the fill so selection never changes the
        // swatch's apparent size.
        let ring = Circle()
            .strokeBorder(Color.primary.opacity(ringOpacity), lineWidth: 2)
            .padding(-3)

        return Circle()
            .fill(theme.swatch)
            .frame(width: 22, height: 22)
            .overlay(ring)
            .overlay(systemMark(for: theme))
    }

    @ViewBuilder
    private func systemMark(for theme: Theme) -> some View {
        if theme.id == Themes.system.id {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.9))
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        section("Startup", symbol: "power") {
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
            }

            Divider()

            Toggle("Hide Dock icon", isOn: $hideDockIcon)
                .onChange(of: hideDockIcon) { _, hidden in
                    // .accessory removes the Dock icon and the menu bar entry
                    // stays as the only way in.
                    NSApp.setActivationPolicy(hidden ? .accessory : .regular)
                }

            Text("SoundFlow stays available from the menu bar either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        section("Levels", symbol: "arrow.counterclockwise") {
            Button("Reset All Volumes") {
                engine.resetAll()
            }

            Text("Sets every application back to 100% and clears saved levels. "
                 + "Stars and custom names are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        section("About", symbol: "info.circle") {
            HStack(spacing: 6) {
                Text("SoundFlow")
                    .font(.system(size: 12, weight: .medium))
                Text(Self.version)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Developed by Ashwin SI")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: Self.githubURL) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                    Text("github.com/ashwinn-si")
                }
                .font(.caption)
            }
        }
    }

    /// Read from the bundle so it cannot drift from `Info.plist`.
    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short.map { "v\($0)" } ?? "v1.0.0"
    }

    // MARK: - Layout

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        isSyncingLaunchToggle = true
        launchAtLogin = value
        isSyncingLaunchToggle = false
    }
}
