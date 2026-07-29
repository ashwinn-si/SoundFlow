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
    
    // MARK: - Device Change Monitoring

    /// Callback fired on the main queue whenever audio devices are added or removed.
    public var onDeviceListChanged: (@Sendable () -> Void)?

    private var isListening = false
    /// Retained `self` handed to the C listener; released when the listener goes.
    private var listenerContext: UnsafeMutableRawPointer?

    /// Start listening for HAL device add/remove events.
    /// Safe to call multiple times; installs the listener only once.
    public func startMonitoringDeviceChanges() {
        guard !isListening else { return }
        isListening = true

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // `self` crosses into C as an opaque pointer. This retain is balanced by
        // the release in stopMonitoringDeviceChanges().
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        listenerContext = selfPtr

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceListListener,
            selfPtr
        )

        if status != noErr {
            print("[AudioDeviceManager] Failed to add device-list listener: \(status)")
            Unmanaged<AudioDeviceManager>.fromOpaque(selfPtr).release()
            listenerContext = nil
            isListening = false
        }
    }

    /// Stop listening for device changes, removing the listener and balancing
    /// its retain. The previous implementation did neither, so every start/stop
    /// cycle leaked the manager and left a live callback behind.
    public func stopMonitoringDeviceChanges() {
        guard isListening, let selfPtr = listenerContext else { return }
        isListening = false

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceListListener,
            selfPtr
        )

        Unmanaged<AudioDeviceManager>.fromOpaque(selfPtr).release()
        listenerContext = nil
    }

    fileprivate func notifyDeviceListChanged() {
        let handler = onDeviceListChanged
        DispatchQueue.main.async { handler?() }
    }

    // MARK: - Master Volume Control
    //
    // Devices disagree about how they expose volume. Some answer the virtual
    // main-volume selector, some only expose a scalar on element 0, and some
    // only on the per-channel elements. Probing in that order and falling back
    // is what makes this work across built-in speakers, USB DACs and AirPods —
    // the previous single-selector read simply returned nil on many devices.

    /// Candidate property addresses for a device's output volume, best first.
    private func volumeAddresses() -> [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 1),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 2)
        ]
    }

    /// Gets the master output volume scalar (0.0–1.0), or `nil` if the device
    /// has no software-controllable volume (common for HDMI and some DACs).
    public func getMasterVolume(deviceID: AudioObjectID) -> Float? {
        for var address in volumeAddresses() {
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
    public func hasSettableVolume(deviceID: AudioObjectID) -> Bool {
        for var address in volumeAddresses() {
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
               settable.boolValue {
                return true
            }
        }
        return false
    }

    /// Sets the master output volume scalar (0.0–1.0).
    ///
    /// Writes every settable channel element rather than stopping at the first,
    /// so devices that only expose per-channel volume stay balanced.
    @discardableResult
    public func setMasterVolume(_ scalar: Float, deviceID: AudioObjectID) -> Bool {
        var volume = Float32(max(0, min(1, scalar)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var wroteAny = false

        for var address in volumeAddresses() {
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

    /// Returns `true` if the device's output is muted.
    public func isMuted(deviceID: AudioObjectID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return status == noErr ? (muted != 0) : nil
    }

    /// Sets the mute state on the device's output.
    @discardableResult
    public func setMuted(_ muted: Bool, deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
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
    private func getDeviceStringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var stringRef: Unmanaged<CFString>? = nil
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &stringRef
        )
        
        if status == noErr, let unmanagedStr = stringRef {
            return unmanagedStr.takeUnretainedValue() as String
        }
        return nil
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
    
    private func checkDeviceHasChannels(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr, dataSize > 0 else { return false }
        
        let rawBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { rawBufferList.deallocate() }
        
        let getStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            rawBufferList
        )
        
        guard getStatus == noErr else { return false }
        
        let buffers = UnsafeMutableAudioBufferListPointer(rawBufferList)
        var totalChannels: UInt32 = 0
        for buffer in buffers {
            totalChannels += buffer.mNumberChannels
        }
        
        return totalChannels > 0
    }
}

// MARK: - C listener

/// File-scope so the function pointer is stable: `AudioObjectRemovePropertyListener`
/// only matches a listener registered with the identical pointer.
private let deviceListListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<AudioDeviceManager>.fromOpaque(clientData)
        .takeUnretainedValue()
        .notifyDeviceListChanged()
    return noErr
}
