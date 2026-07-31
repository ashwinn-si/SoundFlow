import AppKit
import CoreAudio
import os
import Foundation
import Observation
import SoundFlowCore

// MARK: - Logging

/// Diagnostics for the parts of the engine driven by HAL notifications, where
/// a missing callback is otherwise indistinguishable from nothing happening.
enum SoundFlowLog {
    static let registry = Logger(subsystem: "com.soundflow.app", category: "registry")
    static let devices = Logger(subsystem: "com.soundflow.app", category: "devices")
}

// MARK: - AppMix

/// One application in the mixer.
@MainActor
@Observable
final class AppMix {
    let bundleID: String
    private(set) var pid: pid_t
    /// The process object the tap is built on: whichever of this app's audio
    /// processes is actually producing output, falling back to the first.
    private(set) var processObjectID: AudioObjectID

    /// **Every** process object reporting this bundle id, not just the tapped
    /// one. Chromium and Electron apps play from a helper process that reports
    /// the parent's bundle id, so a row routinely stands for several. Kept so
    /// the playback poll can re-read them all without re-enumerating the HAL.
    ///
    /// Not observable: nothing draws it, and republishing it on every refresh
    /// would invalidate every row for a value the UI never reads.
    @ObservationIgnored private(set) var processObjectIDs: [AudioObjectID] = []

    /// The name macOS reports. Often unhelpful for helper processes.
    let name: String
    /// User override for `name`. `nil` means "use what macOS said".
    var customName: String?
    /// What the UI shows and what the list sorts by.
    var displayName: String { customName ?? name }

    let icon: NSImage?

    /// `0...1`. Anything below 1.0 requires a tap; 1.0 plays natively.
    var volume: Float = 1.0
    var isMuted: Bool = false

    /// `true` while CoreAudio still has a live process for this app.
    ///
    /// A starred app that has quit stays in the list as an inactive row so the
    /// user can see and unstar it. It has no process object, so it can never be
    /// tapped — hence the `isActive` term in `needsTap`.
    var isActive: Bool = true

    /// `true` while the process has an active output stream.
    ///
    /// Drives the sidebar's Playing filter, the row's pulsing indicator, and
    /// the sort. Comes from the HAL's `IsRunningOutput`, so it is independent
    /// of whether the app is tapped — an app at 100% still reports honestly.
    var isPlaying: Bool = false
    /// Set when macOS refuses to tap the app (FairPlay-protected audio).
    var isDRMProtected: Bool = false

    /// Starred by the user. Purely a display filter — the menu bar lists only
    /// these. It has no bearing on whether the app is tapped.
    var isFavorite: Bool = false

    /// Whether this app currently needs to be routed through the mixer.
    var needsTap: Bool { isActive && !isDRMProtected && (isMuted || volume < 0.999) }

    /// Playing, but nothing of it reaches the speakers.
    ///
    /// `isPlaying` comes from the HAL and describes what the *app* emits, which
    /// is upstream of our gain stage — so it stays true for an app the user has
    /// turned all the way down. This is the term the row needs to draw that
    /// state honestly. The threshold matches the one `muteSymbol` already uses.
    var isSilenced: Bool { isMuted || volume < 0.01 }

    init(bundleID: String, pid: pid_t, processObjectID: AudioObjectID,
         processObjectIDs: [AudioObjectID] = [],
         name: String, icon: NSImage?) {
        self.bundleID = bundleID
        self.pid = pid
        self.processObjectID = processObjectID
        self.processObjectIDs = processObjectIDs.isEmpty ? [processObjectID]
                                                         : processObjectIDs
        self.name = name
        self.icon = icon
    }

    func refresh(pid: pid_t, processObjectID: AudioObjectID,
                 processObjectIDs: [AudioObjectID], isPlaying: Bool) {
        self.pid = pid
        self.processObjectID = processObjectID
        self.processObjectIDs = processObjectIDs
        self.isPlaying = isPlaying
        self.isActive = true
    }

    /// The process is gone, but the row stays because the app is starred.
    func markInactive() {
        pid = 0
        processObjectID = AudioObjectID(kAudioObjectUnknown)
        processObjectIDs = []
        isActive = false
        isPlaying = false
        // A future launch may not be DRM-protected; re-test rather than inherit.
        isDRMProtected = false
    }
}

/// Declared outside the class body so `id` stays nonisolated: SwiftUI's `List`
/// reads it without hopping to the main actor.
extension AppMix: Identifiable {
    nonisolated var id: String { bundleID }
}

/// What the mixer needs to label a row: everything else about an app comes from
/// the HAL or from preferences.
typealias AppDescriptor = (name: String, icon: NSImage?)

// MARK: - MixerEngine

/// Coordinates the process registry, the audio route, and per-app volume.
///
/// There is no activate/deactivate step: the UI sets a volume and the engine
/// decides whether a tap is required. An app left at 100% is never tapped, so it
/// plays natively with no added latency and no risk — only attenuated apps enter
/// the audio path.
@MainActor
@Observable
final class MixerEngine {

    // MARK: Observable state

    private(set) var apps: [AppMix] = []
    /// The starred subset, in the same order as `apps`.
    var favoriteApps: [AppMix] { apps.filter(\.isFavorite) }
    /// The subset currently producing audio, in the same order as `apps`.
    ///
    /// A display filter and nothing more. `routedApps` remains the slot
    /// authority for the IOProc — filtering the list here can never affect it.
    var playingApps: [AppMix] { apps.filter(\.isPlaying) }
    private(set) var outputDevices: [AudioDeviceItem] = []
    private(set) var inputDevices: [AudioDeviceItem] = []
    private(set) var permission: TapPermissionStatus = .undetermined
    private(set) var outputDeviceName: String = ""
    private(set) var inputDeviceName: String = ""
    /// Set when the route cannot be built, so the UI can explain itself.
    private(set) var routeError: String?

    /// The default **output device's own** level — the same value the volume
    /// keys and Control Center move. Not a SoundFlow gain stage: this is the
    /// hardware's control, and the two are kept as one number in both
    /// directions.
    ///
    /// `private(set)` on purpose. It used to be settable with a `didSet` that
    /// pushed to the hardware, which meant every assignment was also a write —
    /// so copying a device's own level *in* bounced it straight back out, and
    /// the only thing standing between that and a device being forced to 100%
    /// was a `isReadingDeviceVolume` flag every reader had to remember. Now the
    /// two directions are separate methods and the hazard cannot be expressed.
    private(set) var masterVolume: Float = 1.0
    private(set) var isOutputMuted: Bool = false

    var hasMasterVolumeControl: Bool = true

    /// Input gain for the default capture device. Separate from `masterVolume`
    /// because the same selectors address playback and capture by scope.
    private(set) var inputVolume: Float = 1.0
    private(set) var isInputMuted: Bool = false

    /// Plenty of microphones expose no settable gain, so the slider hides.
    var hasInputVolumeControl: Bool = true

    // MARK: Private state

    private let registry = AudioProcessRegistry()
    private let deviceManager = AudioDeviceManager()

    private var route: AggregateRoute?
    private var watchdog: RouteWatchdog?
    /// Taps currently in the route, parallel to the route's slot indices.
    private var routedApps: [AppMix] = []
    private var taps: [ProcessTap] = []

    /// Readable by the UI so the output picker can match on identity rather than
    /// on a display name, which is not unique across devices — two identical
    /// USB interfaces report the same name.
    private(set) var outputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDeviceUID: String?
    /// Readable by the UI so the input picker can match on identity rather than
    /// on a display name, which is not unique across devices.
    private(set) var inputDeviceID: AudioObjectID = kAudioObjectUnknown

    private var preferences: [String: AppPreference] = [:]
    private var favorites: Set<String> = []
    private var customNames: [String: String] = [:]
    /// Only apps the user customised. Absent means `AppIconStyle.default`.
    private var iconStyles: [String: AppIconStyle] = [:]
    /// Bundle id → name and icon, or `nil` for "this is not an app". See
    /// `cachedBundleDescriptor(_:)`.
    private var descriptorCache: [String: AppDescriptor?] = [:]
    private var watchdogFeedTimer: Timer?
    private var started = false
    /// Coalesces `UserDefaults` writes: a slider drag calls `persist` on every
    /// frame, and each call re-encodes the whole preference blob.
    private var preferenceSaveTask: Task<Void, Never>?
    /// Recovery attempts carried across watchdog-driven rebuilds. Each rebuild
    /// produces a fresh `RouteWatchdog`, so the budget has to live out here or
    /// `maxRecoveryAttempts` never bites.
    private var routeRecoveryAttempts = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        // Clear anything a previous crash stranded: a leaked tap keeps an app
        // muted, and a stale aggregate clutters the device list.
        TapMaintenance.destroyOrphanedTaps()
        AggregateRoute.destroyOrphanedRoutes()

        preferences = Preferences.load()
        favorites = Preferences.loadFavorites()
        customNames = Preferences.loadCustomNames()
        iconStyles = Preferences.loadIconStyles()

        refreshDevices()
        requestPermission()

        // Observe before reading, not after.
        //
        // `refreshApps()` used to run first, and its `snapshot()` is what
        // installs the per-process `IsRunningOutput` listeners — but that call
        // early-returns while the registry is not yet listening. The result was
        // that no app running at launch ever had an output listener: it could
        // start playing and nothing fired, so `isPlaying` stayed false until
        // some unrelated change to the process list forced a refresh.
        registry.onChange = { [weak self] in
            Task { @MainActor in self?.refreshApps() }
        }
        registry.startMonitoring()

        refreshApps()

        deviceManager.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        // Choosing a different existing device in Control Center changes no
        // device list, so without these the route keeps feeding the old device.
        deviceManager.onDefaultOutputChanged = { [weak self] in
            Task { @MainActor in self?.refreshOutputState() }
        }
        deviceManager.onDefaultInputChanged = { [weak self] in
            Task { @MainActor in self?.refreshInputState() }
        }
        // The volume keys, Control Center and the Sound pane all change a
        // device's own level without touching any of the selectors above. These
        // are what keep the master slider from going stale — the app used to
        // sit at whatever it last read while the Mac was somewhere else
        // entirely.
        deviceManager.onOutputLevelChanged = { [weak self] in
            Task { @MainActor in self?.readOutputLevel() }
        }
        deviceManager.onInputLevelChanged = { [weak self] in
            Task { @MainActor in self?.readInputLevel() }
        }
        deviceManager.startMonitoringDeviceChanges()
        // After the listener context exists: `observeLevels` needs it, and the
        // `refreshDevices()` above ran before there was one.
        observeDeviceLevels()

        observeWorkspace()
    }

    func stop() {
        stopWatchdogFeed()
        stopPlaybackPoll()
        visibleSurfaces = 0
        registry.stopMonitoring()
        deviceManager.stopMonitoringDeviceChanges()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver(_:))
        workspaceObservers = []

        teardownRoute()
        flushPreferences()
        started = false
    }

    // MARK: - Sleep / wake

    /// Taps routinely come back from sleep in the zero-buffer state. The
    /// watchdog would catch it, but only after three seconds of silence — and
    /// only if something is playing. Rebuilding on wake makes the recovery
    /// immediate, and dropping the route on sleep means no tap is left holding
    /// an app muted while the machine is suspended.
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            // Synchronous, not a `Task` hop: the system does not wait for our
            // queue to drain before suspending, and a teardown that lands after
            // sleep is a teardown that did not happen.
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.teardownRoute() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            },
            // An app that was not installed when we last looked it up is the
            // only way a cached "not an app" answer becomes wrong.
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateUnresolvedDescriptors() }
            }
        ]
    }

    private func handleWake() {
        // Devices come and go across a sleep (a dock, a Bluetooth headset), so
        // re-read them before deciding what the route should contain.
        teardownRoute()
        routeRecoveryAttempts = 0
        refreshDevices()
        refreshApps()
    }

    // MARK: - Permission

    /// Re-reads TCC state, and builds the route if the answer just became yes.
    ///
    /// Called whenever the app activates, which is how a user returning from
    /// System Settings gets working sliders. Without the `syncRoute()` the UI
    /// unblocked but no tap was ever created until the process list happened to
    /// change — the app looked granted and did nothing.
    func refreshPermission() {
        let previous = permission
        permission = TapPermission.status()
        guard permission == .granted, previous != .granted else { return }
        routeRecoveryAttempts = 0
        syncRoute()
    }

    /// Raises the system prompt on first launch. Once macOS has been answered
    /// once it will not ask again, so the UI falls back to a Settings link.
    func requestPermission() {
        permission = TapPermission.request()
        if permission == .granted { syncRoute() }
    }

    func openPermissionSettings() {
        TapPermission.openSystemSettings()
    }

    // MARK: - Devices

    func refreshDevices() {
        let all = deviceManager.getAllDevices()
        outputDevices = all.filter(\.isOutput)
        inputDevices = all.filter(\.isInput)
        refreshOutputState()
        refreshInputState()
    }

    func selectOutputDevice(_ device: AudioDeviceItem) {
        deviceManager.setDefaultDevice(device.id, isInput: false)
        refreshOutputState()
    }

    func selectInputDevice(_ device: AudioDeviceItem) {
        deviceManager.setDefaultDevice(device.id, isInput: true)
        refreshInputState()
    }

    /// Re-reads the default playback device and its level, rebuilding the route
    /// when the device actually changed.
    ///
    /// Keyed on the device **UID**, not the `AudioObjectID`: ids are recycled
    /// when hardware comes and goes, so an unplug/replug can hand back the same
    /// number for a different device.
    private func refreshOutputState() {
        let previousUID = outputDeviceUID
        outputDeviceID = deviceManager.getDefaultOutputDeviceID() ?? kAudioObjectUnknown
        outputDeviceUID = caDeviceUID(outputDeviceID)
        outputDeviceName = outputDevices.first { $0.id == outputDeviceID }?.name ?? "Unknown"

        hasMasterVolumeControl = deviceManager.hasSettableVolume(deviceID: outputDeviceID)
        readOutputLevel()
        // The old device's listeners are useless now, and ids get recycled, so
        // one left behind is worse than none.
        observeDeviceLevels()

        // Everything routed through the old device has to be rebuilt.
        guard previousUID != outputDeviceUID else { return }
        teardownRoute()
        routeRecoveryAttempts = 0
        syncRoute()
    }

    /// Re-reads the default capture device and its gain. Split out so switching
    /// an input never touches the output route.
    private func refreshInputState() {
        inputDeviceID = deviceManager.getDefaultInputDeviceID() ?? kAudioObjectUnknown
        inputDeviceName = inputDevices.first { $0.id == inputDeviceID }?.name ?? "Unknown"

        hasInputVolumeControl = deviceManager.hasSettableVolume(
            deviceID: inputDeviceID, scope: kAudioObjectPropertyScopeInput)
        readInputLevel()
        observeDeviceLevels()
    }

    private func observeDeviceLevels() {
        deviceManager.observeLevels(outputDeviceID: outputDeviceID,
                                    inputDeviceID: inputDeviceID)
    }

    // MARK: - Device level

    /// The last scalar we wrote to the output device, so the notification our
    /// own write provokes can be told from someone else's change. See
    /// `readOutputLevel()`.
    private var lastWrittenMasterVolume: Float?
    private var lastWrittenInputVolume: Float?

    /// Copies the output device's own level and mute into the published state.
    ///
    /// Reading never writes: that is the whole point of the split, and a device
    /// with no readable volume must not be forced to 100% just because someone
    /// refreshed the device list.
    ///
    /// The echo check is cosmetic, not correctness. Writing the scalar makes the
    /// HAL notify us straight back, and the value that comes back is quantised
    /// to whatever the hardware actually accepted — so mid-drag it yanks the
    /// thumb out from under the pointer. Ignoring a value that matches what we
    /// just wrote leaves the drag smooth without ever suppressing a real change.
    private func readOutputLevel() {
        guard outputDeviceID != kAudioObjectUnknown else { return }

        var level = masterVolume
        if let hardware = deviceManager.getMasterVolume(deviceID: outputDeviceID) {
            if let written = lastWrittenMasterVolume, abs(hardware - written) < 0.01 {
                // Our own echo. Keep the value the user is dragging.
            } else {
                level = hardware
                lastWrittenMasterVolume = nil
            }
        }
        let muted = deviceManager.isMuted(deviceID: outputDeviceID) ?? false

        // One change arrives several times: a device that answers both the
        // virtual-main selector and the scalar notifies on each, and holding a
        // volume key produces a stream of them. Assigning an unchanged value to
        // an `@Observable` property still invalidates every view reading it, so
        // the comparison is what keeps a key-repeat from re-rendering the mixer
        // four times per step.
        guard level != masterVolume || muted != isOutputMuted else { return }
        masterVolume = level
        isOutputMuted = muted
        SoundFlowLog.devices.debug("output level: \(Int(level * 100), privacy: .public)%\(muted ? " muted" : "", privacy: .public)")
    }

    private func readInputLevel() {
        guard inputDeviceID != kAudioObjectUnknown else { return }

        var level = inputVolume
        if let hardware = deviceManager.getMasterVolume(
            deviceID: inputDeviceID, scope: kAudioObjectPropertyScopeInput) {
            if let written = lastWrittenInputVolume, abs(hardware - written) < 0.01 {
                // Our own echo.
            } else {
                level = hardware
                lastWrittenInputVolume = nil
            }
        }
        let muted = deviceManager.isMuted(
            deviceID: inputDeviceID, scope: kAudioObjectPropertyScopeInput) ?? false

        guard level != inputVolume || muted != isInputMuted else { return }
        inputVolume = level
        isInputMuted = muted
        SoundFlowLog.devices.debug("input level: \(Int(level * 100), privacy: .public)%\(muted ? " muted" : "", privacy: .public)")
    }

    /// Moves the Mac's own output volume. The published value and the hardware
    /// are one number — this is the only place that writes both.
    func setMasterVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard abs(clamped - masterVolume) > 0.0001 else { return }
        masterVolume = clamped
        lastWrittenMasterVolume = clamped
        deviceManager.setMasterVolume(clamped, deviceID: outputDeviceID)
    }

    func setInputVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        guard abs(clamped - inputVolume) > 0.0001 else { return }
        inputVolume = clamped
        lastWrittenInputVolume = clamped
        deviceManager.setMasterVolume(clamped,
                                      deviceID: inputDeviceID,
                                      scope: kAudioObjectPropertyScopeInput)
    }

    func setOutputMuted(_ muted: Bool) {
        isOutputMuted = muted
        deviceManager.setMuted(muted, deviceID: outputDeviceID)
    }

    func setInputMuted(_ muted: Bool) {
        isInputMuted = muted
        deviceManager.setMuted(muted,
                               deviceID: inputDeviceID,
                               scope: kAudioObjectPropertyScopeInput)
    }

    // MARK: - App list

    func refreshApps() {
        let snapshot = registry.snapshot()
        var seen = Set<String>()
        var updated: [AppMix] = []
        // Built once: this method runs on every HAL process-list change, and a
        // linear scan per process made it quadratic in the number of apps.
        let existingByBundle = Dictionary(apps.map { ($0.bundleID, $0) },
                                          uniquingKeysWith: { first, _ in first })

        for group in groupByBundle(snapshot) {
            let bundleID = group.bundleID
            guard let descriptor = describe(process: group.representative,
                                            bundleID: bundleID) else { continue }
            seen.insert(bundleID)

            if let existing = existingByBundle[bundleID] {
                existing.refresh(pid: group.representative.pid,
                                 processObjectID: group.representative.processObjectID,
                                 processObjectIDs: group.processObjectIDs,
                                 isPlaying: group.isPlaying)
                updated.append(existing)
            } else {
                let mix = AppMix(bundleID: bundleID,
                                 pid: group.representative.pid,
                                 processObjectID: group.representative.processObjectID,
                                 processObjectIDs: group.processObjectIDs,
                                 name: descriptor.name,
                                 icon: descriptor.icon)
                let saved = preferences[bundleID] ?? .default
                mix.volume = saved.volume
                mix.isMuted = saved.isMuted
                mix.isFavorite = favorites.contains(bundleID)
                mix.customName = customNames[bundleID]
                mix.isPlaying = group.isPlaying
                updated.append(mix)
            }
        }

        // Starred apps that are not currently producing audio stay in the list
        // as inactive rows. Without this a favourite vanishes the moment it
        // stops playing, which makes the menu bar look broken.
        for bundleID in favorites where !seen.contains(bundleID) {
            if let existing = existingByBundle[bundleID] {
                existing.markInactive()
                updated.append(existing)
                continue
            }
            guard let placeholder = makeInactiveFavorite(bundleID: bundleID) else { continue }
            updated.append(placeholder)
        }

        apps = sortApps(updated)

        let playing = updated.filter(\.isPlaying).map(\.bundleID)
        SoundFlowLog.registry.debug("refreshApps: \(updated.count, privacy: .public) apps, playing: \(playing.joined(separator: ", "), privacy: .public)")

        syncRoute()
    }

    /// One row's worth of the HAL's process list.
    private struct AppProcessGroup {
        let bundleID: String
        /// The process the row is built and tapped on.
        let representative: AudioProcessInfo
        /// Every process object with this bundle id, representative included.
        let processObjectIDs: [AudioObjectID]
        let isPlaying: Bool
    }

    /// Collapses the HAL's process list into one group per bundle id.
    ///
    /// A single app routinely owns several audio process objects: Chromium and
    /// Electron apps (Chrome, Spotify, Discord, Slack, VS Code) play from a
    /// helper process that reports the *parent's* bundle id.
    ///
    /// This used to keep the first process it saw and discard the rest, which
    /// was a real bug. `kAudioHardwarePropertyProcessObjectList` has no defined
    /// order, so when the silent main process sorted first its `IsRunningOutput`
    /// of `0` became the row's answer and the playing helper beside it was
    /// thrown away. The indicator then stayed dark for seconds — until the list
    /// happened to reorder or the idle object was torn down — while every
    /// notification in between was delivered on time and ignored.
    ///
    /// So `isPlaying` is the **union** across the group, and the representative
    /// is whichever member is actually producing output. That second part also
    /// points the tap at the process emitting the audio rather than an idle
    /// sibling, which is what invariant 2 wants anyway.
    private func groupByBundle(_ snapshot: [AudioProcessInfo]) -> [AppProcessGroup] {
        var order: [String] = []
        var members: [String: [AudioProcessInfo]] = [:]

        for process in snapshot {
            guard let bundleID = process.bundleID else { continue }
            if members[bundleID] == nil {
                members[bundleID] = []
                order.append(bundleID)
            }
            members[bundleID]?.append(process)
        }

        return order.compactMap { bundleID in
            guard let group = members[bundleID], let first = group.first else { return nil }
            return AppProcessGroup(
                bundleID: bundleID,
                representative: group.first(where: \.isRunningOutput) ?? first,
                processObjectIDs: group.map(\.processObjectID),
                isPlaying: group.contains(where: \.isRunningOutput)
            )
        }
    }

    /// Builds a row for a starred app that has no live audio process.
    ///
    /// The name and icon come from the installed bundle. A renamed app still
    /// gets a row even if the bundle cannot be found, since the user chose that
    /// label deliberately; anything else unresolvable is skipped.
    private func makeInactiveFavorite(bundleID: String) -> AppMix? {
        let descriptor = cachedBundleDescriptor(bundleID)
        guard descriptor != nil || customNames[bundleID] != nil else { return nil }

        let mix = AppMix(bundleID: bundleID,
                         pid: 0,
                         processObjectID: AudioObjectID(kAudioObjectUnknown),
                         name: descriptor?.name ?? bundleID,
                         icon: descriptor?.icon)
        let saved = preferences[bundleID] ?? .default
        mix.volume = saved.volume
        mix.isMuted = saved.isMuted
        mix.customName = customNames[bundleID]
        mix.isFavorite = true
        mix.isActive = false
        mix.isPlaying = false
        return mix
    }

    /// Starred first, then whatever is currently playing, then by name.
    private func sortApps(_ list: [AppMix]) -> [AppMix] {
        list.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    /// Resolves a user-facing name and icon, skipping processes that are not
    /// really applications (daemons, XPC helpers with no app bundle).
    private func describe(process: AudioProcessInfo,
                          bundleID: String) -> AppDescriptor? {
        // Always asked fresh: it is an in-memory query against the running-app
        // list, and it is the answer that must never be stale — an app that is
        // running now but was not last time has to get its row.
        if let running = NSRunningApplication(processIdentifier: process.pid),
           let name = running.localizedName, running.bundleIdentifier != nil {
            return (name, running.icon)
        }
        // Helper processes (e.g. browser audio helpers) report the parent app's
        // bundle id, so fall back to looking the bundle up on disk.
        return cachedBundleDescriptor(bundleID)
    }

    /// `describeBundle` memoised, negative answers included.
    ///
    /// That lookup reaches LaunchServices and then the disk for an icon, and it
    /// used to run for every unresolved process on every refresh — so daemons,
    /// which can never resolve, were paying the most to be skipped again. A
    /// bundle's name and icon do not change underneath us, so a positive is
    /// kept for the session; negatives are dropped when an app launches, since
    /// that is the one event that can make one wrong.
    private func cachedBundleDescriptor(_ bundleID: String) -> AppDescriptor? {
        if let cached = descriptorCache[bundleID] { return cached }
        let resolved = describeBundle(bundleID)
        descriptorCache[bundleID] = resolved
        return resolved
    }

    private func invalidateUnresolvedDescriptors() {
        descriptorCache = descriptorCache.filter { $0.value != nil }
    }

    /// Name and icon for an installed bundle, with no running process required.
    private func describeBundle(_ bundleID: String) -> AppDescriptor? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }

    // MARK: - Volume

    func setVolume(_ value: Float, for app: AppMix) {
        app.volume = max(0, min(1, value))
        persist(app)
        applyOrSync(app)
    }

    func setMuted(_ muted: Bool, for app: AppMix) {
        app.isMuted = muted
        persist(app)
        applyOrSync(app)
    }

    func resetAll() {
        for app in apps {
            app.volume = 1.0
            app.isMuted = false
        }
        preferenceSaveTask?.cancel()
        preferenceSaveTask = nil
        Preferences.clear()
        preferences = [:]
        syncRoute()
    }

    private func persist(_ app: AppMix) {
        preferences[app.bundleID] = AppPreference(volume: app.volume, isMuted: app.isMuted)
        schedulePreferenceSave()
    }

    /// Coalesces writes. A slider drag calls `persist` on every frame, and each
    /// save re-encodes the whole blob to JSON on the main thread; the last value
    /// is the only one that matters.
    private func schedulePreferenceSave() {
        preferenceSaveTask?.cancel()
        preferenceSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.preferenceSaveTask = nil
            Preferences.save(self.preferences)
        }
    }

    /// Writes any pending change immediately. Called on teardown so a level set
    /// moments before quitting is not lost with the cancelled task.
    private func flushPreferences() {
        guard preferenceSaveTask != nil else { return }
        preferenceSaveTask?.cancel()
        preferenceSaveTask = nil
        Preferences.save(preferences)
    }

    /// Applies a gain change in place when the app is already routed; otherwise
    /// reconciles the route because the app just entered or left the mix.
    private func applyOrSync(_ app: AppMix) {
        if let index = routedApps.firstIndex(where: { $0 === app }), app.needsTap {
            route?.ioProc?.setVolume(slot: index, sliderValue: app.volume)
            route?.ioProc?.setMuted(slot: index, app.isMuted)
            return
        }
        syncRoute()
    }

    // MARK: - Naming

    /// Renames an app in the mixer. Blank, whitespace-only, or a name equal to
    /// the system one clears the override rather than storing a duplicate.
    ///
    /// Keyed by bundle id like every other preference, so the label survives
    /// quitting the app and restarting SoundFlow. Display-only: nothing here
    /// touches the route.
    func rename(_ app: AppMix, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == app.name {
            app.customName = nil
            customNames.removeValue(forKey: app.bundleID)
        } else {
            app.customName = trimmed
            customNames[app.bundleID] = trimmed
        }
        Preferences.saveCustomNames(customNames)
        apps = sortApps(apps)
    }

    // MARK: - Icon styles

    /// How this app should be drawn. Apps the user never customised are absent
    /// from the store and get the default — their own macOS icon.
    func iconStyle(for app: AppMix) -> AppIconStyle {
        iconStyles[app.bundleID] ?? .default
    }

    /// Display-only, exactly like starring and renaming: the audio path is
    /// decided by `needsTap` alone, and an icon has no bearing on it. Nothing
    /// here may touch the route.
    func setIconStyle(_ style: AppIconStyle, for app: AppMix) {
        if style == .default {
            // Storing a default is indistinguishable from not storing it, and
            // an absent entry is what "reset" means.
            iconStyles.removeValue(forKey: app.bundleID)
        } else {
            iconStyles[app.bundleID] = style
        }
        Preferences.saveIconStyles(iconStyles)
        // Force the list to re-publish: AppMix does not carry the style, so
        // nothing else would tell the rows to redraw.
        apps = apps
    }

    // MARK: - Favourites

    /// Stars or unstars an app. No route work: the audio path is decided by
    /// `needsTap` alone, and a star changes nothing about it.
    func toggleFavorite(_ app: AppMix) {
        app.isFavorite.toggle()
        if app.isFavorite {
            favorites.insert(app.bundleID)
        } else {
            favorites.remove(app.bundleID)
        }
        Preferences.saveFavorites(favorites)

        // An unstarred row with no live process has nothing left to show.
        if !app.isFavorite && !app.isActive {
            apps.removeAll { $0 === app }
        } else {
            apps = sortApps(apps)
        }
    }

    // MARK: - Route management

    /// Rebuilds the route so it contains exactly the apps that need a tap.
    ///
    /// - Parameter preservingRecoveryBudget: `true` only for a watchdog-driven
    ///   rebuild. Every other caller represents a real change in circumstances
    ///   (the user moved a slider, a device appeared, the machine woke) and
    ///   deserves a fresh set of recovery attempts.
    private func syncRoute(preservingRecoveryBudget: Bool = false) {
        if !preservingRecoveryBudget { routeRecoveryAttempts = 0 }
        guard permission != .denied else { return }

        let wanted = apps.filter(\.needsTap)
        guard !wanted.isEmpty else {
            teardownRoute()
            routeError = nil
            return
        }
        guard let outputDeviceUID else {
            routeError = "No output device available."
            return
        }

        // Nothing to do when membership is unchanged. Compared as a set, not
        // pairwise: `wanted` follows the display order, and re-sorting the list
        // (an app starts playing, or gets starred) must not tear down and
        // rebuild an identical route. `routedApps` stays the slot authority.
        let sameMembership = wanted.count == routedApps.count
            && Set(wanted.map(ObjectIdentifier.init)) == Set(routedApps.map(ObjectIdentifier.init))
        if sameMembership, route?.ioProc != nil {
            applyAllGains()
            return
        }

        teardownRoute()

        var newTaps: [ProcessTap] = []
        var newApps: [AppMix] = []
        for app in wanted {
            do {
                let tap = try ProcessTap.create(processObjectID: app.processObjectID)
                newTaps.append(tap)
                newApps.append(app)
                app.isDRMProtected = false
            } catch TapError.drmProtected {
                app.isDRMProtected = true
            } catch TapError.permissionDenied {
                permission = .denied
                newTaps.forEach { $0.destroy() }
                return
            } catch {
                print("[MixerEngine] Tap failed for \(app.name): \(error)")
            }
        }

        guard !newTaps.isEmpty else { routeError = nil; return }

        let newRoute = AggregateRoute(outputDeviceUID: outputDeviceUID)
        guard newRoute.start(taps: newTaps) else {
            newTaps.forEach { $0.destroy() }
            routeError = "Could not route audio through \(outputDeviceName)."
            return
        }

        route = newRoute
        taps = newTaps
        routedApps = newApps
        routeError = nil
        applyAllGains()
        startWatchdogFeed()

        let monitor = RouteWatchdog(route: newRoute) { [weak self] in
            // Reading @MainActor state from the watchdog thread would be unsafe,
            // so the answer is cached on each meter tick instead.
            self?.cachedExpectingAudio.withLock { $0 } ?? false
        }
        monitor.onNeedsRebuild = { [weak self] in
            Task { @MainActor in self?.rebuildRoute() }
        }
        monitor.onGaveUp = { [weak self] in
            Task { @MainActor in self?.abandonRoute() }
        }
        monitor.start(carryingOverAttempts: routeRecoveryAttempts)
        watchdog = monitor
    }

    private func applyAllGains() {
        guard let ioProc = route?.ioProc else { return }
        for (index, app) in routedApps.enumerated() {
            ioProc.setVolume(slot: index, sliderValue: app.volume)
            ioProc.setMuted(slot: index, app.isMuted)
        }
    }

    private func rebuildRoute() {
        // The replacement route gets a new watchdog, so carry the spent budget
        // across by hand — otherwise a permanently dead pipeline is torn down
        // and rebuilt every three seconds for as long as the app runs.
        routeRecoveryAttempts = watchdog?.recoveryAttempts ?? routeRecoveryAttempts
        teardownRoute()
        syncRoute(preservingRecoveryBudget: true)
        watchdog?.noteRebuilt()
    }

    /// Every recovery attempt failed. Dropping the route is the safe end state:
    /// without a tap the apps play natively at full volume, which is audible and
    /// obviously wrong rather than silent and mysterious.
    private func abandonRoute() {
        teardownRoute()
        routeRecoveryAttempts = 0
        routeError = "Audio routing stopped responding and was disabled. "
            + "Adjust a level to try again."
    }

    private func teardownRoute() {
        watchdog?.stop()
        watchdog = nil
        route?.destroy()
        route = nil
        taps.forEach { $0.destroy() }
        taps = []
        routedApps = []
        stopWatchdogFeed()
    }

    // MARK: - Playback poll

    /// How many mixer surfaces are on screen. Both the window and the menu bar
    /// popover host a `MixerView`, and both can be open at once.
    private var visibleSurfaces = 0
    private var playbackPollTimer: Timer?

    /// Called by `MixerView` when it appears. Balanced by `endObservingPlayback()`.
    func beginObservingPlayback() {
        visibleSurfaces += 1
        SoundFlowLog.registry.debug("playback poll: \(self.visibleSurfaces, privacy: .public) surface(s) visible")
        startPlaybackPoll()
    }

    func endObservingPlayback() {
        visibleSurfaces = max(0, visibleSurfaces - 1)
        SoundFlowLog.registry.debug("playback poll: \(self.visibleSurfaces, privacy: .public) surface(s) visible")
        if visibleSurfaces == 0 { stopPlaybackPoll() }
    }

    /// A backstop under the `IsRunningOutput` listeners, running only while the
    /// user can actually see a row.
    ///
    /// The listeners are the real mechanism and this changes nothing when they
    /// arrive on time. It exists because when they do *not*, the failure is
    /// invisible: the indicator simply stays dark and the app looks like it did
    /// not notice. Half a second is the cap on how long that can last.
    ///
    /// Cheap on purpose. It re-reads one `UInt32` per process object already in
    /// `apps` — no `snapshot()`, which re-enumerates the HAL and reads a pid and
    /// a bundle id for every process on the system, and no `describe()`. When
    /// nothing has changed it does nothing at all: no publish, no re-sort, no
    /// route work. Same discipline as the watchdog feed below — it stops the
    /// moment there is nothing to watch.
    private func startPlaybackPoll() {
        guard playbackPollTimer == nil else { return }
        playbackPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPlaybackState() }
        }
    }

    private func stopPlaybackPoll() {
        playbackPollTimer?.invalidate()
        playbackPollTimer = nil
    }

    private func pollPlaybackState() {
        // `endObservingPlayback()` is the primary signal, but `onDisappear` is
        // SwiftUI's to deliver and the menu bar popover is not a window we own.
        // Confirming something is actually on screen makes a missed one heal
        // itself, instead of leaving a timer running for the rest of the
        // session with nobody looking at it.
        guard visibleSurfaces > 0, NSApp.windows.contains(where: \.isVisible) else {
            visibleSurfaces = 0
            stopPlaybackPoll()
            return
        }

        let changed = apps.contains { app in
            guard app.isActive, !app.processObjectIDs.isEmpty else { return false }
            // Union across the group, exactly as `groupByBundle` computes it:
            // one row can stand for a silent main process and a playing helper.
            let playing = app.processObjectIDs.contains { registry.isRunningOutput($0) }
            return playing != app.isPlaying
        }
        guard changed else { return }

        SoundFlowLog.registry.debug("playback poll: state changed, refreshing")
        refreshApps()
    }

    // MARK: - Watchdog expectation

    /// Whether any routed app should currently be producing sound.
    ///
    /// Cached in a lock so `RouteWatchdog`, which runs on its own thread, never
    /// touches main-actor state to answer the question.
    private let cachedExpectingAudio = OSAllocatedUnfairLock(initialState: false)

    /// Keeps `cachedExpectingAudio` fresh, and runs only while a route exists.
    ///
    /// This used to also read per-app RMS and publish it as `AppMix.level` for
    /// the row meters, which is why it ticked at 12.5 Hz. The meters are gone —
    /// they could only ever animate for apps the user had already turned down —
    /// so all that remains is one boolean the watchdog samples against a
    /// three-second window. 2 Hz is ample for that, and it is six times fewer
    /// wakeups in an app built to sit in the menu bar all day.
    ///
    /// It is still stopped with the route. An earlier version started it
    /// unconditionally in `start()` and never stopped it, so an idle SoundFlow
    /// paid for a timer forever with no route to watch.
    private func startWatchdogFeed() {
        guard watchdogFeedTimer == nil else { return }
        watchdogFeedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateWatchdogExpectation() }
        }
    }

    private func stopWatchdogFeed() {
        watchdogFeedTimer?.invalidate()
        watchdogFeedTimer = nil
        cachedExpectingAudio.withLock { $0 = false }
    }

    private func updateWatchdogExpectation() {
        guard route?.ioProc != nil else {
            stopWatchdogFeed()
            return
        }
        let expecting = routedApps.contains { $0.isPlaying && !$0.isMuted && $0.volume > 0.01 }
        cachedExpectingAudio.withLock { $0 = expecting }
    }
}
