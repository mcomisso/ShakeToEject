# ShakeToEject — Phase 4: External Drive Monitor & Ejector

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app the ability to enumerate mounted external drives, observe their arrival and departure in real time, and safely unmount + eject all of them on a single button press. This is the second load-bearing primitive (alongside the sensor pipeline from Phase 3); Phase 6 will wire shake events to an ejection call.

**Architecture:** Three new files in `App/Services/`: `DriveInfo.swift` (the immutable value type), `DriveMonitor.swift` (`@MainActor @Observable` class wrapping `DASession` + `DARegisterDiskAppearedCallback` / `DARegisterDiskDisappearedCallback` with a dispatch queue set to `.main` so all callbacks fire on the main actor), and `DriveEjector.swift` (a stateless helper that unmounts then ejects via `DADiskUnmount` + `DADiskEject`, fire-and-forget with a logging callback). `AppDelegate` gains a `DriveMonitor` alongside the existing `SensorService` and starts/stops it in the lifecycle hooks. `MenuBarContent` gains a live drive list and an "Eject All" button.

**Tech Stack:** DiskArbitration framework (`DASession`, `DADisk`, `DADiskCopyDescription`, `DADiskUnmount`, `DADiskEject`, `DADissenterGetStatus`), Swift 6 strict concurrency with `@preconcurrency import DiskArbitration` to bridge the pre-Sendable CF types, SwiftUI `@Observable` for UI reactivity.

**Prerequisites:**
- Phase 3 committed on main (commit `b1b3e81` or later).
- App launches from Finder, menu bar icon appears, shake counter increments on physical motion.
- 22/22 existing tests still green.

**No new tests in Phase 4.** DiskArbitration is a thin wrapper around an OS IPC — there is no useful unit test surface without mocking the entire framework, which is more scaffolding than the code under test. We rely on a manual smoke test (Task 7) with a real external drive or a synthetic `hdiutil`-created disk image. The existing 22 HIDReport + ShakeDetector tests remain the test backbone.

---

## Swift 6 concurrency notes

- `@preconcurrency import DiskArbitration` is **required** — CFTypes from DiskArbitration are not yet declared Sendable in the system headers. The `@preconcurrency` import tells Swift 6 to treat them as implicitly Sendable for the purposes of crossing isolation boundaries.
- `DriveMonitor` is `@MainActor` and `@Observable`. All mutations of `drives` happen on the main actor.
- DiskArbitration C callbacks are `@convention(c)` and nonisolated. We set the session's dispatch queue to `.main` via `DASessionSetDispatchQueue`, which means callbacks fire on the main thread. Inside each C callback we call `MainActor.assumeIsolated { ... }` to reach the main-actor-isolated handler methods — this is safe because we know we're already on main.
- `DADiskRef` is held inside the monitor keyed by BSD name. The dict itself is main-actor-isolated, so lookups during `Eject All` are race-free.
- The unmount/eject callbacks are purely logging (they don't touch observable state). The UI updates via the separate "disk disappeared" callback when the drive actually leaves.

---

### Task 0: Refresh the overview document

The overview doc at `docs/superpowers/plans/2026-04-10-shaketoeject-overview.md` still reflects the pre-Phase-3 architecture with the SMAppService privileged helper + XPC. After the Phase 3 pivot those phases don't exist. This task updates the overview to the current reality so it remains an accurate north star.

**Files:**
- Modify: `docs/superpowers/plans/2026-04-10-shaketoeject-overview.md`

- [ ] **Step 1: Replace the architecture + file structure + roadmap sections**

Find the section starting with `## Architecture` and ending with the `## Cross-cutting Concerns` heading. Replace the entire block between those two headings (the Architecture, Tech Stack, File Structure, and Phase Roadmap sections) with this consolidated version:

```markdown
## Architecture

**Single app target.** The original plan called for a two-target split (SwiftUI menu bar app + privileged `SMAppService` launch daemon talking over XPC) because we believed IOKit HID access to the BMI286 required root. Phase 1 disproved that assumption on macOS 26: a code-signed unprivileged process can successfully call `IORegistryEntrySetCFProperty` on `AppleSPUHIDDriver` services and receive input reports. Phase 3 collapsed the architecture to one target and deleted the helper wholesale.

All code now runs in `ShakeToEject.app`:

- The SwiftUI app shell (`@main`, `MenuBarExtra`, `NSApplicationDelegateAdaptor`).
- The sensor pipeline (`AccelerometerReader` → `ShakeDetector`) on a dedicated worker thread with its own `CFRunLoop`.
- The drive subsystem (`DriveMonitor` + `DriveEjector`) on the main dispatch queue via `DASessionSetDispatchQueue`.
- The warning/countdown overlay (Phase 5) and its sound assets.
- The settings UI and persistence (Phase 8).

**No XPC. No SMAppService. No launch daemon plist.** If Apple ever re-tightens the privilege requirement on `AppleSPUHIDDriver` in a future macOS release, the `Helper/` directory and the `SMAppService` registration can be reconstructed from the Phase 0 / Phase 1 plan documents — the approach is fully documented in git history.

## Tech Stack

- **Language:** Swift 6, strict concurrency enabled
- **UI:** SwiftUI, `MenuBarExtra`, `@Observable`, `NSApplicationDelegateAdaptor`
- **App target:** macOS 14+ deployment, developed on macOS 26
- **Project generator:** XcodeGen (`project.yml` is the source of truth; `.xcodeproj` is git-ignored)
- **Low-level sensor:** IOKit HID (`IOHIDManager`, `IOHIDDeviceRegisterInputReportCallback`), plus `IOServiceMatching("AppleSPUHIDDriver")` + `IORegistryEntrySetCFProperty` for the driver wake step
- **Drive enumeration/ejection:** `DiskArbitration.framework` (`DASession`, `DADiskCopyDescription`, `DADiskUnmount`, `DADiskEject`)
- **Audio:** `AVAudioPlayer` (Phase 5)
- **Settings:** `UserDefaults` + `@Observable` store (Phase 8)
- **Testing:** Swift Testing

## File Structure

```
ShakeToEject/
├── project.yml
├── README.md                                  (Phase 9)
├── LICENSE
├── .gitignore
├── docs/
│   ├── hardware-probe-m1pro.txt
│   └── superpowers/plans/                     this overview + phase plans
│
├── App/                                       main app target
│   ├── ShakeToEjectApp.swift                  @main + AppDelegate
│   ├── ShakeToEject.entitlements              sandbox off
│   ├── Assets.xcassets/                       (Phase 9)
│   │
│   ├── MenuBar/
│   │   └── MenuBarContent.swift               popover: status, drives, events
│   │
│   ├── Windows/                               (Phase 5)
│   │   ├── WarningOverlayWindow.swift
│   │   └── DashboardWindow.swift              (Phase 8)
│   │
│   ├── Views/                                 (Phases 5, 8)
│   │   ├── WarningView.swift
│   │   ├── DashboardView.swift
│   │   ├── DriveListView.swift
│   │   ├── SensitivitySliderView.swift
│   │   └── CountdownSettingView.swift
│   │
│   ├── Sensing/                               sensor pipeline
│   │   ├── HIDReport.swift
│   │   ├── AccelerometerReader.swift
│   │   └── ShakeDetector.swift
│   │
│   ├── Services/                              app-wide services
│   │   ├── SensorWorker.swift                 dedicated thread + CFRunLoop
│   │   ├── SensorService.swift                @Observable facade
│   │   ├── DriveInfo.swift                    value type  (Phase 4)
│   │   ├── DriveMonitor.swift                 @Observable drive list  (Phase 4)
│   │   ├── DriveEjector.swift                 unmount + eject  (Phase 4)
│   │   ├── SoundPlayer.swift                  (Phase 5)
│   │   └── SettingsStore.swift                (Phase 8)
│   │
│   └── Resources/
│       └── Sounds/                            user-provided audio  (Phase 5+)
│
├── Shared/
│   └── Constants.swift                        just appBundleID
│
└── Tests/
    ├── HIDReportTests.swift                   10 cases
    └── ShakeDetectorTests.swift               12 cases
```

## Phase Roadmap

**Completed:**

- **Phase 0** — XcodeGen scaffolding, menu bar app stub, hardware verification (commit `fe1eb71`)
- **Phase 1** — IOKit HID accelerometer reader with `HIDReport` parser + 10 tests (commit `6a3aedf`)
- **Phase 2** — pure `ShakeDetector` algorithm with 12 tests + `--detect` CLI mode (commit `79c786d`)
- **Phase 3** — collapse helper target into the app, add `SensorWorker` + `SensorService`, menu bar shake counter (commit `b1b3e81`)

**Remaining:**

- **Phase 4** — DiskArbitration: `DriveInfo`, `DriveMonitor` (observable drive list), `DriveEjector` (unmount + eject), menu bar "Eject All" button. The plan this document is attached to.
- **Phase 5** — Warning overlay window + countdown + sound player. Dev-only "Simulate Shake" menu item to trigger the flow without physically moving the laptop.
- **Phase 6** — Wire the sensor pipeline → warning overlay → ejection. End-to-end: shake the laptop → warning appears → countdown runs → drives eject unless cancelled. The app is now functional.
- **Phase 7** — Auto-arm on drive presence. `SensorService` only runs while at least one external drive is mounted; automatically starts when a drive appears and stops when the last one leaves. Saves battery and cleans up semantics.
- **Phase 8** — Settings UI + persistence. Dashboard window with threshold slider, countdown length stepper, drive exclusion list. `SettingsStore` via `UserDefaults`. Launch at login via `SMAppService.mainApp.register()`.
- **Phase 9** — Playful polish. Custom menu bar icon, animated shake visualisation, drives "shake off" ejection animation, README, app icon, optional Liquid Glass effects for iOS 26-era UI.

```

- [ ] **Step 2: Update the "Open Questions Before Phase 0 Starts" section**

That section is stale (all questions answered long ago). Replace it with:

```markdown
## Discoveries worth remembering

1. **macOS 26 allows unprivileged SPU HID access for code-signed processes.** Setting `SensorPropertyReportingState`, `SensorPropertyPowerState`, and `ReportInterval` on `AppleSPUHIDDriver` services via `IORegistryEntrySetCFProperty` works from a regular user process on M1 Pro — no sudo required. This contradicts `olvvier/apple-silicon-accelerometer`'s published "requires root" note and was the basis for the Phase 3 architecture pivot. See `docs/superpowers/plans/2026-04-10-shaketoeject-phase-1-hid-reader.md` "Discoveries during execution" for the full context.

2. **Hardware match criteria are not specific enough alone.** `{VendorID: 1452, UsagePage: 0xFF00, Usage: 3}` on M1 Pro matches both the real BMI286 accelerometer **and** the Apple Internal Keyboard/Trackpad. Disambiguate via `MaxInputReportSize == 22` after enumeration. This is baked into `AccelerometerReader.swift`.

3. **The gravity axis on M1 Pro is -y, not -z.** Irrelevant for `ShakeDetector` (orientation-agnostic magnitude), but important for any future "which way is down?" UI.

4. **Native sample rate is ~800 Hz, not the ~100 Hz suggested by the olvvier Python library.** They decimate 8:1; we don't. `ShakeDetector.cooldownSamples` defaults to 800 (= ~1 second at the native rate).
```

- [ ] **Step 3: Save the file**

The write tool will have done this. Move on.

---

### Task 1: Create `DriveInfo.swift`

**Files:**
- Create: `App/Services/DriveInfo.swift`

- [ ] **Step 1: Write the value type**

Create `App/Services/DriveInfo.swift` with this exact content:

```swift
import Foundation

/// Immutable snapshot of a mounted external drive at a moment in time.
///
/// Identity is the BSD device name (e.g. `disk4s2`) — stable across a
/// single plug-in/unplug lifecycle of a drive, and independent of the
/// volume name which the user can rename at any time.
///
/// `DriveInfo` is value-type-pure on purpose so that SwiftUI view
/// diffing can rely on `Equatable` conformance to detect changes.
struct DriveInfo: Identifiable, Equatable, Hashable {
    /// BSD name, e.g. `"disk4s2"`. Also the `id` for `Identifiable`.
    let id: String

    /// User-visible volume name, e.g. `"My External SSD"`. Falls back
    /// to `"Untitled"` when DiskArbitration has no description for it.
    let volumeName: String

    /// Mount point URL, e.g. `file:///Volumes/My%20External%20SSD/`.
    /// Always present for drives published by `DriveMonitor`, which
    /// filters out unmounted entries.
    let mountPoint: URL

    var bsdName: String { id }
}
```

---

### Task 2: Create `DriveMonitor.swift`

**Files:**
- Create: `App/Services/DriveMonitor.swift`

- [ ] **Step 1: Write the monitor**

Create `App/Services/DriveMonitor.swift` with this exact content:

```swift
@preconcurrency import DiskArbitration
import Foundation
import Observation

/// Observes DiskArbitration for external drive mount/unmount events and
/// publishes the current set of eligible drives as an `@Observable`
/// array that SwiftUI views can bind to directly.
///
/// **Eligibility** is defined as "not internal, and currently mounted":
/// the drive reports `kDADiskDescriptionDeviceInternalKey == false` and
/// its description contains a non-nil `kDADiskDescriptionVolumePathKey`.
/// This excludes the boot drive, internal SSDs, and any unmounted
/// slices that DiskArbitration surfaces.
///
/// **Threading:** the monitor sets its `DASession`'s dispatch queue to
/// `DispatchQueue.main`, so every DiskArbitration callback fires on the
/// main actor. The C callbacks use `MainActor.assumeIsolated` to
/// reach the main-actor-isolated handler methods without a `Task` hop.
/// `@preconcurrency import DiskArbitration` bridges the pre-Sendable
/// CFTypes (`DADisk`, `DASession`, `DADissenter`) into Swift 6 strict
/// concurrency.
@MainActor
@Observable
final class DriveMonitor {
    /// The current list of mounted external drives. Ordered by
    /// appearance (most-recently-mounted last). Mutated only by the
    /// DiskArbitration callbacks.
    private(set) var drives: [DriveInfo] = []

    private var session: DASession?
    private var disksByBSDName: [String: DADisk] = [:]

    /// Starts the DiskArbitration session and registers the appear /
    /// disappear callbacks. Safe to call multiple times — subsequent
    /// calls are no-ops.
    func start() {
        guard session == nil else { return }

        guard let newSession = DASessionCreate(kCFAllocatorDefault) else {
            NSLog("[drives] DASessionCreate failed — monitor inactive")
            return
        }
        session = newSession
        DASessionSetDispatchQueue(newSession, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(
            newSession,
            nil,
            Self.diskAppearedCallback,
            context
        )

        DARegisterDiskDisappearedCallback(
            newSession,
            nil,
            Self.diskDisappearedCallback,
            context
        )

        NSLog("[drives] DriveMonitor started")
    }

    /// Tears down the DiskArbitration session and clears the drive list.
    /// Safe to call multiple times.
    func stop() {
        if let s = session {
            DASessionSetDispatchQueue(s, nil)
        }
        session = nil
        disksByBSDName.removeAll()
        drives.removeAll()
        NSLog("[drives] DriveMonitor stopped")
    }

    /// Unmounts and ejects every drive currently in the list. Each
    /// drive is handled independently; a failure on one does not stop
    /// the others.
    func ejectAll() {
        let snapshot = Array(disksByBSDName.values)
        NSLog("[drives] ejectAll — \(snapshot.count) drive(s)")
        for disk in snapshot {
            DriveEjector.unmountAndEject(disk)
        }
    }

    // MARK: - C callback bridges

    private static let diskAppearedCallback: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleDiskAppeared(disk)
        }
    }

    private static let diskDisappearedCallback: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.handleDiskDisappeared(disk)
        }
    }

    // MARK: - Main-actor handlers

    private func handleDiskAppeared(_ disk: DADisk) {
        guard let bsdNameCStr = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNameCStr)

        guard let descriptionCF = DADiskCopyDescription(disk) else { return }
        let description = descriptionCF as NSDictionary

        let isInternal = (description[kDADiskDescriptionDeviceInternalKey] as? NSNumber)?.boolValue ?? true
        guard !isInternal else { return }

        guard let mountPoint = description[kDADiskDescriptionVolumePathKey] as? URL else {
            // Not a mounted volume — could be the whole-disk entry
            // (e.g. disk4) that appears alongside its partition slices.
            // We only track mounted volumes.
            return
        }

        let volumeName = (description[kDADiskDescriptionVolumeNameKey] as? String) ?? "Untitled"

        let info = DriveInfo(
            id: bsdName,
            volumeName: volumeName,
            mountPoint: mountPoint
        )

        disksByBSDName[bsdName] = disk
        if let existingIndex = drives.firstIndex(where: { $0.id == bsdName }) {
            drives[existingIndex] = info
        } else {
            drives.append(info)
        }

        NSLog("[drives] appeared: \(bsdName) \"\(volumeName)\" at \(mountPoint.path)")
    }

    private func handleDiskDisappeared(_ disk: DADisk) {
        guard let bsdNameCStr = DADiskGetBSDName(disk) else { return }
        let bsdName = String(cString: bsdNameCStr)

        if disksByBSDName.removeValue(forKey: bsdName) != nil {
            drives.removeAll { $0.id == bsdName }
            NSLog("[drives] disappeared: \(bsdName)")
        }
    }
}
```

---

### Task 3: Create `DriveEjector.swift`

**Files:**
- Create: `App/Services/DriveEjector.swift`

- [ ] **Step 1: Write the ejector**

Create `App/Services/DriveEjector.swift` with this exact content:

```swift
@preconcurrency import DiskArbitration
import Foundation

/// Stateless helper that unmounts and then ejects a single `DADisk`.
///
/// The operations are asynchronous via DiskArbitration's dissenter-
/// callback mechanism. This type is fire-and-forget: callers invoke
/// `unmountAndEject(_:)`, the drive starts shutting down, and when it
/// finishes disappearing it naturally leaves `DriveMonitor.drives` via
/// the `DARegisterDiskDisappearedCallback` path. Success/failure is
/// logged via `NSLog`.
///
/// The DiskArbitration callbacks fire on the same dispatch queue that
/// was set on the owning `DASession` (main, in our case). No actor
/// hopping is needed because the callbacks only log.
enum DriveEjector {
    /// Initiates an unmount followed by an eject for the given disk.
    /// Returns immediately; the work completes asynchronously.
    static func unmountAndEject(_ disk: DADisk) {
        let bsdName = Self.bsdName(of: disk)
        NSLog("[drives] unmounting \(bsdName)…")

        DADiskUnmount(
            disk,
            DADiskUnmountOptions(kDADiskUnmountOptionDefault),
            Self.unmountCallback,
            nil
        )
    }

    // MARK: - Callbacks

    private static let unmountCallback: DADiskUnmountCallback = { disk, dissenter, _ in
        let bsdName = Self.bsdName(of: disk)
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            NSLog("[drives] unmount \(bsdName) DISSENTED status=0x\(String(status, radix: 16, uppercase: true))")
            return
        }
        NSLog("[drives] unmount \(bsdName) ok — ejecting…")
        DADiskEject(
            disk,
            DADiskEjectOptions(kDADiskEjectOptionDefault),
            Self.ejectCallback,
            nil
        )
    }

    private static let ejectCallback: DADiskEjectCallback = { disk, dissenter, _ in
        let bsdName = Self.bsdName(of: disk)
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            NSLog("[drives] eject \(bsdName) DISSENTED status=0x\(String(status, radix: 16, uppercase: true))")
            return
        }
        NSLog("[drives] eject \(bsdName) ok")
    }

    // MARK: - Helpers

    private static func bsdName(of disk: DADisk) -> String {
        guard let cStr = DADiskGetBSDName(disk) else { return "(unknown)" }
        return String(cString: cStr)
    }
}
```

---

### Task 4: Wire `DriveMonitor` into `AppDelegate`

**Files:**
- Modify: `App/ShakeToEjectApp.swift`

- [ ] **Step 1: Add a `DriveMonitor` property and lifecycle calls**

Replace the entire contents of `App/ShakeToEjectApp.swift` with:

```swift
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                sensor: appDelegate.sensor,
                drives: appDelegate.drives
            )
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sensor = SensorService()
    let drives = DriveMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sensor.start()
        drives.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
        drives.stop()
    }
}
```

---

### Task 5: Update `MenuBarContent` with a drive list + eject button

**Files:**
- Modify: `App/MenuBar/MenuBarContent.swift`

- [ ] **Step 1: Replace the view**

Replace the entire contents of `App/MenuBar/MenuBarContent.swift` with:

```swift
import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService
    let drives: DriveMonitor

    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        Text(sensor.isRunning ? "Sensor: running" : "Sensor: stopped")
        Text("Shakes: \(sensor.shakeCount)")

        if sensor.lastShakeMagnitude > 0 {
            Text(String(format: "Last magnitude: %.3f g", sensor.lastShakeMagnitude))
        }

        Divider()

        if drives.drives.isEmpty {
            Text("No external drives")
                .foregroundStyle(.secondary)
        } else {
            ForEach(drives.drives) { drive in
                Text("⏏︎ \(drive.volumeName)")
            }
            Button("Eject All \(drives.drives.count) Drive\(drives.drives.count == 1 ? "" : "s")") {
                drives.ejectAll()
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
```

Note: menu-style `MenuBarExtra` content has limited layout capability (no scroll views, no complex SwiftUI containers) — that is why the drive list is just a sequence of `Text` items with a plural-aware button label. Phase 8 adds a proper dashboard window for richer drive management.

---

### Task 6: Regenerate, rebuild, run tests

- [ ] **Step 1: Regenerate**

```bash
xcodegen generate 2>&1 | tail -3
```

Expected: `Created project at ...`.

- [ ] **Step 2: Clean build**

```bash
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

Watch for Swift 6 concurrency warnings about `DADisk`/`DASession`/`DADissenter` not being Sendable. If they appear, the `@preconcurrency import DiskArbitration` line in one of the new files is missing or misplaced — fix and rebuild.

- [ ] **Step 3: Run the test suite**

```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` — still 22 tests (Phase 4 adds no new tests).

---

### Task 7: Smoke test with a real or synthetic external drive

This task requires an actual mounted external drive. If the user doesn't have a USB stick or external SSD plugged in, create a synthetic drive via `hdiutil`.

- [ ] **Step 1: Create a synthetic test drive** (only if the user has no physical external drive handy)

```bash
hdiutil create -size 20m -fs APFS -volname ShakeTest /tmp/shake-test.dmg 2>&1 | tail -3
hdiutil attach /tmp/shake-test.dmg 2>&1 | tail -3
diskutil list | tail -10
```

This creates a 20 MB APFS disk image named "ShakeTest" and mounts it at `/Volumes/ShakeTest`. DiskArbitration will publish it via the appeared callback because disk images are not marked as internal.

- [ ] **Step 2: Launch the app from Finder**

```bash
open build/Build/Products/Debug/ShakeToEject.app
```

- [ ] **Step 3: Verify the drive list populates**

Click the menu bar eject-circle icon. The popover should now show:

```
ShakeToEject 0.1.0
Sensor: running
Shakes: 0
───
⏏︎ ShakeTest          (or whatever your real drive is called)
Eject All 1 Drive
───
Quit
```

If the list is missing the drive, check Console.app for `[drives]` log lines.

- [ ] **Step 4: Click Eject All**

The `ShakeTest` drive should:
- Disappear from `/Volumes/ShakeTest` within ~1 second
- Disappear from the menu bar list (the view re-renders as the observed `drives` array empties)

If using the synthetic drive, verify with `ls /Volumes/` — `ShakeTest` should be gone.

- [ ] **Step 5: Plug/unplug live test** (only if the user has a physical drive)

Plug a USB drive in → should appear in the menu bar list within 1-2 seconds. Unplug it → should disappear.

- [ ] **Step 6: Clean up** (only if synthetic drive was used)

```bash
rm /tmp/shake-test.dmg 2>/dev/null
```

- [ ] **Step 7: User reports result**

- **"drive list populates, Eject All works"** → proceed to commit.
- **"drive list stays empty"** → triage. Most likely cause: the `kDADiskDescriptionDeviceInternalKey` filter is false-negative for this drive. Ask the user for the output of `diskutil info /Volumes/<DRIVE>` so we can see the `Protocol`, `Internal`, `Ejectable` properties.
- **"Eject All logs 'DISSENTED' status"** → something is holding a file handle on the drive. For a synthetic test, check `lsof /Volumes/ShakeTest`. For a real drive, close any open Finder windows pointing at it.

---

### Task 8: Commit Phase 4

- [ ] **Step 1: Review the diff**

```bash
git status --short
```

Expected:
```
 M App/MenuBar/MenuBarContent.swift
 M App/ShakeToEjectApp.swift
 M docs/superpowers/plans/2026-04-10-shaketoeject-overview.md
?? App/Services/DriveEjector.swift
?? App/Services/DriveInfo.swift
?? App/Services/DriveMonitor.swift
?? docs/superpowers/plans/2026-04-10-shaketoeject-phase-4-drives.md
```

- [ ] **Step 2: Stage**

```bash
git add -A
git status --short
```

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Phase 4: DiskArbitration drive monitor + ejector + menu bar list

- Add App/Services/DriveInfo.swift — immutable value type keyed by
  BSD name, with volume name and mount point URL.
- Add App/Services/DriveMonitor.swift — @MainActor @Observable class
  wrapping a DASession with its dispatch queue set to main. Registers
  DARegisterDiskAppearedCallback / DARegisterDiskDisappearedCallback
  and filters to external mounted drives (!isInternal AND volumePath
  is non-nil). Uses @preconcurrency import DiskArbitration to bridge
  the pre-Sendable CFTypes, and MainActor.assumeIsolated inside the
  C callbacks to reach the main-actor-isolated handler methods.
- Add App/Services/DriveEjector.swift — stateless helper performing
  unmount-then-eject via DADiskUnmount + DADiskEject, fire-and-forget
  with NSLog-based success/dissenter reporting.
- Extend AppDelegate to own a DriveMonitor and start/stop it in the
  same lifecycle hooks as SensorService.
- Extend MenuBarContent with a live drive list (one row per drive,
  showing the volume name) and a plural-aware "Eject All" button.
- Refresh docs/superpowers/plans/2026-04-10-shaketoeject-overview.md
  with the post-Phase-3 single-target architecture and the updated
  phase roadmap (old Phase 4 = SMAppService is gone, new Phases 4-9
  listed). Adds a "Discoveries worth remembering" section capturing
  the macOS 26 unprivileged HID access finding, the keyboard/trackpad
  false-positive on HID matching, the -y gravity axis on M1 Pro, and
  the ~800 Hz native sample rate.

No new tests — DiskArbitration is a thin OS IPC wrapper with no
useful pure unit test surface. Verified by smoke test (synthetic
hdiutil disk image or real USB drive): drive appears in menu bar
list on mount, disappears on unmount, Eject All successfully
unmounts + ejects.

Phase 4 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify**

```bash
git status
git log --oneline -6
```

---

## Phase 4 Exit Criteria

- [ ] Overview doc reflects the post-Phase-3 single-target architecture.
- [ ] `App/Services/DriveInfo.swift`, `DriveMonitor.swift`, `DriveEjector.swift` all exist.
- [ ] `AppDelegate` owns both `SensorService` and `DriveMonitor` and starts/stops both in the lifecycle hooks.
- [ ] `xcodebuild -scheme ShakeToEject build` succeeds with no Swift 6 concurrency errors.
- [ ] `xcodebuild test` reports 22/22 green (unchanged from Phase 3).
- [ ] The built `.app` launched from Finder shows mounted external drives in its menu bar popover.
- [ ] Plugging/unplugging (or synthetic mount/unmount) updates the list in real time.
- [ ] Clicking "Eject All" successfully unmounts + ejects every drive in the list.
- [ ] Phase 4 is committed on `main`.

---

## What Phase 4 Does Not Do

- No connection between shake events and ejection yet — the sensor counter and the drive list coexist but don't talk. Phase 6 wires them together.
- No warning overlay, no countdown, no cancel button — those are Phase 5.
- No sound playback on eject — Phase 5's sound player.
- No per-drive exclusions. The Eject All button ejects literally every drive in the list. Phase 8 adds the exclusion UI.
- No undo / "force eject" retry. If `DADiskEject` dissents, the user sees an NSLog line and has to resolve the dissenter manually (close the offending app, etc). Phase 5/6 can surface this to the UI if it proves a real pain point.
- No dashboard window. Drive management lives entirely in the menu bar popover for Phase 4. Phase 8 adds the richer UI.
- No tests for `DriveMonitor` / `DriveEjector`. Adding them requires mocking the whole DiskArbitration framework — more infrastructure than the code under test. Manual smoke test is the verification.
