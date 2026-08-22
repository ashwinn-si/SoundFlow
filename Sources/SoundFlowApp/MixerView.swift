import AppKit
import CoreAudio
import SwiftUI
import SoundFlowCore

/// The mixer.
///
/// Two layouts from one view. The main window gets a sidebar and a content
/// pane; the menu bar popover stays a single lean list, because a dropdown is
/// for a two-second adjustment and navigation would make it a chore — and a
/// 158pt rail does not fit in a 320pt popover anyway.
///
/// Colour comes from exactly one place: the theme accent, applied once as a
/// `tint` at the root so sliders, stars and toggles inherit it, and once more
/// as the background wash. Everything else is system material and automatic
/// light/dark.
struct MixerView: View {
    let engine: MixerEngine
    /// Trimmed layout for the menu bar popover.
    var compact = false

    @AppStorage(Preferences.themeKey) private var themeID = Themes.system.id
    enum CompactTab {
        case apps, devices
    }
    @State private var compactTab: CompactTab = .apps
    @State private var tab: MixerTab = .allApps
    /// The app whose name and icon are being edited. Hosted here rather than in
    /// each row so there is one sheet, not one per visible app.
    @State private var editing: AppMix?
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
        .background(AccentWash(accent: theme.accent))
        .frame(minWidth: compact ? 300 : 560,
               minHeight: compact ? 260 : 440)
        .frame(width: compact ? 320 : nil)
        .sheet(item: $editing) { app in
            CustomizeAppSheet(app: app, engine: engine)
                .tint(theme.accent)
                .environment(\.themeAccent, theme.accent)
        }
        // The playing indicator is driven by HAL notifications; this is the
        // backstop under them, and it only needs to run while a row is on
        // screen to be seen going stale. Refcounted in the engine, because the
        // window and the menu bar popover can both be open.
        .onAppear { engine.beginObservingPlayback() }
        .onDisappear { engine.endObservingPlayback() }
    }

    // MARK: - Main window

    /// A `NavigationSplitView` rather than an `HStack` of two panes.
    ///
    /// It is what buys the platform behaviour that a hand-built split cannot:
    /// the sidebar runs the full height of the window with the traffic lights
    /// sitting on it, the collapse control appears in the toolbar for free, and
    /// the title belongs to the real titlebar instead of being body text drawn
    /// near the top of the content.
    @ViewBuilder
    private var windowLayout: some View {
        if engine.permission == .denied {
            // The rail is meaningless without permission — every filter would
            // list apps whose sliders do nothing — so it is not drawn at all.
            PermissionView(engine: engine)
        } else {
            NavigationSplitView {
                Sidebar(engine: engine, selection: $tab)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 280)
            } detail: {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(tab.title)
                    .navigationSubtitle(subtitle)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// Empty rather than `nil`: `navigationSubtitle` takes a `String`, and an
    /// empty one simply draws nothing.
    private var subtitle: String {
        switch tab {
        case .allApps: "\(engine.apps.count) apps"
        case .starred: "\(engine.favoriteApps.count) in menu bar"
        case .playing: "\(engine.playingApps.count) making sound"
        default: ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .allApps:
            appList(engine.apps) { allAppsEmpty }
        case .starred:
            appList(engine.favoriteApps) { starredEmpty }
        case .playing:
            appList(engine.playingApps) { playingEmpty }
        case .devices:
            DevicesView(engine: engine)
        case .developer:
            DeveloperView()
        case .version:
            VersionView()
        }
    }

    // MARK: - Menu bar

    private var compactLayout: some View {
        VStack(spacing: 0) {
            if engine.permission == .denied {
                PermissionView(engine: engine)
            } else {
                Picker("View", selection: $compactTab) {
                    Text("Audio").tag(CompactTab.apps)
                    Text("Devices").tag(CompactTab.devices)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()

                ZStack(alignment: .top) {
                    if compactTab == .apps {
                        VStack(spacing: 0) {
                            compactHeader
                            Divider()
                            appList(visibleCompactApps) { allAppsEmpty }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading),
                            removal: .move(edge: .leading)
                        ))
                    } else {
                        compactDevicesList
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .trailing)
                        ))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: compactTab)
            }

            Divider()
            footer
        }
    }

    private var compactHeader: some View {
        VStack(spacing: 8) {
            Picker("Output", selection: outputSelection) {
                ForEach(visibleCompactOutputDevices) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if engine.hasMasterVolumeControl {
                LevelSlider(
                    symbol: "speaker.fill",
                    value: Binding(
                        get: { Double(engine.masterVolume) },
                        set: { engine.setMasterVolume(Float($0)) }
                    ),
                    isMuted: Binding(
                        get: { engine.isOutputMuted },
                        set: { engine.setOutputMuted($0) }
                    )
                )
            } else {
                Text("This device has no software volume control.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let error = engine.routeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private var compactDevicesList: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !visibleCompactOutputDevices.isEmpty {
                    compactDeviceCard(
                        title: "Output",
                        symbol: "speaker.wave.2.fill",
                        devices: visibleCompactOutputDevices,
                        selection: outputSelection
                    ) {
                        if engine.hasMasterVolumeControl {
                            LevelSlider(
                                symbol: "speaker.fill",
                                value: Binding(
                                    get: { Double(engine.masterVolume) },
                                    set: { engine.setMasterVolume(Float($0)) }
                                ),
                                isMuted: Binding(
                                    get: { engine.isOutputMuted },
                                    set: { engine.setOutputMuted($0) }
                                )
                            )
                        } else {
                            Text("This device has no software volume control.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if !visibleCompactInputDevices.isEmpty {
                    compactDeviceCard(
                        title: "Input",
                        symbol: "mic.fill",
                        devices: visibleCompactInputDevices,
                        selection: inputSelection
                    ) {
                        if engine.hasInputVolumeControl {
                            LevelSlider(
                                symbol: "mic.fill",
                                value: Binding(
                                    get: { Double(engine.inputVolume) },
                                    set: { engine.setInputVolume(Float($0)) }
                                ),
                                isMuted: Binding(
                                    get: { engine.isInputMuted },
                                    set: { engine.setInputMuted($0) }
                                )
                            )
                        } else {
                            Text("This microphone has no software gain control.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(14)
        }
        .scrollContentBackground(.hidden)
    }

    private func compactDeviceCard<Control: View>(
        title: String,
        symbol: String,
        devices: [AudioDeviceItem],
        selection: Binding<AudioObjectID>,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(title, selection: selection) {
                ForEach(devices) { device in
                    Text(device.displayName).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            control()

            if let error = engine.routeError, title == "Output" {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

    private var inputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.inputDeviceID },
            set: { newID in
                if let device = engine.inputDevices.first(where: { $0.id == newID }) {
                    engine.selectInputDevice(device)
                }
            }
        )
    }

    // MARK: - Apps

    /// The menu bar lists only starred apps — unless nothing is starred yet, in
    /// which case it shows everything rather than an empty popover.
    private var visibleCompactApps: [AppMix] {
        let favorites = engine.favoriteApps
        return favorites.isEmpty ? engine.apps : favorites
    }

    private var visibleCompactOutputDevices: [AudioDeviceItem] {
        let favs = engine.outputDevices.filter(\.isFavorite)
        return favs.isEmpty ? engine.outputDevices : favs
    }

    private var visibleCompactInputDevices: [AudioDeviceItem] {
        let favs = engine.inputDevices.filter(\.isFavorite)
        return favs.isEmpty ? engine.inputDevices : favs
    }

    @ViewBuilder
    private func appList<Empty: View>(
        _ apps: [AppMix],
        @ViewBuilder empty: () -> Empty
    ) -> some View {
        if apps.isEmpty {
            empty()
        } else {
            List(apps) { app in
                AppRowView(app: app,
                           engine: engine,
                           showsRowActions: !compact,
                           onEdit: { editing = $0 })
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var allAppsEmpty: some View {
        ContentUnavailableView(
            "No Audio Apps",
            systemImage: "speaker.slash",
            description: Text("Applications appear here once they start using audio.")
        )
    }

    private var starredEmpty: some View {
        ContentUnavailableView(
            "Nothing Starred",
            systemImage: "star",
            description: Text("Star an app to keep it in the menu bar popover.")
        )
    }

    private var playingEmpty: some View {
        ContentUnavailableView(
            "Nothing Playing",
            systemImage: "waveform",
            description: Text("Apps appear here while they are producing audio.")
        )
    }
}

// MARK: - Accent wash

/// The window's background: a bloom of the theme accent from the top-left, and
/// a fainter counter-light from the bottom-right.
///
/// The stops are explicit rather than an even three-colour spread, which falls
/// off too fast and reads as a smudge instead of a wash. Light mode gets a much
/// gentler bloom — what reads as elegant on charcoal reads as a stain on white.
struct AccentWash: View {
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            Rectangle().fill(.background)

            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: accent.opacity(isDark ? 0.26 : 0.15), location: 0),
                    .init(color: accent.opacity(isDark ? 0.09 : 0.055), location: 0.36),
                    .init(color: accent.opacity(0), location: 0.70)
                ]),
                center: .topLeading,
                startRadius: 0,
                endRadius: 620
            )

            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: accent.opacity(isDark ? 0.07 : 0.04), location: 0),
                    .init(color: accent.opacity(0), location: 0.62)
                ]),
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}
