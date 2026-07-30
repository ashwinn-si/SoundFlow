# SoundFlow

Per-application output volume for macOS. A regular windowed SwiftUI app with a
Dock icon plus a `MenuBarExtra` companion, both driven by one `MixerEngine`.
Volume control is real: a CoreAudio **process tap** silences the app at the
source, and a private **aggregate device** re-plays the tapped stream through a
gain stage.

Swift 6 tools / SwiftPM, macOS 15+, no Xcode project.

> Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing anything
> under `Sources/SoundFlowCore/`. It explains the signal path, the threading
> rules, and the CoreAudio behaviour that is not discoverable from the API docs.

---

## Build & run

```bash
./build.sh && open build/SoundFlow.app
```

`build.sh` builds release, assembles `build/SoundFlow.app`, signs it, and
produces `SoundFlow.dmg`. For a fast compile check only:

```bash
swift build --product SoundFlowApp
```

| Task | Command |
| :--- | :--- |
| Compile check (no bundle) | `swift build --product SoundFlowApp` |
| Full app + signed bundle + DMG | `./build.sh` |
| Headless engine smoke test | `./scripts/run-spike.sh` |
| Engine self-test (pass/fail) | `./scripts/run-spike.sh --selftest` |
| AddressSanitizer build | `./scripts/build-asan.sh` |
| Power / Apple-silicon check | `./scripts/power-test.sh` (no sudo needed) |
| One-time signing identity setup | `./scripts/setup-signing.sh` |

**Never `swift run` the app or the spike.** A bare SwiftPM binary has no stable
code identity, so TCC cannot hold a permission grant for it — and the HAL does
not return an error, it hands back zero-filled buffers. The tap looks perfectly
healthy and captures silence. Everything must run from a signed `.app` bundle.

**Never sign ad-hoc (`codesign -s -`).** An ad-hoc Designated Requirement is
keyed to the binary's cdhash, which changes every rebuild, so macOS silently
revokes System Audio Recording each time. `build.sh` refuses to proceed without
the `SoundFlow Dev` identity for exactly this reason.

If an instance is already running, quit it (`osascript -e 'quit app "SoundFlow"'`)
before `./build.sh` — the script does `rm -rf build`, and a graceful quit is
what destroys the live taps.

---

## Layout

| Path | Responsibility |
| :--- | :--- |
| `Sources/SoundFlowCore/` | Engine. No SwiftUI. Reusable from the CLI. |
| `CoreAudioHelpers.swift` | `caAddress` / `caValue` / `caArray` / `caString` / `caSet` / `caStreamBuffers` / `caChannelCount` / `caDeviceUID` / `caDeviceID(forUID:)` / `caProcessObject(forPID:)`. **Use these instead of hand-rolling `AudioObjectGetPropertyData`.** |
| `AudioProcessRegistry.swift` | Who is playing audio, via `kAudioHardwarePropertyProcessObjectList` + per-process `IsRunningOutput` listeners. |
| `ProcessTapEngine.swift` | `ProcessTap` create/destroy, `TapError` classification, orphan sweeping. |
| `AggregateRoute.swift` | Private aggregate device: taps in, one physical output out. |
| `MixerIOProc.swift` | The real-time callback. Channel mapping, gain, mixing, RMS. |
| `RouteWatchdog.swift` | Detects the zero-buffer failure and asks the owner to rebuild. Counters are lock-guarded; the recovery budget is seeded by the owner. |
| `AudioDeviceManager.swift` | Device enumeration, device-list **and default-output/input** listeners, volume/mute. Volume and mute take a `scope:` — the same selectors address playback and capture. |
| `TapPermission.swift` | TCC state. Screen-capture preflight, **not** tap success. |
| `Sources/SoundFlowApp/` | The app. |
| `MixerEngine.swift` | `@MainActor @Observable`. Owns `AppMix` list, prefs, and the route. The only place that decides what gets tapped. |
| `MixerView.swift` | Root UI. Main window = `Sidebar` + content pane; menu bar (`compact`) = one lean list + footer. Applies the theme tint, owns the `AccentWash` background and hosts the single edit sheet. |
| `Sidebar.swift` | `MixerTab` enum and the left rail: counted filters, devices, the inline settings (theme, startup, reset), and the About rows. |
| `DevicesView.swift` | Devices pane: output/input pickers and their levels. Also owns the shared `LevelSlider`. |
| `Theme.swift` | Accent presets, `Themes.all`, and the `\.themeAccent` environment key. |
| `AboutView.swift` | `DeveloperView` (GitHub / LinkedIn link rows) and `VersionView` (version read from the bundle, requirements, what's new). |
| `AppIcon.swift` | `AppIconStyle`, the bundle-id → hue derivation, and `AppIconView` / `GeneratedIconTile`. |
| `CustomizeAppSheet.swift` | The pencil's sheet: edits one app's name and icon together. |
| `AppRowView.swift` | One app row: icon, name (double-click to rename), looping `PlayingIndicator`, slider, %, pencil, star, mute, context menu. |
| `Preferences.swift` | `UserDefaults`: volume/mute blob, favourites, custom names, icon styles, hide-Dock-icon. |
| `LaunchAtLogin.swift` | `SMAppService.mainApp` wrapper. No mirrored preference — the service is the source of truth. |
| `SoundFlowApp.swift` | Scenes, `AppDelegate`, teardown on quit. |
| `Sources/SoundFlowSpikeMain/` | CLI smoke test + `--selftest`. Not shipped. |

`README.md` is the public-facing page: what the app does, install steps,
limitations. Keep its feature list in step with what actually ships.

`PLAN.md` is the **original design document, not current truth.** It predates
the implementation and differs from it (0–150% gain range, `AudioEngineController`,
`ProcessWatchdog`, `MenuView` — none of which exist). Treat this file and
`docs/ARCHITECTURE.md` as authoritative.

---

## Invariants

Each of these was a real bug. Breaking one produces silence, a stuck-muted app,
or a crash — rarely a compile error.

1. **Taps take a process-object id, never a pid.** `ProcessTap.create` wants an
   `AudioObjectID` from `caProcessObject(forPID:)` or `AudioProcessRegistry`.
   Passing a raw pid creates a tap over nothing.

2. **Taps go in `kAudioAggregateDeviceTapListKey`, not the sub-device list.** A
   tap is not a sub-device. Listed in the wrong key it wires up nothing and the
   IOProc reads silence.

3. **The IOProc accumulates (`+=`), never assigns.** Output buffers are zeroed
   once per callback, then every slot sums into them. Assigning means the last
   tap silences the others.

4. **`muteBehavior` stays `2` (`.mutedWhenTapped`).** The app is silenced only
   while our aggregate is actively reading. Unconditional `.muted` (`1`) leaves
   the app permanently silent if SoundFlow dies.

5. **The audio thread touches only POD memory.** No Swift classes, no
   allocation, no locks, no logging inside `mixerIOProc` — state lives in
   manually allocated `MixerState` / `MixSlot` / `ChannelMap`. Cross-thread
   fields are naturally aligned 32-bit scalars, which cannot tear.

6. **Tap success is not a permission check.** With TCC denied,
   `AudioHardwareCreateProcessTap` still returns `noErr` and the IOProc fires
   ~87×/s with every sample zero. Use `TapPermission.status()`
   (`CGPreflightScreenCaptureAccess`); on macOS 15+ system audio shares the
   screen-recording TCC service.

7. **`routedApps` is the slot authority, not `apps`.** IOProc slot *i* belongs
   to `routedApps[i]`. `apps` is display order and re-sorts freely; never index
   slots off it. The `syncRoute()` membership check compares as an unordered
   set so a re-sort does not tear down a healthy route.

8. **Only `needsTap` decides what is tapped** —
   `isActive && !isDRMProtected && (isMuted || volume < 0.999)`. An app at 100%
   is never tapped, so it plays natively with no added latency. The `isActive`
   term matters: a starred app that has quit stays in the list as an inactive
   row with no process object, and tapping it would fail on every sync.
   Starring and renaming are display-only and must never touch the route.

9. **Sweep orphans at launch.** `TapMaintenance.destroyOrphanedTaps()` and
   `AggregateRoute.destroyOrphanedRoutes()` run in `MixerEngine.start()`; a
   leaked tap from a crash keeps a real app muted. Ownership is matched by the
   `"SoundFlow Tap "` name prefix and the `com.soundflow.route.` UID prefix.

10. **`applicationWillTerminate` must destroy the route.** It is the only thing
    standing between a quit and permanently muted apps.

11. **The engine starts from `AppDelegate`, never a view's `.task`.** SwiftUI
    does not guarantee the `Window` scene's content exists at launch — with the
    Dock icon hidden and launch-at-login on, it usually does not. Starting from
    the main window meant saved levels were not applied, the menu bar was empty,
    and the delegate had no engine to tear taps down with. `AppDelegate` owns
    the `MixerEngine`; the scenes read it.

12. **The recovery budget must outlive the watchdog.** A rebuild destroys the
    route and therefore its `RouteWatchdog`, so `maxRecoveryAttempts` only means
    anything if `MixerEngine.routeRecoveryAttempts` carries the count into
    `start(carryingOverAttempts:)`. Reset it for a real change of circumstances,
    not for a watchdog-driven rebuild — that is what
    `syncRoute(preservingRecoveryBudget:)` is for. Without the hand-off a dead
    pipeline rebuilds every three seconds forever.

13. **Watch the default-device selectors, not just the device list.** Choosing a
    different *existing* output in Control Center adds and removes nothing, so
    `kAudioHardwarePropertyDevices` never fires. `AudioDeviceManager` also
    listens on `kAudioHardwarePropertyDefaultOutputDevice` and
    `…DefaultInputDevice`. Device identity is compared by **UID**: ids get
    recycled as hardware comes and goes.

14. **Reading a device's level must not write it back.** `masterVolume` and
    `inputVolume` push to the hardware in `didSet`, so copying a device's own
    level into them re-writes it — and a device with no readable volume gets
    forced to 100%. Every such read goes through `readDeviceVolume { }`.

15. **Selection binds to `AudioObjectID`, never to a device name.** Names are not
    unique (two identical interfaces) and can read "Unknown", which leaves the
    picker blank.

16. **Permission granted while running must call `syncRoute()`.**
    `refreshPermission()` runs on every activation; without the sync the UI
    unblocks after the user returns from System Settings and the sliders do
    nothing until the process list happens to change.

---

## Where changes go

| Want to… | Touch |
| :--- | :--- |
| Change what appears in the mixer | `MixerEngine.refreshApps()` / `describe(process:bundleID:)` |
| Change how an app is labelled | `AppMix.displayName` — never read `.name` in the UI |
| Change row layout, add a per-app control | `AppRowView.swift` |
| Change window vs menu bar differences | `MixerView.swift` (`compact`), `visibleCompactApps` |
| Add a persisted setting | `Preferences.swift` + `Sidebar.swift` |
| Change how an app's icon is generated | `AppIcon.swift` (`GeneratedIcon.hues` / `automaticHue`) |
| Change login-item behaviour | `LaunchAtLogin.swift` — needs a signed bundle to register |
| Change the volume curve | `MixerIOProc.setVolume(slot:sliderValue:)` — currently squared |
| Change tap/route lifecycle | `MixerEngine.syncRoute()` — the single decision point |
| React to a new system event | Add a listener in `AudioDeviceManager`, route it into `MixerEngine` — see the trigger table in `docs/ARCHITECTURE.md` §2 |
| Debug "no audio" | `MixerIOProc.diagnostics` (set `measuresInputPeak` first), then `./scripts/run-spike.sh --selftest` |

Adding a field to `AppPreference` breaks decoding of every saved blob —
synthesised `Codable` ignores property defaults for missing keys and
`Preferences.load()` swallows the failure with `try?`, silently resetting all
volumes. Add a separate `UserDefaults` key instead, as favourites, custom names
and icon styles do. `AppIconStyle` already writes its `init(from:)` by hand with
`decodeIfPresent`, so that store *can* grow a field safely; `AppPreference`
cannot.

## Style

System materials, automatic light/dark, SF Symbols. **Colour comes from exactly
one place**: the theme accent, applied once as `.tint()` at the root of
`MixerView`, so sliders, stars and toggles inherit it. Views that need the raw
`Color` (custom-drawn bars) read `\.themeAccent` from the environment. Do not
hardcode a colour anywhere else, and do not add gradients.

Comments explain *why* — especially the CoreAudio workarounds — and the
existing density is the target.
