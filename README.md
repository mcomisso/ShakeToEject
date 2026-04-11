# ShakeToEject

**A macOS menu bar app that safely ejects external drives when it detects you picking up your laptop.**

ShakeToEject watches the hidden accelerometer on Apple Silicon MacBook Pros and pops a playful warning countdown when it notices the laptop being moved. If you don't cancel within a few seconds, it unmounts and ejects every external drive so your data isn't at risk when you walk off with an open laptop still plugged into a portable SSD.

## How it works

1. A dedicated background thread reads raw accelerometer samples from the Bosch BMI286 IMU via IOKit HID — the same sensor Apple uses internally for features like "Knock" and lid-angle detection.
2. A pure-Swift shake detector computes the magnitude of non-gravity acceleration on every sample and fires an event when it exceeds a configurable threshold.
3. On detection, a full-screen overlay (or a compact capsule that drops out of the MacBook notch, on notched models) shows a countdown with a random panic line from the drives' perspective: *"THEY MOVED US!!"*, *"QUICK, BEFORE THEY DROP US!"*, *"EARTHQUAKE!!!"*.
4. If you press Esc or click Cancel within the countdown, nothing happens. Otherwise, every non-excluded external drive is unmounted and ejected via DiskArbitration.

The whole thing runs as an unprivileged code-signed process — no launch daemon, no root, no `sudo`.

## Requirements

- **Mac:** Apple Silicon MacBook Pro with the M1 Pro chip, or any M2/M3/M4 chip. Other M1 variants (M1 / M1 Air / M1 13-inch Pro), Intel Macs, and non-MacBook Apple Silicon machines **do not have the sensor** and are not supported.
- **macOS:** 14 Sonoma or later. Developed and tested on macOS 26.
- **Xcode:** 26 or later, if you want to build from source.
- **Code signing:** required (even ad-hoc). The driver wake step that unlocks the accelerometer only works for code-signed processes on macOS 26.

## Build from source

```bash
# Clone
git clone <your-fork-url> ShakeToEject
cd ShakeToEject

# Install XcodeGen (Homebrew)
brew install xcodegen

# Generate the Xcode project from project.yml
xcodegen generate

# Open and build
open ShakeToEject.xcodeproj
# or from the command line:
xcodebuild -scheme ShakeToEject -configuration Debug build
```

If you don't have a paid Apple Developer account, the free personal team is sufficient for local builds. Open `ShakeToEject.xcodeproj` in Xcode and pick your team under *Signing & Capabilities*, or set `DEVELOPMENT_TEAM` in `project.yml` to your Team ID so it persists across regenerations.

## Usage

1. Launch the app. A menu bar icon (eject circle) appears in the top right of your screen.
2. Plug in an external drive. The menu bar popover shows it in the list.
3. Move the laptop. A warning appears — press Esc or click Cancel to stop, or let the countdown finish to eject.

**From the menu bar popover you can:**
- See the current sensor status and live shake counter
- View every mounted external drive and manually Eject All
- Open **Settings…** (⌘,) to configure the detection thresholds and warning style
- Click **Simulate Shake (dev)** to trigger the warning flow without physically moving the laptop — useful for testing

## Settings

Open with **Settings…** in the menu bar or press ⌘,.

### Detection

- **Sensitivity** (0.05 – 1.0 g) — how much non-gravity acceleration triggers a shake event. Lower values catch gentle motion; higher values only fire on firm movement. Default 0.30 g.
- **Cooldown** (0.5 – 5.0 s) — minimum time between detected shake events. Prevents one continuous shake from firing repeatedly. Default 1.0 s.

Both take effect **live** — drag the slider and the running sensor picks up the new value on its next sample.

### Warning

- **Countdown** (1 – 30 s) — how long the warning overlay waits before ejecting. Default 5 s.
- **Style** — how the warning presents itself:
  - **Fullscreen** — dark overlay covering the whole screen, with giant countdown and panic line. Visible on every connected display.
  - **Notch (compact)** — a small rounded capsule that drops out of the MacBook hardware notch on notched MacBook Pros. Non-notched screens (external monitors) fall back to the fullscreen style.
  - **Auto** — notch capsule on notched Macs, fullscreen elsewhere. Recommended.

### Drives

- Per-drive **Exclude from auto-eject** toggles. Excluded drives appear with a 🔒 in the menu bar and are never ejected by the shake flow or the Eject All button.
- Unmounted drives you've excluded in the past appear under *Remembered exclusions (not mounted)* with a Forget button.

### General

- **Launch at login** — registers the app as a login item via `SMAppService`.
- **Version** — current build.

## Known limitations

- **Hardware support is narrow.** Only MacBook Pro M1 Pro and M2+ chips have the BMI286 IMU. M1 (non-Pro), M1 Air, M1 13" Pro, Intel Macs, and Mac mini / Mac Studio / iMac are all unsupported because the sensor isn't present.
- **Volume-name-based exclusions.** The drive exclusion list matches by volume name, so renaming a drive breaks its exclusion. For a v1 this is an intentional simplification; a future version may move to volume UUIDs.
- **No notarization yet.** Running the app outside Xcode on another Mac requires either disabling Gatekeeper or running a locally-built signed copy. Notarized distribution is not yet set up.
- **The notch width is approximated.** AppKit does not expose the exact notch cutout width; the compact-mode capsule uses 200 pt which looks right across 14" and 16" MacBook Pros but may be imperfect on future models.
- **Sample rate is hardcoded.** The cooldown-to-samples conversion assumes the ~800 Hz native rate measured on M1 Pro. Other chips may run at different rates; at present this only affects the cooldown slider feeling slightly off in real seconds.

## Credits

ShakeToEject would not exist without these two projects that proved the IOKit HID path into the BMI286 is feasible:

- **[olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)** — the Python reference that documented the `AppleSPUHIDDevice` matching criteria, the 22-byte report layout, and (crucially) the `SensorPropertyReportingState` / `SensorPropertyPowerState` / `ReportInterval` wake-up step. MIT licensed.
- **[taigrr/spank](https://github.com/taigrr/spank)** — the Go implementation that inspired the "playful toy" angle and whose README first pointed me at the underlying sensor. MIT licensed.

ShakeToEject re-implements the sensor read path in Swift from the technical details those projects published. No code was copied directly from either.

## License

MIT — see [LICENSE](LICENSE).

© 2026 Matteo Comisso
