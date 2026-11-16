# HiFi Guard

I wrote this menu-bar app because my Bluetooth earbuds kept dropping into call mode on my Mac. As soon as a call
app opened the earbuds' microphone, music went from stereo to muffled mono, and for the whole call macOS turned
every other app down. HiFi Guard stops both, and it gives each app its own volume slider.

It needs macOS 15 or newer. It is not affiliated with Apple.

## Per-app volume

Every app that's playing gets a slider from 0 to 150%. Click its icon to mute it, or the percentage to reset it.
The curve is squared, so 50% sounds about half as loud, and boosted audio is soft-clipped.

Each slider is a Core Audio process tap. The tap mutes the app and captures its audio, a private aggregate device
pairs it with your output device, and an IO callback copies the audio across with the gain applied. Apps at 100%
are never tapped, so they get no extra latency. If HiFi Guard quits or crashes, Core Audio removes the taps and
the apps sound normal again. Nothing is recorded.

## Keeping earbuds out of call mode

A Bluetooth headset can't play high-quality stereo (A2DP) while its mic is open. It switches to the hands-free
profile instead, which is mono at 8 to 24 kHz. Most call apps use the system's default mic, so when that default is
the earbuds, HiFi Guard moves it to the built-in mic (or a USB or other non-Bluetooth mic) before any app asks.

The panel shows whether the earbuds are in high-quality or call mode, names any app holding their mic, and lets you
switch devices without opening System Settings. Picking the earbuds' mic yourself turns the guard off.

## Undoing the call volume dip

During a call, macOS lowers every other app on the call's output device and leaves only the call app alone. Apple
doesn't document by how much, so I looked in `coreaudiod`'s log and found it: a fixed volume scalar of 0.1778 for
each app, about 15 dB down.

HiFi Guard treats the app that opened the mic as the call app, and keeps treating it that way while its audio
plays, so muting yourself doesn't end the call. It reads the duck factor through `/usr/bin/log stream`, routes every
other playing app through its mixer and boosts it by the inverse, at most +20 dB. The reading has to come from the
current call on the current output device, and the boost drops back to 1 the moment the call audio stops.

The call app itself is never routed through HiFi Guard. An early version did tap it (I had moved WhatsApp's
slider), which took away its exemption from the duck, and the other person's voice dropped to about 18% volume.
Call apps are now left alone whatever their slider says.

## Limits

- macOS has no public API for checking the System Audio Recording permission, so HiFi Guard calls Apple's private
  TCC functions, and tries the taps anyway if they are missing. The duck factor comes from an undocumented log
  line. Either one could break in a future macOS release.
- I tested anti-duck on macOS 26 with WhatsApp calls. With other call apps or macOS versions it may not manage to
  measure the duck, and the panel says so when that happens.
- The earbuds' own mic always means call quality on a Mac. That's a Bluetooth limit no app can remove. If a call
  app picks the earbuds' mic by name in its own settings (Zoom can), set it to the Mac's mic or "Same as System".
- macOS asks for System Audio Recording permission the first time a slider moves. Without it, the sliders do
  nothing.
- It opens at login unless you untick "Open at login" in the panel.
- I've only run it on an Intel Mac. The build also makes an Apple silicon slice, which I haven't tested on real
  hardware.

## Build

You need macOS 15+ and a Swift 6 toolchain. The Command Line Tools are enough; there is no Xcode project.

```bash
swift build -c release
```

To build a signed `HiFi Guard.app` and install it to `/Applications`:

```bash
scripts/build-app.sh            # installs to /Applications (quits a running copy first)
scripts/build-app.sh "$HOME/Applications"  # or install somewhere else
```

The script builds a universal binary and signs it ad hoc. It isn't notarized, so the first launch needs System
Settings > Privacy & Security > Open Anyway. `scripts/package.sh` zips the latest build with the install notes in
`Resources/READ ME FIRST.txt`.

## Tests

```bash
swift run HiFiGuardTests
```

The tests are a plain executable, because the Command Line Tools ship neither XCTest nor a complete Testing
framework. They cover the logic that needs no audio hardware: device and mic policy, call tracking, the anti-duck
maths, the mixer, the tap planner and the status text.

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

## Tech and credits

Swift 6 toolchain in Swift 5 language mode, SwiftUI `MenuBarExtra`, Core Audio and `ServiceManagement` for the
login item, with no third-party dependencies. The permission check follows the approach of open-source
audio-capture tools such as AudioCap, and the app icon is drawn in code by `HiFiGuardIcon`.

## Licence

[MIT](LICENSE)
