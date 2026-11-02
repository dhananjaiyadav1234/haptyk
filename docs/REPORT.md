# Engineering report

Environment: MacBook Air 15" (Mac15,13, Apple M3), macOS 26.6, Swift 6.3, Command Line Tools only (no Xcode).

## Verified
| Item | Result |
|---|---|
| Release build | succeeds (`scripts/build-app.sh`); `.app` + DMG produced, `codesign --verify --strict` OK (ad-hoc) |
| Automated tests | `scripts/test.sh`: **49 tests in 7 suites, all passed** (key classification, event de-duplication/auto-repeat/modifiers, settings persistence across store instances + corruption handling, synthesis bounds/determinism/variation, profile distinctness, special keys, mixer volume/pan/pitch/overload, coordinator mute/release/profile switching, accelerometer analysis and intensity mapping) |
| Bugs found by tests | Volume change while idle ramped from the old level on the next sound (fixed); modifier keys on Topre were too close to letters (retuned) |
| Launch | App launches as a menu-bar agent (no Dock icon), settings window renders (see `--snapshot`), ran stably; idle ~1–3 % CPU, ~31 MB RSS with the audio engine and sensor active |
| Event tap | With Input Monitoring granted, the listen-only tap is created and runs. **Live key delivery was not machine-verified**: posting synthetic key events is denied without Accessibility access, which I did not change |
| Audio path | `--play-test`: engine started, 144 triggers rendered; trigger → render-callback delay mean 1.43 ms, max 2.90 ms; 128-frame buffer. The output device in this run was Bluetooth headphones (reported output latency 152 ms), so hardware latency on built-in speakers will be much lower |
| Mixer cost | `--bench`: mean 2.1 µs per 128-frame block (0.077 % of the 2.67 ms budget), worst 4.6 µs |
| Synthesis | about 60–80 ms per profile, done off the main thread and cached |
| Profile separation (alpha key, spectral centroid / 30 dB decay) | Blue 3424 Hz/116 ms · Gateron 2157/176 · Brown 1673/222 · Red 1297/278 · Panda 1183/360 · Topre 762/144 |
| Accelerometer | Device present, unprivileged IOHID reads work, ~407 Hz measured, noise floor ≈ 0.0025 g. Correlation with real typing is **not verified** (see README) |
| Privacy | Only key code/flags read; no persistence except settings; no networking code in the project |

## Review notes
Fixed during review: tap watchdog and permission-loss handling, UI redraw storm (15 Hz meter redrew every tab → isolated meter object, change-only publishing), sleep/wake recovery, main-thread synthesis stall on profile switch.

## Not done / limits
Notarization, universal binary, real-recording sound packs, automated end-to-end typing test.
