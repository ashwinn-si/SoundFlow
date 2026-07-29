import AppKit
import CoreAudio
import Foundation
import SoundFlowCore

/// Headless engine smoke test.
///
/// Proves the thing the whole project exists for — two applications at two
/// different volumes at the same time — without any UI in the way. Run it with
/// audio playing in two apps:
///
///     swift run SoundFlowSpike
///
/// A successful run shows one app's RMS bar shrink while the other's does not.
@main
struct SoundFlowSpike {

    static func main() {
        // `--selftest` verifies the engine against a tone it generates itself,
        // with no dependence on what happens to be playing.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }

        print("SoundFlow — engine smoke test")
        print(String(repeating: "=", count: 64))

        // Clear anything a previous crashed run stranded, so a leaked tap can't
        // leave an app muted or a stale aggregate confuse the device list.
        TapMaintenance.destroyOrphanedTaps()
        AggregateRoute.destroyOrphanedRoutes()

        let registry = AudioProcessRegistry()
        let deviceManager = AudioDeviceManager()

        // ── Permission ────────────────────────────────────────────────
        print("\n── Permission ──")
        switch TapPermission.request() {
        case .granted:
            print("  Screen & System Audio Recording: granted")
        case .denied:
            print("""
              DENIED. Grant it in:
                System Settings → Privacy & Security → Screen & System Audio Recording

              When running via `swift run`, the permission belongs to your
              terminal app, not to SoundFlow.
            """)
            exit(1)
        case .undetermined:
            print("  Could not determine permission state — continuing anyway.")
        }

        // ── Output device ─────────────────────────────────────────────
        print("\n── Output device ──")
        guard let outputDeviceID = deviceManager.getDefaultOutputDeviceID(),
              let outputUID = caDeviceUID(outputDeviceID) else {
            print("  FATAL: no default output device.")
            exit(1)
        }
        let outputName = deviceManager.getDeviceInfo(deviceID: outputDeviceID)?.name ?? "?"
        print("  \(outputName)")
        print("  uid: \(outputUID)")
        print("  output channels: \(caChannelCount(outputDeviceID, scope: kAudioObjectPropertyScopeOutput))")
        print("  input channels:  \(caChannelCount(outputDeviceID, scope: kAudioObjectPropertyScopeInput))")

        // ── Processes ─────────────────────────────────────────────────
        print("\n── Processes known to CoreAudio ──")
        let processes = registry.snapshot()
        for process in processes {
            let marker = process.isRunningOutput ? "♪" : " "
            print("  \(marker) pid \(String(format: "%6d", process.pid))  "
                  + "obj \(String(format: "%4d", process.processObjectID))  "
                  + "\(displayName(for: process))")
        }

        let playing = processes.filter(\.isRunningOutput)
        guard !playing.isEmpty else {
            print("""

              No process is currently playing audio.
              Start playback in two apps (a browser and a music app, say) and
              re-run. Nothing below can be verified without live audio.
            """)
            exit(1)
        }

        let targets = Array(playing.prefix(2))
        print("\n  Tapping: \(targets.map { displayName(for: $0) }.joined(separator: ", "))")
        if targets.count == 1 {
            print("  (only one app is playing — start a second to see independence)")
        }

        // ── Build the route ───────────────────────────────────────────
        print("\n── Building route ──")
        var taps: [ProcessTap] = []
        for process in targets {
            do {
                let tap = try ProcessTap.create(processObjectID: process.processObjectID)
                print("  tap for \(displayName(for: process)): "
                      + "id \(tap.tapID), \(tap.channelCount)ch, uid \(tap.uid)")
                taps.append(tap)
            } catch {
                print("  FAILED for \(displayName(for: process)): \(error)")
            }
        }
        guard !taps.isEmpty else {
            print("  FATAL: no taps could be created.")
            exit(1)
        }

        let route = AggregateRoute(outputDeviceUID: outputUID)
        guard route.start(taps: taps) else {
            print("  FATAL: route failed to start.")
            taps.forEach { $0.destroy() }
            exit(1)
        }
        print("\n" + route.describeStreams())

        guard let ioProc = route.ioProc else {
            print("  FATAL: no IOProc.")
            route.destroy()
            exit(1)
        }

        // ── Independent gains ─────────────────────────────────────────
        // The whole point: different volumes for different apps, at once.
        let gains: [Float] = [0.1, 0.8]
        print("\n── Applying independent volumes ──")
        for (index, tap) in taps.enumerated() {
            let gain = gains[min(index, gains.count - 1)]
            ioProc.setVolume(slot: index, sliderValue: gain)
            _ = tap
            print(String(format: "  slot %d → %.0f%%", index, gain * 100))
        }

        print("\n── Live RMS (10s) ──")
        print("  Expect the 10% app quiet and the 80% app loud.\n")

        for tick in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            var line = String(format: "  t=%4.1fs ", Double(tick + 1) * 0.5)
            for (index, process) in targets.enumerated() where index < ioProc.slotCount {
                let rms = ioProc.rms(slot: index)
                let bar = String(repeating: "█", count: min(20, Int(rms * 60)))
                    .padding(toLength: 20, withPad: " ", startingAt: 0)
                line += " │ \(shortName(for: process)) \(bar) " + String(format: "%.4f", rms)
            }
            let diagnostics = ioProc.diagnostics
            line += "   [cb \(diagnostics.callbacks)"
                + " in \(diagnostics.inputBuffers)buf/\(diagnostics.inputChannels)ch]"
            print(line)
        }

        let final = ioProc.diagnostics
        if final.callbacks == 0 {
            print("""

              IOProc never fired. The aggregate device never started IO, so no
              audio was ever offered to the mixer.
            """)
        } else if final.inputChannels == 0 {
            print("""

              IOProc fired \(final.callbacks)x but the input side carried no
              channels — the tap is not feeding the aggregate device.
            """)
        }

        // ── Teardown ──────────────────────────────────────────────────
        print("\n── Tearing down ──")
        route.destroy()
        taps.forEach { $0.destroy() }
        registry.stopMonitoring()

        let leaked = caArray(AudioObjectID(kAudioObjectSystemObject),
                             caAddress(kAudioHardwarePropertyTapList),
                             AudioObjectID(0))
        print("  taps remaining on system: \(leaked.count)")
        print("\nDone.")
    }

    // MARK: - Naming

    private static func displayName(for process: AudioProcessInfo) -> String {
        if let app = NSRunningApplication(processIdentifier: process.pid),
           let name = app.localizedName {
            return name
        }
        return process.bundleID ?? "pid \(process.pid)"
    }

    private static func shortName(for process: AudioProcessInfo) -> String {
        String(displayName(for: process).prefix(12))
            .padding(toLength: 12, withPad: " ", startingAt: 0)
    }
}
