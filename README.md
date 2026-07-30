# SoundFlow — Per-App Volume Control for macOS

**Set a different volume for every application on your Mac.** Turn Chrome down
to 30%, mute Slack, leave Spotify at full — independently, in real time, from
the menu bar.

macOS has never shipped per-application volume. SoundFlow adds it natively,
using Core Audio process taps on Apple silicon and Intel Macs. No kernel
extension, no virtual audio driver to install, no login shell hacks.

[![Version 1.1.0](https://img.shields.io/badge/version-1.1.0-3D9E6B)](https://github.com/ashwinn-si/mediaControl/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native%20arm64-0071e3)](https://support.apple.com/en-us/116943)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-1575F9)](https://developer.apple.com/xcode/swiftui/)

---

## Features

- **Per-app volume sliders** — every app currently playing audio gets its own
  slider and mute button, live as you drag.
- **Per-app mute** — silence one app without touching anything else.
- **Star your favourites** — starred apps are the only ones shown in the menu
  bar, so the dropdown stays short. Starred apps stay listed even when they are
  not playing.
- **Sidebar with counted filters** — All Apps, Starred and Playing, each showing
  how many, plus devices and settings without leaving the window.
- **Rename anything** — click the pencil, or double-click a name. "Browser
  Helper" and `callservicesd` become whatever you want, and the label persists.
- **Custom app icons** — keep the app's real icon, or give it a generated tile
  in a colour and letters of your choosing. Automatic colours are derived from
  the bundle identifier, so an app looks the same every launch.
- **Output and input device switching** — pick your speakers, headphones or
  microphone, with a level slider for each.
- **Accent themes** — six presets (System, Ocean, Forest, Sunset, Violet,
  Graphite) applied across sliders, stars and highlights, and as a soft
  background wash in both light and dark mode.
- **Playing indicator** — a pulse beside any app currently producing audio, so
  you can see at a glance which row is making the noise.
- **Launch at login** and an optional **hidden Dock icon** for a pure menu bar
  app.
- **Zero latency when unused** — an app left at 100% is never tapped at all, so
  it keeps its native audio path.

## Install

Requires **macOS 15 or later**.

```bash
git clone https://github.com/ashwinn-si/mediaControl.git
cd mediaControl
./scripts/setup-signing.sh   # one-time: creates a local signing identity
./build.sh
open build/SoundFlow.app
```

`build.sh` produces both `build/SoundFlow.app` and a distributable
`SoundFlow.dmg`.

On first launch macOS asks for **Screen & System Audio Recording**. This is the
permission Apple gates system-audio capture behind — SoundFlow needs it to
attach to another app's audio stream. Nothing is recorded, stored, or sent
anywhere; audio is processed in memory and passed straight to your speakers.

> **Why the signing step?** An ad-hoc signature changes identity on every
> rebuild, so macOS revokes the audio permission each time you build. The script
> creates a stable local certificate so you grant it once.

## How it works

macOS 14.4 added Core Audio **process taps**. A tap is a wiretap — it copies an
app's audio while the original keeps playing. SoundFlow turns that into a volume
control:

1. The tap is created with `mutedWhenTapped`, silencing the app at the source —
   but only while SoundFlow is actively reading it, so a crash can never leave
   an app permanently muted.
2. A **private aggregate device** joins every tapped app to your real output.
3. One real-time `AudioDeviceIOProc` applies per-app gain and mixes them
   together.
4. Apps at 100% are skipped entirely and never enter the audio path.

A watchdog handles the Core Audio zero-buffer failure — taps can silently die
after sleep/wake — and rebuilds the route automatically.

Full technical write-up: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Efficiency

SoundFlow is a native `arm64` binary and is built to sit in your menu bar all
day. A power harness ships with it:

```bash
./scripts/power-test.sh
```

It verifies the binary runs natively (no Rosetta), then measures CPU, Activity
Monitor's Energy Impact, and idle wakeups — no `sudo` needed.

Measured on an M4, idle with no apps attenuated:

| Metric | Measured |
| :--- | :--- |
| CPU | 0.11% average |
| Energy impact | 0.42 |
| Idle wakeups | 6.6/s |
| Memory | ~57 MB |

## Known limitations

- **DRM-protected audio cannot be controlled.** Apple Music lossless and some
  Safari streams refuse to be tapped; SoundFlow greys those rows out rather
  than pretending.
- **Bluetooth adds latency.** Routing through an aggregate device costs under
  10 ms on wired output, but A2DP itself adds 300–400 ms — that is the
  Bluetooth stack, not SoundFlow.
- Apps only appear once they actually produce audio, since that is how Core
  Audio reports them.

## Development

```bash
swift build --product SoundFlowApp   # fast compile check
./scripts/run-spike.sh --selftest    # headless engine self-test
./scripts/power-test.sh              # power and arm64 audit
```

Agent and contributor notes live in **[CLAUDE.md](CLAUDE.md)**; the engine
internals and the Core Audio gotchas are in
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Release notes

### 1.1.0

- Sidebar navigation with counted All Apps, Starred and Playing filters,
  replacing the top tab pills.
- Per-app custom icons: keep the real one, or generate a tile with a chosen
  colour, style and letters.
- Edit an app's name and icon together from the new pencil button. The
  double-click-to-rename shortcut still works.
- A themed background wash that follows the accent colour.
- Settings moved into the sidebar; About split into Developer and Version.

### 1.0.0

- Initial release: per-app volume and mute via Core Audio process taps,
  favourites, renaming, device switching and accent themes.

## Author

Developed by **Ashwin SI**

- GitHub — [github.com/ashwinn-si](https://github.com/ashwinn-si)
- LinkedIn — [linkedin.com/in/ashwinsi](https://www.linkedin.com/in/ashwinsi/)

---

<sub>Keywords: macOS per-app volume control, application volume mixer for Mac,
per-application audio control macOS, Mac volume mixer, individual app volume
Mac, macOS audio routing, Core Audio process tap, per-app mute macOS, Apple
silicon menu bar volume app, SoundFlow.</sub>
