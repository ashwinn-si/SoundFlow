import CoreAudio
import Foundation

// MARK: - Real-time state (plain C-compatible memory)
//
// Everything the IOProc touches lives in manually allocated POD memory. Swift
// classes are avoided on the audio thread because dereferencing one can touch
// runtime metadata and retain/release traffic, neither of which is real-time
// safe. The previous IOProcEngine passed a Swift class through the callback.
//
// Cross-thread access: `gain`/`muted` are written by the main thread and read by
// the audio thread; `rms` goes the other way. All are naturally aligned 32-bit
// scalars, so loads and stores are indivisible on every architecture macOS
// supports — no tearing is possible. Ordering does not matter here because each
// value is independent and eventual consistency (one buffer of latency) is fine.

/// Routes one channel of a tap to one channel of the output device.
struct ChannelMap {
    var inBufferIndex: Int32
    var inOffset: Int32
    var inStride: Int32
    var outBufferIndex: Int32
    var outOffset: Int32
    var outStride: Int32
}

/// One tapped application within the mix.
struct MixSlot {
    /// Index of this slot's first entry in the shared channel-map array.
    var mapStart: Int32
    var mapCount: Int32
    /// Linear gain, `0...1`. Written from the main thread.
    var gain: Float32
    var muted: Int32
    /// RMS of the most recent buffer. Written from the audio thread.
    var rms: Float32
}

struct MixerState {
    var slots: UnsafeMutablePointer<MixSlot>?
    var slotCount: Int32
    var maps: UnsafeMutablePointer<ChannelMap>?
    var mapCount: Int32
    /// Callback invocations. Distinguishes "IO never started" from "IO is
    /// running but the tap delivers silence" — two failures that otherwise look
    /// identical from an RMS reading of zero.
    var callbackCount: UInt64
    /// Input channels the callback last saw, for diagnosing stream mapping.
    var lastInputBuffers: Int32
    var lastInputChannels: Int32
    /// Bytes in the first input buffer. Zero here means the tap is delivering
    /// empty buffers, which is a different failure from delivering silence.
    var lastInputBytes: Int32
    /// Largest absolute input sample seen, before gain. Separates "the tap is
    /// silent" from "our gain or channel mapping zeroed it".
    var lastInputPeak: Float32

    /// A detached state: no slots, no maps, nothing for the callback to reach.
    static var empty: MixerState {
        MixerState(slots: nil, slotCount: 0, maps: nil, mapCount: 0,
                   callbackCount: 0, lastInputBuffers: 0, lastInputChannels: 0,
                   lastInputBytes: 0, lastInputPeak: 0)
    }
}

// MARK: - The IOProc

/// Reads every tap's channels, scales each by its own gain, and **accumulates**
/// them into the output device's buffers.
///
/// Accumulation is what allows several applications to share one output device.
/// The previous implementation assigned (`=`) instead of summing, so whichever
/// tap ran last silenced the others.
///
/// - Warning: real-time thread. No allocation, no locks, no Swift runtime calls.
let mixerIOProc: AudioDeviceIOProc = { (
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus in

    guard let clientData else { return noErr }
    let statePtr = clientData.assumingMemoryBound(to: MixerState.self)
    let state = statePtr.pointee

    let inputBufs = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inInputData)
    )
    let outputBufs = UnsafeMutableAudioBufferListPointer(outOutputData)

    statePtr.pointee.callbackCount &+= 1
    statePtr.pointee.lastInputBuffers = Int32(inputBufs.count)
    var seenChannels: Int32 = 0
    for index in 0..<inputBufs.count {
        seenChannels += Int32(inputBufs[index].mNumberChannels)
    }
    statePtr.pointee.lastInputChannels = seenChannels

    // Raw input inspection, independent of gain and channel mapping.
    if inputBufs.count > 0 {
        let first = inputBufs[0]
        statePtr.pointee.lastInputBytes = Int32(first.mDataByteSize)
        if let data = first.mData, first.mDataByteSize > 0 {
            let samples = data.assumingMemoryBound(to: Float32.self)
            let count = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
            var peak: Float32 = 0
            for index in 0..<count {
                let magnitude = abs(samples[index])
                if magnitude > peak { peak = magnitude }
            }
            statePtr.pointee.lastInputPeak = peak
        } else {
            statePtr.pointee.lastInputPeak = 0
        }
    }

    // Start from silence: every output channel is a sum of zero or more taps.
    for index in 0..<outputBufs.count {
        if let data = outputBufs[index].mData {
            memset(data, 0, Int(outputBufs[index].mDataByteSize))
        }
    }

    guard let slots = state.slots, let maps = state.maps else { return noErr }

    for slotIndex in 0..<Int(state.slotCount) {
        let slot = slots[slotIndex]
        let gain = slot.muted != 0 ? Float32(0) : slot.gain

        var sumSquares: Float32 = 0
        var rmsFrames: Int = 0

        for mapIndex in Int(slot.mapStart)..<Int(slot.mapStart + slot.mapCount) {
            let map = maps[mapIndex]

            guard Int(map.inBufferIndex) < inputBufs.count,
                  Int(map.outBufferIndex) < outputBufs.count else { continue }

            let inBuf = inputBufs[Int(map.inBufferIndex)]
            let outBuf = outputBufs[Int(map.outBufferIndex)]
            guard let inData = inBuf.mData, let outData = outBuf.mData else { continue }

            let inStride = Int(map.inStride)
            let outStride = Int(map.outStride)
            guard inStride > 0, outStride > 0 else { continue }

            let inFrames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float32>.size * inStride)
            let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float32>.size * outStride)
            let frames = min(inFrames, outFrames)
            guard frames > 0 else { continue }

            let inSamples = inData.assumingMemoryBound(to: Float32.self)
            let outSamples = outData.assumingMemoryBound(to: Float32.self)
            var inIndex = Int(map.inOffset)
            var outIndex = Int(map.outOffset)

            // RMS is measured on the slot's first channel only — enough for a
            // meter and for the watchdog's silence detection.
            let measure = (mapIndex == Int(slot.mapStart))

            for _ in 0..<frames {
                let scaled = inSamples[inIndex] * gain
                outSamples[outIndex] += scaled
                if measure { sumSquares += scaled * scaled }
                inIndex += inStride
                outIndex += outStride
            }

            if measure { rmsFrames = frames }
        }

        slots[slotIndex].rms = rmsFrames > 0 ? sqrtf(sumSquares / Float32(rmsFrames)) : 0
    }

    return noErr
}

// MARK: - MixerIOProc

/// Owns the IOProc registration and the real-time state buffer for one route.
public final class MixerIOProc: @unchecked Sendable {

    /// Describes one tap's position in the aggregate device's input streams.
    public struct TapPlacement {
        /// Index of the tap's first channel among all aggregate input channels.
        public let firstInputChannel: Int
        public let channelCount: Int

        public init(firstInputChannel: Int, channelCount: Int) {
            self.firstInputChannel = firstInputChannel
            self.channelCount = channelCount
        }
    }

    private let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private var state: UnsafeMutablePointer<MixerState>
    private var slotStorage: UnsafeMutablePointer<MixSlot>?
    private var mapStorage: UnsafeMutablePointer<ChannelMap>?

    public private(set) var isRunning = false
    public private(set) var slotCount = 0
    private var mapCount = 0

    public init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        self.state = .allocate(capacity: 1)
        self.state.initialize(to: MixerState.empty)
    }

    deinit {
        stop()
        releaseStorage()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: - Stream mapping

    /// Builds the channel map for `placements` by inspecting the aggregate
    /// device's actual stream configuration.
    ///
    /// Done once at configuration time; the callback only walks the resulting
    /// flat arrays. Handles interleaved buffers (`mNumberChannels > 1`) and
    /// one-buffer-per-channel layouts alike, which the previous IOProc did not —
    /// it assumed the latter and produced wrong channel math on real devices.
    public func configure(placements: [TapPlacement]) -> Bool {
        let wasRunning = isRunning
        if wasRunning { _ = stop() }

        let inputBuffers = caStreamBuffers(deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputBuffers = caStreamBuffers(deviceID, scope: kAudioObjectPropertyScopeOutput)

        guard !inputBuffers.isEmpty, !outputBuffers.isEmpty else {
            print("[MixerIOProc] Device \(deviceID) has no usable streams "
                  + "(in: \(inputBuffers.count), out: \(outputBuffers.count))")
            return false
        }

        let outputChannelCount = outputBuffers.reduce(0) { $0 + $1.channelCount }
        guard outputChannelCount > 0 else { return false }

        /// Resolves a global channel index to (buffer, offset, stride).
        func locate(_ globalChannel: Int,
                    in buffers: [CAStreamBuffer]) -> (Int32, Int32, Int32)? {
            for buffer in buffers {
                let end = buffer.startingChannel + buffer.channelCount
                if globalChannel >= buffer.startingChannel && globalChannel < end {
                    return (Int32(buffer.bufferIndex),
                            Int32(globalChannel - buffer.startingChannel),
                            Int32(buffer.channelCount))
                }
            }
            return nil
        }

        var slots: [MixSlot] = []
        var maps: [ChannelMap] = []

        for placement in placements {
            let mapStart = maps.count
            for channel in 0..<placement.channelCount {
                let inputChannel = placement.firstInputChannel + channel
                // Fold a tap with more channels than the device onto what exists.
                let outputChannel = channel % outputChannelCount

                guard let input = locate(inputChannel, in: inputBuffers),
                      let output = locate(outputChannel, in: outputBuffers) else {
                    print("[MixerIOProc] Cannot map tap channel \(inputChannel) → \(outputChannel)")
                    continue
                }

                maps.append(ChannelMap(
                    inBufferIndex: input.0, inOffset: input.1, inStride: input.2,
                    outBufferIndex: output.0, outOffset: output.1, outStride: output.2
                ))
            }

            slots.append(MixSlot(
                mapStart: Int32(mapStart),
                mapCount: Int32(maps.count - mapStart),
                gain: 1.0,
                muted: 0,
                rms: 0
            ))
        }

        installStorage(slots: slots, maps: maps)

        if wasRunning { return start() }
        return true
    }

    private func installStorage(slots: [MixSlot], maps: [ChannelMap]) {
        // Safe because the IOProc is stopped whenever this runs.
        releaseStorage()

        if !slots.isEmpty {
            let buffer = UnsafeMutablePointer<MixSlot>.allocate(capacity: slots.count)
            buffer.initialize(from: slots, count: slots.count)
            slotStorage = buffer
        }
        if !maps.isEmpty {
            let buffer = UnsafeMutablePointer<ChannelMap>.allocate(capacity: maps.count)
            buffer.initialize(from: maps, count: maps.count)
            mapStorage = buffer
        }

        state.pointee = MixerState(
            slots: slotStorage,
            slotCount: Int32(slots.count),
            maps: mapStorage,
            mapCount: Int32(maps.count),
            callbackCount: 0,
            lastInputBuffers: 0,
            lastInputChannels: 0,
            lastInputBytes: 0,
            lastInputPeak: 0
        )
        slotCount = slots.count
        mapCount = maps.count
    }

    private func releaseStorage() {
        // Detach from the callback before freeing anything it could reach.
        state.pointee = MixerState.empty
        if let slotStorage {
            slotStorage.deinitialize(count: slotCount)
            slotStorage.deallocate()
        }
        if let mapStorage {
            mapStorage.deinitialize(count: mapCount)
            mapStorage.deallocate()
        }
        slotStorage = nil
        mapStorage = nil
        slotCount = 0
        mapCount = 0
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }

        if procID == nil {
            let status = AudioDeviceCreateIOProcID(deviceID, mixerIOProc,
                                                   UnsafeMutableRawPointer(state), &procID)
            guard status == noErr, procID != nil else {
                print("[MixerIOProc] AudioDeviceCreateIOProcID failed: \(status)")
                return false
            }
        }

        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            print("[MixerIOProc] AudioDeviceStart failed: \(status)")
            return false
        }
        isRunning = true
        return true
    }

    @discardableResult
    public func stop() -> Bool {
        guard let procID else { return true }
        if isRunning {
            AudioDeviceStop(deviceID, procID)
            isRunning = false
        }
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        return true
    }

    // MARK: - Per-slot control

    /// Sets a slot's gain from a `0...1` slider position.
    ///
    /// Squared curve: perceived loudness tracks roughly the square of amplitude,
    /// so this makes the slider feel linear to the ear.
    public func setVolume(slot: Int, sliderValue: Float) {
        guard let slots = slotStorage, slot >= 0, slot < slotCount else { return }
        let clamped = max(0, min(1, sliderValue))
        slots[slot].gain = Float32(clamped * clamped)
    }

    public func setMuted(slot: Int, _ muted: Bool) {
        guard let slots = slotStorage, slot >= 0, slot < slotCount else { return }
        slots[slot].muted = muted ? 1 : 0
    }

    /// RMS of the slot's most recent buffer, for meters and silence detection.
    public func rms(slot: Int) -> Float {
        guard let slots = slotStorage, slot >= 0, slot < slotCount else { return 0 }
        return Float(slots[slot].rms)
    }

    /// Diagnostics for distinguishing "IO never started" from "IO running but
    /// the tap is silent".
    public var diagnostics: (callbacks: UInt64, inputBuffers: Int, inputChannels: Int,
                             inputBytes: Int, inputPeak: Float) {
        (state.pointee.callbackCount,
         Int(state.pointee.lastInputBuffers),
         Int(state.pointee.lastInputChannels),
         Int(state.pointee.lastInputBytes),
         Float(state.pointee.lastInputPeak))
    }

    /// Peak RMS across all slots. The watchdog uses this to spot a dead pipeline.
    public var peakRMS: Float {
        guard let slots = slotStorage, slotCount > 0 else { return 0 }
        var peak: Float32 = 0
        for index in 0..<slotCount where slots[index].rms > peak {
            peak = slots[index].rms
        }
        return Float(peak)
    }
}
