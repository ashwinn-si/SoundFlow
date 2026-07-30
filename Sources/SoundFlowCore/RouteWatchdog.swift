import CoreAudio
import Foundation
import os

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
///
/// The owner rebuilds by destroying the route and creating a new one, which
/// means a *new* watchdog. The recovery budget therefore cannot live purely in
/// this object's lifetime — see `start(carryingOverAttempts:)`.
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

    /// Counters are touched by both the poll thread and the owner's thread
    /// (`stop`, `noteRebuilt`, `recoveryAttempts`), so they live behind a lock
    /// rather than as bare stored properties.
    private struct Counters {
        var running = false
        var silentPolls = 0
        var recoveryAttempts = 0
    }
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    public init(route: AggregateRoute,
                isExpectingAudio: @escaping @Sendable () -> Bool) {
        self.route = route
        self.isExpectingAudio = isExpectingAudio
    }

    deinit { stop() }

    /// Attempts spent so far. The owner reads this before tearing the route
    /// down so the budget can be handed to the watchdog of the replacement.
    public var recoveryAttempts: Int {
        counters.withLock { $0.recoveryAttempts }
    }

    /// Starts monitoring.
    ///
    /// - Parameter carryingOverAttempts: recovery attempts already spent on the
    ///   route this one replaces. A rebuild always produces a fresh watchdog, so
    ///   without this the budget resets every time and `maxRecoveryAttempts`
    ///   never bites — a permanently dead pipeline would be torn down and
    ///   rebuilt every three seconds, forever.
    public func start(carryingOverAttempts: Int = 0) {
        let shouldStart = counters.withLock { state -> Bool in
            guard !state.running else { return false }
            state.running = true
            state.silentPolls = 0
            state.recoveryAttempts = carryingOverAttempts
            return true
        }
        guard shouldStart else { return }

        let thread = Thread { [weak self] in self?.poll() }
        thread.name = "com.soundflow.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Stops monitoring. Does **not** tear down the route — the owner does that.
    public func stop() {
        counters.withLock { $0.running = false }
    }

    /// Clears the silence counter after the owner rebuilds the route. The
    /// recovery budget is deliberately left alone: it is what limits how many
    /// times a hopeless route is rebuilt.
    public func noteRebuilt() {
        counters.withLock { $0.silentPolls = 0 }
    }

    private func poll() {
        while counters.withLock({ $0.running }) {
            Thread.sleep(forTimeInterval: pollInterval)
            guard counters.withLock({ $0.running }) else { return }

            // Silence is only suspicious when something should be playing.
            guard isExpectingAudio() else {
                counters.withLock { $0.silentPolls = 0 }
                continue
            }

            let rms = route.ioProc?.peakRMS ?? 0
            if rms > 1e-7 {
                counters.withLock {
                    $0.silentPolls = 0
                    $0.recoveryAttempts = 0
                }
                continue
            }

            // `nil` → keep polling; a value → act on it.
            enum Verdict { case rebuild(Int), giveUp }
            let verdict: Verdict? = counters.withLock { state in
                state.silentPolls += 1
                guard state.silentPolls >= self.silenceThreshold else { return nil }

                state.recoveryAttempts += 1
                guard state.recoveryAttempts <= self.maxRecoveryAttempts else {
                    state.running = false
                    return .giveUp
                }
                state.silentPolls = 0
                return .rebuild(state.recoveryAttempts)
            }

            switch verdict {
            case nil:
                continue
            case .giveUp:
                print("[Watchdog] Giving up on route \(route.outputDeviceUID) "
                      + "after \(maxRecoveryAttempts) attempts.")
                let handler = onGaveUp
                DispatchQueue.main.async { handler?() }
                return
            case .rebuild(let attempt):
                print("[Watchdog] Zero-buffer on route \(route.outputDeviceUID); "
                      + "requesting rebuild (attempt \(attempt)).")
                let handler = onNeedsRebuild
                DispatchQueue.main.async { handler?() }
            }
        }
    }
}
