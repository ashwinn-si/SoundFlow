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

    /// Fired on the main queue when processes appear, disappear, or start/stop output.
    public var onChange: (@Sendable () -> Void)?

    private var isListening = false
    private var listenerContext: UnsafeMutableRawPointer?

    /// Process objects we have installed an `IsRunningOutput` listener on.
    private var observedProcesses: Set<AudioObjectID> = []
    private let lock = NSLock()

    public init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Enumeration

    /// Current process list. Excludes SoundFlow itself and processes with no
    /// bundle identifier (coreaudiod, system agents — nothing a user would mix).
    public func snapshot() -> [AudioProcessInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let objectIDs = caArray(AudioObjectID(kAudioObjectSystemObject),
                                caAddress(kAudioHardwarePropertyProcessObjectList),
                                AudioObjectID(0))

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

    // MARK: - Change monitoring

    /// Installs a listener on the process list. Idempotent.
    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        guard !isListening else { return }
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
        }
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

    fileprivate func notifyChanged() {
        let callback = onChange
        DispatchQueue.main.async { callback?() }
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
