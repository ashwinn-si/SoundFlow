import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// TCC state for Screen & System Audio Recording, the permission process taps need.
public enum TapPermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// Not yet determined; requesting will show the system prompt.
    case undetermined
}

/// Determines whether SoundFlow may capture other applications' audio.
///
/// **Creating a tap is not a permission test.** `AudioHardwareCreateProcessTap`
/// returns `noErr` and produces a healthy-looking tap even when TCC has denied
/// access — the HAL then feeds the aggregate device zero-filled buffers forever.
/// Measured directly: a tap with 4096-byte buffers, an IOProc firing 87 times a
/// second, and every sample zero. Any probe based on "did the tap succeed?"
/// therefore always answers "granted" and is worthless.
///
/// On macOS 15+ system-audio capture is gated by the *same* TCC service as
/// screen recording — the settings pane is named "Screen & System Audio
/// Recording" — so `CGPreflightScreenCaptureAccess()` is the real check and
/// `CGRequestScreenCaptureAccess()` raises the real prompt.
public enum TapPermission {

    /// System Settings pane for Screen & System Audio Recording.
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// Current permission state. Cheap — safe to call whenever the app activates.
    public static func status() -> TapPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Raises the system prompt if the user has never answered.
    ///
    /// Once denied, macOS will not prompt again; the user has to enable the app
    /// in System Settings, so `openSystemSettings()` is the fallback.
    @discardableResult
    public static func request() -> TapPermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Opens the pane where the user grants the permission.
    @MainActor
    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Confirms audio actually flows, not merely that TCC says yes.
    ///
    /// Guards against the silent-denial mode above: taps a process that is
    /// currently producing output and checks for a non-zero sample. Costs about
    /// `timeout` seconds, so it is a diagnostic rather than a routine check.
    public static func verifyAudioFlows(using registry: AudioProcessRegistry,
                                        outputDeviceUID: String,
                                        timeout: TimeInterval = 2.0) -> Bool {
        let candidates = registry.snapshot().filter(\.isRunningOutput)
        guard let target = candidates.first else { return false }

        guard let tap = try? ProcessTap.create(processObjectID: target.processObjectID,
                                               muteBehavior: 0) else { return false }
        defer { tap.destroy() }

        let route = AggregateRoute(outputDeviceUID: outputDeviceUID)
        defer { route.destroy() }
        guard route.start(taps: [tap]), let ioProc = route.ioProc else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ioProc.diagnostics.inputPeak > 0.0001 { return true }
            usleep(100_000)
        }
        return false
    }
}
