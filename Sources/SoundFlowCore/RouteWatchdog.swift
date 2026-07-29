import CoreAudio
import Foundation

/// Watches one route for the CoreAudio zero-buffer failure.
///
/// Process taps can drop into an all-zero sample state after sleep/wake or a
/// device change: the tap object stays alive with valid timestamps but produces
/// silence forever. The only recovery is to rebuild the pipeline.
///
/// Scoped per *route* rather than per app — one route already carries every tap
/// going to a given output device, so a single monitor covers all of them. The
/// previous per-app watchdog rebuilt taps internally but never told the owner
/// the tap id had changed, so the stale id was destroyed later while the real
/// tap leaked and left the app muted. Recovery here is delegated to the owner
/// via `onNeedsRebuild`, keeping one component responsible for tap ownership.
public final class RouteWatchdog: @unchecked Sendable {

    /// Seconds between RMS samples.
    public var pollInterval: TimeInterval = 0.5
    /// Consecutive silent polls before declaring the pipeline dead (3s).
    public var silenceThreshold = 6
    public var maxRecoveryAttempts = 5

    /// Called on the main queue when the route must be rebuilt. The owner
    /// recreates taps and the aggregate, and remains the sole owner of both.
    public var onNeedsRebuild: (@Sendable () -> Void)?
    /// Called on the main queue when every recovery attempt has failed.
    public var onGaveUp: (@Sendable () -> Void)?

    private let route: AggregateRoute
    /// Returns `true` while at least one tapped process is actually playing.
    /// Without this, a legitimately idle route looks identical to a dead one.
    private let isExpectingAudio: @Sendable () -> Bool

    private var thread: Thread?
    private var running = false
    private var silentPolls = 0
    private var recoveryAttempts = 0

    public init(route: AggregateRoute,
                isExpectingAudio: @escaping @Sendable () -> Bool) {
        self.route = route
        self.isExpectingAudio = isExpectingAudio
    }

    deinit { stop() }

    public func start() {
        guard !running else { return }
        running = true
        silentPolls = 0
        recoveryAttempts = 0

        let thread = Thread { [weak self] in self?.poll() }
        thread.name = "com.soundflow.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    /// Stops monitoring. Does **not** tear down the route — the owner does that.
    public func stop() {
        running = false
        thread = nil
    }

    /// Clears the failure counters after the owner rebuilds the route.
    public func noteRebuilt() {
        silentPolls = 0
    }

    private func poll() {
        while running {
            Thread.sleep(forTimeInterval: pollInterval)
            guard running else { return }

            // Silence is only suspicious when something should be playing.
            guard isExpectingAudio() else {
                silentPolls = 0
                continue
            }

            let rms = route.ioProc?.peakRMS ?? 0
            if rms > 1e-7 {
                silentPolls = 0
                recoveryAttempts = 0
                continue
            }

            silentPolls += 1
            guard silentPolls >= silenceThreshold else { continue }

            recoveryAttempts += 1
            guard recoveryAttempts <= maxRecoveryAttempts else {
                print("[Watchdog] Giving up on route \(route.outputDeviceUID) "
                      + "after \(maxRecoveryAttempts) attempts.")
                running = false
                let handler = onGaveUp
                DispatchQueue.main.async { handler?() }
                return
            }

            print("[Watchdog] Zero-buffer on route \(route.outputDeviceUID); "
                  + "requesting rebuild (attempt \(recoveryAttempts)).")
            silentPolls = 0
            let handler = onNeedsRebuild
            DispatchQueue.main.async { handler?() }
        }
    }
}
