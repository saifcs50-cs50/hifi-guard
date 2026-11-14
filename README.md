# HiFi Guard

A small macOS menu-bar app for people who use Bluetooth earbuds with a Mac. It does three things:

- **Per-app volume.** A slider for every app that is playing (0 to 150%), plus mute and reset.
- **Bluetooth guard.** Stops Bluetooth earbuds from dropping into muffled mono "call mode" by keeping the
  Mac's default microphone off the earbuds' own mic.
- **Call anti-duck.** During a call, macOS turns every other app down by a fixed amount (about 15 dB). HiFi Guard
  measures that dip and cancels it, so music and videos stay at the level you set.

HiFi Guard is an independent project and is not affiliated with or endorsed by Apple.

## Features

### App volume

Each app that plays sound gets a slider from 0 to 150%. Click the app's icon to mute it, click the percentage to
reset it to 100%. The slider uses a squared taper (50% is roughly "half as loud") and boosted audio is soft-clipped
so it never goes past full scale.

Under the hood this uses Core Audio process taps: a muted tap captures the app's audio, a private aggregate
device pairs the tap with your real output device, and an IO callback copies the audio across with the gain
applied. Apps left at 100% are never touched, so they get no extra latency. If HiFi Guard quits or crashes, Core
Audio destroys the taps and the apps' own audio comes straight back. Nothing is recorded or saved.

### Bluetooth guard

Opening a Bluetooth headset's microphone forces the headset from high-quality stereo (A2DP) into the hands-free
profile (mono, 8 to 24 kHz). When the default mic is a Bluetooth mic, HiFi Guard switches the default input to the
built-in mic (or USB, or another real mic) so call apps that follow the system default never trigger that switch.
The panel shows whether the link is currently high quality or call quality, names any app that is holding the
earbuds' mic, and lets you switch output and input devices without opening System Settings. Picking the earbuds'
mic yourself turns the guard off, since using that mic is what forces call mode.

### Call anti-duck

When a call app is live, macOS ducks every other app on the call's output device by a fixed factor and exempts only
the call app. HiFi Guard:

1. detects which app is in a call (it uses the mic, and stays "in a call" while its audio keeps playing, so muting
   yourself does not end it),
2. reads the duck factor macOS reports in `coreaudiod`'s log (via `/usr/bin/log stream`),
3. routes every other playing app through its mixer and boosts by the inverse, capped at +20 dB.

The boost is only applied with a reading taken during the current call on the current output device, and it drops
to 1 the moment the call's audio stops. The call app itself is never routed through HiFi Guard.

## Limits and caveats

- **Needs macOS 15 (Sequoia) or newer.**
- **Private APIs and logs.** macOS has no public API to check the "System Audio Recording" permission, so HiFi
  Guard looks up Apple's private TCC functions at run time. The duck factor is read from an undocumented
  `coreaudiod` log line. If Apple changes the log wording, the anti-duck feature simply stops compensating; if the
  private permission functions go missing, the app attempts the taps anyway. Either way, expect it to need updates
  after some macOS releases.
- The anti-duck feature was built and tested on macOS 26 with WhatsApp calls. On other macOS versions, or with
  other call apps, it may not be able to measure the duck; the panel says so when that happens.
- The earbuds' own microphone always means call quality on a Mac. That is a Bluetooth limitation, not something an
  app can remove. Call apps that choose the earbuds' mic by name in their own settings (for example Zoom) will still
  force call mode; set them to the Mac's microphone or "Same as System".
- The first time HiFi Guard needs to change an app's volume, macOS asks for **System Audio Recording** permission.
  Without it, volume changes are not applied.
- It opens at login by default (untick "Open at login" in the panel to stop that).
- Run-tested on an Intel Mac. The build script also targets Apple silicon (arm64), but that slice has not been
  tested on real hardware.

## Build

You need macOS 15+ and a Swift 6 toolchain (Xcode or just the Command Line Tools, no Xcode project is needed).

```bash
swift build -c release
```

To build a signed `HiFi Guard.app` and install it to `/Applications`:

```bash
scripts/build-app.sh            # installs to /Applications (quits a running copy first)
scripts/build-app.sh "$HOME/Applications"  # or install somewhere else
```

The script builds a universal (Intel + Apple silicon) binary, assembles the bundle, and signs it ad hoc. It is
not notarized, so macOS will refuse to open it the first time: go to System Settings > Privacy & Security and click
**Open Anyway**. `scripts/package.sh` zips the most recent build together with install notes
(`Resources/READ ME FIRST.txt`).

## Tests

The tests are a small dependency-free executable, because the Command Line Tools ship neither XCTest nor a complete
Testing framework:

```bash
swift run HiFiGuardTests
```

They cover the pure logic (device and mic policy, call tracking, anti-duck maths, the mixer, the tap planner and the
status text). They do not touch real audio hardware.

## Project layout

| Path | What |
|---|---|
| `Sources/HiFiGuardCore` | Audio logic and Core Audio access (policy, mixer, process taps, anti-duck, call tracking) |
| `Sources/HiFiGuard` | The menu-bar app (SwiftUI panel and app state) |
| `Sources/HiFiGuardProbe` | Command-line tool: prints the live audio state, can set the default mic |
| `Sources/HiFiGuardIcon` | Renders the app icon set from the same vector paths as the menu-bar icon |
| `Sources/HiFiGuardTests` | The test executable |
| `Resources` | `Info.plist`, app icon set, install notes |
| `scripts` | `build-app.sh` and `package.sh` |

## Tech

Swift 6 toolchain (Swift 5 language mode), SwiftUI `MenuBarExtra`, Core Audio (process taps, aggregate devices,
HAL properties), `ServiceManagement` for the login item. No third-party dependencies.

## Credits

The "System Audio Recording" permission check follows the approach used by open-source audio-capture tools such as
AudioCap. No third-party code or assets are bundled; the app icon is drawn in code by `HiFiGuardIcon`.

## Licence

[MIT](LICENSE)
