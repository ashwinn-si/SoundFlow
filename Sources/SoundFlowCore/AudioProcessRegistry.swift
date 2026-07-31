import CoreAudio
import Foundation

// MARK: - AudioProcessInfo

/// A process CoreAudio knows about, as reported by the HAL.
///
/// Deliberately free of AppKit types so it can cross threads. The app layer
/// decorates it with an icon and display name from `bundleID` / `pid`.
public struct AudioProcessInfo: Identifiable, Sendable, Hashable {
    public var id: AudioObjectID { processObjectID }

    /// CoreAudio process-object id — the value `CATapDescription` requires.
    public let processObjectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// `true` while the process has at least one active output stream.
    public let isRunningOutput: Bool
}

// MARK: - AudioProcessRegistry

/// Enumerates processes that CoreAudio is actually running audio for.
///
/// Replaces the old approach of listing every `.regular` `NSRunningApplication`,
/// which both missed background audio producers and padded the mixer with dozens
/// of silent apps. `kAudioHardwarePropertyProcessObjectList` is the HAL's own
/// answer to "who is playing audio", so it is the correct source of truth.
public final class AudioProcessRegistry: @unchecked Sendable {

    /// Fired on the main queue when processes appear, disappear, or start/stop
    /// output. Lock-guarded: the listeners that read it run on a HAL thread.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }
    private var changeHandler: (@Sendable () -> Void)?

    private var isListening = false
    private var listenerContext: UnsafeMutableRawPointer?
    /// A main-queue hop is already scheduled, so further notifications in this
    /// burst have nothing left to ask for.
    private var notificationPending = false

    /// Process objects we have installed an `IsRunningOutput` listener on.
    private var observedProcesses: Set<AudioObjectID> = []
    private let lock = NSLock()

    public init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Enumeration

    /// Every process object the HAL currently knows about, unfiltered.
    private func currentProcessObjectIDs() -> [AudioObjectID] {
        caArray(AudioObjectID(kAudioObjectSystemObject),
                caAddress(kAudioHardwarePropertyProcessObjectList),
                AudioObjectID(0))
    }

    /// Current process list. Excludes SoundFlow itself and processes with no
    /// bundle identifier (coreaudiod, system agents — nothing a user would mix).
    ///
    /// **This also re-syncs the per-process output listeners**, which is how
    /// processes that appear later come to be observed. It is a read with a
    /// side effect, deliberately: the alternative is a caller remembering to
    /// re-register after every process-list change, and forgetting once is
    /// silent — playback state simply stops updating.
    public func snapshot() -> [AudioProcessInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let objectIDs = currentProcessObjectIDs()

        var result: [AudioProcessInfo] = []
        for objectID in objectIDs {
            guard let pid = caValue(objectID,
                                    caAddress(kAudioProcessPropertyPID),
                                    pid_t(0)),
                  pid != ownPID else { continue }

            guard let bundleID = caString(objectID, caAddress(kAudioProcessPropertyBundleID)),
                  !bundleID.isEmpty else { continue }

            let runningOutput = caValue(objectID,
                                        caAddress(kAudioProcessPropertyIsRunningOutput),
                                        UInt32(0)) ?? 0

            result.append(AudioProcessInfo(
                processObjectID: objectID,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: runningOutput != 0
            ))
        }

        refreshOutputListeners(for: objectIDs)
        return result
    }

    /// Looks up the process object for a pid, for callers that already have one.
    public func processObject(forPID pid: pid_t) -> AudioObjectID? {
        caProcessObject(forPID: pid)
    }

    /// Whether a single process object has an active output stream.
    ///
    /// One property read, deliberately: this is what a caller polls with when it
    /// wants playback state without paying for `snapshot()`, which re-enumerates
    /// the HAL and reads a pid and a bundle id for every process on the system.
    public func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        (caValue(objectID, caAddress(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
    }

    // MARK: - Change monitoring

    /// Installs a listener on the process list, and one on every process that
    /// already exists. Idempotent.
    ///
    /// The second half matters more than it looks. The process-list listener
    /// only fires when a process appears or disappears — it says nothing about
    /// an existing process starting to play. Without seeding the per-process
    /// `IsRunningOutput` listeners here, any app that was already running when
    /// monitoring began could start producing audio and never be noticed, until
    /// something unrelated changed the process list.
    ///
    /// The lock is released before that seeding: `refreshOutputListeners` takes
    /// the same `NSLock`, which is not recursive, so holding it across the call
    /// would deadlock on launch.
    public func startMonitoring() {
        // Before any listener exists: otherwise these callbacks are main
        // run-loop sources and stall whenever a menu or the menu bar popover
        // holds the run loop in tracking mode.
        caDetachNotificationRunLoop()

        lock.lock()

        guard !isListening else {
            lock.unlock()
            return
        }
        isListening = true

        let context = Unmanaged.passRetained(self).toOpaque()
        listenerContext = context

        var addr = caAddress(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            registryListener,
            context
        )

        if status != noErr {
            print("[ProcessRegistry] Failed to observe process list: \(status)")
            Unmanaged<AudioProcessRegistry>.fromOpaque(context).release()
            listenerContext = nil
            isListening = false
            lock.unlock()
            return
        }

        lock.unlock()

        refreshOutputListeners(for: currentProcessObjectIDs())
    }

    /// Removes every listener installed by this registry and balances its retains.
    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, let context = listenerContext else { return }
        isListening = false

        var addr = caAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            registryListener,
            context
        )

        var outputAddr = caAddress(kAudioProcessPropertyIsRunningOutput)
        for objectID in observedProcesses {
            AudioObjectRemovePropertyListener(objectID, &outputAddr, registryListener, context)
        }
        observedProcesses.removeAll()

        Unmanaged<AudioProcessRegistry>.fromOpaque(context).release()
        listenerContext = nil
    }

    /// Keeps per-process `IsRunningOutput` listeners in sync with the live
    /// process list, so the mixer reacts the moment an app starts playing.
    private func refreshOutputListeners(for current: [AudioObjectID]) {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, let context = listenerContext else { return }

        var addr = caAddress(kAudioProcessPropertyIsRunningOutput)
        let currentSet = Set(current)

        for objectID in currentSet.subtracting(observedProcesses) {
            if AudioObjectAddPropertyListener(objectID, &addr, registryListener, context) == noErr {
                observedProcesses.insert(objectID)
            }
        }
        for objectID in observedProcesses.subtracting(currentSet) {
            AudioObjectRemovePropertyListener(objectID, &addr, registryListener, context)
            observedProcesses.remove(objectID)
        }
    }

    /// Hops to main, once per burst.
    ///
    /// Every process object carries its own `IsRunningOutput` listener and they
    /// share this one C proc, so a single play event routinely fires several —
    /// and each hop used to run a full `refreshApps()`, which re-reads three
    /// properties per process over IPC and then reconciles the route. The flag
    /// collapses a burst into one refresh without delaying it: it is cleared
    /// before the callback runs, so anything that changes *during* a refresh
    /// still schedules the next one.
    fileprivate func notifyChanged() {
        lock.lock()
        guard !notificationPending else {
            lock.unlock()
            return
        }
        notificationPending = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notificationPending = false
            let callback = self.changeHandler
            self.lock.unlock()
            callback?()
        }
    }
}

// MARK: - C listener

/// Shared listener for both the process list and per-process output state.
/// Runs on a HAL thread, so it only hops to main and returns.
private let registryListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<AudioProcessRegistry>.fromOpaque(clientData)
        .takeUnretainedValue()
        .notifyChanged()
    return noErr
}
