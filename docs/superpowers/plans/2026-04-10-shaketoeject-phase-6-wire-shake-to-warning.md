# ShakeToEject — Phase 6: Wire Sensor → Warning Coordinator

**Goal:** Connect the shake events the `SensorService` has been emitting since Phase 3 to the `WarningCoordinator.trigger()` call from Phase 5, so that physically moving the laptop produces the real warning-then-eject flow instead of just an incrementing counter. This is the moment the app starts doing what the user originally asked for.

**Scope:** Two small edits. No new files, no new tests, no architectural change. The groundwork for this moment was intentionally laid out so that Phase 6 would be small and reversible.

**Prerequisites:**
- Phase 5 committed on main (commit `471324c` or later).
- `Simulate Shake (dev)` menu item demonstrates the overlay + countdown + eject path works end-to-end.
- 22/22 tests green.

---

## Edit 1: `App/Services/SensorService.swift`

Add an `onShake: ((ShakeEvent) -> Void)?` property and invoke it from the existing `@MainActor` hop inside the `SensorWorker` handler, after the observable counters are updated.

Key points:

- The property is a plain `var` on a `@MainActor` class, so access is main-actor-isolated by default — no `@MainActor` annotation on the closure type needed.
- Invoked **after** `shakeCount += 1` and `lastShakeMagnitude = event.magnitude`, so any SwiftUI re-render triggered by the closure sees the updated counters.
- Doc comment tells callers to assign before calling `start()` so the first shake after launch finds the handler in place.

## Edit 2: `App/ShakeToEjectApp.swift`

In `AppDelegate.applicationDidFinishLaunching`, wire the handler **before** starting the sensor:

```swift
sensor.onShake = { [weak self] _ in
    self?.warningCoordinator.trigger()
}
sensor.start()
drives.start()
_ = warningCoordinator
```

Calling `trigger()` without `force: true` means the "no drives mounted → no-op" guard applies. Shaking the laptop with nothing plugged in is silent — the shake counter still increments (users can see the sensor is alive in the menu bar), but no warning fires. That's the desired behaviour.

---

## Verification

Three tests, all via physical laptop motion:

1. **Cancel path** — mount a drive (real or `hdiutil` synthetic), tap the laptop, warning appears, press Esc before countdown, drive stays mounted.
2. **Complete path** — tap again, let countdown finish, drive ejects automatically, overlay disappears, Glass sound plays.
3. **No-drive guard** — after the drive is gone, shake the laptop, no overlay appears, shake counter still increments in the menu bar, Console.app shows `[warning] trigger ignored — no drives to eject`.

---

## Why this is the smallest phase

Every phase from 0 through 5 was designed to make Phase 6 trivial:

- Phase 3 put the sensor and the app in the same process so there's no IPC boundary to cross.
- Phase 4 gave us a live drive list to snapshot on trigger.
- Phase 5 built the coordinator so that "trigger the warning flow" is a single method call that already handles window lifecycle, sound, countdown, cancel, and ejection.

Phase 6 is just the join. Everything else was scaffolding for this moment.

---

## What Phase 6 Does Not Do

- **Does not auto-arm on drive presence.** The sensor runs whenever the app is running. Shaking the laptop with no drive mounted wakes the sensor for nothing, burning a tiny bit of battery. Phase 7 fixes this.
- **Does not expose threshold/countdown/cooldown as user settings.** Still hardcoded. Phase 8.
- **Does not add tests.** The integration is behavioural; meaningful tests would need a mock sensor and a mock coordinator, more scaffolding than the 3 lines under test justify.
- **Does not add visual polish.** The warning overlay still uses the Phase 5 "good enough" look. Phase 9.
