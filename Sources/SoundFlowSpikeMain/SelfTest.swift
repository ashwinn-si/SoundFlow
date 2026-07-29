import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import SoundFlowCore

/// Self-contained engine verification.
///
/// Spawns `afplay` on a generated tone, taps that process, and sweeps the gain
/// while measuring RMS. If RMS tracks the gain, per-app volume control works.
///
/// Needed because "is this app playing audio?" cannot be answered by
/// `kAudioProcessPropertyIsRunningOutput` alone — browsers and chat apps hold an
/// output stream open while emitting pure silence, which looks identical to a
/// broken tap. A process we control removes that ambiguity.
enum SelfTest {

    static func run() -> Int32 {
        print("SoundFlow — engine self-test")
        print(String(repeating: "=", count: 64))

        TapMaintenance.destroyOrphanedTaps()
        AggregateRoute.destroyOrphanedRoutes()

        let registry = AudioProcessRegistry()
        let deviceManager = AudioDeviceManager()

        print("Bundle: \(Bundle.main.bundleIdentifier ?? "none (unbundled binary)")")
        let permission = TapPermission.request()
        print("Screen & System Audio Recording: \(permission)")
        guard permission == .granted else {
            print("""

              Without this permission macOS does not fail the tap — it delivers
              silence. Grant it in System Settings -> Privacy & Security ->
              Screen & System Audio Recording, then re-run.
            """)
            return 1
        }

        guard let outputDeviceID = deviceManager.getDefaultOutputDeviceID(),
              let outputUID = caDeviceUID(outputDeviceID) else {
            print("\nFAILED: no default output device.")
            return 1
        }
        print("\nOutput: \(deviceManager.getDeviceInfo(deviceID: outputDeviceID)?.name ?? "?")")

        // ── Tone source ───────────────────────────────────────────────
        let toneURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soundflow-selftest-tone.wav")
        do {
            try writeSineWAV(to: toneURL, seconds: 30, frequency: 440, amplitude: 0.5)
        } catch {
            print("\nFAILED: could not write test tone: \(error)")
            return 1
        }
        print("Tone:   440 Hz at \(toneURL.path)")

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneURL.path]
        do {
            try player.run()
        } catch {
            print("\nFAILED: could not launch afplay: \(error)")
            return 1
        }
        defer {
            if player.isRunning { player.terminate() }
            try? FileManager.default.removeItem(at: toneURL)
        }
        print("Player: afplay pid \(player.processIdentifier)")

        // ── Wait for CoreAudio to see it ──────────────────────────────
        guard let processObject = waitForProcessObject(pid: player.processIdentifier) else {
            print("\nFAILED: afplay never appeared in CoreAudio's process list.")
            return 1
        }
        print("Object: \(processObject)")

        // ── Matrix mode ───────────────────────────────────────────────
        // Sweeps the tap flags whose correct values are not documented, so the
        // working combination is found by measurement rather than guesswork.
        if CommandLine.arguments.contains("--matrix") {
            return runMatrix(processObject: processObject,
                             outputUID: outputUID,
                             playerPID: player.processIdentifier)
        }

        // ── Tap it ────────────────────────────────────────────────────
        let tap: ProcessTap
        do {
            tap = try ProcessTap.create(processObjectID: processObject)
        } catch {
            print("\nFAILED: tap creation: \(error)")
            return 1
        }
        print("Tap:    id \(tap.tapID), \(tap.channelCount)ch")

        let route = AggregateRoute(outputDeviceUID: outputUID)
        guard route.start(taps: [tap]), let ioProc = route.ioProc else {
            print("\nFAILED: route did not start.")
            tap.destroy()
            return 1
        }
        defer {
            route.destroy()
            tap.destroy()
        }
        print("Route:  aggregate \(route.deviceID)\n")

        // ── Gain sweep ────────────────────────────────────────────────
        // The tone is constant, so RMS should be proportional to the applied
        // gain. Gain is the square of the slider, matching the UI curve.
        print("Sweeping volume — RMS must follow gain:\n")
        print("  slider   expected gain   measured RMS")
        print("  " + String(repeating: "-", count: 44))

        var measurements: [(slider: Float, rms: Float)] = []
        for slider in [Float(1.0), 0.5, 0.25, 0.0, 1.0] {
            ioProc.setVolume(slot: 0, sliderValue: slider)
            // Let the meter settle across several buffers.
            Thread.sleep(forTimeInterval: 1.0)
            let rms = ioProc.rms(slot: 0)
            measurements.append((slider, rms))
            let bar = String(repeating: "█", count: min(24, Int(rms * 80)))
            print(String(format: "  %5.0f%%   %11.3f   %8.5f  %@",
                         slider * 100, slider * slider, rms, bar))
        }

        let diagnostics = ioProc.diagnostics
        print("\n  IOProc callbacks: \(diagnostics.callbacks), "
              + "input \(diagnostics.inputBuffers) buffer(s) / "
              + "\(diagnostics.inputChannels) channel(s)")

        // ── Verdict ───────────────────────────────────────────────────
        print("\n" + String(repeating: "=", count: 64))

        guard diagnostics.callbacks > 0 else {
            print("FAIL: IOProc never fired — the aggregate device never started IO.")
            return 1
        }
        guard diagnostics.inputChannels > 0 else {
            print("FAIL: IOProc ran but the tap fed no input channels.")
            return 1
        }

        let fullGain = measurements[0].rms
        let halfGain = measurements[1].rms
        let silent = measurements[3].rms
        let restored = measurements[4].rms

        guard fullGain > 0.001 else {
            print("""
            FAIL: tap delivered silence at 100%.
                  The pipeline is connected (callbacks are firing with input
                  channels) but carries no samples.
            """)
            return 1
        }
        guard silent < fullGain * 0.05 else {
            print("FAIL: 0% did not silence the stream (\(silent) vs \(fullGain)).")
            return 1
        }
        guard restored > fullGain * 0.5 else {
            print("FAIL: volume did not recover after returning to 100%.")
            return 1
        }
        // 50% slider is gain 0.25, so RMS should land near a quarter of full.
        let ratio = halfGain / fullGain
        guard ratio > 0.15 && ratio < 0.40 else {
            print(String(format: "FAIL: 50%% slider gave RMS ratio %.3f, expected ~0.25.", ratio))
            return 1
        }

        print("PASS: gain tracks the slider, 0% is silent, and volume recovers.")
        print("      Per-app volume control works.")
        return 0
    }

    // MARK: - Flag matrix

    /// Tries each (muteBehavior, isPrivate) pair against a live tone and reports
    /// which ones actually deliver samples.
    private static func runMatrix(processObject: AudioObjectID,
                                  outputUID: String,
                                  playerPID: pid_t) -> Int32 {
        // Confirm the process object really is the player before blaming the
        // audio path. A wrong object would tap silence and look identical.
        let readBackPID = caValue(processObject, caAddress(kAudioProcessPropertyPID), pid_t(0))
        let readBackBundle = caString(processObject, caAddress(kAudioProcessPropertyBundleID))
        let running = caValue(processObject,
                              caAddress(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0
        print("\nProcess object \(processObject) sanity check:")
        print("  pid readback:     \(readBackPID.map(String.init) ?? "nil") "
              + "(afplay is \(playerPID)) \(readBackPID == playerPID ? "✓" : "✗ MISMATCH")")
        print("  bundle:           \(readBackBundle ?? "nil")")
        print("  isRunningOutput:  \(running)")

        // Control experiment: a global tap exercises the same aggregate and
        // IOProc path without any per-process targeting.
        print("\nControl — global tap (all processes):")
        do {
            let globalTap = try ProcessTap.createGlobal()
            defer { globalTap.destroy() }
            let route = AggregateRoute(outputDeviceUID: outputUID)
            defer { route.destroy() }
            if route.start(taps: [globalTap]), let ioProc = route.ioProc {
                ioProc.setVolume(slot: 0, sliderValue: 1.0)
                Thread.sleep(forTimeInterval: 1.5)
                let diagnostics = ioProc.diagnostics
                print(String(format: "  callbacks %d, bytes %d, peak %.5f, rms %.5f  → %@",
                             Int(diagnostics.callbacks), diagnostics.inputBytes,
                             diagnostics.inputPeak, ioProc.rms(slot: 0),
                             diagnostics.inputPeak > 0.0001 ? "AUDIO ✓" : "silent"))
            } else {
                print("  route failed")
            }
        } catch {
            print("  global tap failed: \(error)")
        }
        Thread.sleep(forTimeInterval: 0.5)

        print("\nPer-process tap flag sweep:\n")
        print("  mute  private   callbacks   inCh   RMS@100%   result")
        print("  " + String(repeating: "-", count: 56))

        var anyWorked = false

        for muteBehavior in [0, 1, 2] {
            for isPrivate in [false, true] {
                var note = ""
                var callbacks: UInt64 = 0
                var inputChannels = 0
                var rms: Float = 0

                do {
                    let tap = try ProcessTap.create(processObjectID: processObject,
                                                    muteBehavior: muteBehavior,
                                                    isPrivate: isPrivate)
                    defer { tap.destroy() }

                    let route = AggregateRoute(outputDeviceUID: outputUID)
                    if route.start(taps: [tap]), let ioProc = route.ioProc {
                        ioProc.setVolume(slot: 0, sliderValue: 1.0)
                        Thread.sleep(forTimeInterval: 1.5)
                        rms = ioProc.rms(slot: 0)
                        let diagnostics = ioProc.diagnostics
                        callbacks = diagnostics.callbacks
                        inputChannels = diagnostics.inputChannels
                        note = rms > 0.001 ? "AUDIO ✓"
                             : "silent (bytes \(diagnostics.inputBytes),"
                               + " peak \(String(format: "%.5f", diagnostics.inputPeak)))"
                        if rms > 0.001 { anyWorked = true }
                    } else {
                        note = "route failed"
                    }
                    route.destroy()
                } catch {
                    note = "tap failed: \(error)"
                }

                print("  " + String(format: "%4d  %7@   %9d   %4d   %8.5f   ",
                                    muteBehavior, isPrivate ? "yes" : "no",
                                    Int(callbacks), inputChannels, rms) + note)
                // Let coreaudiod settle between configurations.
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        print("\n" + String(repeating: "=", count: 64))
        if anyWorked {
            print("At least one configuration delivered audio — see AUDIO ✓ above.")
            return 0
        }
        print("No configuration delivered audio. The problem is not these flags.")
        return 1
    }

    // MARK: - Helpers

    /// Polls until CoreAudio publishes a process object for `pid`.
    /// `afplay` does not register until it opens its output stream.
    private static func waitForProcessObject(pid: pid_t,
                                             timeout: TimeInterval = 5) -> AudioObjectID? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let object = caProcessObject(forPID: pid) {
                // Wait for output to actually be running, otherwise the tap
                // attaches to a stream that has not started yet.
                let running = caValue(object,
                                      caAddress(kAudioProcessPropertyIsRunningOutput),
                                      UInt32(0)) ?? 0
                if running != 0 { return object }
            }
            usleep(100_000)
        }
        return nil
    }

    /// Writes a 16-bit stereo PCM WAV containing a constant sine tone.
    private static func writeSineWAV(to url: URL,
                                     seconds: Double,
                                     frequency: Double,
                                     amplitude: Double) throws {
        let sampleRate = 44100
        let channels = 2
        let bitsPerSample = 16
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataBytes = frameCount * channels * bitsPerSample / 8

        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))                                        // subchunk size
        appendLE(UInt16(1))                                         // PCM
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * channels * bitsPerSample / 8)) // byte rate
        appendLE(UInt16(channels * bitsPerSample / 8))              // block align
        appendLE(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(dataBytes))

        let step = 2.0 * Double.pi * frequency / Double(sampleRate)
        for frame in 0..<frameCount {
            let sample = Int16(sin(Double(frame) * step) * amplitude * 32767)
            appendLE(sample)
            appendLE(sample)
        }

        try data.write(to: url)
    }
}
