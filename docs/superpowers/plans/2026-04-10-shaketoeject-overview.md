# ShakeToEject — Overview & Phase Roadmap

> **This is a design/roadmap document.** It describes the architecture, file
> structure, and the phased plan for building ShakeToEject. Each phase has its
> own detailed plan file under `docs/superpowers/plans/` that the executing
> agent will follow task-by-task.

## Goal

A playful macOS menu bar app that safely ejects all external drives when it
detects the laptop being picked up or shaken, giving the user a configurable
countdown warning to cancel before ejection happens.

## Motivation

MacBook Pro M1 Pro and M2+ chips contain a Bosch BMI286 IMU (accelerometer +
gyroscope) managed by the Sensor Processing Unit. Apple does not expose it
through any public framework, but it is readable via IOKit HID under
`AppleSPUHIDDevice`. Third-party tools (`spank`, `Haptyk`, `Knock`,
`olvvier/apple-silicon-accelerometer`) have proven the technique reliable on
M1 Pro and M2+.

By combining this motion signal with DiskArbitration (the public macOS
framework for enumerating and unmounting drives), we can build a tool that
protects external drive data loss when the laptop is moved while something is
plugged in — a plausible concern for anyone who edits video, does field work,
or uses portable SSDs.

## Hardware & OS Requirements

- **CPU:** Apple Silicon M1 Pro, or any M2+ chip. No other M1 variant, no
  Intel, no A-series.
- **macOS:** 14.0 Sonoma or later (deployment target). Developed and tested
  on macOS 26.
- **Privileges:** none beyond a code-signed unprivileged process. Phase 1
  discovered that on macOS 26 the SPU driver wake step works without root
  when the calling process is code-signed.

## Architecture

**Single app target.** The original plan called for a two-target split (SwiftUI menu bar app + privileged `SMAppService` launch daemon talking over XPC) because we believed IOKit HID access to the BMI286 required root. Phase 1 disproved that assumption on macOS 26: a code-signed unprivileged process can successfully call `IORegistryEntrySetCFProperty` on `AppleSPUHIDDriver` services and receive input reports. Phase 3 collapsed the architecture to one target and deleted the helper wholesale.

All code now runs in `ShakeToEject.app`:

- The SwiftUI app shell (`@main`, `MenuBarExtra`, `NSApplicationDelegateAdaptor`).
- The sensor pipeline (`AccelerometerReader` → `ShakeDetector`) on a dedicated worker thread with its own `CFRunLoop`.
- The drive subsystem (`DriveMonitor` + `DriveEjector`) on the main dispatch queue via `DASessionSetDispatchQueue`.
- The warning/countdown overlay (Phase 5) and its sound assets.
- The settings UI and persistence (Phase 8).

**No XPC. No SMAppService. No launch daemon plist.** If Apple ever re-tightens the privilege requirement on `AppleSPUHIDDriver` in a future macOS release, the `Helper/` directory and the `SMAppService` registration can be reconstructed from the Phase 0 / Phase 1 plan documents — the approach is fully documented in git history.

### Control flow

1. App launches. `AppDelegate` starts `SensorService` and `DriveMonitor`.
2. `SensorService` spins up a dedicated worker thread, wakes the SPU driver, opens the HID device, and begins streaming samples at ~800 Hz. `ShakeDetector` ingests every sample.
3. `DriveMonitor`'s `DASession` (dispatch queue = main) publishes drive appear/disappear events. The observable `drives` array drives the menu bar popover.
4. When a shake event fires (Phase 6 wiring), the app shows a full-screen warning overlay with a countdown and plays the warning sound.
5. If the user clicks Cancel or presses Escape, the overlay closes. Cooldown applies to prevent immediate re-fire.
6. If the countdown completes, `DriveEjector.unmountAndEject` runs on every drive; the drives disappear from the list as DiskArbitration notifies us of their departure.
7. Phase 7 gates the sensor on drive presence: the sensor only runs while at least one external drive is mounted.

## Tech Stack

- **Language:** Swift 6, strict concurrency enabled
- **UI:** SwiftUI, `MenuBarExtra`, `@Observable`, `NSApplicationDelegateAdaptor`
- **App target:** macOS 14+ deployment, developed on macOS 26 / Xcode 26
- **Project generator:** XcodeGen (`project.yml` is the source of truth; `.xcodeproj` is git-ignored)
- **Low-level sensor:** IOKit HID (`IOHIDManager`, `IOHIDDeviceRegisterInputReportCallback`), plus `IOServiceMatching("AppleSPUHIDDriver")` + `IORegistryEntrySetCFProperty` for the driver wake step
- **Drive enumeration/ejection:** `DiskArbitration.framework` (`DASession`, `DADiskCopyDescription`, `DADiskUnmount`, `DADiskEject`), imported via `@preconcurrency`
- **Audio:** `AVAudioPlayer` (Phase 5)
- **Settings:** `UserDefaults` + `@Observable` store (Phase 8)
- **Testing:** Swift Testing

## File Structure

```
ShakeToEject/
├── project.yml                                # XcodeGen source of truth
├── README.md                                  # (Phase 9)
├── LICENSE                                    # MIT (credits olvvier + spank)
├── .gitignore                                 # ignores ShakeToEject.xcodeproj/
├── docs/
│   ├── hardware-probe-m1pro.txt               # captured ioreg output
│   └── superpowers/plans/                     # this overview + phase plans
│
├── App/                                       # main app target (only target)
│   ├── ShakeToEjectApp.swift                  # @main + AppDelegate
│   ├── ShakeToEject.entitlements              # sandbox off
│   ├── Assets.xcassets/                       # (Phase 9)
│   │
│   ├── MenuBar/
│   │   └── MenuBarContent.swift               # popover: status, drives, events
│   │
│   ├── Windows/                               # (Phase 5, 8)
│   │   ├── WarningOverlayWindow.swift         # borderless full-screen warning
│   │   └── DashboardWindow.swift              # settings window
│   │
│   ├── Views/                                 # (Phases 5, 8)
│   │   ├── WarningView.swift
│   │   ├── DashboardView.swift
│   │   ├── DriveListView.swift
│   │   ├── SensitivitySliderView.swift
│   │   └── CountdownSettingView.swift
│   │
│   ├── Sensing/                               # sensor pipeline
│   │   ├── HIDReport.swift                    # pure byte parser
│   │   ├── AccelerometerReader.swift          # IOKit HID wrapper
│   │   └── ShakeDetector.swift                # pure algorithm
│   │
│   ├── Services/                              # app-wide services
│   │   ├── SensorWorker.swift                 # dedicated thread + CFRunLoop
│   │   ├── SensorService.swift                # @Observable facade
│   │   ├── DriveInfo.swift                    # value type (Phase 4)
│   │   ├── DriveMonitor.swift                 # @Observable drive list (Phase 4)
│   │   ├── DriveEjector.swift                 # unmount + eject (Phase 4)
│   │   ├── SoundPlayer.swift                  # (Phase 5)
│   │   └── SettingsStore.swift                # (Phase 8)
│   │
│   └── Resources/
│       └── Sounds/                            # user-provided audio (Phase 5+)
│
├── Shared/
│   └── Constants.swift                        # just appBundleID
│
└── Tests/
    ├── HIDReportTests.swift                   # 10 cases
    └── ShakeDetectorTests.swift               # 12 cases
```

## Phase Roadmap

**Completed:**

- **Phase 0** — XcodeGen scaffolding, menu bar app stub, hardware verification (commit `fe1eb71`)
- **Phase 1** — IOKit HID accelerometer reader with `HIDReport` parser + 10 tests (commit `6a3aedf`)
- **Phase 2** — pure `ShakeDetector` algorithm with 12 tests + `--detect` CLI mode (commit `79c786d`)
- **Phase 3** — collapse helper target into the app, add `SensorWorker` + `SensorService`, menu bar shake counter (commit `b1b3e81`)

**Remaining:**

- **Phase 4** — DiskArbitration: `DriveInfo`, `DriveMonitor` (observable drive list), `DriveEjector` (unmount + eject), menu bar "Eject All" button. See `2026-04-10-shaketoeject-phase-4-drives.md`.
- **Phase 5** — Warning overlay window + countdown + sound player. Dev-only "Simulate Shake" menu item to trigger the flow without physically moving the laptop.
- **Phase 6** — Wire the sensor pipeline → warning overlay → ejection. End-to-end: shake the laptop → warning appears → countdown runs → drives eject unless cancelled. The app is now functional.
- **Phase 7** — Auto-arm on drive presence. `SensorService` only runs while at least one external drive is mounted; automatically starts when a drive appears and stops when the last one leaves. Saves battery and cleans up semantics.
- **Phase 8** — Settings UI + persistence. Dashboard window with threshold slider, countdown length stepper, drive exclusion list. `SettingsStore` via `UserDefaults`. Launch at login via `SMAppService.mainApp.register()`.
- **Phase 9** — Playful polish. Custom menu bar icon, animated shake visualisation, drives "shake off" ejection animation, README, app icon, optional Liquid Glass effects for iOS 26-era UI.

## Cross-cutting Concerns

### Signing

The app is code-signed with the developer's Team ID (baked into `project.yml` as `DEVELOPMENT_TEAM`). Code signing is **required** — Phase 1 verified that only code-signed binaries can successfully wake the SPU driver via `IORegistryEntrySetCFProperty`. Ad-hoc signing also works for local dev. Distribution will require a paid Developer ID and notarisation; the Debug-vs-Release `--timestamp=none` conditional in the `codesign` invocation (now removed with the helper) was originally designed to handle this.

### Licensing of Third-Party Work

The HID-read approach is derived from `olvvier/apple-silicon-accelerometer`
(MIT) and `taigrr/spank` (MIT). Our README credits both. We do **not** copy
code directly; we reimplement the byte-parsing and callback setup in Swift.

### Sound Assets

Placeholder uses `NSSound(named: "Funk")` (system sound). User will add
`warning.wav` and `ejected.wav` under `App/Resources/Sounds/` later. The
`SoundPlayer` API will be stable so swapping in real assets is a drop-in.

### Sandbox

v1 ships with App Sandbox **off**. DiskArbitration ejection works under
sandbox with the right temporary exceptions, but IOKit HID access to the
SPU driver properties is less certain — we can revisit sandboxing after
Phase 9 if it proves worth the investigation.

## Discoveries worth remembering

1. **macOS 26 allows unprivileged SPU HID access for code-signed processes.** Setting `SensorPropertyReportingState`, `SensorPropertyPowerState`, and `ReportInterval` on `AppleSPUHIDDriver` services via `IORegistryEntrySetCFProperty` works from a regular user process on M1 Pro — no sudo required. This contradicts `olvvier/apple-silicon-accelerometer`'s published "requires root" note and was the basis for the Phase 3 architecture pivot. See `docs/superpowers/plans/2026-04-10-shaketoeject-phase-1-hid-reader.md` "Discoveries during execution" for the full context.

2. **Hardware match criteria are not specific enough alone.** `{VendorID: 1452, UsagePage: 0xFF00, Usage: 3}` on M1 Pro matches both the real BMI286 accelerometer **and** the Apple Internal Keyboard/Trackpad. Disambiguate via `MaxInputReportSize == 22` after enumeration. This is baked into `AccelerometerReader.swift`.

3. **The gravity axis on M1 Pro is -y, not -z.** Irrelevant for `ShakeDetector` (orientation-agnostic magnitude), but important for any future "which way is down?" UI.

4. **Native sample rate is ~800 Hz, not the ~100 Hz suggested by the olvvier Python library.** They decimate 8:1; we don't. `ShakeDetector.cooldownSamples` defaults to 800 (= ~1 second at the native rate).
