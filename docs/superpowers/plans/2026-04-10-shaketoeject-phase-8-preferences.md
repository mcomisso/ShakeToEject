# ShakeToEject — Phase 8: Preferences (SettingsStore + Dashboard)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the user a proper settings surface for the five configurable parameters that were previously hardcoded: countdown length, shake sensitivity threshold, shake cooldown, warning style (fullscreen / notch / auto), and launch at login. Persist via `UserDefaults`, apply live without a sensor restart, and expose a dashboard window reachable from the menu bar popover.

**Architecture:**

```
SettingsStore (@MainActor @Observable)      single source of truth
    ↓ (read)                                ↓ (read)
SensorService.setThreshold(_:)              WarningCoordinator.trigger()
SensorService.setCooldownSamples(_:)           → reads countdownSeconds + style
    ↓ (forwards)
SensorWorker / ShakeDetector
```

The `SettingsStore` is instantiated once in `AppDelegate` and passed by reference to everything that needs it. Mutations to its observable properties trigger:
- SwiftUI dashboard re-renders (via `@Observable` tracking)
- Immediate side-effects through a small number of `didSet` observers that forward values to the running sensor and register/unregister the launch-at-login entry

Dashboard window is a classic `NSWindow` subclass hosted via `NSHostingView`, opened from a new "Settings…" button in the menu bar popover. The window persists after first open (stored in `AppDelegate`) so the dashboard remembers its position.

**Tech Stack:** `UserDefaults`, `@Observable`, SwiftUI `Form` / `Stepper` / `Slider` / `Picker` / `Toggle`, `NSWindow`, `NSHostingView`, `ServiceManagement.framework` (`SMAppService.mainApp`).

**Prerequisites:**
- Phase 7 committed on main (commit `ac82664` or later).
- End-to-end shake → warning → eject flow works.
- Ejection-in-progress guard is in place.

**No new tests in Phase 8.** The settings store could be unit-tested in principle, but the behaviour under test is "UserDefaults round-trips" which is trivial. The real verification is manual: open the dashboard, drag sliders, verify live changes take effect.

---

## Data model

### SettingsStore defaults and ranges

| Setting              | Key (UserDefaults)           | Type      | Default | Range     |
|----------------------|------------------------------|-----------|---------|-----------|
| countdownSeconds     | `settings.countdownSeconds`  | `Int`     | `5`     | `1…30`    |
| sensitivityThreshold | `settings.sensitivity`       | `Double`  | `0.3`   | `0.05…1.0`|
| cooldownSeconds      | `settings.cooldownSeconds`   | `Double`  | `1.0`   | `0.5…5.0` |
| warningStyle         | `settings.warningStyle`      | `String`  | `"fullscreen"` | enum raw values |
| launchAtLogin        | `settings.launchAtLogin`     | `Bool`    | `false` | —         |

`cooldownSeconds` is stored in seconds for UI clarity and converted to samples (`cooldown * 800`) when forwarded to the detector. The 800 sample rate is the measured M1 Pro native rate from Phase 1; Phase 10 could measure it dynamically.

### WarningStyle enum

```swift
enum WarningStyle: String, CaseIterable, Identifiable {
    case fullscreen
    case notch
    case auto

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .notch:      return "Notch (coming in Phase 9)"
        case .auto:       return "Auto (coming in Phase 9)"
        }
    }
}
```

Only `.fullscreen` is functional in Phase 8. The other two cases are picker placeholders that fall back to fullscreen with an NSLog warning until Phase 9 fills them in.

---

### Task 1: Create `App/Services/SettingsStore.swift`

**Files:**
- Create: `App/Services/SettingsStore.swift`

- [ ] **Step 1: Write the store**

```swift
import Foundation
import Observation
import ServiceManagement

/// Enumeration of how the warning UI presents itself on screen.
/// Only `.fullscreen` is implemented in Phase 8; `.notch` and
/// `.auto` are placeholder cases that fall through to fullscreen
/// until Phase 9 implements the notch expansion window.
enum WarningStyle: String, CaseIterable, Identifiable, Sendable {
    case fullscreen
    case notch
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .notch: return "Notch (coming in Phase 9)"
        case .auto: return "Auto (coming in Phase 9)"
        }
    }
}

/// Main-actor-isolated, @Observable facade over `UserDefaults`.
///
/// Every configurable parameter the user can touch lives here. The
/// store is instantiated once in `AppDelegate` and passed to every
/// consumer (sensor, warning coordinator, dashboard view).
///
/// Mutations trigger `didSet` handlers that forward values to the
/// running services:
/// - `sensitivityThreshold` and `cooldownSeconds` push live updates
///   into the already-running `SensorService` via `onSensorChange`
///   (set by AppDelegate at launch).
/// - `launchAtLogin` invokes `SMAppService.mainApp` register /
///   unregister synchronously.
/// - `countdownSeconds` and `warningStyle` don't push — consumers
///   read the current value on every `trigger()` call.
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Keys
    private enum Key {
        static let countdownSeconds = "settings.countdownSeconds"
        static let sensitivityThreshold = "settings.sensitivity"
        static let cooldownSeconds = "settings.cooldownSeconds"
        static let warningStyle = "settings.warningStyle"
        static let launchAtLogin = "settings.launchAtLogin"
    }

    // MARK: - Defaults
    static let defaultCountdownSeconds = 5
    static let defaultSensitivityThreshold = 0.3
    static let defaultCooldownSeconds = 1.0
    static let defaultWarningStyle: WarningStyle = .fullscreen
    static let defaultLaunchAtLogin = false

    // MARK: - Ranges
    static let countdownRange = 1...30
    static let sensitivityRange = 0.05...1.0
    static let cooldownRange = 0.5...5.0

    /// The assumed native HID sample rate of the BMI286 accelerometer
    /// on M1 Pro, measured in Phase 1. Cooldown seconds are converted
    /// to sample counts for the detector using this constant.
    static let assumedSampleRateHz: Double = 800.0

    // MARK: - Observable state

    var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Key.countdownSeconds) }
    }

    var sensitivityThreshold: Double {
        didSet {
            UserDefaults.standard.set(sensitivityThreshold, forKey: Key.sensitivityThreshold)
            onSensitivityChange?(sensitivityThreshold)
        }
    }

    var cooldownSeconds: Double {
        didSet {
            UserDefaults.standard.set(cooldownSeconds, forKey: Key.cooldownSeconds)
            onCooldownChange?(Int((cooldownSeconds * Self.assumedSampleRateHz).rounded()))
        }
    }

    var warningStyle: WarningStyle {
        didSet { UserDefaults.standard.set(warningStyle.rawValue, forKey: Key.warningStyle) }
    }

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    // MARK: - Live-update hooks

    /// Called on every sensitivity mutation with the new value in g.
    /// AppDelegate wires this to `SensorService.setThreshold(_:)`.
    var onSensitivityChange: ((Double) -> Void)?

    /// Called on every cooldown mutation with the new value in samples
    /// (seconds × 800). AppDelegate wires this to
    /// `SensorService.setCooldownSamples(_:)`.
    var onCooldownChange: ((Int) -> Void)?

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let storedCountdown = defaults.integer(forKey: Key.countdownSeconds)
        self.countdownSeconds = storedCountdown > 0 ? storedCountdown : Self.defaultCountdownSeconds

        let storedSensitivity = defaults.double(forKey: Key.sensitivityThreshold)
        self.sensitivityThreshold = storedSensitivity > 0 ? storedSensitivity : Self.defaultSensitivityThreshold

        let storedCooldown = defaults.double(forKey: Key.cooldownSeconds)
        self.cooldownSeconds = storedCooldown > 0 ? storedCooldown : Self.defaultCooldownSeconds

        let storedStyle = defaults.string(forKey: Key.warningStyle) ?? Self.defaultWarningStyle.rawValue
        self.warningStyle = WarningStyle(rawValue: storedStyle) ?? Self.defaultWarningStyle

        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    /// Reads the current cooldown value as a detector sample count.
    /// Used by `SensorService` at startup before any didSet has fired.
    var cooldownSamples: Int {
        Int((cooldownSeconds * Self.assumedSampleRateHz).rounded())
    }

    // MARK: - Launch at login

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                NSLog("[settings] launch at login: registered")
            } else {
                try service.unregister()
                NSLog("[settings] launch at login: unregistered")
            }
        } catch {
            NSLog("[settings] launch at login error: \(error.localizedDescription)")
        }
    }
}
```

---

### Task 2: Extend `SensorService` with live-update methods

**Files:**
- Modify: `App/Services/SensorService.swift`

- [ ] **Step 1: Add `setThreshold(_:)` and `setCooldownSamples(_:)`**

The current `SensorService` starts a `SensorWorker` and never touches the detector's configurable fields. Add two methods that forward to the worker. The worker in turn exposes the detector — or we add the forwarding methods there too. Either way, the mutation ends up on `ShakeDetector.threshold` / `.cooldownSamples`, which are plain `var` properties and safe to set from the main thread (worst case, one HID callback uses the old value).

Add these methods to `SensorService` (anywhere after `stop()`):

```swift
/// Applies a new sensitivity threshold in g to the running sensor.
/// Safe to call while the sensor is running; the change takes
/// effect on the next sample the worker processes.
func setThreshold(_ threshold: Double) {
    worker?.updateThreshold(threshold)
}

/// Applies a new cooldown sample count to the running sensor.
/// Safe to call while the sensor is running.
func setCooldownSamples(_ samples: Int) {
    worker?.updateCooldownSamples(samples)
}
```

And add the corresponding forwarding methods on `SensorWorker` (the file `App/Services/SensorWorker.swift`) just after `stop()`:

```swift
/// Updates the detector's threshold from the main thread. The
/// `ShakeDetector` class is @unchecked Sendable; races against
/// the HID callback thread are benign (one sample lands with the
/// old value, the next with the new).
func updateThreshold(_ value: Double) {
    detector.threshold = value
}

/// Updates the detector's cooldown sample count from the main
/// thread. Same race-benign semantics as `updateThreshold`.
func updateCooldownSamples(_ value: Int) {
    detector.cooldownSamples = value
}
```

Note: `SensorWorker`'s `detector` property is currently `private let`. Change it to `private let` stays fine for the reference — we're mutating the class's properties, not the reference. No change needed to the declaration.

Also: `SensorWorker.init(threshold:cooldownSamples:handler:)` currently takes `threshold: Double = 0.3` and `cooldownSamples: Int = 800` with hardcoded defaults. Remove the defaults so callers must pass them explicitly — this forces the `AppDelegate` wiring to come from `SettingsStore` and prevents regressions.

Update the init signature:

```swift
init(
    threshold: Double,
    cooldownSamples: Int,
    handler: @escaping ShakeHandler
) {
    self.handler = handler
    self.detector = ShakeDetector(threshold: threshold, cooldownSamples: cooldownSamples)
}
```

(Just remove the `= 0.3` and `= 800` defaults from the existing signature.)

And update `SensorService.start()` to accept threshold + cooldown parameters and pass them through:

```swift
/// Starts the sensor pipeline with the given detector parameters.
/// No-op if already running.
func start(threshold: Double, cooldownSamples: Int) {
    guard worker == nil else { return }

    let newWorker = SensorWorker(
        threshold: threshold,
        cooldownSamples: cooldownSamples
    ) { [weak self] event in
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.shakeCount += 1
            self.lastShakeMagnitude = event.magnitude
            self.onShake?(event)
        }
    }
    newWorker.start()
    worker = newWorker
    isRunning = true
}
```

---

### Task 3: Extend `WarningCoordinator` to read countdown + style from settings

**Files:**
- Modify: `App/Services/WarningCoordinator.swift`

- [ ] **Step 1: Add a `settings: SettingsStore` stored property**

Change the init to take a `SettingsStore`:

```swift
private let driveMonitor: DriveMonitor
private let soundPlayer: SoundPlayer
private let settings: SettingsStore

init(driveMonitor: DriveMonitor, soundPlayer: SoundPlayer, settings: SettingsStore) {
    self.driveMonitor = driveMonitor
    self.soundPlayer = soundPlayer
    self.settings = settings
}
```

- [ ] **Step 2: Change `trigger()` to read from settings**

Replace the existing `trigger(countdownSeconds:force:)` signature with:

```swift
/// Starts the warning flow. `countdownSeconds` is taken from the
/// `SettingsStore` unless overridden via `overrideCountdown` (used
/// by the dev simulate button to keep behaviour predictable).
func trigger(force: Bool = false, overrideCountdown: Int? = nil) {
    guard !isShowing else { return }

    guard !isEjecting else {
        NSLog("[warning] trigger ignored — ejection in progress")
        return
    }

    drivesSnapshot = driveMonitor.drives

    if drivesSnapshot.isEmpty && !force {
        NSLog("[warning] trigger ignored — no drives to eject")
        return
    }

    let countdown = overrideCountdown ?? settings.countdownSeconds
    totalSeconds = countdown
    secondsRemaining = countdown
    isShowing = true

    // Log the warning style even though only fullscreen is
    // implemented in Phase 8 — this surfaces future issues when
    // Phase 9 fills in notch/auto.
    if settings.warningStyle != .fullscreen {
        NSLog("[warning] warning style \(settings.warningStyle.rawValue) not yet implemented — falling back to fullscreen")
    }

    soundPlayer.playWarning()
    showWindow()
    startCountdown()
}
```

The caller signature change means existing callers need to be updated:

- `AppDelegate.applicationDidFinishLaunching` currently has:
  ```swift
  sensor.onShake = { [weak self] _ in
      self?.warningCoordinator.trigger()
  }
  ```
  Change to:
  ```swift
  sensor.onShake = { [weak self] _ in
      self?.warningCoordinator.trigger()
  }
  ```
  No change needed — the defaults now pull from settings.
- `MenuBarContent`'s Simulate Shake button calls `warningCoordinator.trigger(force: true)`. Still works; `force: true` plus default (no override) reads countdown from settings.

---

### Task 4: Create `App/Windows/DashboardWindow.swift`

**Files:**
- Create: `App/Windows/DashboardWindow.swift`

- [ ] **Step 1: Write the window subclass**

```swift
import AppKit
import SwiftUI

/// A regular titled window hosting the settings dashboard. Unlike
/// `WarningOverlayWindow` this is a normal user-facing window: it
/// has a title bar, can be dragged and closed, remembers its
/// position via the default autosave name.
final class DashboardWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "ShakeToEject Settings"
        isReleasedWhenClosed = false
        setFrameAutosaveName("ShakeToEject.Dashboard")
        contentView = NSHostingView(rootView: rootView)
    }
}
```

Notes:
- `isReleasedWhenClosed = false` lets the window be closed and re-shown without being deallocated. The coordinator holds it alive in `AppDelegate`.
- `setFrameAutosaveName` makes AppKit remember the user's preferred window position across launches — automatic, no UserDefaults wiring needed.
- No resizable flag — the dashboard is fixed-size to avoid layout headaches.

---

### Task 5: Create `App/Views/DashboardView.swift`

**Files:**
- Create: `App/Views/DashboardView.swift`

- [ ] **Step 1: Write the SwiftUI form**

```swift
import SwiftUI

struct DashboardView: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section("Detection") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(String(format: "%.2f g", settings.sensitivityThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.sensitivityThreshold },
                            set: { settings.sensitivityThreshold = $0 }
                        ),
                        in: SettingsStore.sensitivityRange
                    )
                    Text("Lower = detects gentler motion. Higher = only strong shakes trigger.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text(String(format: "%.1f s", settings.cooldownSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.cooldownSeconds },
                            set: { settings.cooldownSeconds = $0 }
                        ),
                        in: SettingsStore.cooldownRange,
                        step: 0.1
                    )
                    Text("Minimum time between detected shake events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Warning") {
                Stepper(
                    "Countdown: \(settings.countdownSeconds)s",
                    value: Binding(
                        get: { settings.countdownSeconds },
                        set: { settings.countdownSeconds = $0 }
                    ),
                    in: SettingsStore.countdownRange
                )
                Text("How long the warning overlay waits before ejecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Style",
                    selection: Binding(
                        get: { settings.warningStyle },
                        set: { settings.warningStyle = $0 }
                    )
                ) {
                    ForEach(WarningStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0 }
                    )
                )

                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.shortVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
```

The manual `Binding(get:set:)` wrapping is deliberately verbose — it lets us keep `@Observable` without adopting `@Bindable` at every site, and makes the data flow explicit for future readers.

---

### Task 6: Wire everything through `AppDelegate`

**Files:**
- Modify: `App/ShakeToEjectApp.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import AppKit
import SwiftUI

@main
struct ShakeToEjectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                sensor: appDelegate.sensor,
                drives: appDelegate.drives,
                warningCoordinator: appDelegate.warningCoordinator,
                settings: appDelegate.settings,
                onOpenDashboard: { [weak appDelegate] in
                    appDelegate?.openDashboard()
                }
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
    let settings = SettingsStore()
    lazy var warningCoordinator = WarningCoordinator(
        driveMonitor: drives,
        soundPlayer: soundPlayer,
        settings: settings
    )

    private var dashboardWindow: DashboardWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire settings → sensor for live updates
        settings.onSensitivityChange = { [weak self] value in
            self?.sensor.setThreshold(value)
        }
        settings.onCooldownChange = { [weak self] samples in
            self?.sensor.setCooldownSamples(samples)
        }

        // Wire real shakes → warning flow
        sensor.onShake = { [weak self] _ in
            self?.warningCoordinator.trigger()
        }

        // Start the sensor with the current settings values
        sensor.start(
            threshold: settings.sensitivityThreshold,
            cooldownSamples: settings.cooldownSamples
        )
        drives.start()
        _ = warningCoordinator // force lazy init
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
        drives.stop()
    }

    /// Creates-or-shows the settings window. Idempotent; subsequent
    /// calls just bring the existing window to the front.
    func openDashboard() {
        if let existing = dashboardWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DashboardView(settings: settings)
        let window = DashboardWindow(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow = window
    }
}
```

---

### Task 7: Add "Settings…" to the menu bar

**Files:**
- Modify: `App/MenuBar/MenuBarContent.swift`

- [ ] **Step 1: Update the view**

```swift
import SwiftUI

struct MenuBarContent: View {
    let sensor: SensorService
    let drives: DriveMonitor
    let warningCoordinator: WarningCoordinator
    let settings: SettingsStore
    let onOpenDashboard: () -> Void

    var body: some View {
        Text("ShakeToEject \(Bundle.main.shortVersion)")
            .font(.headline)

        Text(sensor.isRunning ? "Sensor: running" : "Sensor: stopped")
        Text("Shakes: \(sensor.shakeCount)")

        if sensor.lastShakeMagnitude > 0 {
            Text(String(format: "Last magnitude: %.3f g", sensor.lastShakeMagnitude))
        }

        if warningCoordinator.isEjecting {
            Text("Ejecting…")
                .foregroundStyle(.orange)
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

        Button("Settings…") {
            onOpenDashboard()
        }
        .keyboardShortcut(",")

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

Notes:
- `Settings…` with `keyboardShortcut(",")` uses ⌘, — the standard macOS settings shortcut.
- Added an `Ejecting…` row in the sensor section that surfaces the new `isEjecting` observable from Phase 7. This also doubles as visual feedback of the guard working.
- `onOpenDashboard` is passed as a closure so `MenuBarContent` doesn't need to know about `AppDelegate`.

---

### Task 8: Regenerate, build, run tests

- [ ] **Step 1:**
```bash
xcodegen generate 2>&1 | tail -3
```

- [ ] **Step 2:**
```bash
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3:**
```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **` 22/22.

---

### Task 9: Manual smoke test

1. Launch the app from Finder.
2. Click menu bar icon → **Settings…**
3. Dashboard window opens with Detection / Warning / General sections.
4. Drag the **Sensitivity** slider — the value label updates live.
5. Drag the **Cooldown** slider.
6. Step the **Countdown** stepper up and down.
7. Open the **Style** picker — verify the notch/auto options are present but mention "coming in Phase 9".
8. Toggle **Launch at login** on, then off — Console should show `[settings] launch at login: registered` / `unregistered`.
9. Close the dashboard, reopen it — values persist (via UserDefaults).
10. Quit the app, relaunch — values still persist.
11. Change the countdown to, say, 3 seconds. Click **Simulate Shake (dev)** — warning counts down from 3, not 5.
12. Change sensitivity to a low value like 0.1. Tap the laptop gently — warning fires on much less motion than before.
13. Change sensitivity to a high value like 0.8. Tap gently — no warning; shake more vigorously — warning fires.

---

### Task 10: Commit Phase 8

- [ ] **Step 1:**
```bash
git status --short
git add -A
git commit -m "$(cat <<'EOF'
Phase 8: preferences window, SettingsStore, live sensor updates

Adds a proper settings surface for the five parameters that were
hardcoded since Phase 0-7: countdown length, shake sensitivity,
shake cooldown, warning style, and launch at login. Values persist
to UserDefaults and most apply live without a sensor restart.

- Add App/Services/SettingsStore.swift — @MainActor @Observable
  class wrapping UserDefaults. Exposes countdownSeconds,
  sensitivityThreshold, cooldownSeconds, warningStyle, and
  launchAtLogin. didSet handlers write to UserDefaults and forward
  live changes via onSensitivityChange / onCooldownChange hooks.
  Launch at login uses SMAppService.mainApp.register() / unregister().
- Add App/Windows/DashboardWindow.swift — titled NSWindow subclass
  with setFrameAutosaveName for position persistence across launches.
- Add App/Views/DashboardView.swift — SwiftUI Form with three
  sections (Detection / Warning / General), sliders for sensitivity
  and cooldown, a stepper for countdown, a picker for warning style,
  a launch-at-login toggle, and a version label.
- Extend SensorService + SensorWorker with setThreshold(_:) and
  setCooldownSamples(_:) that mutate the running ShakeDetector's
  fields from the main thread. Races against the HID callback
  thread are benign (one sample uses the old value, the next uses
  the new).
- Change SensorService.start() to take threshold and cooldownSamples
  explicitly so AppDelegate must pass them from the SettingsStore —
  prevents regressions to the old hardcoded defaults.
- Change WarningCoordinator.init to take a SettingsStore and read
  countdownSeconds from it in trigger(). Log a warning if the
  selected warningStyle is .notch or .auto (not yet implemented;
  falls back to fullscreen).
- Wire AppDelegate to own a SettingsStore, install the
  onSensitivityChange / onCooldownChange hooks, and expose
  openDashboard() for the menu bar button to call.
- Extend MenuBarContent with a "Settings…" button (⌘,) that calls
  the AppDelegate closure, and a small "Ejecting…" status row that
  surfaces the Phase 7 isEjecting observable.

Defer drive exclusions to a later phase — the picker UI + per-drive
state management is enough work to deserve its own commit.

Verified: settings persist across relaunch, slider drags propagate
live to the running sensor, countdown length change takes effect on
next trigger, launch-at-login toggle registers successfully. 22/22
tests still green.

Phase 8 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 Exit Criteria

- [ ] `SettingsStore.swift` compiles and round-trips all five settings through UserDefaults.
- [ ] `DashboardWindow` opens via ⌘, and shows the current values.
- [ ] Sensitivity slider applies live to the running sensor (tap the laptop with threshold at 0.1 → warning fires; raise to 0.8 → no warning on gentle taps).
- [ ] Countdown stepper takes effect on next Simulate Shake.
- [ ] Launch-at-login toggle succeeds (Console log line) without an error dialog.
- [ ] All values persist across app quit/relaunch.
- [ ] Ejecting… row appears in the menu bar popover during the post-countdown window.
- [ ] 22/22 tests green.
- [ ] Phase 8 committed on main.

## What Phase 8 Does Not Do

- No drive exclusion list.
- No per-style configuration for notch/auto (they're placeholder cases).
- No measured sample rate — still assumes 800 Hz for the cooldown conversion.
- No import/export of settings.
- No keyboard-driven navigation of the dashboard beyond the standard Tab/arrow keys SwiftUI gives for free.
