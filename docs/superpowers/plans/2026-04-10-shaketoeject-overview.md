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
- **Privileges:** The privileged helper must run as root to open the IOKit
  HID device. The main app runs as the user.

## Architecture

Two binaries packaged in one app bundle:

1. **`ShakeToEject.app`** — SwiftUI menu bar application (`LSUIElement` true,
   no Dock icon). Runs in user context. Owns all UI, settings storage, drive
   monitoring, drive ejection, and the warning/countdown flow.

2. **`com.mcsoftware.ShakeToEject.Helper`** — privileged launch daemon embedded
   at `Contents/MacOS/com.mcsoftware.ShakeToEject.Helper` inside the app
   bundle. Registered with launchd via `SMAppService.daemon(plistName:)`
   (macOS 13+ replacement for the deprecated `SMJobBless`). Runs as root. Only
   reads the accelerometer and runs shake detection — nothing else. Publishes
   events to the app over XPC.

### Why this split

- Reading the IMU requires root; ejecting drives does not (`DiskArbitration`
  works fine as the user).
- Keeping the privileged surface tiny (one sensor read loop + detection math)
  minimises the security blast radius.
- The app stays sandbox-friendly (even if we do not enable App Sandbox in v1,
  we preserve the option).
- The helper has no AppKit, no SwiftUI, no third-party dependencies. It is a
  plain `CommandLineTool` target.

### Communication

`NSXPCConnection` over a Mach service named
`com.mcsoftware.ShakeToEject.Helper`. The connection is declared in the
daemon plist under `MachServices`.

Two protocols in `Shared/HelperProtocol.swift`:

- `HelperProtocol` (helper exports to app): `getVersion`, `arm(sensitivity:)`,
  `disarm`, `updateSensitivity(_:)`.
- `HelperClientProtocol` (app exports to helper): `shakeDetected(magnitude:)`,
  `accelSample(x:y:z:)` (for the live visualisation in the UI).

### Control flow

1. App launches. Registers helper via `SMAppService` if not already
   registered. Waits for user to approve in System Settings → Login Items.
2. App subscribes to DiskArbitration for drive mount/unmount events.
3. When at least one external drive is mounted, app calls `helper.arm()`.
4. Helper opens the HID device, starts receiving samples at ~100 Hz, runs
   shake detection with the configured sensitivity.
5. On detection, helper calls `client.shakeDetected(magnitude:)`.
6. App shows a full-screen warning overlay window with a countdown
   (configurable) and plays the warning sound.
7. If the user clicks Cancel or presses Escape, the overlay closes. The
   helper stays armed.
8. If the countdown completes, the app ejects all mounted external drives via
   DiskArbitration and plays an ejection confirmation sound.
9. When the last external drive unmounts, app calls `helper.disarm()` and the
   helper stops the HID read loop to save power.

## Tech Stack

- **Language:** Swift 6
- **UI:** SwiftUI, `MenuBarExtra`, `@Observable`
- **App target:** macOS 14+
- **Project generator:** XcodeGen (`project.yml` is the source of truth)
- **Low-level sensor:** IOKit HID framework (`IOHIDManager`,
  `IOHIDDeviceRegisterInputReportCallback`), likely via a small Swift wrapper
  with a `@convention(c)` callback
- **Drive enumeration/ejection:** `DiskArbitration.framework`
  (`DASessionCreate`, `DADiskCreateFromBSDName`, `DADiskUnmount`,
  `DADiskEject`)
- **Privileged helper registration:** `ServiceManagement.framework`
  (`SMAppService.daemon(plistName:)`)
- **IPC:** `NSXPCConnection` / `NSXPCListener`
- **Audio:** `AVAudioPlayer`
- **Settings:** `UserDefaults` + `@Observable` store
- **Testing:** Swift Testing (preferred) or XCTest where needed

## File Structure

```
ShakeToEject/
├── project.yml                                # XcodeGen source of truth
├── README.md
├── LICENSE                                    # MIT (to match spank/library deps)
├── .gitignore
├── docs/
│   └── superpowers/
│       └── plans/                             # This overview + phase plans
│
├── App/                                       # Main app target
│   ├── ShakeToEjectApp.swift                  # @main, MenuBarExtra scene
│   ├── Info.plist                             # LSUIElement = true
│   ├── ShakeToEject.entitlements
│   ├── Assets.xcassets/                       # Menu bar icon, app icon
│   │
│   ├── MenuBar/
│   │   └── MenuBarContent.swift               # SwiftUI content inside MenuBarExtra
│   │
│   ├── Windows/
│   │   ├── DashboardWindow.swift              # Settings/status window
│   │   └── WarningOverlayWindow.swift         # Borderless full-screen warning
│   │
│   ├── Views/
│   │   ├── DashboardView.swift                # Main window body
│   │   ├── DriveListView.swift                # Live external drives
│   │   ├── AccelerometerView.swift            # Live 3-axis visualisation
│   │   ├── SensitivitySliderView.swift
│   │   ├── CountdownSettingView.swift
│   │   └── WarningView.swift                  # Big countdown + Cancel
│   │
│   ├── Services/
│   │   ├── HelperConnection.swift             # XPC client wrapper + client impl
│   │   ├── HelperInstaller.swift              # SMAppService registration
│   │   ├── DriveMonitor.swift                 # DiskArbitration observer
│   │   ├── DriveEjector.swift                 # DiskArbitration ejection
│   │   ├── SoundPlayer.swift                  # AVAudioPlayer wrapper
│   │   └── SettingsStore.swift                # @Observable settings
│   │
│   └── Resources/
│       └── Sounds/                            # User-provided audio assets
│
├── Helper/                                    # Privileged launch daemon target
│   ├── main.swift                             # Entry point + NSXPCListener
│   ├── Helper.entitlements
│   ├── HelperService.swift                    # NSXPCListenerDelegate
│   ├── AccelerometerReader.swift              # IOKit HID reader
│   ├── ShakeDetector.swift                    # Pure detection algorithm
│   ├── HIDReport.swift                        # Byte parsing helpers
│   └── Launchd/
│       └── com.mcsoftware.ShakeToEject.Helper.plist
│
├── Shared/                                    # Compiled into both targets
│   ├── HelperProtocol.swift                   # @objc XPC protocols
│   ├── AccelerationSample.swift               # Codable sample
│   └── Constants.swift                        # Bundle IDs, Mach service name
│
└── Tests/
    ├── HIDReportTests.swift                   # Byte parsing (hardware-free)
    ├── ShakeDetectorTests.swift               # Algorithm (hardware-free)
    └── SettingsStoreTests.swift
```

## Phase Roadmap

Each phase produces working, independently testable software. Each is
captured in its own plan file that the executing agent follows step-by-step.

### Phase 0 — Scaffolding & Hardware Verification

Migrate the stock Xcode template to XcodeGen with two targets (app +
helper). App launches as a menu bar app with `LSUIElement=true`. Helper
target builds as a command line tool and is embedded in the app bundle via
a Copy Files phase. Verify the M1 Pro has the IMU via `ioreg`. Strip all
SwiftData template code.

**Exit criteria:**
- `xcodegen generate && xcodebuild -scheme ShakeToEject build` succeeds.
- App launches, shows a menu bar icon, quits cleanly.
- Helper binary exists at `Contents/MacOS/com.mcsoftware.ShakeToEject.Helper`
  inside the built app bundle.
- `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice` shows the sensor on the dev
  machine.

**Plan file:** `2026-04-10-shaketoeject-phase-0-scaffolding.md`

### Phase 1 — IOKit HID Accelerometer Reader (Helper only)

In the helper, implement `AccelerometerReader` that opens the BMI286 IMU via
`IOHIDManager` with matching criteria (vendor usage page `0xFF00`, usage 3),
registers an input report callback, parses 22-byte HID reports into g-force
samples, and prints them to stdout when the helper runs as a standalone
binary under `sudo`. Add `HIDReport` byte-parsing unit tests.

**Exit criteria:**
- `sudo ./com.mcsoftware.ShakeToEject.Helper --print` streams x/y/z in g at
  ~100 Hz.
- `HIDReportTests` passes without any hardware access.

### Phase 2 — Shake Detection Algorithm (Pure, Hardware-free)

Implement `ShakeDetector` as a pure type that ingests samples, removes
gravity, computes dynamic magnitude, applies a configurable threshold with
debounce cooldown, and emits discrete shake events. All tested with
synthetic sample sequences (at-rest, drift, sharp spike, sustained motion,
debounce window). No hardware needed for tests.

**Exit criteria:**
- `ShakeDetectorTests` covers: no-event-at-rest, event-on-spike, respects
  debounce cooldown, sensitivity scaling.
- Helper `--print` mode can flip to `--detect` mode and logs detected shakes
  with magnitudes.

### Phase 3 — XPC Listener in the Helper

Define `HelperProtocol` and `HelperClientProtocol` in `Shared/`. Helper sets
up `NSXPCListener(machServiceName:)` and implements `getVersion`, `arm`,
`disarm`. `arm` starts the reader+detector; `disarm` stops. On detection,
the helper calls back to the connected client's `shakeDetected`.

**Exit criteria:**
- A tiny test client (a throwaway command line tool, committed or not) can
  connect to the helper, call `getVersion`, call `arm`, and receive shake
  events.

### Phase 4 — SMAppService Helper Registration (App side)

App gains `HelperInstaller` which wraps `SMAppService.daemon(plistName:)`.
Menu bar has an "Install Helper" button that triggers registration, opens
System Settings if approval is needed, and shows install status. App has a
`HelperConnection` that creates an `NSXPCConnection` to the helper's Mach
service. A dev-only menu item calls `helper.getVersion()` and displays it.

**Exit criteria:**
- Fresh install: click Install, get prompted in System Settings, enable,
  click "Ping Helper" → see version string.
- Uninstall: click Uninstall, helper disappears from `launchctl list`.

### Phase 5 — DiskArbitration Drive Monitor & Ejector (App side)

Implement `DriveMonitor` (observes `kDADiskAppearedCallback` and
`kDADiskDisappearedCallback` on a private `DASession`, filters to external
volumes, publishes an `@Observable` list) and `DriveEjector` (unmounts then
ejects via `DADiskUnmount` + `DADiskEject`). Dashboard window shows the
live list with an "Eject All" button.

**Exit criteria:**
- Plug a USB drive → appears in list within 1 s. Unplug → disappears.
- Click Eject All → drive is safely ejected, no system warning dialog.

### Phase 6 — Warning Overlay + Countdown + Sound

Implement a borderless, full-screen, always-on-top `WarningOverlayWindow`
that animates in with a big countdown, a playful "CANCEL" button, and
cancellable keyboard shortcut (Esc). Sound plays via `SoundPlayer` with a
placeholder system sound until user adds the real asset. Dev menu item lets
us trigger the flow without shaking the laptop.

**Exit criteria:**
- Dev menu → "Simulate Shake" → overlay appears, countdown runs, sound
  plays.
- Pressing Escape or clicking Cancel aborts the flow.
- Countdown completing triggers `DriveEjector.ejectAll()`.

### Phase 7 — Menu Bar & Settings UI

Menu bar icon reflects arm state (armed/disarmed/no drives). Menu has:
Status summary, Arm/Disarm toggle, Open Dashboard, Quit. Dashboard window
has: arm toggle, sensitivity slider (0.05–0.5 g), countdown length stepper
(1–30 s), drive list, live accelerometer preview (Phase 9 polishes the
viz), install/uninstall helper buttons. All settings persisted via
`SettingsStore`.

**Exit criteria:**
- Settings round-trip across app relaunch.
- Arming/disarming via UI actually starts/stops the helper loop (verify in
  `log stream --predicate 'subsystem == "com.mcsoftware.ShakeToEject.Helper"'`).

### Phase 8 — Auto-Arm Integration

Wire `DriveMonitor` → `HelperConnection`: when drive count goes from 0 to
1, call `helper.arm()`. When it goes from 1 to 0, call `helper.disarm()`.
User can still manually force-disarm via menu, in which case auto-arm is
suppressed until the next drive event.

**Exit criteria:**
- Plug a drive, laptop shake triggers warning. Eject the drive, shake no
  longer triggers.

### Phase 9 — Playful Polish

Live accelerometer sparkline or 3D cube in the dashboard. Drives "shake
off" the list with a SwiftUI animation when ejected. Custom menu bar icon
that subtly bounces on shake detection. Playful copy in the warning
overlay. Launch-at-login via `SMAppService.mainApp.register()`. README with
install instructions, licence, credits, sensor source references.

**Exit criteria:**
- Visual QA passes: app feels like a toy, not a utility.
- README is ready for the initial public release.

## Cross-cutting Concerns

### Signing

SMAppService requires both the app and the embedded daemon to be signed
with the **same Team ID**, even in dev. A free personal Apple Developer
account (no paid membership needed) provides a `Development` certificate
which is sufficient for local builds. For public releases we will need a
paid Developer ID to notarise for distribution outside the App Store.

Phase 0 documents how to configure the signing identity in `project.yml`
under `targets.*.settings.base.DEVELOPMENT_TEAM`.

### Licensing of Third-Party Work

The HID-read approach is derived from `olvvier/apple-silicon-accelerometer`
(MIT) and `taigrr/spank` (MIT). Our README credits both. We do **not** copy
code directly; we reimplement the byte-parsing and callback setup in Swift.

### Sound Assets

Placeholder uses `NSSound(named: "Funk")` (system sound). User will add
`warning.wav` and `ejected.wav` under `App/Resources/Sounds/` later. The
`SoundPlayer` API is stable so swapping in real assets is a drop-in.

### Sandbox

v1 ships with App Sandbox **off** to keep the SMAppService + XPC + Mach
lookup path as simple as possible. We can revisit sandboxing in a later
iteration if needed.

## Open Questions Before Phase 0 Starts

1. **Apple Developer account** — do you have a free personal team
   configured in Xcode? We need a Team ID for signing the helper.
2. **Hardware smoke test** — please run
   `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice` and paste the output to
   confirm the sensor exists on this specific M1 Pro unit.
3. **Bundle ID prefix** — plan assumes `com.mcsoftware`. Happy with that or
   prefer something else (e.g. `dev.matcom`)?
