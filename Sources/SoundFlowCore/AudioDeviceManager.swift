import Foundation
import CoreAudio
import AudioToolbox

public struct AudioDeviceItem: Identifiable {
    public let id: AudioObjectID
    public let name: String
    public let uid: String
    public let isOutput: Bool
    public let isInput: Bool
    public let transportType: String
}

public class AudioDeviceManager: @unchecked Sendable {
    public init() {}
    
    /// Enumerate all audio devices on the system
    public func getAllDevices() -> [AudioDeviceItem] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr, dataSize > 0 else {
            print("Error getting audio devices data size: \(status)")
            return []
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        
        let getDevicesStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard getDevicesStatus == noErr else {
            print("Error getting audio device IDs: \(getDevicesStatus)")
            return []
        }
        
        return deviceIDs.compactMap { getDeviceInfo(deviceID: $0) }
    }
    
    /// Get detailed device info for a given AudioObjectID
    public func getDeviceInfo(deviceID: AudioObjectID) -> AudioDeviceItem? {
        let name = getDeviceStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Unknown Device"
        let uid = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown UID"
        let transport = getDeviceTransportType(deviceID: deviceID)
        
        let hasOutput = checkDeviceHasChannels(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput)
        let hasInput = checkDeviceHasChannels(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        
        return AudioDeviceItem(
            id: deviceID,
            name: name,
            uid: uid,
            isOutput: hasOutput,
            isInput: hasInput,
            transportType: transport
        )
    }
    
    /// Fetch default Output device ID
    public func getDefaultOutputDeviceID() -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    
    /// Fetch default Input device ID
    public func getDefaultInputDeviceID() -> AudioObjectID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        return status == noErr ? deviceID : nil
    }
    
    /// Makes `deviceID` the system default for playback or capture.
    @discardableResult
    public func setDefaultDevice(_ deviceID: AudioObjectID, isInput: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: isInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &value
        )
        if status != noErr {
            print("[AudioDeviceManager] setDefaultDevice failed: \(status)")
        }
        return status == noErr
    }

    // MARK: - Device Change Monitoring

    /// Callback fired on the main queue whenever audio devices are added or removed.
    public var onDeviceListChanged: (@Sendable () -> Void)?
    /// Fired on the main queue when the *system default output* changes.
    ///
    /// Distinct from `onDeviceListChanged`: picking a different existing device
    /// in Control Center or the Sound pane does not add or remove anything, so
    /// the device-list listener never fires for it. Without this the route keeps
    /// feeding the old device and the picker shows a stale selection.
    public var onDefaultOutputChanged: (@Sendable () -> Void)?
    /// Fired on the main queue when the system default *input* changes.
    public var onDefaultInputChanged: (@Sendable () -> Void)?

    /// The hardware properties worth watching, all on the system object.
    private static let monitoredSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice
    ]

    /// Retained `self` handed to the C listener; released when the listeners go.
    private var listenerContext: UnsafeMutableRawPointer?
    /// Selectors actually registered, so a partial failure still unwinds cleanly.
    private var registeredSelectors: [AudioObjectPropertySelector] = []
    private let listenerLock = NSLock()

    /// Start listening for HAL device add/remove and default-device events.
    /// Safe to call multiple times; installs the listeners only once.
    public func startMonitoringDeviceChanges() {
        // Same reason as in `AudioProcessRegistry.startMonitoring()`: the HAL
        // notifies on the main run loop unless told otherwise, and these
        // callbacks are written for a thread of their own.
        caDetachNotificationRunLoop()

        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard listenerContext == nil else { return }

        // `self` crosses into C as an opaque pointer. This single retain covers
        // every registration below and is balanced in stopMonitoringDeviceChanges().
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        var registered: [AudioObjectPropertySelector] = []
        for selector in Self.monitoredSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address, hardwareListener, selfPtr)
            if status == noErr {
                registered.append(selector)
            } else {
                print("[AudioDeviceManager] Failed to observe \(selector): \(status)")
            }
        }

        guard !registered.isEmpty else {
            Unmanaged<AudioDeviceManager>.fromOpaque(selfPtr).release()
            return
        }
        listenerContext = selfPtr
        registeredSelectors = registered
    }

    /// Stop listening, removing every listener and balancing its retain. The
    /// original implementation did neither, so each start/stop cycle leaked the
    /// manager and left a live callback behind.
    public func stopMonitoringDeviceChanges() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard let selfPtr = listenerContext else { return }

        for selector in registeredSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address, hardwareListener, selfPtr)
        }
        registeredSelectors = []
        listenerContext = nil

        Unmanaged<AudioDeviceManager>.fromOpaque(selfPtr).release()
    }

    /// Routes a HAL notification to the matching callback. Runs on a HAL thread,
    /// so it only hops to main and returns.
    fileprivate func notify(selector: AudioObjectPropertySelector) {
        let handler: (@Sendable () -> Void)?
        switch selector {
        case kAudioHardwarePropertyDevices:             handler = onDeviceListChanged
        case kAudioHardwarePropertyDefaultOutputDevice: handler = onDefaultOutputChanged
        case kAudioHardwarePropertyDefaultInputDevice:  handler = onDefaultInputChanged
        default:                                        return
        }
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }

    // MARK: - Master Volume Control
    //
    // Devices disagree about how they expose volume. Some answer the virtual
    // main-volume selector, some only expose a scalar on element 0, and some
    // only on the per-channel elements. Probing in that order and falling back
    // is what makes this work across built-in speakers, USB DACs and AirPods —
    // the previous single-selector read simply returned nil on many devices.

    /// Candidate property addresses for a device's volume, best first.
    ///
    /// `scope` selects playback or capture: the same selectors carry a device's
    /// input gain when addressed with `kAudioObjectPropertyScopeInput`.
    private func volumeAddresses(
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: 1),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: 2)
        ]
    }

    /// Gets the master volume scalar (0.0–1.0), or `nil` if the device has no
    /// software-controllable volume (common for HDMI, some DACs, and plenty of
    /// microphones).
    public func getMasterVolume(deviceID: AudioObjectID,
                                scope: AudioObjectPropertyScope
                                    = kAudioObjectPropertyScopeOutput) -> Float? {
        for var address in volumeAddresses(scope: scope) {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return Float(volume)
            }
        }
        return nil
    }

    /// `true` when the device's volume can be changed in software.
    public func hasSettableVolume(deviceID: AudioObjectID,
                                  scope: AudioObjectPropertyScope
                                      = kAudioObjectPropertyScopeOutput) -> Bool {
        for var address in volumeAddresses(scope: scope) {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
               settable.boolValue {
                return true
            }
        }
        return false
    }

    /// Sets the master volume scalar (0.0–1.0) for the given scope.
    ///
    /// Writes every settable channel element rather than stopping at the first,
    /// so devices that only expose per-channel volume stay balanced.
    @discardableResult
    public func setMasterVolume(_ scalar: Float,
                                deviceID: AudioObjectID,
                                scope: AudioObjectPropertyScope
                                    = kAudioObjectPropertyScopeOutput) -> Bool {
        var volume = Float32(max(0, min(1, scalar)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var wroteAny = false

        for var address in volumeAddresses(scope: scope) {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            guard AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr
            else { continue }

            wroteAny = true
            // The virtual main selector already covers every channel.
            if address.mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume {
                return true
            }
        }
        return wroteAny
    }

    // MARK: - Master Mute Control

    /// Returns `true` if the device is muted in the given scope.
    public func isMuted(deviceID: AudioObjectID,
                        scope: AudioObjectPropertyScope
                            = kAudioObjectPropertyScopeOutput) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return status == noErr ? (muted != 0) : nil
    }

    /// Sets the mute state on the device in the given scope.
    @discardableResult
    public func setMuted(_ muted: Bool,
                         deviceID: AudioObjectID,
                         scope: AudioObjectPropertyScope
                             = kAudioObjectPropertyScopeOutput) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        if status != noErr {
            print("[AudioDeviceManager] setMuted failed: \(status)")
        }
        return status == noErr
    }

    // MARK: - Private Helpers

    /// CoreAudio hands CFString properties back at +1. Reading them through
    /// `caString` takes that ownership; the previous `takeUnretainedValue()`
    /// leaked a string per device per read, and `getAllDevices()` runs on every
    /// HAL device change.
    private func getDeviceStringProperty(deviceID: AudioObjectID,
                                         selector: AudioObjectPropertySelector) -> String? {
        caString(deviceID, caAddress(selector))
    }

    private func getDeviceTransportType(deviceID: AudioObjectID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &transportType
        )
        
        guard status == noErr else { return "Unknown" }
        
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort / HDMI"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Other (\(transportType))"
        }
    }
    
    /// Shares `caStreamBuffers`' byte-exact allocation. The previous version
    /// allocated `dataSize` whole `AudioBufferList` structs — a ~24× over-read
    /// of the required size, per device, per scope, on every enumeration.
    private func checkDeviceHasChannels(deviceID: AudioObjectID,
                                        scope: AudioObjectPropertyScope) -> Bool {
        caChannelCount(deviceID, scope: scope) > 0
    }
}

// MARK: - C listener

/// File-scope so the function pointer is stable: `AudioObjectRemovePropertyListener`
/// only matches a listener registered with the identical pointer.
///
/// One proc serves all three watched properties; the changed addresses arrive as
/// arguments, so the selector is what decides which callback fires.
private let hardwareListener: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
    guard let clientData else { return noErr }
    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    for index in 0..<Int(count) {
        manager.notify(selector: addresses[index].mSelector)
    }
    return noErr
}
