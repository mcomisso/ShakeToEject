# ShakeToEject — Phase 5: Warning Overlay + Countdown + Sound

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a big, unmissable full-screen warning overlay that counts down from a configured number of seconds, plays a warning sound, and either dismisses on cancel (Esc or Cancel button) or fires `DriveMonitor.ejectAll()` when the countdown reaches zero. Add a dev-only "Simulate Shake" menu item so the flow can be exercised without physically moving the laptop. **Do not** wire real shake events to the overlay yet — that's Phase 6.

**Architecture:** Four new files:

1. `App/Services/SoundPlayer.swift` — thin `AVAudioPlayer` wrapper with `playWarning()` and `playEjected()` methods, each falling back to a system sound (`NSSound(named: "Funk")` / `"Glass"`) when the corresponding bundled asset isn't present.
2. `App/Services/WarningCoordinator.swift` — `@MainActor @Observable` class owning the countdown `Task`, the overlay window's lifecycle, and the publish-state for the SwiftUI view. Takes a `DriveMonitor` and `SoundPlayer` via init. Exposes `trigger(countdownSeconds:force:)` to start the flow and `cancel()` to abort.
3. `App/Views/WarningView.swift` — the SwiftUI view that lives inside the overlay. Reads `secondsRemaining` and `drivesCount` from the coordinator, renders a big warning triangle, title, countdown number, and CANCEL button. Esc keyboard shortcut on the Cancel button.
4. `App/Windows/WarningOverlayWindow.swift` — a borderless `NSWindow` subclass that sits at `.screenSaver` window level, covers the main screen, has no background, hosts the `WarningView` via `NSHostingView`, and overrides `canBecomeKey` so the Esc shortcut works.

Wiring updates:

- `AppDelegate` gains `soundPlayer` and `coordinator` properties alongside the existing `sensor` and `drives`. Lifecycle order: start sensor, start drives, create coordinator (no start method — it's dormant until `trigger()` is called).
- `MenuBarContent` gains a dev-only "Simulate Shake" button that calls `coordinator.trigger(force: true)`. The `force: true` lets the flow run even without drives mounted, for testing.

**Tech Stack:** SwiftUI, `@Observable`, `AppKit` (`NSWindow`, `NSHostingView`, `NSScreen`, `NSSound`), `AVFoundation` (`AVAudioPlayer`).

**Prerequisites:**
- Phase 4 committed on main (commit `908a94d` or later).
- 22/22 tests still green.
- The menu bar popover shows the sensor + drive list.

**No new tests in Phase 5.** The coordinator's countdown logic would be useful to unit-test (timing, cancellation, completion), but `Task.sleep` + the coordinator's tight coupling to `NSWindow` makes the unit test surface small relative to the mocking scaffolding required. Manual verification via the dev menu item is the test plan for this phase. We can circle back and add countdown tests in Phase 6 once the logic is split cleanly.

---

## Design choices locked in

- **Countdown length:** 5 seconds, hardcoded. Phase 8 wires it to `SettingsStore`.
- **Visual style:** solid black background at 0.85 opacity, yellow SF Symbol warning triangle (pulsing), "SHAKE DETECTED" title, "Ejecting N drive(s) in" subtitle, giant yellow countdown number, big white CANCEL capsule button. Not fancy, but unmissable. Phase 9 adds polish (blur, animations, drives "falling off").
- **Screen coverage:** main screen only. Multi-screen is a Phase 9 concern.
- **Sound assets:** placeholder using `NSSound(named: "Funk")` for the warning and `NSSound(named: "Glass")` for the ejection confirmation. User drops `warning.wav` / `ejected.wav` into `App/Resources/Sounds/` later and the real files take over automatically via the `Bundle.main.url(forResource:)` lookup.
- **No wiring to real shakes yet.** Phase 6 adds `sensor.onShake = { coordinator.trigger() }`.

---

### Task 1: Create `App/Services/SoundPlayer.swift`

**Files:**
- Create: `App/Services/SoundPlayer.swift`

- [ ] **Step 1: Write the file**

```swift
import AVFoundation
import AppKit
import Foundation

/// Thin wrapper around `AVAudioPlayer` that plays the warning and
/// ejected sounds for the `WarningCoordinator` flow.
///
/// The player looks for `warning.wav` and `ejected.wav` in the app
/// bundle's main resources. If the assets are missing (the
/// default — the user adds real files under `App/Resources/Sounds/`
/// later), it falls back to the macOS system sounds `Funk` (warning)
/// and `Glass` (eject confirmation) so the flow is still audible
/// during development.
///
/// `@MainActor` because AVAudioPlayer and NSSound are not Sendable
/// and the coordinator that drives us is main-actor-isolated.
@MainActor
final class SoundPlayer {
    private var currentPlayer: AVAudioPlayer?

    /// Plays the "shake detected, countdown starting" sound.
    func playWarning() {
        play(resourceName: "warning", fallbackSystemName: "Funk")
    }

    /// Plays the "drives ejected" confirmation sound.
    func playEjected() {
        play(resourceName: "ejected", fallbackSystemName: "Glass")
    }

    private func play(resourceName: String, fallbackSystemName: String) {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            player.play()
            currentPlayer = player
            return
        }
        NSSound(named: NSSound.Name(fallbackSystemName))?.play()
    }
}
```

Notes:
- `currentPlayer` holds a strong reference so the `AVAudioPlayer` survives the brief async playback period (SwiftUI ARC would otherwise release it before the first frame plays).
- The system-sound fallback is fire-and-forget — no retain needed because `NSSound` internally manages its own lifetime.
- `.wav` is the only extension we try. If the user adds `.mp3` or `.caf`, update the extension list here.

---

### Task 2: Create `App/Windows/WarningOverlayWindow.swift`

**Files:**
- Create: `App/Windows/WarningOverlayWindow.swift`

- [ ] **Step 1: Write the window subclass**

```swift
import AppKit
import SwiftUI

/// Borderless full-screen always-on-top window that hosts the
/// `WarningView`. Sized to cover the main screen, positioned at the
/// `.screenSaver` window level so it draws above menu bars, Dock,
/// and even other apps in full-screen mode.
///
/// `canBecomeKey` is overridden to true so the SwiftUI `keyboardShortcut(.escape)`
/// on the Cancel button actually receives the Esc keystroke — a
/// borderless `NSWindow` is non-key by default.
final class WarningOverlayWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

Notes on the flags:
- `.borderless` — no title bar or window chrome.
- `level: .screenSaver` — draws above the Dock and menu bar. Higher than `.floating` or `.popUpMenu`.
- `backgroundColor = .clear` + `isOpaque = false` — lets the SwiftUI view draw its own background.
- `.canJoinAllSpaces` + `.fullScreenAuxiliary` — the overlay follows the user across Spaces and appears on top of other apps' full-screen modes.
- `canBecomeKey` override — without this, the SwiftUI button's Esc shortcut won't fire because the window can't receive key events.

---

### Task 3: Create `App/Services/WarningCoordinator.swift`

**Files:**
- Create: `App/Services/WarningCoordinator.swift`

- [ ] **Step 1: Write the coordinator**

```swift
import AppKit
import Foundation
import Observation

/// Owns the end-to-end warning flow: showing the overlay window,
/// running the countdown, playing sounds, cancelling on user action
/// or timer completion, and (when the timer completes) telling the
/// `DriveMonitor` to eject all mounted drives.
///
/// The coordinator is `@MainActor` so it can touch `NSWindow` and
/// drive @Observable state that SwiftUI views bind to. The countdown
/// runs as a `Task` that inherits main-actor isolation and therefore
/// can mutate `secondsRemaining` without any actor hops.
///
/// This type is deliberately dormant until someone calls `trigger()`.
/// It has no `start()`/`stop()` lifecycle; the owning `AppDelegate`
/// simply instantiates it once at launch and discards it at quit.
@MainActor
@Observable
final class WarningCoordinator {
    /// True while the overlay is visible (i.e. between `trigger()`
    /// and either `cancel()` or the automatic `complete()` path).
    private(set) var isShowing: Bool = false

    /// Seconds left on the current countdown. `0` when not showing.
    private(set) var secondsRemaining: Int = 0

    /// The initial countdown value for the currently-showing warning.
    /// `0` when not showing. Exposed so the view can render a progress
    /// bar or ring proportional to the original length.
    private(set) var totalSeconds: Int = 0

    /// Snapshot of the drive list taken at `trigger()` time. The view
    /// reads this so it shows the right count even if drives appear
    /// or disappear during the countdown.
    private(set) var drivesSnapshot: [DriveInfo] = []

    private let driveMonitor: DriveMonitor
    private let soundPlayer: SoundPlayer

    private var window: WarningOverlayWindow?
    private var countdownTask: Task<Void, Never>?

    init(driveMonitor: DriveMonitor, soundPlayer: SoundPlayer) {
        self.driveMonitor = driveMonitor
        self.soundPlayer = soundPlayer
    }

    // MARK: - Public flow

    /// Starts the warning flow: snaps the current drive list, shows
    /// the overlay window, plays the warning sound, and begins the
    /// countdown. No-op if the overlay is already showing.
    ///
    /// Set `force: true` to show the overlay even when no drives are
    /// mounted — used by the dev-only "Simulate Shake" menu item so
    /// the flow can be exercised without a physical drive plugged in.
    func trigger(countdownSeconds: Int = 5, force: Bool = false) {
        guard !isShowing else { return }

        drivesSnapshot = driveMonitor.drives

        if drivesSnapshot.isEmpty && !force {
            NSLog("[warning] trigger ignored — no drives to eject")
            return
        }

        totalSeconds = countdownSeconds
        secondsRemaining = countdownSeconds
        isShowing = true

        soundPlayer.playWarning()
        showWindow()
        startCountdown()
    }

    /// Aborts the flow — hides the window, cancels the countdown,
    /// does NOT eject drives. Safe to call when not showing.
    func cancel() {
        guard isShowing else { return }
        NSLog("[warning] cancelled by user")
        countdownTask?.cancel()
        countdownTask = nil
        tearDown()
    }

    // MARK: - Private flow

    private func complete() {
        NSLog("[warning] countdown complete — ejecting \(drivesSnapshot.count) drive(s)")
        soundPlayer.playEjected()
        driveMonitor.ejectAll()
        countdownTask = nil
        tearDown()
    }

    private func tearDown() {
        hideWindow()
        isShowing = false
        secondsRemaining = 0
        totalSeconds = 0
        drivesSnapshot = []
    }

    private func startCountdown() {
        countdownTask = Task { [weak self] in
            guard let self else { return }
            // secondsRemaining starts at totalSeconds (set by trigger).
            // Tick once per second; completion fires after the last tick.
            while self.secondsRemaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.secondsRemaining -= 1
            }
            if !Task.isCancelled {
                self.complete()
            }
        }
    }

    private func showWindow() {
        let view = WarningView(coordinator: self)
        let newWindow = WarningOverlayWindow(rootView: view)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func hideWindow() {
        window?.orderOut(nil)
        window = nil
    }
}
```

Notes on the countdown loop:
- The loop decrements once per second so `secondsRemaining` transitions `5 → 4 → 3 → 2 → 1 → 0`.
- When it hits 0, the loop exits and `complete()` fires immediately. From the user's perspective the countdown lands on `0` just before the eject starts.
- `Task.isCancelled` is checked both inside the loop and before calling `complete()` so a cancel that fires during the last `sleep` doesn't accidentally trigger eject.
- `weak self` on the Task prevents a strong reference cycle through the coordinator. Even though the coordinator outlives the task in practice, `weak` is the safer default.

---

### Task 4: Create `App/Views/WarningView.swift`

**Files:**
- Create: `App/Views/WarningView.swift`

- [ ] **Step 1: Write the SwiftUI view**

```swift
import SwiftUI

/// The SwiftUI content of the full-screen warning overlay.
///
/// Binds to `WarningCoordinator` for state (`secondsRemaining`,
/// `drivesSnapshot`) and invokes `coordinator.cancel()` when the
/// user presses Escape or clicks the Cancel button.
struct WarningView: View {
    let coordinator: WarningCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)

                Text("SHAKE DETECTED")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(4)

                Text(ejectingSubtitle)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 240, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: coordinator.secondsRemaining)
                    .monospacedDigit()

                Button(action: { coordinator.cancel() }) {
                    Text("CANCEL")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .tracking(2)
                        .padding(.horizontal, 80)
                        .padding(.vertical, 22)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Text("or press Esc")
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(80)
        }
    }

    private var ejectingSubtitle: String {
        let count = coordinator.drivesSnapshot.count
        if count == 0 {
            return "(dev simulation — no drives to eject)"
        }
        return "Ejecting \(count) drive\(count == 1 ? "" : "s") in"
    }
}
```

Notes:
- `.symbolEffect(.pulse, options: .repeating)` is an SF Symbol effect available on macOS 14+, no OS version check needed.
- `.contentTransition(.numericText(countsDown: true))` + `.animation(.snappy, value:)` gives the countdown digit a nice rolling-down transition.
- `.monospacedDigit()` prevents horizontal jitter when the digit width changes between `0`/`1`/`2`/...
- The dev-simulation subtitle ("no drives to eject") only appears when the flow was triggered via `force: true` with an empty drive list — a helpful indicator that this is a test run and no real eject will happen.

---

### Task 5: Wire the coordinator into `AppDelegate`

**Files:**
- Modify: `App/ShakeToEjectApp.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                sensor: appDelegate.sensor,
                drives: appDelegate.drives,
                warningCoordinator: appDelegate.warningCoordinator
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
    let soundPlayer = SoundPlayer()
    lazy var warningCoordinator = WarningCoordinator(
        driveMonitor: drives,
        soundPlayer: soundPlayer
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        sensor.start()
        drives.start()
        _ = warningCoordinator // force lazy init
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
        drives.stop()
    }
}
```

Notes:
- `lazy var warningCoordinator` defers creation until first access. This sidesteps "instance member referenced in initialiser" ordering problems that would appear if we tried to initialise it in-line, because its init takes `drives` and `soundPlayer` which are themselves instance members.
- The `_ = warningCoordinator` line in `applicationDidFinishLaunching` forces the lazy property to materialise at launch so the dev menu item can reference it without triggering a surprise instantiation later.

---

### Task 6: Add a dev-only "Simulate Shake" button to `MenuBarContent`

**Files:**
- Modify: `App/MenuBar/MenuBarContent.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService
    let drives: DriveMonitor
    let warningCoordinator: WarningCoordinator

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

        Button("Simulate Shake (dev)") {
            warningCoordinator.trigger(force: true)
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

The "Simulate Shake (dev)" label carries the `(dev)` suffix on purpose so it's obvious this is a development-time button. Phase 8 or 9 can decide whether to keep it, gate it on a Debug build, or hide it behind an alt-click on the menu bar icon.

---

### Task 7: Regenerate, clean build, run tests

- [ ] **Step 1: Regenerate**

```bash
xcodegen generate 2>&1 | tail -3
```

- [ ] **Step 2: Clean build**

```bash
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

Watch for warnings about:
- `AVAudioPlayer` being Main actor bound in Swift 6 — the `@MainActor` on `SoundPlayer` should handle this.
- `NSHostingView` or `NSSound` Sendable concerns — `@MainActor` on the coordinator handles this.

- [ ] **Step 3: Run the test suite**

```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with 22 tests passing (unchanged from Phase 4).

---

### Task 8: Manual smoke test via the dev menu item

This task verifies the full warning flow end-to-end using the Simulate Shake button. No real laptop shaking required.

- [ ] **Step 1: Launch from Finder**

```bash
open build/Build/Products/Debug/ShakeToEject.app
```

- [ ] **Step 2: Test the cancel path (no drives needed)**

1. Click the menu bar icon
2. Click "Simulate Shake (dev)"
3. The overlay window appears, filling the screen:
   - Black background
   - Pulsing yellow warning triangle
   - "SHAKE DETECTED" title
   - "(dev simulation — no drives to eject)" subtitle OR "Ejecting N drive(s) in" if a drive is mounted
   - Giant yellow `5` countdown
   - White "CANCEL" capsule button
   - "or press Esc" helper text
4. System sound (Funk) plays once when the overlay appears
5. Within ~5 seconds, press **Escape** OR click the **CANCEL** button
6. Overlay disappears, returns to the menu bar
7. `log stream --process ShakeToEject` or Console.app filtered on `[warning]` should show:
   ```
   [warning] cancelled by user
   ```

- [ ] **Step 3: Test the complete path (with a drive)**

If you don't have a drive mounted, create a synthetic one:

```bash
hdiutil create -size 20m -fs APFS -volname ShakeTest /tmp/shake-test.dmg
hdiutil attach /tmp/shake-test.dmg
```

Then:

1. Click menu bar icon → "Simulate Shake (dev)"
2. Overlay appears, countdown ticks from 5 → 0
3. **Do nothing** — let the countdown complete
4. The drive (`ShakeTest`) ejects, `Glass` system sound plays, overlay disappears
5. Verify: `ls /Volumes/` no longer shows `ShakeTest`
6. Console.app `[warning]` filter:
   ```
   [warning] countdown complete — ejecting 1 drive(s)
   ```
7. Menu bar popover no longer lists the drive

Cleanup:

```bash
rm /tmp/shake-test.dmg 2>/dev/null
```

- [ ] **Step 4: User reports result**

Respond with:
- **"cancel works, complete + eject works"** → proceed to commit
- **"overlay doesn't appear" / "overlay stuck" / "eject doesn't fire"** → triage

Expected edge cases:
- If the overlay appears but the countdown is stuck at `5`, the `countdownTask` isn't running — check for `Task.sleep` warnings in Console.
- If Esc doesn't cancel, `WarningOverlayWindow.canBecomeKey` isn't being honoured — verify the override exists.
- If the sound doesn't play, `NSSound(named: "Funk")` may have been removed in a recent macOS. Substitute `"Purr"` or `"Submarine"`.

---

### Task 9: Commit Phase 5

- [ ] **Step 1: Review the diff**

```bash
git status --short
```

Expected:
```
 M App/MenuBar/MenuBarContent.swift
 M App/ShakeToEjectApp.swift
?? App/Services/SoundPlayer.swift
?? App/Services/WarningCoordinator.swift
?? App/Views/WarningView.swift
?? App/Windows/WarningOverlayWindow.swift
?? docs/superpowers/plans/2026-04-10-shaketoeject-phase-5-warning-overlay.md
```

Also: the previously-empty `App/Windows/.gitkeep` and `App/Views/.gitkeep` placeholders should be deleted (they have real content now).

- [ ] **Step 2: Delete the gitkeep placeholders**

```bash
rm -f App/Windows/.gitkeep App/Views/.gitkeep
```

- [ ] **Step 3: Stage**

```bash
git add -A
git status --short
```

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Phase 5: warning overlay + countdown + sound player + dev trigger

- Add App/Services/SoundPlayer.swift — @MainActor AVAudioPlayer
  wrapper with playWarning() and playEjected(). Looks for
  warning.wav and ejected.wav under the app bundle and falls back
  to NSSound(named:) system sounds (Funk / Glass) when the assets
  aren't present. The user will drop real audio files into
  App/Resources/Sounds/ later and the playback path picks them up
  automatically.
- Add App/Windows/WarningOverlayWindow.swift — a borderless
  NSWindow subclass at .screenSaver level covering the main screen.
  Overrides canBecomeKey so the SwiftUI Esc keyboard shortcut on
  the Cancel button actually fires.
- Add App/Services/WarningCoordinator.swift — @MainActor @Observable
  glue that owns the countdown Task, the overlay window lifecycle,
  and the snapshot of drive state. Exposes trigger(countdownSeconds:
  force:) and cancel(). When the countdown reaches zero it calls
  DriveMonitor.ejectAll() and tears down. The force: true parameter
  lets the dev menu item run the flow without any drives mounted.
- Add App/Views/WarningView.swift — the SwiftUI content for the
  overlay. Big pulsing yellow warning triangle, SHAKE DETECTED
  title, "Ejecting N drive(s) in" subtitle, giant yellow countdown
  number with snappy numeric-text content transition, big white
  CANCEL capsule button with Esc shortcut, "or press Esc" helper.
- Extend AppDelegate to own a SoundPlayer and a lazy-init
  WarningCoordinator alongside the existing sensor and drives.
- Extend MenuBarContent with a "Simulate Shake (dev)" button that
  calls warningCoordinator.trigger(force: true) so the warning
  flow can be exercised without shaking the laptop.

This phase does NOT wire the real sensor to the warning coordinator
— that's a one-liner in Phase 6. Keeping them separate lets us
verify the overlay + countdown + eject path via the dev menu before
involving the HID sensor.

Verified: Simulate Shake shows the overlay, Cancel dismisses it,
countdown to zero fires eject on mounted drives. 22/22 tests still
green; no Swift 6 concurrency warnings.

Phase 5 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify**

```bash
git log --oneline -7
git status
```

---

## Phase 5 Exit Criteria

- [ ] `App/Services/SoundPlayer.swift` exists and plays the warning + eject sounds (real or fallback).
- [ ] `App/Windows/WarningOverlayWindow.swift` produces a full-screen borderless window at `.screenSaver` level.
- [ ] `App/Services/WarningCoordinator.swift` exposes `trigger(countdownSeconds:force:)` / `cancel()`.
- [ ] `App/Views/WarningView.swift` renders the countdown, title, and CANCEL button.
- [ ] `AppDelegate` owns the coordinator and its dependencies.
- [ ] "Simulate Shake (dev)" menu item in the popover triggers the full flow.
- [ ] Cancel (Esc or button) dismisses the overlay without ejecting.
- [ ] Letting the countdown reach zero with drives mounted ejects them and dismisses the overlay.
- [ ] `xcodebuild test` still passes 22/22.
- [ ] Phase 5 is committed on `main`.

---

## What Phase 5 Does Not Do

- **Does not wire real shakes.** The sensor keeps incrementing the counter as before; nothing calls `warningCoordinator.trigger()` from the shake path. Phase 6 does this in one line.
- **Does not gate on drive presence for real.** `trigger(force: false)` is what Phase 6 uses; dev mode uses `force: true`.
- **Does not add real audio assets.** Placeholders are system sounds. User adds files whenever they're ready.
- **Does not animate drives "falling off" the list.** Phase 9 polish.
- **Does not support multi-screen.** Main screen only. Phase 9 polish.
- **Does not add settings.** Countdown length is hardcoded 5. Phase 8 wires it to `SettingsStore`.
- **Does not support resume / re-arm semantics.** A cancel immediately disarms the flow; the next shake starts fresh. Phase 6+ may add "snooze" semantics.
- **Does not add tests.** Countdown logic is testable in principle; deferring to Phase 6 or 8 when the logic is more settled.
