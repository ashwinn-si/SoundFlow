import CoreAudio
import Foundation

/// A private aggregate device that mixes a set of process taps into one physical
/// output device.
///
/// One route exists per *output device*, not per app. Every app sent to that
/// device contributes a tap to the same aggregate, and a single IOProc mixes
/// them. The previous design built one aggregate plus one IOProc per app, so N
/// aggregates all competed for the same physical device.
///
/// The composition below is the other half of the original bug: taps belong in
/// `kAudioAggregateDeviceTapListKey`, **not** in the sub-device list. A tap is
/// not a sub-device, so listing it there wired up nothing and the IOProc read
/// silence. See `AudioHardware.h` — `kAudioAggregateDeviceTapListKey` ("taps")
/// and `kAudioSubTapUIDKey` ("uid").
public final class AggregateRoute: @unchecked Sendable {

    public let outputDeviceUID: String
    public private(set) var deviceID: AudioDeviceID = kAudioObjectUnknown
    public private(set) var taps: [ProcessTap] = []
    public private(set) var ioProc: MixerIOProc?

    private let aggregateUID: String

    public init(outputDeviceUID: String) {
        self.outputDeviceUID = outputDeviceUID
        // Deterministic per output device, so a stale aggregate from a previous
        // run is replaced rather than accumulating duplicates.
        self.aggregateUID = "com.soundflow.route.\(outputDeviceUID)"
    }

    deinit { destroy() }

    // MARK: - Composition

    private func composition(for taps: [ProcessTap]) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey as String: "SoundFlow Route",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            // Private: not published system-wide, so it never shows up in the
            // user's Sound settings as a selectable device.
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            // Wait for a tapped process to produce audio before starting IO.
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            // Literal value is "master"; the physical device drives the clock.
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: taps.map { tap in
                [
                    kAudioSubTapUIDKey as String: tap.uid,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            }
        ]
    }

    // MARK: - Lifecycle

    /// Creates the aggregate device and starts mixing `taps` into the output.
    @discardableResult
    public func start(taps: [ProcessTap]) -> Bool {
        guard !taps.isEmpty else { return false }
        destroy()

        var newDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            composition(for: taps) as CFDictionary,
            &newDeviceID
        )
        guard status == noErr, newDeviceID != kAudioObjectUnknown else {
            print("[AggregateRoute] Create failed for \(outputDeviceUID): \(status)")
            return false
        }

        self.deviceID = newDeviceID
        self.taps = taps

        // The HAL publishes the aggregate's streams asynchronously; mapping them
        // immediately can see an empty configuration.
        guard waitForStreams() else {
            print("[AggregateRoute] Streams never appeared for \(outputDeviceUID)")
            destroy()
            return false
        }

        let proc = MixerIOProc(deviceID: newDeviceID)
        guard proc.configure(placements: placements(for: taps)), proc.start() else {
            print("[AggregateRoute] IOProc setup failed for \(outputDeviceUID)")
            destroy()
            return false
        }

        self.ioProc = proc
        return true
    }

    /// Replaces the tap set on a live route.
    ///
    /// `kAudioAggregateDevicePropertyTapList` is settable (a `CFArray` of tap UID
    /// strings), so apps can be added and removed without tearing the device
    /// down. Falls back to a full rebuild if the HAL rejects the live update.
    @discardableResult
    public func setTaps(_ newTaps: [ProcessTap]) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return start(taps: newTaps) }
        guard !newTaps.isEmpty else { destroy(); return true }

        var addr = caAddress(kAudioAggregateDevicePropertyTapList)
        var uids = newTaps.map { $0.uid as CFString } as CFArray
        let size = UInt32(MemoryLayout<CFArray>.size)
        let status = withUnsafeMutablePointer(to: &uids) { pointer in
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, pointer)
        }

        guard status == noErr else {
            print("[AggregateRoute] Live tap-list update failed (\(status)); rebuilding.")
            return start(taps: newTaps)
        }

        self.taps = newTaps
        guard waitForStreams(), let ioProc else { return start(taps: newTaps) }

        // Channel offsets shift when the tap set changes, so remap.
        guard ioProc.configure(placements: placements(for: newTaps)) else {
            return start(taps: newTaps)
        }
        return true
    }

    public func destroy() {
        ioProc?.stop()
        ioProc = nil
        if deviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            if status != noErr {
                print("[AggregateRoute] Destroy failed for \(deviceID): \(status)")
            }
            deviceID = kAudioObjectUnknown
        }
        taps = []
    }

    // MARK: - Stream placement

    /// Where each tap's channels sit among the aggregate's input channels.
    ///
    /// The aggregate's input side carries the sub-device's own input channels (a
    /// USB interface with mic inputs, say) plus one region per tap, in tap-list
    /// order. Tap regions occupy the tail, so the base offset is whatever is left
    /// after the tap channels are accounted for. When the output device has no
    /// inputs — speakers, AirPods, HDMI — that base is simply 0.
    private func placements(for taps: [ProcessTap]) -> [MixerIOProc.TapPlacement] {
        let totalInputChannels = caChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
        let tapChannels = taps.reduce(0) { $0 + $1.channelCount }
        let base = max(0, totalInputChannels - tapChannels)

        if base != 0 {
            print("[AggregateRoute] Output device contributes \(base) input channel(s); "
                  + "taps start at channel \(base) of \(totalInputChannels).")
        }

        var placements: [MixerIOProc.TapPlacement] = []
        var cursor = base
        for tap in taps {
            placements.append(.init(firstInputChannel: cursor, channelCount: tap.channelCount))
            cursor += tap.channelCount
        }
        return placements
    }

    /// Polls until the aggregate reports input and output streams, up to ~1s.
    /// Replaces the previous engine's blind `Thread.sleep(0.3)` / `sleep(0.5)`.
    private func waitForStreams(timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let inputs = caChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
            let outputs = caChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
            if inputs > 0 && outputs > 0 { return true }
            usleep(25_000)
        }
        return false
    }

    // MARK: - Diagnostics

    /// Human-readable stream layout, used by the spike CLI to verify channel
    /// mapping against real hardware.
    public func describeStreams() -> String {
        let inputs = caStreamBuffers(deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputs = caStreamBuffers(deviceID, scope: kAudioObjectPropertyScopeOutput)
        var lines = ["Aggregate device \(deviceID) (\(outputDeviceUID))"]
        lines.append("  input buffers:")
        for buffer in inputs {
            lines.append("    [\(buffer.bufferIndex)] channels=\(buffer.channelCount) "
                         + "startingChannel=\(buffer.startingChannel)")
        }
        lines.append("  output buffers:")
        for buffer in outputs {
            lines.append("    [\(buffer.bufferIndex)] channels=\(buffer.channelCount) "
                         + "startingChannel=\(buffer.startingChannel)")
        }
        for (index, placement) in placements(for: taps).enumerated() {
            lines.append("  tap \(index): firstInputChannel=\(placement.firstInputChannel) "
                         + "channels=\(placement.channelCount)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Maintenance

    /// Removes aggregates left behind by a previous run.
    public static func destroyOrphanedRoutes() {
        let devices = caArray(AudioObjectID(kAudioObjectSystemObject),
                              caAddress(kAudioHardwarePropertyDevices),
                              AudioObjectID(0))
        for device in devices {
            guard let uid = caDeviceUID(device),
                  uid.hasPrefix("com.soundflow.route.") else { continue }
            AudioHardwareDestroyAggregateDevice(device)
        }
    }
}
