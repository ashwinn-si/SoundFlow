import CoreAudio
import Foundation

// MARK: - Property address shorthand

@inline(__always)
public func caAddress(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - Typed property readers
//
// CoreAudio's C API needs four lines of ceremony per property read. These
// wrappers collapse that so the engine code stays readable.

/// Reads a single fixed-size value (`UInt32`, `AudioObjectID`, `Float32`, a struct…).
///
/// `BitwiseCopyable` keeps reference-holding types out: CoreAudio would memcpy
/// over them, which would corrupt the retain count. Use `caString` for CFString
/// properties instead.
public func caValue<T: BitwiseCopyable>(_ objectID: AudioObjectID,
                                        _ address: AudioObjectPropertyAddress,
                                        _ initial: T) -> T? {
    guard objectID != kAudioObjectUnknown else { return nil }
    var addr = address
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

/// Reads a variable-length array of fixed-size elements (device lists, stream lists…).
public func caArray<T: BitwiseCopyable>(_ objectID: AudioObjectID,
                                        _ address: AudioObjectPropertyAddress,
                                        _ zero: T) -> [T] {
    guard objectID != kAudioObjectUnknown else { return [] }
    var addr = address
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize) == noErr,
          dataSize > 0 else { return [] }

    let count = Int(dataSize) / MemoryLayout<T>.size
    var values = [T](repeating: zero, count: count)
    let status = values.withUnsafeMutableBytes { buffer in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, buffer.baseAddress!)
    }
    guard status == noErr else { return [] }
    return values
}

/// Reads a `CFString` property as a Swift `String`.
///
/// Returns `nil` when the selector names something that is not a string. That
/// check is not paranoia: `kAudioTapPropertyDescription` answers with a
/// `CATapDescription` object, and the read succeeds — only the *type* is wrong.
/// Bridging it with `as String` sends `NSString` selectors to an object that
/// does not implement them, which forwards, throws, and terminates the process.
public func caString(_ objectID: AudioObjectID,
                     _ address: AudioObjectPropertyAddress) -> String? {
    guard objectID != kAudioObjectUnknown else { return nil }
    var addr = address
    var unmanaged: Unmanaged<AnyObject>?
    var size = UInt32(MemoryLayout<Unmanaged<AnyObject>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &unmanaged)
    guard status == noErr, let ref = unmanaged else { return nil }

    // CoreAudio hands these back at +1. Take ownership before the type check so
    // a non-string property is released rather than leaked.
    let object = ref.takeRetainedValue()
    guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
    return (object as! CFString) as String
}

/// Writes a single fixed-size value.
@discardableResult
public func caSet<T: BitwiseCopyable>(_ objectID: AudioObjectID,
                                      _ address: AudioObjectPropertyAddress,
                                      _ value: T) -> OSStatus {
    var addr = address
    var v = value
    return AudioObjectSetPropertyData(objectID, &addr, 0, nil,
                                      UInt32(MemoryLayout<T>.size), &v)
}

// MARK: - Stream configuration

/// One buffer in a device's `AudioBufferList`, flattened for stream mapping.
public struct CAStreamBuffer: Sendable {
    /// Index of this buffer within the device's `AudioBufferList`.
    public let bufferIndex: Int
    /// Channels carried by this buffer. `> 1` means interleaved.
    public let channelCount: Int
    /// Channel number of this buffer's first channel within the whole device.
    public let startingChannel: Int
}

/// Reads `kAudioDevicePropertyStreamConfiguration` and flattens it into a
/// buffer list with cumulative channel offsets.
///
/// A device may present its channels either as one interleaved buffer
/// (`mNumberChannels == 2`) or as several mono buffers. The IOProc needs both
/// the buffer index and the stride to address a channel, so both are captured
/// here rather than being re-derived inside the real-time callback.
public func caStreamBuffers(_ deviceID: AudioObjectID,
                            scope: AudioObjectPropertyScope) -> [CAStreamBuffer] {
    var addr = caAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr,
          dataSize > 0 else { return [] }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, raw) == noErr else {
        return []
    }

    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )

    var result: [CAStreamBuffer] = []
    var channelCursor = 0
    for (index, buffer) in list.enumerated() {
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }
        result.append(CAStreamBuffer(bufferIndex: index,
                                     channelCount: channels,
                                     startingChannel: channelCursor))
        channelCursor += channels
    }
    return result
}

/// Total channel count for a scope. `0` means the device has nothing on that side.
public func caChannelCount(_ deviceID: AudioObjectID,
                           scope: AudioObjectPropertyScope) -> Int {
    caStreamBuffers(deviceID, scope: scope).reduce(0) { $0 + $1.channelCount }
}

// MARK: - Device / process lookup

/// Device UID for an `AudioDeviceID`, or `nil` if the device has gone away.
public func caDeviceUID(_ deviceID: AudioObjectID) -> String? {
    caString(deviceID, caAddress(kAudioDevicePropertyDeviceUID))
}

/// Finds the `AudioDeviceID` whose UID matches, scanning all system devices.
public func caDeviceID(forUID uid: String) -> AudioObjectID? {
    let devices = caArray(AudioObjectID(kAudioObjectSystemObject),
                          caAddress(kAudioHardwarePropertyDevices),
                          AudioObjectID(0))
    return devices.first { caDeviceUID($0) == uid }
}

/// Translates a BSD process id into the CoreAudio *process object* id.
///
/// This is the step the previous implementation skipped: `CATapDescription`
/// takes process-object ids, not pids, and passing a raw pid silently targets
/// the wrong object. See `CATapDescription.h` and the
/// `kAudioHardwarePropertyTranslatePIDToProcessObject` documentation in
/// `AudioHardware.h`.
public func caProcessObject(forPID pid: pid_t) -> AudioObjectID? {
    var addr = caAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var inputPID = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &addr,
        UInt32(MemoryLayout<pid_t>.size),
        &inputPID,
        &size,
        &objectID
    )
    // Documented behaviour: an unknown pid returns kAudioObjectUnknown, not an error.
    guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
    return objectID
}
