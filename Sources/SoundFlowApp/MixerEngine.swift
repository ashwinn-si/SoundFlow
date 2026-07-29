import AppKit
import CoreAudio
import os
import Foundation
import Observation
import SoundFlowCore

// MARK: - AppMix

/// One application in the mixer.
@MainActor
@Observable
final class AppMix {
    let bundleID: String
    private(set) var pid: pid_t
    private(set) var processObjectID: AudioObjectID

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

    /// `true` while the process has an active output stream.
    var isPlaying: Bool = false
    /// Live meter level.
    var level: Float = 0
    /// Set when macOS refuses to tap the app (FairPlay-protected audio).
    var isDRMProtected: Bool = false

    /// Starred by the user. Purely a display filter — the menu bar lists only
    /// these. It has no bearing on whether the app is tapped.
    var isFavorite: Bool = false

    /// Whether this app currently needs to be routed through the mixer.
    var needsTap: Bool { !isDRMProtected && (isMuted || volume < 0.999) }

    init(bundleID: String, pid: pid_t, processObjectID: AudioObjectID,
         name: String, icon: NSImage?) {
        self.bundleID = bundleID
        self.pid = pid
        self.processObjectID = processObjectID
        self.name = name
        self.icon = icon
    }

    func refresh(pid: pid_t, processObjectID: AudioObjectID, isPlaying: Bool) {
        self.pid = pid
        self.processObjectID = processObjectID
        self.isPlaying = isPlaying
    }
}

/// Declared outside the class body so `id` stays nonisolated: SwiftUI's `List`
/// reads it without hopping to the main actor.
extension AppMix: Identifiable {
    nonisolated var id: String { bundleID }
}

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
    private(set) var outputDevices: [AudioDeviceItem] = []
    private(set) var permission: TapPermissionStatus = .undetermined
    private(set) var outputDeviceName: String = ""
    /// Set when the route cannot be built, so the UI can explain itself.
    private(set) var routeError: String?

    var masterVolume: Float = 1.0 {
        didSet {
            guard abs(masterVolume - oldValue) > 0.0001 else { return }
            deviceManager.setMasterVolume(masterVolume, deviceID: outputDeviceID)
        }
    }

    var hasMasterVolumeControl: Bool = true

    // MARK: Private state

    private let registry = AudioProcessRegistry()
    private let deviceManager = AudioDeviceManager()

    private var route: AggregateRoute?
    private var watchdog: RouteWatchdog?
    /// Taps currently in the route, parallel to the route's slot indices.
    private var routedApps: [AppMix] = []
    private var taps: [ProcessTap] = []

    private var outputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDeviceUID: String?

    private var preferences: [String: AppPreference] = [:]
    private var favorites: Set<String> = []
    private var customNames: [String: String] = [:]
    private var meterTimer: Timer?
    private var started = false

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

        refreshDevices()
        requestPermission()
        refreshApps()

        registry.onChange = { [weak self] in
            Task { @MainActor in self?.refreshApps() }
        }
        registry.startMonitoring()

        deviceManager.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
        deviceManager.startMonitoringDeviceChanges()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeters() }
        }
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        registry.stopMonitoring()
        deviceManager.stopMonitoringDeviceChanges()
        teardownRoute()
        started = false
    }

    // MARK: - Permission

    func refreshPermission() {
        permission = TapPermission.status()
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
        outputDevices = deviceManager.getAllDevices().filter(\.isOutput)

        let previousUID = outputDeviceUID
        outputDeviceID = deviceManager.getDefaultOutputDeviceID() ?? kAudioObjectUnknown
        outputDeviceUID = caDeviceUID(outputDeviceID)
        outputDeviceName = outputDevices.first { $0.id == outputDeviceID }?.name ?? "Unknown"

        hasMasterVolumeControl = deviceManager.hasSettableVolume(deviceID: outputDeviceID)
        masterVolume = deviceManager.getMasterVolume(deviceID: outputDeviceID) ?? 1.0

        // Everything routed through the old device has to be rebuilt.
        if previousUID != nil && previousUID != outputDeviceUID {
            teardownRoute()
            syncRoute()
        }
    }

    func selectOutputDevice(_ device: AudioDeviceItem) {
        var address = caAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = device.id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &deviceID)
        refreshDevices()
    }

    // MARK: - App list

    func refreshApps() {
        let snapshot = registry.snapshot()
        var seen = Set<String>()
        var updated: [AppMix] = []

        for process in snapshot {
            guard let bundleID = process.bundleID else { continue }
            // A single app can own several audio processes (browser helpers);
            // collapse them so the user sees one row per app.
            guard !seen.contains(bundleID) else { continue }

            guard let descriptor = describe(process: process, bundleID: bundleID) else { continue }
            seen.insert(bundleID)

            if let existing = apps.first(where: { $0.bundleID == bundleID }) {
                existing.refresh(pid: process.pid,
                                 processObjectID: process.processObjectID,
                                 isPlaying: process.isRunningOutput)
                updated.append(existing)
            } else {
                let mix = AppMix(bundleID: bundleID,
                                 pid: process.pid,
                                 processObjectID: process.processObjectID,
                                 name: descriptor.name,
                                 icon: descriptor.icon)
                let saved = preferences[bundleID] ?? .default
                mix.volume = saved.volume
                mix.isMuted = saved.isMuted
                mix.isFavorite = favorites.contains(bundleID)
                mix.customName = customNames[bundleID]
                mix.isPlaying = process.isRunningOutput
                updated.append(mix)
            }
        }

        apps = sortApps(updated)

        syncRoute()
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
                          bundleID: String) -> (name: String, icon: NSImage?)? {
        if let running = NSRunningApplication(processIdentifier: process.pid),
           let name = running.localizedName, running.bundleIdentifier != nil {
            return (name, running.icon)
        }
        // Helper processes (e.g. browser audio helpers) report the parent app's
        // bundle id, so fall back to looking the bundle up on disk.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        return nil
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
        Preferences.clear()
        preferences = [:]
        syncRoute()
    }

    private func persist(_ app: AppMix) {
        preferences[app.bundleID] = AppPreference(volume: app.volume, isMuted: app.isMuted)
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
        apps = sortApps(apps)
    }

    // MARK: - Route management

    /// Rebuilds the route so it contains exactly the apps that need a tap.
    private func syncRoute() {
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

        let monitor = RouteWatchdog(route: newRoute) { [weak self] in
            // Reading @MainActor state from the watchdog thread would be unsafe,
            // so the answer is cached on each meter tick instead.
            self?.cachedExpectingAudio.withLock { $0 } ?? false
        }
        monitor.onNeedsRebuild = { [weak self] in
            Task { @MainActor in self?.rebuildRoute() }
        }
        monitor.start()
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
        teardownRoute()
        syncRoute()
        watchdog?.noteRebuilt()
    }

    private func teardownRoute() {
        watchdog?.stop()
        watchdog = nil
        route?.destroy()
        route = nil
        taps.forEach { $0.destroy() }
        taps = []
        routedApps = []
    }

    // MARK: - Meters

    /// Cached so the watchdog thread never touches main-actor state.
    private let cachedExpectingAudio = OSAllocatedUnfairLock(initialState: false)

    private func updateMeters() {
        guard let ioProc = route?.ioProc else {
            for app in apps where app.level != 0 { app.level = 0 }
            cachedExpectingAudio.withLock { $0 = false }
            return
        }
        for (index, app) in routedApps.enumerated() {
            app.level = ioProc.rms(slot: index)
        }
        let expecting = routedApps.contains { $0.isPlaying && !$0.isMuted && $0.volume > 0.01 }
        cachedExpectingAudio.withLock { $0 = expecting }
    }
}
