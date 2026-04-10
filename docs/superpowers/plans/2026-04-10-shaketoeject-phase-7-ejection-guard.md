# ShakeToEject — Phase 7: Ejection In-Progress Guard

**Goal:** Suppress new warning triggers while an ejection is in progress, so that repeated shakes during the post-countdown drive-ejection window don't produce duplicate overlays or try to re-eject drives that are already on their way out.

**The bug:** `DriveEjector.unmountAndEject` is asynchronous. When the countdown reaches zero, the coordinator calls `driveMonitor.ejectAll()`, tears down its own state, and returns. The drives then take anywhere from ~500 ms (disk image) to several seconds (real USB SSD) to actually unmount + eject. During that window, if the user moves the laptop, a fresh shake event fires `warningCoordinator.trigger()`, which sees `isShowing == false` and starts a new warning flow — even though the drives it would "protect" are already in the middle of being ejected. Worst case: two overlapping warnings on top of each other.

**The fix:** Add an `isEjecting` state to `WarningCoordinator`. Set it when `complete()` fires ejection; clear it when either (a) all the drives from the ejection snapshot have left `DriveMonitor.drives`, or (b) a safety timeout expires (to handle dissented ejections that never complete). While `isEjecting`, `trigger()` is a no-op with an explanatory log line.

**Scope:** one file, `App/Services/WarningCoordinator.swift`, ~30 added lines. No new files, no new tests, no architectural change.

**Prerequisites:**
- Phase 6 committed on main (commit `5f7bc3f` or later).
- End-to-end shake-to-eject flow works.

---

## Changes to `WarningCoordinator.swift`

1. Add `private(set) var isEjecting: Bool = false` alongside the other observable state.
2. Add `private var ejectingWatchTask: Task<Void, Never>?` for the drives-disappeared watcher.
3. Modify `trigger(countdownSeconds:force:)` to early-return with a log line when `isEjecting` is true.
4. Modify `complete()` to:
   - Capture the expected-BSD-name set before tearing down.
   - Set `isEjecting = true` if the set is non-empty.
   - Start a `startEjectionWatcher(expectedBSDNames:)` task.
5. Add `startEjectionWatcher(expectedBSDNames:)`:
   - Cancels any existing watcher task.
   - Runs a `Task` that polls `driveMonitor.drives` every 300 ms.
   - Exits when all expected BSD names have left the live drive list, or after a 10-second safety timeout.
   - Clears `isEjecting = false` on exit.

The polling approach is used instead of `withObservationTracking` because the tracking API is one-shot (you'd re-register on every tick anyway). 300 ms is low enough that the user never perceives the block dragging on past actual completion, and high enough that it doesn't meaningfully wake the CPU.

## Verification

Manual. Two passes:

1. **With a real drive** that takes > 500 ms to eject:
   - Mount the drive, tap the laptop, let countdown finish, ejection starts
   - Immediately tap the laptop again (before the drive actually disappears)
   - Expected: no new overlay, Console.app shows `[warning] trigger ignored — ejection in progress`
   - After the drive actually leaves (~1-2 s later), a fresh shake no longer produces the log line — the guard has cleared

2. **Safety timeout** (hard to reproduce naturally):
   - If a drive dissents the eject (e.g. Finder has a file open), the drive stays in the list
   - Expected: after 10 seconds, `isEjecting` still clears and the next shake re-triggers normally
   - Log line: `[warning] ejection watcher timed out after 10s`

## What Phase 7 Does Not Do

- **Does not expose the grace period or timeout as settings.** Both are hardcoded. Phase 8 can promote them if needed.
- **Does not retry dissented ejections.** If a drive refuses to eject, the app logs and moves on.
- **Does not visually indicate "ejection in progress" in the menu bar.** Observable state is there for Phase 8 / 9 UI to pick up.
- **Does not handle the "user cancels during ejection" case.** By design — once the countdown has fired eject, there's no undo.
