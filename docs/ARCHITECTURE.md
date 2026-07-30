# SoundFlow — Architecture

Reference for the engine. [../CLAUDE.md](../CLAUDE.md) has the build commands
and the short invariant list; this file explains *why* the pipeline is shaped
the way it is, and records the CoreAudio behaviour that is expensive to
rediscover.

---

## 1. The core idea

A CoreAudio process tap is a **wiretap**, not a volume control. By default it
hands you a copy of an application's output while the original keeps playing at
full volume. Turning that into a volume control takes four moving parts:

1. **Silence the app at the source.** The tap is created with
   `muteBehavior = 2` (`.mutedWhenTapped`), so macOS mutes the app's own path
   to the hardware — but only while something is actively reading the tap.
2. **Re-play the copy.** A private aggregate device joins the tap to the real
   output device.
3. **Apply gain in between.** One `AudioDeviceIOProc` on the aggregate reads
   every tap's channels, scales them, and sums them into the output buffers.
4. **Do all of it only when needed.** An app left at 100% is never tapped at
   all, so it keeps its native, zero-added-latency path.

```mermaid
graph LR
    subgraph Apps
        A1[Spotify<br/>volume 30%]
        A2[Chrome<br/>muted]
        A3[Zoom<br/>volume 100%]
    end

    A1 -->|ProcessTap<br/>mutedWhenTapped| AGG
    A2 -->|ProcessTap<br/>mutedWhenTapped| AGG
    A3 -.->|never tapped —<br/>plays natively| OUT

    subgraph AGG[Private aggregate device — one per output device]
        TAPS[tap list<br/>slot 0, slot 1] --> IOPROC[mixerIOProc<br/>gain · sum · RMS]
    end

    IOPROC --> OUT[Physical output device]

    WD[RouteWatchdog<br/>polls peak RMS] -.->|zero-buffer detected| REBUILD[MixerEngine.rebuildRoute]
    REBUILD -.-> AGG
```

**One route per output device, not per app.** Every attenuated app contributes
one tap to the same aggregate, and one IOProc mixes them. An earlier design
built one aggregate + IOProc per app; N aggregates then fought over the same
physical device.

---

## 2. Ownership

`MixerEngine` is the sole owner of taps and routes. Nothing else creates or
destroys them.

```
MixerEngine  (@MainActor, @Observable)
├── AudioProcessRegistry     who is playing audio  → onChange → refreshApps()
├── AudioDeviceManager       device list + master volume → onDeviceListChanged
├── apps: [AppMix]           display model, freely re-sorted
├── route: AggregateRoute?   the aggregate device
│   └── ioProc: MixerIOProc  the real-time callback + its POD state
├── taps: [ProcessTap]       parallel to the route's tap list
├── routedApps: [AppMix]     slot i of the IOProc belongs to routedApps[i]
└── watchdog: RouteWatchdog  → onNeedsRebuild → rebuildRoute()
```

`RouteWatchdog` deliberately does **not** rebuild anything itself. An earlier
per-app watchdog recreated taps internally and never told the owner the tap id
had changed; the stale id was destroyed later while the real tap leaked and left
the app permanently muted. Recovery is now delegated back to the one component
that owns taps.

### `syncRoute()` — the single decision point

Every path that could change the audio graph funnels here.

```
syncRoute()
  ├── permission denied?           → return, UI shows PermissionView
  ├── wanted = apps.filter(needsTap)
  ├── wanted empty?                → teardownRoute(), clear error
  ├── no output device UID?        → routeError
  ├── same membership (as a SET)   → applyAllGains(), return
  ├── teardownRoute()
  ├── create a ProcessTap per app  → DRM / permission errors classified here
  ├── AggregateRoute.start(taps:)  → fails → destroy taps, set routeError
  └── applyAllGains(), start watchdog
```

The membership check compares `wanted` and `routedApps` as unordered sets. It
must stay that way: `wanted` follows display order, and the list re-sorts
whenever an app starts playing or gets starred. A pairwise comparison treated
those re-sorts as a membership change and tore down a perfectly healthy route —
an audible glitch for every app in it.

`applyOrSync(_:)` is the fast path for a slider drag: if the app is already
routed and still needs a tap, it writes gain straight into the slot and skips
`syncRoute()` entirely.

---

## 3. Threading

| Thread | Runs | Rules |
| :--- | :--- | :--- |
| Main actor | `MixerEngine`, `AppMix`, all SwiftUI | Everything observable lives here. |
| CoreAudio IO thread | `mixerIOProc` | **Real-time.** No allocation, no locks, no Swift runtime, no logging. POD memory only. |
| HAL listener threads | `registryListener`, device listeners | Hop to main immediately and return. |
| Watchdog thread | `RouteWatchdog.poll()` | `.utility` QoS. Never reads main-actor state. |
| Meter timer | `updateMeters()` every 0.08 s | Main actor. Reads slot RMS, caches "expecting audio". |

Two crossings deserve attention:

**Main → audio thread.** `gain` and `muted` are written by the main thread and
read by the callback; `rms` goes the other way. They are naturally aligned
32-bit scalars, so loads and stores are indivisible on every architecture macOS
supports — no tearing is possible. No ordering guarantees are needed because
each value is independent and one buffer of latency is fine.

**Watchdog → main actor.** The watchdog needs to know whether anything *should*
be playing (silence is only suspicious if it is unexpected), but reading
`@MainActor` state from its thread would be unsafe. So `updateMeters()` caches
the answer into an `OSAllocatedUnfairLock`-guarded `Bool` on each tick, and the
watchdog reads that.

---

## 4. Channel mapping

The aggregate device's **input** side carries the sub-device's own input
channels first (a USB interface with mic inputs, say), then one region per tap
in tap-list order. `AggregateRoute.placements(for:)` works out where the tap
regions start:

```
base = max(0, totalInputChannels - Σ tapChannels)
```

For speakers, AirPods, or HDMI — devices with no inputs — `base` is simply 0.

`MixerIOProc.configure(placements:)` then resolves each global channel index to
a concrete `(buffer, offset, stride)` triple by inspecting the real stream
configuration. This handles both interleaved buffers (`mNumberChannels > 1`) and
one-buffer-per-channel layouts; an earlier IOProc assumed the latter and
produced wrong channel math on real hardware. A tap with more channels than the
device folds onto what exists via `channel % outputChannelCount`.

The callback itself only walks the resulting flat arrays — all the reasoning
happens at configure time, off the audio thread.

**Gain curve:** `MixerIOProc.setVolume(slot:sliderValue:)` stores
`gain = slider²`. Perceived loudness tracks roughly the square of amplitude, so
the squared curve makes a linear slider feel linear to the ear. Range is
`0...1`; `PLAN.md`'s 0–150% was never implemented.

**RMS** is measured on each slot's *first* channel only — enough for a meter and
for the watchdog's silence detection, and it keeps the inner loop cheap.

---

## 5. Permission

This is the single most misleading part of the API.

With TCC denied, `AudioHardwareCreateProcessTap` still returns `noErr`. The tap
object is valid, the aggregate builds, the IOProc fires ~87 times a second with
4096-byte buffers — and every sample is zero. There is no error anywhere. Any
probe of the form "did tap creation succeed?" therefore always answers
"granted" and is worthless.

On macOS 15+ system-audio capture is gated by the **same TCC service as screen
recording** (the pane is literally "Screen & System Audio Recording"), so:

- `TapPermission.status()` → `CGPreflightScreenCaptureAccess()`
- `TapPermission.request()` → `CGRequestScreenCaptureAccess()`, which raises the
  real prompt (once — macOS never asks twice, hence the Settings deep link
  fallback in `PermissionView`)
- `TapPermission.verifyAudioFlows(...)` is the heavyweight ground-truth check:
  tap a process that is actually playing and look for a non-zero sample. Costs
  ~2 s, so it is a diagnostic, not a routine check. Currently has no callers.

Because TCC binds a grant to a **code identity**, an unsigned SwiftPM binary can
never hold the permission — which is why every run path goes through a signed
`.app` bundle, and why `scripts/setup-signing.sh` exists.

### Error classification

`ProcessTapEngine.classify(_:)` maps `OSStatus` to intent:

| Status | Meaning |
| :--- | :--- |
| `560947818` (`kAudioHardwareIllegalOperationError`, `'what'`), `-50` | TCC blocked the tap → `.permissionDenied` |
| `kAudioHardwareBadObjectError`, `kAudioHardwareNotRunningError` | → `.drmProtected` |
| `noErr` **with** `tapID == kAudioObjectUnknown` | Silent success = how a FairPlay stream fails → `.drmProtected` |
| anything else | `.failed(status)` |

A `.drmProtected` app gets `isDRMProtected = true`, is excluded from `needsTap`
forever after, and the UI greys its row out.

---

## 6. Leak safety

A leaked tap is worse than a crash: it keeps a real application silent after
SoundFlow is gone. Three defences, in order:

1. **`muteBehavior = 2`.** The app is muted only while the aggregate is reading.
   If SoundFlow dies, the tap dies with it and audio returns on its own. An
   earlier build used unconditional `.muted` (`1`) and could strand an app.
2. **`applicationWillTerminate`** calls `engine.stop()` → `teardownRoute()`.
3. **Launch-time sweep.** `MixerEngine.start()` runs
   `TapMaintenance.destroyOrphanedTaps()` and
   `AggregateRoute.destroyOrphanedRoutes()` before anything else. Ownership is
   recognised by naming: taps are `"SoundFlow Tap <processObjectID>"`, aggregate
   UIDs are `com.soundflow.route.<outputDeviceUID>`. The aggregate UID is
   deterministic per output device so stale ones get replaced rather than
   accumulating.

Reading a tap's name needs care: `kAudioTapPropertyDescription` returns a
`CATapDescription` **object**, not a string, so `caString` cannot read it — see
`TapMaintenance.tapName(_:)`.

---

## 7. The app layer

### `AppMix`

One row in the mixer, keyed by **bundle id**. A single app can own several audio
processes (browser helpers), so `refreshApps()` collapses them — first process
wins, one row per app. `describe(process:bundleID:)` resolves a name and icon
from `NSRunningApplication`, falling back to a disk lookup via `NSWorkspace`;
anything that resolves to neither is skipped, which is what keeps daemons and
XPC helpers out of the list.

| Field | Notes |
| :--- | :--- |
| `volume`, `isMuted` | Persisted. Drive `needsTap`. |
| `needsTap` | `isActive && !isDRMProtected && (isMuted \|\| volume < 0.999)` |
| `isActive` | `false` for a starred app with no live CoreAudio process. No process object, so it can never be tapped. |
| `isPlaying` | From the HAL's `IsRunningOutput`. Affects sort only. |
| `level` | Live meter, written every 0.08 s. |
| `isDRMProtected` | Set by tap failure. Disables the controls. |
| `isFavorite` | Persisted. **Display filter only.** |
| `customName` / `displayName` | Persisted override. UI must read `displayName`. |

`id` is declared `nonisolated` in an extension so SwiftUI's `List` can read it
without hopping to the main actor.

### Display rules

- The **main window** lists every app; the **menu bar** lists only starred ones.
  With nothing starred the menu falls back to showing everything, so it is never
  an empty dead end.
- Sort order is **starred → playing → name**, applied by
  `MixerEngine.sortApps(_:)`. Both the star toggle and a rename re-sort.
- Both surfaces are the same `MixerView`, switched by `compact`. The star button
  is hidden in compact mode (`showsFavoriteToggle`) since that list is already
  filtered.
- Renaming is inline: double-click the name, or use the row's context menu.
  Blank input, or input equal to the system name, clears the override rather
  than storing a duplicate. The system name stays in the tooltip so a renamed
  row can still be traced back to its process.
- **Starred apps persist through quitting.** `refreshApps()` appends an
  inactive row for every favourite missing from the HAL snapshot, so a
  favourite never disappears from the menu just because it stopped playing.
  Name and icon come from the installed bundle via `describeBundle(_:)`; a
  renamed app still gets a row even if the bundle cannot be found, since the
  user chose that label deliberately. Inactive rows read "Not running", are
  dimmed to 65%, and keep working controls — the level is saved and applies the
  next time the app produces audio. Unstarring an inactive row removes it
  outright, since nothing is left to show.
- The main window is a **nav bar plus three tabs** — Mixer, Devices, Settings.
  The **master level stays on the Mixer tab** as a row above the app list: it is
  adjusted constantly, and burying it a tab away would be a downgrade. Only
  device *selection* moved to Devices.
- **Devices** holds the Output and Input pickers with a level for each. Input is
  the *system default capture device*: selecting one writes
  `kAudioHardwarePropertyDefaultInputDevice`, exactly what the Sound settings
  pane does, and has nothing to do with the per-app output route —
  `selectInputDevice` calls `refreshInputState()` only, never `refreshDevices()`.
  Either slider hides when the device exposes no settable volume
  (`hasMasterVolumeControl` / `hasInputVolumeControl`); common for HDMI outputs
  and most microphones.
- **There is no `Settings` scene.** Settings is a tab. With the Dock icon hidden
  there is no app menu, so `Cmd+,` and `SettingsLink` would be a dead end.
- The menu bar popover keeps **Output picker + master level + starred apps +
  footer**, and no tabs — a dropdown is for a two-second adjustment. The footer
  has **Open SoundFlow** and **Quit**, and renders even when permission is
  denied: with the Dock icon hidden it is the only route back into the app, and
  Quit is the only thing that runs `applicationWillTerminate` and destroys the
  taps. `openWindow(id: "main")` is followed by `NSApp.activate()`, required in
  `.accessory` mode.

### Theming

`Theme` is one accent colour and nothing else. `MixerView` resolves the stored
id from `@AppStorage(Preferences.themeKey)` and applies it **once** at the root
as `.tint()`, so `Slider`, the star button, `Toggle` and selection states all
follow with no per-view plumbing. `\.themeAccent` carries the raw `Color` for
the two places that draw their own shapes — the nav bar highlight and
`LevelMeter`.

Preset colours are deliberately mid-tone: a colour that reads well on white
usually washes out on charcoal, so nothing sits at the extremes of lightness.
`Themes.theme(id:)` falls back to the system accent, so an id from a future
build degrades quietly rather than losing colour entirely.

`LevelMeter` is three bars driven by `AppMix.level`, which `MixerEngine` has
been writing every 80 ms all along and nothing displayed. Bar height uses
`sqrt(level)` because RMS spends most of its time near zero and a linear map
leaves the bars looking permanently flat.

### Persistence

All in `UserDefaults`, all keyed by bundle id, so settings survive both quitting
the app and restarting SoundFlow.

| Key | Shape | Cleared by |
| :--- | :--- | :--- |
| `SoundFlow.appPreferences` | JSON blob `[bundleID: {volume, isMuted}]` | "Reset All Volumes" |
| `SoundFlow.favoriteApps` | `[String]` | nothing |
| `SoundFlow.customNames` | `[String: String]` | nothing (per-app, via context menu) |
| `SoundFlow.hideDockIcon` | `Bool` | nothing |

Launch-at-login is deliberately **not** in this table. `SMAppService.mainApp` is
its own source of truth; a mirrored `UserDefaults` flag would drift the moment
the user toggles the item in System Settings → General → Login Items. The
toggle in `SettingsView` re-reads the real status on appear, and reverts itself
if registration throws — which it will for an unsigned or quarantined bundle.
`status == .requiresApproval` means the user disabled it in System Settings and
is reported honestly as off.

> **Do not add fields to `AppPreference`.** Swift's synthesised `Codable`
> ignores property defaults for missing keys, so a new field makes every
> existing blob fail to decode — and `Preferences.load()` swallows that with
> `try?`, silently resetting everyone's volumes. Favourites and custom names use
> separate keys for this reason (and so "Reset All Volumes" does not wipe them).

---

## 8. Failure modes

| Symptom | Likely cause | Where to look |
| :--- | :--- | :--- |
| Everything silent, IOProc firing, all samples zero | TCC denied, or running an unsigned binary | `TapPermission.status()`; run from a signed bundle |
| IOProc never fires | Aggregate never started IO | `MixerIOProc.diagnostics.callbacks == 0`; check `waitForStreams()` |
| Input arrives but output is silent | Channel mapping | `diagnostics.inputPeak > 0` but RMS 0 → `configure(placements:)` |
| One app silences the others | IOProc assigning instead of accumulating | `outSamples[i] += scaled` |
| App stuck muted after a crash | Leaked tap | Launch sweep; confirm `muteBehavior == 2` |
| Audio dies after sleep/wake | Zero-buffer failure | Watchdog should rebuild within ~3 s |
| Clicks/dropouts when the list changes | Route rebuilt unnecessarily | `syncRoute()` set-based membership check |

`MixerIOProc.diagnostics` exists precisely to separate these: `callbacks`
distinguishes "IO never started" from "IO running but silent", and
`lastInputPeak` distinguishes "the tap is silent" from "our gain or mapping
zeroed it".

The watchdog's numbers: polls every **0.5 s**, needs **6** consecutive silent
polls (**3 s**) while audio is expected, allows **5** rebuild attempts. Anything
above `1e-7` peak RMS resets the counters.

### Tools

```bash
./scripts/run-spike.sh --selftest
```

Runs the engine headless from a signed bundle and reports pass/fail per stage.
`SelfTest` also has a global-tap control case: if a global tap carries audio
while a per-process tap does not, the fault is in process targeting, not in the
tap/aggregate/IOProc plumbing.

---

## 9. Power and Apple silicon

```bash
./scripts/power-test.sh
```

`audit` checks the binary statically; `sample <label> <seconds>` measures the
running app; `compare` walks a window-closed vs window-open A/B; `deep` prints
`powermetrics` commands for you to run yourself.

No sudo required for the parts that matter. `top -stats pid,cpu,power,idlew`
reports the same **Energy Impact** number Activity Monitor shows plus **idle
wakeups**, per process. Energy behaviour only exists in the real running app —
an XCTest process has no menu bar, no SwiftUI redraw loop and no IOProc, which
is exactly where this app's power goes, so the harness is a shell script rather
than a test target.

**Idle wakeups are the metric that matters.** Each one pulls a core out of a
low-power state; a background app that never sleeps is what drains a battery
overnight. CPU percentage barely moves for an app like this, so it is the
weaker signal.

Baseline measured 2026-07-30, M4, idle with no apps attenuated:

| Metric | Measured | Target |
| :--- | :--- | :--- |
| CPU | 0.11% avg | ≤ 1% |
| Energy impact | 0.42 | ≤ 1.0 |
| Idle wakeups | 6.6/s | ≤ 5/s |
| Threads | 8 | — |

The wakeup number traces to one line: `MixerEngine.meterTimer` fires every
**0.08 s** and is started unconditionally in `start()`, so it keeps running when
no route exists, nothing is being metered, and no UI is on screen. 12.5 Hz of
timer maps to ~6.6 observed wakeups because macOS coalesces them, but it is
still a floor the app pays for permanently. Two obvious fixes if this ever
matters: stop the timer when `route == nil`, and suspend it when neither the
window nor the popover is visible — `updateMeters()` mutates `@Observable`
state 12.5×/s, which invalidates every visible row whether or not the value
changed.

`ProcessTapEngine` and `MixerIOProc` are already arm-friendly: the callback
touches only POD memory, allocates nothing, and takes no locks. One thing does
run in the hot path that need not — the `lastInputPeak` scan walks every sample
of input buffer 0 on **every** callback purely for diagnostics.

## 10. Implemented but unused

Live and tested, with no current callers — know they exist before writing
something similar.

| API | Notes |
| :--- | :--- |
| `AggregateRoute.setTaps(_:)` | Updates a live route's tap list in place (`kAudioAggregateDevicePropertyTapList` is settable), falling back to a rebuild. `MixerEngine` always rebuilds instead. The obvious optimisation if rebuild glitches ever matter. |
| `TapPermission.verifyAudioFlows(...)` | Ground-truth permission check, ~2 s. |
| `ProcessTap.createGlobal(excluding:)` | Diagnostic control case; `SelfTest` only. |
| `RouteWatchdog.onGaveUp` | Never assigned — after 5 failed rebuilds the route dies **silently**, with no UI. A real gap if a user ever hits it. |
| `AudioDeviceManager.isMuted(deviceID:scope:)`, `setMuted(_:deviceID:scope:)` | Device-level mute, in either scope. No UI uses it — per-app mute goes through the IOProc slot instead, and there is no hardware mic-mute button yet. |
