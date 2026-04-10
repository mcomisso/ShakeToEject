# ShakeToEject — Phase 3: Collapse Helper into the App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the two-target + helper-embed architecture now that Phase 1 demonstrated unprivileged IOKit HID access works on macOS 26. Move the sensor code into the main app target, run it on a dedicated worker thread owning its own CFRunLoop, and surface shake events through an `@Observable` `SensorService` that the menu bar content reads directly. The end state is a single-target SwiftUI app that can count shakes the user triggers on the laptop.

**Why the pivot:** See the Phase 1 "Discoveries during execution" section and `memory/macos26_unprivileged_hid_access.md`. The original architecture assumed the SPU wake step required root, which is why we built an SMAppService launch daemon. We proved in Phase 1 that `IORegistryEntrySetCFProperty` on `AppleSPUHIDDriver` succeeds from an unprivileged, code-signed process on macOS 26 M1 Pro. The helper is now pure overhead: the user would have to approve it in System Settings → Login Items, XPC adds latency and complexity, and the install flow is worse — all to solve a problem we don't actually have. Collapsing now saves us from writing Phases 4-8 (SMAppService registration, XPC protocols, XPC wiring for drives/warning overlay) that would only exist to serve a non-existent privilege boundary.

**Architecture after this phase:**

```
App target (ShakeToEject.app)
├── @main ShakeToEjectApp                (SwiftUI entry)
│    └── NSApplicationDelegateAdaptor -> AppDelegate
│         └── owns SensorService @MainActor @Observable
│              └── SensorWorker @unchecked Sendable
│                   └── dedicated Thread running CFRunLoop
│                        └── AccelerometerReader  (IOKit HID)
│                        └── ShakeDetector        (pure algorithm)
└── MenuBarContent reads SensorService.shakeCount
```

No helper target. No XPC. No SMAppService. No launch daemon plist. No embed post-build script.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI `@Observable`, `NSApplicationDelegateAdaptor`, `Thread` + `CFRunLoop` for the dedicated sensor run loop, `Task { @MainActor in ... }` for background → main hop.

**Prerequisites:**
- Phase 2 committed on main (commit `79c786d` or later).
- 22/22 tests green.
- `Helper/` directory still exists with current sensor code.

---

## Validation gate

If Task 1 fails to read samples from a Finder-launched `.app`, **STOP** and report BLOCKED. We do not proceed with deletions unless the pivot is proven viable. This is deliberately the first task so nothing has been ripped out yet — rollback is a `git checkout`.

---

### Task 1: Validate unprivileged HID access from inside the app bundle

**Files:**
- Create: `App/Sensing/HIDReport.swift`                    (copied verbatim)
- Create: `App/Sensing/AccelerometerReader.swift`          (copied verbatim)
- Modify: `App/ShakeToEjectApp.swift`                      (temporary launch-time reader)

The copies are a deliberate duplicate. At this stage the helper target still exists and still compiles its own copies. The validation has to run inside the **app** target to prove the pivot is viable. Task 2 deletes the helper's copies.

- [ ] **Step 1: Create the sensor directory and copy the two files**

```bash
mkdir -p App/Sensing
cp Helper/HIDReport.swift App/Sensing/HIDReport.swift
cp Helper/AccelerometerReader.swift App/Sensing/AccelerometerReader.swift
```

XcodeGen already globs `App/` for the app target's sources, so these files will be picked up on the next `xcodegen generate` with no `project.yml` change.

**Important:** the helper target ALSO globs `Helper/` — so both targets will compile their own copies of these two files during the validation phase. That's fine, just temporary.

- [ ] **Step 2: Add a temporary launch-time probe to `App/ShakeToEjectApp.swift`**

Replace the entire contents of `App/ShakeToEjectApp.swift` with:

```swift
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Temporary Phase 3 Task 1 probe: prove the IOKit HID read path works
/// from inside the Finder-launched .app bundle. If we see samples in
/// Console.app filtered by "shake-probe" then the pivot is viable and
/// Task 2 removes this code and deletes the helper target.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var probeReader: AccelerometerReader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[shake-probe] applicationDidFinishLaunching — starting probe reader")
        var sampleCount = 0
        let reader = AccelerometerReader { [weak self] sample in
            sampleCount += 1
            if sampleCount == 1 {
                NSLog("[shake-probe] first sample x=\(sample.x) y=\(sample.y) z=\(sample.z)")
            } else if sampleCount == 100 {
                NSLog("[shake-probe] 100 samples received — HID path works from app bundle")
            }
            _ = self  // silence @Sendable warning if any
        }
        do {
            try reader.start()
            probeReader = reader
            NSLog("[shake-probe] reader.start() succeeded")
        } catch {
            NSLog("[shake-probe] reader.start() FAILED: \(error)")
        }
    }
}
```

Note that `AppDelegate` captures a mutable `sampleCount` inside the closure. That's intentional — `AccelerometerReader.SampleHandler` is `@Sendable`, but the closure captures `sampleCount` by reference in Swift's default capture semantics. Strict concurrency may warn about this; if so, promote `sampleCount` to an `nonisolated(unsafe)` instance property on `AppDelegate` or use a `Locked<Int>` wrapper. Report as DONE_WITH_CONCERNS if you need to adjust — the goal is just to see "100 samples received" in Console.app.

- [ ] **Step 3: Regenerate and build the app**

```bash
xcodegen generate
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch the built app from Finder (not Xcode, not Terminal)**

The subagent hands this step off to the user because the purpose is to test the Finder-launch TCC posture. Ask the user to:

1. Open Finder to `build/Build/Products/Debug/`
2. Double-click `ShakeToEject.app`
3. Watch the menu bar for the eject-circle icon
4. Open Console.app and filter by `shake-probe`
5. Within 1-2 seconds of launch, they should see lines like:
   ```
   [shake-probe] applicationDidFinishLaunching — starting probe reader
   [shake-probe] reader.start() succeeded
   [shake-probe] first sample x=… y=… z=…
   [shake-probe] 100 samples received — HID path works from app bundle
   ```
6. Quit the app via the menu bar icon

- [ ] **Step 5: User reports result**

- **A) "Console shows '100 samples received'"** → pivot is viable. Proceed to Task 2.
- **B) "Console shows 'reader.start() FAILED: …'"** → the error message tells us what to investigate. Most likely the wake step's `IORegistryEntrySetCFProperty` returns `kIOReturnNotPrivileged` inside a Finder-launched app (different TCC posture from Terminal). Stop and triage; do not proceed.
- **C) "Console shows 'reader.start() succeeded' but then silence — no 'first sample'"** → the wake step may have succeeded but report delivery is blocked. Stop and triage.

---

### Task 2: Delete the Helper target and the files it owned

This task only runs if Task 1 passed. It is destructive — do not begin without an explicit green light.

**Files:**
- Delete: `Helper/HIDReport.swift`
- Delete: `Helper/AccelerometerReader.swift`
- Delete: `Helper/ShakeDetector.swift`
- Delete: `Helper/main.swift`
- Delete: `Helper/Helper.entitlements`
- Delete: `Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist`
- Delete: `Helper/Launchd/` directory
- Delete: `Helper/` directory
- Create: `App/Sensing/ShakeDetector.swift` (copy from Helper/)
- Modify: `project.yml` (remove helper target + post-build script + test target sources)
- Modify: `Shared/Constants.swift` (prune helper constants)

- [ ] **Step 1: Copy `ShakeDetector.swift` to the new location**

```bash
cp Helper/ShakeDetector.swift App/Sensing/ShakeDetector.swift
```

No content changes — it's a pure file that doesn't care what target compiles it.

- [ ] **Step 2: Delete the helper directory wholesale**

```bash
rm -rf Helper/
```

After this, `App/Sensing/` contains `HIDReport.swift`, `AccelerometerReader.swift`, and `ShakeDetector.swift`. The helper target's source directory is gone, which will make `xcodegen generate` unhappy until Step 3 removes the target definition.

- [ ] **Step 3: Edit `project.yml`**

Three edits:

**3a) Remove the `dependencies:` and `postBuildScripts:` blocks from the `ShakeToEject` target.**

Find this block:

```yaml
    dependencies:
      - target: ShakeToEjectHelper
        embed: false
        link: false
    postBuildScripts:
      - name: "Embed Privileged Helper"
        runOnlyWhenInstalling: false
        inputFiles:
          - $(BUILT_PRODUCTS_DIR)/com.mcsoftware.ShakeToEject.Helper
          - $(SRCROOT)/Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist
        outputFiles:
          - $(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)/Contents/MacOS/com.mcsoftware.ShakeToEject.Helper
          - $(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)/Contents/Library/LaunchDaemons/com.mcsoftware.ShakeToEject.Helper.plist
        script: |
          set -euo pipefail
          HELPER_SRC="${BUILT_PRODUCTS_DIR}/com.mcsoftware.ShakeToEject.Helper"
          APP_BUNDLE="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
          HELPER_DEST_DIR="${APP_BUNDLE}/Contents/MacOS"
          LAUNCHD_DEST_DIR="${APP_BUNDLE}/Contents/Library/LaunchDaemons"
          LAUNCHD_SRC="${SRCROOT}/Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist"

          mkdir -p "${HELPER_DEST_DIR}"
          mkdir -p "${LAUNCHD_DEST_DIR}"

          cp -f "${HELPER_SRC}" "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
          cp -f "${LAUNCHD_SRC}"  "${LAUNCHD_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper.plist"

          # Re-sign the helper in place so the embedded binary matches the app's signature.
          if [ "${CODE_SIGNING_REQUIRED:-YES}" = "YES" ]; then
              SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
              if [ -z "${SIGN_ID}" ]; then
                  echo "error: no code signing identity resolved for helper embed step." >&2
                  echo "       set DEVELOPMENT_TEAM in project.yml or select a team in Xcode." >&2
                  exit 1
              fi

              # Debug builds skip the secure timestamp so the script works offline
              # and on machines without access to Apple's timestamp server. Release
              # builds use the default secure timestamp so the bundle can be notarised.
              if [ "${CONFIGURATION}" = "Debug" ]; then
                  codesign --force --sign "${SIGN_ID}" \
                      --entitlements "${SRCROOT}/Helper/Helper.entitlements" \
                      --options runtime \
                      --timestamp=none \
                      "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
              else
                  codesign --force --sign "${SIGN_ID}" \
                      --entitlements "${SRCROOT}/Helper/Helper.entitlements" \
                      --options runtime \
                      "${HELPER_DEST_DIR}/com.mcsoftware.ShakeToEject.Helper"
              fi
          fi
```

And delete it entirely. The `ShakeToEject:` target should end with `CODE_SIGN_ENTITLEMENTS: App/ShakeToEject.entitlements` followed by a blank line before the next target.

**3b) Remove the entire `ShakeToEjectHelper:` target block.**

Find the block that starts with

```yaml
  ShakeToEjectHelper:
    type: tool
```

and ends with

```yaml
        CODE_SIGN_ENTITLEMENTS: Helper/Helper.entitlements
        ENABLE_HARDENED_RUNTIME: YES
```

Delete it entirely, including the blank line that preceded it.

**3c) Update `ShakeToEjectTests` target's `sources` list.**

Currently:

```yaml
    sources:
      - path: Tests
      - path: Helper/HIDReport.swift
      - path: Helper/ShakeDetector.swift
```

Change to:

```yaml
    sources:
      - path: Tests
      - path: App/Sensing/HIDReport.swift
      - path: App/Sensing/ShakeDetector.swift
```

- [ ] **Step 4: Prune `Shared/Constants.swift`**

The file currently declares `appBundleID`, `helperBundleID`, `helperMachServiceName`, `helperPlistName`, `helperExecutableName`. The four helper-related constants no longer have callers. Replace the entire file contents with:

```swift
import Foundation

public enum Constants {
    public static let appBundleID = "com.mcsoftware.ShakeToEject"
}
```

`Shared/` now contains a single constant but we keep the directory + file convention in case Phase 4+ adds more cross-cutting constants.

- [ ] **Step 5: Regenerate and confirm the project structure is clean**

```bash
xcodegen generate 2>&1 | tail -5
```

Expected: `Created project at ...` with no warnings.

```bash
grep -c "ShakeToEjectHelper" ShakeToEject.xcodeproj/project.pbxproj
```

Expected: `0` — the pbxproj has no trace of the helper target.

```bash
grep -c "com.mcsoftware.ShakeToEject.Helper" ShakeToEject.xcodeproj/project.pbxproj
```

Expected: `0`.

```bash
find build -name "com.mcsoftware.ShakeToEject.Helper" 2>/dev/null
```

Expected: either no output (clean build dir) or stale files from the previous phase's build — those will be overwritten on the next build and are not a concern.

---

### Task 3: Write `SensorWorker` and `SensorService`

**Files:**
- Create: `App/Services/SensorWorker.swift`
- Create: `App/Services/SensorService.swift`

- [ ] **Step 1: Create `App/Services/SensorWorker.swift`**

```swift
import Foundation

/// Owns the dedicated background thread that runs the IOKit HID run loop.
///
/// `SensorWorker` is the low-level lifecycle wrapper: it spins up a named
/// `Thread`, captures its `CFRunLoop` reference so callers can stop it
/// from another thread, runs `AccelerometerReader` on that run loop, and
/// invokes a handler closure whenever the `ShakeDetector` emits an event.
///
/// Callers that need to present state to the UI should wrap this in a
/// `@MainActor`-isolated `SensorService` and hop to the main actor from
/// the worker's handler. `SensorWorker` itself is non-main so it can
/// safely own the blocking `CFRunLoopRun()` call.
///
/// **Thread safety:** the public `start()`/`stop()` methods may be called
/// from any thread; they serialise via `runLoopReady` and the atomic
/// `runLoop` reference. The handler closure is always invoked on the
/// worker's private thread — never on the caller.
final class SensorWorker: @unchecked Sendable {
    typealias ShakeHandler = @Sendable (ShakeEvent) -> Void

    private let handler: ShakeHandler
    private let detector: ShakeDetector

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)

    init(
        threshold: Double = 0.3,
        cooldownSamples: Int = 800,
        handler: @escaping ShakeHandler
    ) {
        self.handler = handler
        self.detector = ShakeDetector(threshold: threshold, cooldownSamples: cooldownSamples)
    }

    /// Starts the dedicated thread and blocks the caller until the
    /// worker's `CFRunLoop` reference has been captured (so a follow-up
    /// `stop()` from the same thread is race-free).
    func start() {
        guard thread == nil else { return }
        let newThread = Thread { [weak self] in
            self?.runSensorLoop()
        }
        newThread.name = "com.mcsoftware.ShakeToEject.Sensor"
        newThread.qualityOfService = .userInitiated
        thread = newThread
        newThread.start()
        runLoopReady.wait()
    }

    /// Stops the worker's run loop. After this returns the worker thread
    /// will exit naturally.
    func stop() {
        if let loop = runLoop {
            CFRunLoopStop(loop)
        }
        thread = nil
        runLoop = nil
    }

    // MARK: - Worker thread body

    private func runSensorLoop() {
        runLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()

        let reader = AccelerometerReader { [weak self] sample in
            guard let self, let event = self.detector.process(sample) else { return }
            self.handler(event)
        }

        do {
            try reader.start()
        } catch {
            NSLog("[sensor] AccelerometerReader.start() failed: \(error)")
            return
        }

        // Blocks until `CFRunLoopStop` is called on this thread's run loop.
        CFRunLoopRun()
        reader.stop()
    }
}
```

- [ ] **Step 2: Create `App/Services/SensorService.swift`**

```swift
import Foundation
import Observation

/// Main-actor-isolated facade for the sensor pipeline. Views observe this
/// type via `@Observable`; the underlying `SensorWorker` does the blocking
/// IOKit work on a dedicated thread and hops back here for state updates.
///
/// The service is deliberately a thin shim — all meaningful work lives in
/// `SensorWorker`, `AccelerometerReader`, and `ShakeDetector`. This file's
/// only job is to expose observable state to SwiftUI and manage the
/// worker's lifecycle.
@MainActor
@Observable
final class SensorService {
    private(set) var isRunning: Bool = false
    private(set) var shakeCount: Int = 0
    private(set) var lastShakeMagnitude: Double = 0

    private var worker: SensorWorker?

    /// Starts the sensor pipeline. No-op if already running.
    func start() {
        guard worker == nil else { return }

        let newWorker = SensorWorker { [weak self] event in
            // Called on the sensor worker thread. Hop to @MainActor for
            // observable state mutations so SwiftUI sees them safely.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shakeCount += 1
                self.lastShakeMagnitude = event.magnitude
            }
        }
        newWorker.start()
        worker = newWorker
        isRunning = true
    }

    /// Stops the sensor pipeline. No-op if already stopped.
    func stop() {
        worker?.stop()
        worker = nil
        isRunning = false
    }
}
```

---

### Task 4: Replace the Task 1 probe with the real app wiring

**Files:**
- Modify: `App/ShakeToEjectApp.swift`
- Modify: `App/MenuBar/MenuBarContent.swift`

- [ ] **Step 1: Replace `App/ShakeToEjectApp.swift`**

Replace the entire contents with:

```swift
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(sensor: appDelegate.sensor)
        } label: {
            Image(systemName: "eject.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sensor = SensorService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sensor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
    }
}
```

This removes the Task 1 `[shake-probe]` NSLog harness and the ad-hoc probe reader. The real `SensorService` now owns the sensor for the app's lifetime.

- [ ] **Step 2: Replace `App/MenuBar/MenuBarContent.swift`**

Replace with:

```swift
import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService

    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        if sensor.isRunning {
            Text("Sensor: running")
        } else {
            Text("Sensor: stopped")
        }

        Text("Shakes: \(sensor.shakeCount)")

        if sensor.lastShakeMagnitude > 0 {
            Text(String(format: "Last magnitude: %.3f g", sensor.lastShakeMagnitude))
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

The menu bar now has a live shake counter that increments every time the user bumps the laptop. This is our end-to-end proof that the single-target pivot works.

---

### Task 5: Build, run, verify

- [ ] **Step 1: Regenerate, clean build, app build**

```bash
xcodegen generate
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -10
```

A clean build (`rm -rf build`) is important because the previous build dir still has the stale helper binary and embedded app bundle with `Contents/MacOS/com.mcsoftware.ShakeToEject.Helper`. Removing it ensures we're looking at a truly pivoted bundle.

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Verify the helper is gone from the built app bundle**

```bash
find build/Build/Products/Debug/ShakeToEject.app -type f | sort
```

Expected: no lines matching `com.mcsoftware.ShakeToEject.Helper`. The bundle should contain only the SwiftUI app binary, Info.plist, entitlements, resources, and the usual macOS bundle boilerplate.

- [ ] **Step 3: Run the test suite**

```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with 22 tests passing (10 HIDReportTests + 12 ShakeDetectorTests, compiled from the new `App/Sensing/` paths).

- [ ] **Step 4: Launch from Finder and verify the shake counter**

Hand off to user:

1. `open build/Build/Products/Debug/ShakeToEject.app`
2. Menu bar eject-circle icon appears
3. Click it — popover shows `Sensor: running` and `Shakes: 0`
4. Tap the laptop — counter increments
5. Shake more — counter continues incrementing with ~1-second minimum spacing
6. "Last magnitude" shows the most recent event's magnitude in g
7. Quit via the menu

- [ ] **Step 5: User reports result**

- **"Shake counter increments on motion"** → proceed to commit.
- **"Counter stays at 0"** → triage with the user. Open Console.app and filter by `sensor` or `accel` for error output. Most likely the worker thread's reader failed to start; check the SensorWorker error log.
- **"App crashed"** → paste the crash report; do not commit.

---

### Task 6: Commit Phase 3

- [ ] **Step 1: Review the diff**

```bash
git status --short
git diff --stat
```

Expected set of changes (big diff — moves, deletions, new files):

- `A  App/Sensing/HIDReport.swift`
- `A  App/Sensing/AccelerometerReader.swift`
- `A  App/Sensing/ShakeDetector.swift`
- `A  App/Services/SensorService.swift`
- `A  App/Services/SensorWorker.swift`
- `M  App/ShakeToEjectApp.swift`
- `M  App/MenuBar/MenuBarContent.swift`
- `D  Helper/HIDReport.swift`
- `D  Helper/AccelerometerReader.swift`
- `D  Helper/ShakeDetector.swift`
- `D  Helper/main.swift`
- `D  Helper/Helper.entitlements`
- `D  Helper/Launchd/com.mcsoftware.ShakeToEject.Helper.plist`
- `M  Shared/Constants.swift`
- `M  project.yml`
- `A  docs/superpowers/plans/2026-04-10-shaketoeject-phase-3-collapse-helper.md`

- [ ] **Step 2: Stage everything**

```bash
git add -A
git status --short
```

Verify the staged set matches the expected above.

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
Phase 3: collapse helper target into the app, drop XPC plan

Phase 1 proved that on macOS 26 M1 Pro an unprivileged, code-signed
process can successfully wake the SPU driver and read the BMI286
accelerometer via IOKit HID. The original two-target + SMAppService
architecture existed only to work around a privilege boundary that
turns out not to exist. This commit removes the helper entirely and
runs the sensor pipeline inline in the main app target.

- Move Helper/HIDReport.swift, Helper/AccelerometerReader.swift,
  Helper/ShakeDetector.swift -> App/Sensing/ (unchanged content).
- Add App/Services/SensorWorker.swift — dedicated Thread owning a
  CFRunLoop on which AccelerometerReader schedules its HID manager
  and ShakeDetector ingests samples. The worker captures its
  CFRunLoop reference via a semaphore-gated handoff so callers can
  safely CFRunLoopStop it from the main thread.
- Add App/Services/SensorService.swift — @MainActor @Observable
  facade exposing shakeCount / lastShakeMagnitude to SwiftUI. The
  SensorWorker handler hops back via Task { @MainActor ... } for
  observable mutations.
- Wire AppDelegate via NSApplicationDelegateAdaptor to start/stop
  the service across app lifecycle.
- Update MenuBarContent to display sensor status, shake count, and
  most recent shake magnitude.
- Delete Helper/ directory wholesale (source files, launchd plist,
  entitlements).
- Delete ShakeToEjectHelper target, its post-build helper embed
  script, and its xcodegen dependency from project.yml.
- Update ShakeToEjectTests source paths to compile its own copies
  of HIDReport.swift and ShakeDetector.swift from the new
  App/Sensing/ location.
- Prune Shared/Constants.swift down to just appBundleID; the
  helper-related constants no longer have callers.

Validated (Task 1 in the phase plan) that a Finder-launched app
bundle successfully wakes the SPU driver and receives input reports,
not just a Terminal-launched raw binary, before doing any deletions.

Verified: 22/22 tests green; clean build; menu bar shake counter
increments on physical motion; no helper binary in the built .app.

This obsoletes the planned Phases 4 (SMAppService registration) and
part of Phase 6 (XPC wiring). The remaining future phases are:

- Phase 4 (new): DiskArbitration drive monitor + ejector in the app
- Phase 5 (new): warning overlay with countdown + sound
- Phase 6 (new): menu bar/settings UI polish
- Phase 7 (new): auto-arm on drive mount + playful polish

Phase 3 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md
(the overview document will be updated with the new phase numbers in
a follow-up commit once Phase 4 begins)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Verify clean tree and git log**

```bash
git status
git log --oneline -5
```

---

## Phase 3 Exit Criteria

- [ ] Task 1 validation passed: `[shake-probe]` log lines show "100 samples received — HID path works from app bundle" in Console.app.
- [ ] `Helper/` directory no longer exists on disk.
- [ ] `ShakeToEjectHelper` target no longer exists in `project.yml` or the generated `project.pbxproj`.
- [ ] `build/.../ShakeToEject.app/Contents/MacOS/` does NOT contain any file named `com.mcsoftware.ShakeToEject.Helper`.
- [ ] `xcodebuild -scheme ShakeToEject build` succeeds.
- [ ] `xcodebuild test -scheme ShakeToEjectTests` reports 22/22 passing.
- [ ] Finder-launched `ShakeToEject.app` shows a menu bar icon whose popover has a `Shakes:` counter that increments on physical laptop motion.
- [ ] Phase 3 is committed on `main`.

---

## What Phase 3 Does Not Do

- No DiskArbitration drive monitor or ejector yet — Phase 4.
- No warning overlay window with countdown — Phase 5.
- No sound playback — Phase 5.
- No arm/disarm toggle — always running for now.
- No auto-start-on-drive-mount — always running.
- No settings UI — threshold and cooldown are hardcoded.
- No launch-at-login — user has to open the app each session.
- No sandboxing (entitlement still set to `com.apple.security.app-sandbox = false`).
- No `Shared/` module tidy-up beyond pruning `Constants.swift`. The directory stays for future cross-cutting needs.
