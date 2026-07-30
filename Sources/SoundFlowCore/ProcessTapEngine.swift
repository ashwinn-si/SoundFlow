import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Errors

public enum TapError: Error, CustomStringConvertible {
    /// TCC has not granted Screen & System Audio Recording.
    case permissionDenied
    /// The process is playing FairPlay-protected audio; macOS refuses the tap.
    case drmProtected
    /// The tap was created but exposes no UID, so it cannot join an aggregate.
    case unresolvableUID
    case failed(OSStatus)

    public var description: String {
        switch self {
        case .permissionDenied: "System Audio Recording permission denied"
        case .drmProtected:     "Stream is DRM-protected"
        case .unresolvableUID:  "Tap has no resolvable UID"
        case .failed(let s):    "CoreAudio error \(s)"
        }
    }
}

/// Classifies the `OSStatus` from `AudioHardwareCreateProcessTap`.
///
/// Permission failures are indistinguishable from other errors without this
/// mapping. `kAudioHardwareIllegalOperationError` ('what', 560947818) is what the
/// HAL returns when TCC blocks tap creation; `kAudio_ParamError` (-50) is the
/// older form. Both are spelled as SDK constants rather than literals so a future
/// SDK renumbering cannot silently reclassify a denial as a generic failure.
private func classify(_ status: OSStatus) -> TapError {
    switch status {
    case kAudioHardwareIllegalOperationError, OSStatus(kAudio_ParamError):
        return .permissionDenied
    case kAudioHardwareBadObjectError, kAudioHardwareNotRunningError:
        return .drmProtected
    default:
        return .failed(status)
    }
}

// MARK: - ProcessTap

/// A live CoreAudio process tap: a copy of one process's output stream.
///
/// Created with `muteBehavior = .mutedWhenTapped`, so the process's original
/// output is silenced *only while an aggregate device is actively reading the
/// tap*. If SoundFlow dies, the tap dies with it and the app returns to normal
/// volume on its own. The previous implementation used unconditional `.muted`,
/// which risked leaving an app permanently silent after a crash.
public final class ProcessTap: @unchecked Sendable {

    public let tapID: AudioObjectID
    public let processObjectID: AudioObjectID
    /// UID string used to reference this tap in an aggregate device's tap list.
    public let uid: String
    /// Channels the tap produces. Stereo mixdown, so normally 2.
    public let channelCount: Int

    private var destroyed = false
    private let lock = NSLock()

    /// Name prefix used to recognise our own taps when sweeping orphans.
    static let namePrefix = "SoundFlow Tap "

    private init(tapID: AudioObjectID,
                 processObjectID: AudioObjectID,
                 uid: String,
                 channelCount: Int) {
        self.tapID = tapID
        self.processObjectID = processObjectID
        self.uid = uid
        self.channelCount = channelCount
    }

    deinit { destroy() }

    // MARK: - Creation

    /// Creates a stereo mixdown tap for one process.
    ///
    /// - Parameters:
    ///   - processObjectID: a CoreAudio **process-object id**, from
    ///     `caProcessObject(forPID:)` or `AudioProcessRegistry`. Passing a raw
    ///     pid here is the bug that made the previous engine tap nothing.
    ///   - muteBehavior: `0` unmuted, `1` muted, `2` muted only while tapped.
    ///     `2` is the default: the app's own output is silenced only while our
    ///     aggregate is reading, so a crash cannot leave it permanently muted.
    ///   - isPrivate: whether the tap is visible only to this process.
    public static func create(processObjectID: AudioObjectID,
                              muteBehavior: Int = 2,
                              isPrivate: Bool = false) throws -> ProcessTap {
        try create(description: CATapDescription(stereoMixdownOfProcesses: [processObjectID]),
                   processObjectID: processObjectID,
                   muteBehavior: muteBehavior,
                   isPrivate: isPrivate)
    }

    /// Creates a tap over *every* process except those listed.
    ///
    /// Used as a diagnostic control: if a global tap carries audio while a
    /// per-process tap does not, the fault is in process targeting rather than
    /// in the tap/aggregate/IOProc plumbing.
    public static func createGlobal(excluding excluded: [AudioObjectID] = [],
                                    muteBehavior: Int = 0,
                                    isPrivate: Bool = false) throws -> ProcessTap {
        try create(description: CATapDescription(stereoGlobalTapButExcludeProcesses: excluded),
                   processObjectID: kAudioObjectUnknown,
                   muteBehavior: muteBehavior,
                   isPrivate: isPrivate)
    }

    private static func create(description: CATapDescription,
                               processObjectID: AudioObjectID,
                               muteBehavior: Int,
                               isPrivate: Bool) throws -> ProcessTap {
        description.isPrivate = isPrivate
        description.name = "\(namePrefix)\(processObjectID)"
        description.uuid = UUID()

        // Raw value avoids dot-syntax bridging differences across SDK versions.
        if let behavior = CATapMuteBehavior(rawValue: muteBehavior) {
            description.muteBehavior = behavior
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)

        guard status == noErr, tapID != kAudioObjectUnknown else {
            // A silent success with no object is how a DRM-blocked stream fails.
            if status == noErr { throw TapError.drmProtected }
            throw classify(status)
        }

        guard let uid = caString(tapID, caAddress(kAudioTapPropertyUID)) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.unresolvableUID
        }

        var channels = 2
        if let format = caValue(tapID,
                                caAddress(kAudioTapPropertyFormat),
                                AudioStreamBasicDescription()),
           format.mChannelsPerFrame > 0 {
            channels = Int(format.mChannelsPerFrame)
        }

        return ProcessTap(tapID: tapID,
                          processObjectID: processObjectID,
                          uid: uid,
                          channelCount: channels)
    }

    // MARK: - Teardown

    /// Destroys the tap. Idempotent — safe to call from `deinit` and explicitly.
    public func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !destroyed else { return }
        destroyed = true

        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            print("[ProcessTap] Failed to destroy tap \(tapID): \(status)")
        }
    }
}

// MARK: - Leak sweeping

public enum TapMaintenance {
    /// Destroys taps left behind by a previous SoundFlow run.
    ///
    /// A leaked tap can keep an app muted, so this runs at launch to clear
    /// anything a crash stranded.
    @discardableResult
    public static func destroyOrphanedTaps() -> Int {
        let taps = caArray(AudioObjectID(kAudioObjectSystemObject),
                           caAddress(kAudioHardwarePropertyTapList),
                           AudioObjectID(0))
        var destroyed = 0
        for tapID in taps {
            // Read the description as the object it is. It is not a string, so
            // `caString` cannot be used here — see `tapName` below.
            guard let name = tapName(tapID),
                  name.hasPrefix(ProcessTap.namePrefix) else { continue }
            if AudioHardwareDestroyProcessTap(tapID) == noErr { destroyed += 1 }
        }
        if destroyed > 0 {
            print("[ProcessTap] Cleaned up \(destroyed) orphaned tap(s) from a previous run.")
        }
        return destroyed
    }

    /// `kAudioTapPropertyDescription` returns a `CATapDescription` object rather
    /// than a string, so read it separately when the string read fails.
    private static func tapName(_ tapID: AudioObjectID) -> String? {
        var addr = caAddress(kAudioTapPropertyDescription)
        var unmanaged: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &unmanaged) == noErr,
              let description = unmanaged?.takeRetainedValue() else { return nil }
        return description.name
    }
}
