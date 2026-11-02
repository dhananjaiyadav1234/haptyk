# Thock

A native macOS menu-bar app that makes your MacBook's built-in keyboard sound like a mechanical keyboard.
Free, local-only, no accounts, no network access, no recorded keystrokes.

- Six synthesized switch profiles: Cherry MX Blue / Red / Brown, Gateron Yellow, Holy Panda, Topre
- Two **real recordings** (Old Keyboard, Mac Keyboard; CC BY 3.0, see [ATTRIBUTION.md](ATTRIBUTION.md)) and support for your own sound packs
- Separate sounds for letters, space, enter, backspace, modifiers and other keys; key-release sounds
- Per-press variation (sample variants, pitch, volume, stereo position by key location)
- Typing intensity from the **built-in accelerometer** (see below), with a typing-rhythm fallback
- Menu bar controls, settings window, volume, mute, preview, launch at login, permission status

Requires macOS 14+. The prebuilt app is arm64 (Apple silicon).

## Install

1. Build it yourself (below) or open `Thock-1.0.0.dmg` and drag **Thock** to Applications.
2. The app is **ad-hoc signed, not notarized** (that needs a paid Apple Developer account). First launch:
   right-click Thock → **Open** → **Open**. If macOS still blocks it:
   `xattr -dr com.apple.quarantine /Applications/Thock.app`
3. Click the keyboard icon in the menu bar → **Settings → Permissions** → **Request Access**, then switch **Thock** on in
   System Settings → Privacy & Security → **Input Monitoring**. Thock notices within a second; no relaunch needed
   (macOS may offer "Quit & Reopen" — accept it).

## Build from source

Needs the Swift 6 toolchain (Xcode or Command Line Tools). No third-party dependencies.

```bash
scripts/build-app.sh --dmg     # → dist/Thock.app and dist/Thock-1.0.0.dmg
scripts/test.sh                # runs the automated tests
```

> Ad-hoc signatures change on every build, so macOS treats a rebuilt Thock as a new app. If sounds stop after
> rebuilding/reinstalling: Input Monitoring → select Thock → **–**, then add/enable it again.

## Real recordings and your own sound packs

Recorded profiles play real audio instead of synthesis. Put a folder in `~/Library/Application Support/Thock/Packs/<name>/` with
`pack.json` (`{"name": "My Keyboard", "summary": "..."}`), `press-01.wav`, `press-02.wav`, … and optionally `release-01.wav`, …
(PCM WAV, any sample rate), then restart Thock. Each file is a variant; space/enter/backspace/modifiers reuse them pitched
lower/higher. Only use recordings you have the right to use. The bundled recordings are not switch-specific
(they are an old keyboard and a Mac keyboard) and have no release sound.

## Using it

Menu bar icon: Keyboard Sounds on/off, Mute (⌘M), volume slider, Sound Profile, Preview, Settings (⌘,).
Settings has General (volume, release sounds, stereo width, open at login), Sounds (pick + preview),
Intensity (sensitivity, live sensor status/meter), Permissions, About (measured latency diagnostics).
When disabled or muted, Thock stops its keyboard listener, audio engine and sensor entirely.

## Typing intensity: what was verified

On this hardware (MacBook Air 15", M3, macOS 26) the Apple-silicon motion sensor (`AppleSPUHIDDevice`,
HID page 0xFF00 usage 3) **is readable by an ordinary, non-root process** through IOHID. Verified: reports arrive
(22-byte reports; x/y/z as little-endian Q16.16 values in g at byte offsets 6/10/14), gravity reads about 1 g, and the stream
runs at ~400 Hz with a requested 2 ms interval (`thock --sensor-test`). The only system interaction is setting the
driver's `ReportInterval` while the feature is running, and resetting it to 0 afterwards.

How it is used: the signal is high-pass filtered (rejects gravity and slow lap/desk motion), a noise floor and the
user's typical keystroke strength are tracked adaptively, and the vibration peak around each key-down is mapped
to gain (about 0.55×–1.45× at 100% sensitivity) and a ±2.5% pitch shift. Sounds with the sensor active are delayed by 8 ms
to wait for the impact.

Honest limits:
- **Not verified with real typing.** I can't type into the machine under test, so the mapping is verified with synthetic
  impact signals in unit tests and live sensor reads, not with human keystrokes. The Intensity tab has a live vibration
  meter so you can check on your own Mac. If the bar doesn't react to typing, turn the feature off or set sensitivity to 0.
- The sensor is undocumented and model-dependent (Intel Macs and some models lack it). Apple may change it. If no data
  arrives, Thock falls back to a deliberately subtle typing-cadence mapping.
- Sampling is ~400 Hz, so fine impact detail is limited.

## Privacy

Only the hardware key code and modifier flags of a listen-only event tap are read, to pick a sound. Characters are
never read, nothing is stored or logged (the only persisted data is your settings), and the app opens no network
connections (check with `lsof -i -p $(pgrep Thock)`). macOS Secure Input (password fields) blocks all event taps;
Thock shows a notice and stays silent there by design.

## Architecture

| Piece | Where | Notes |
|---|---|---|
| Key events | `EventTapMonitor`, `KeyEventProcessor` | `CGEventTap` listen-only on its own thread; drops auto-repeat and duplicates, derives modifier press/release; watchdog re-enables a disabled tap |
| Sounds | `Synth`, `Profiles` | Sounds are synthesized (resonant tones + filtered noise bursts from per-profile physical parameters), so there are no copyrighted samples. 6 variants per key-category and press/release |
| Playback | `VoiceMixer`, `AudioOutput` | `AVAudioSourceNode` render callback mixes 48 voices straight from the key-event thread, with no scheduling hop; 128-frame IO buffer requested |
| Intensity | `SensorMonitor`, `Intensity` | IOHID accelerometer → analyzer → mapper |
| App | `Sources/Thock` | AppKit status item and menu, SwiftUI settings, `SMAppService` login item, sleep/wake recovery |

Why Swift/AppKit: global event taps, Core Audio and IOKit are native APIs, and the app idles at about 1–3% CPU and ~31 MB.

## Diagnostics

`Thock.app/Contents/MacOS/Thock --help` — `--render` (WAVs + spectral stats), `--bench`, `--play-test`, `--sensor-test`, `--tap-test`, `--snapshot`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No sound, menu shows "!" | Grant Input Monitoring (see Install). After rebuilding, remove and re-add Thock there |
| Sound only in some apps/fields | Password fields enable Secure Input; macOS hides keys from all apps there |
| Laggy sound on Bluetooth headphones | Bluetooth adds ~100–200 ms; use the built-in speakers or wired output (Settings → About shows the measured latency) |
| "Thock can't be opened" | Right-click → Open, or the `xattr` command above |
| Open at login fails | Enable it in System Settings → General → Login Items; the app should live in /Applications |
| Intensity does nothing | Check Settings → Intensity status; set sensitivity to 0 to disable the effect |

## Known limitations

- Not notarized; ad-hoc signed. Apple silicon build only (a universal build needs full Xcode).
- Sounds are synthesized approximations of switch types, not recordings of real switches.
- Real-keystroke behavior (event delivery through the tap, intensity correlation) was verified by the user-facing
  permission flow and component tests; automated posting of key events is blocked without Accessibility access, so there is
  no automated end-to-end typing test.
- The sensor delay adds 8 ms when intensity is on. Turn it off for the lowest latency.

## Test and measurement results

See [docs/REPORT.md](docs/REPORT.md).
