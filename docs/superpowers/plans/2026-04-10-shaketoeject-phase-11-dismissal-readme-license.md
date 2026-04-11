# ShakeToEject — Phase 11: Dismissal Polish + README + LICENSE

**Goal:** Three small items of polish and release prep:

1. **Dismissal animation** — when `cancel()` or `complete()` fires, the notch capsule retracts toward the notch (scale + fade) and the fullscreen overlay fades out, before the actual `orderOut`. Currently the windows vanish instantly.
2. **README.md** — public-facing project documentation at the repo root: what it is, how to build, credits, license, requirements, known limitations.
3. **LICENSE** — MIT license file at the repo root. Matches the licenses of `olvvier/apple-silicon-accelerometer` and `taigrr/spank`.

**Prerequisites:**
- Phase 10 committed on main (`d313af8` or later).
- 25/25 tests still green.

**Scope:** ~30 lines of code change in `WarningCoordinator.swift`, ~10 lines in `NotchCapsuleView.swift`, ~10 lines in `WarningView.swift`, plus the two new text files. No new Swift source files.

---

## Dismissal design

Add a `private(set) var isDismissing: Bool` observable to `WarningCoordinator`. When it flips true, SwiftUI views that observe the coordinator animate out (opacity + scale). A `Task { @MainActor in ... }` then sleeps for the dismiss animation duration and finally calls the real `tearDown()` which `orderOut`s the windows.

Animation durations:
- **Notch capsule:** 0.30 s spring, scale 1 → 0.3 anchored at the top edge, opacity 1 → 0. Makes the capsule look like it's being sucked back into the notch.
- **Fullscreen overlay:** 0.25 s linear, opacity 1 → 0. No scale — a full-screen scale looks disorienting.

Both views animate from the same `isDismissing` flag so they start retracting at the same moment.

Crucially, the window is still alive during the animation — only `orderOut` is delayed. That means the Esc key monitor stays installed and the user could still press Esc during the animation, which would be a no-op (already dismissing) but safe.

---

## Code changes

### `WarningCoordinator.swift`

**Add an observable property near the top of the class, next to `isShowing` and `isEjecting`:**

```swift
/// True while the exit animation is playing after a cancel or
/// complete, before the windows are actually `orderOut`'d. Views
/// observe this to drive their fade/collapse animations.
private(set) var isDismissing: Bool = false

/// How long to give SwiftUI to play the dismissal animation
/// before we tear the windows down.
static let dismissAnimationDuration: Double = 0.3
```

**Replace `cancel()`:**

```swift
func cancel() {
    guard isShowing else { return }
    NSLog("[warning] cancelled by user")
    countdownTask?.cancel()
    countdownTask = nil
    beginDismissal()
}
```

**Replace `complete()` (keep the ejection watcher block, just route through `beginDismissal`):**

```swift
private func complete() {
    let drivesToEject = drivesSnapshot
    let expectedBSDNames = Set(drivesToEject.map(\.id))
    NSLog("[warning] countdown complete — ejecting \(expectedBSDNames.count) drive(s)")
    soundPlayer.playEjected()
    driveMonitor.eject(drivesToEject)
    countdownTask = nil

    if !expectedBSDNames.isEmpty {
        isEjecting = true
        startEjectionWatcher(expectedBSDNames: expectedBSDNames)
    }

    beginDismissal()
}
```

**Add the new `beginDismissal()` helper (near the other private methods):**

```swift
/// Starts the exit animation and schedules the actual window
/// teardown to fire after `dismissAnimationDuration` seconds.
private func beginDismissal() {
    isDismissing = true
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(Int(Self.dismissAnimationDuration * 1000)))
        guard let self else { return }
        self.tearDown()
        self.isDismissing = false
    }
}
```

### `NotchCapsuleView.swift`

**Add scale + opacity bindings to the outer `RoundedRectangle`:**

```swift
RoundedRectangle(cornerRadius: 22, style: .continuous)
    .fill(.black.opacity(0.95))
    .overlay(alignment: .center) { ... }
    .overlay(alignment: .top) { ... }
    .compositingGroup()
    .cameraShake(amplitude: ShakeAmplitude.subtle)
    .scaleEffect(coordinator.isDismissing ? 0.3 : 1.0, anchor: .top)
    .opacity(coordinator.isDismissing ? 0 : 1)
    .animation(.spring(response: 0.30, dampingFraction: 0.80), value: coordinator.isDismissing)
    .onAppear { ... }
```

### `WarningView.swift`

**Wrap the outer `ZStack` content in an opacity modifier keyed on `coordinator.isDismissing`:**

```swift
ZStack {
    Color.black.opacity(0.88)
        .ignoresSafeArea()

    VStack(spacing: 30) { ... }
        .padding(80)
        .cameraShake(amplitude: currentAmplitude)
}
.opacity(coordinator.isDismissing ? 0 : 1)
.animation(.easeOut(duration: 0.25), value: coordinator.isDismissing)
```

---

## README.md

A focused, friendly README at the repo root with:

- **Tagline:** "A macOS menu bar app that safely ejects external drives when it detects you picking up your laptop."
- **Screenshots section** (placeholder for now — we don't have any yet)
- **How it works** — one paragraph summary of the sensor → detector → warning → eject chain
- **Requirements** — Apple Silicon M1 Pro or M2+, macOS 14+
- **Build from source** — XcodeGen + Xcode 26 instructions
- **Settings** — one sentence per configurable setting
- **Credits** — `olvvier/apple-silicon-accelerometer` and `taigrr/spank`, both MIT
- **License** — MIT
- **Known limitations** — Intel / older M1 Macs not supported, volume-name-based exclusions break on rename, no notarized distribution yet

Target length: ~180 lines of markdown.

## LICENSE

Standard MIT license, year `2026`, copyright `Matteo Comisso`.

---

## Smoke test

1. Build + test pass (25/25)
2. Launch app, Simulate Shake, press Esc: overlay should fade out rather than vanish. Run several times to verify there's no regression on cancel.
3. Simulate Shake with a drive mounted, let countdown complete: overlay should fade out while eject fires in parallel.
4. Try notch style too: capsule should shrink toward the top and fade as it dismisses.
5. Open README.md in a text editor to sanity-check markdown renders reasonably.
6. `git status` should show the 3 modified Swift files, README.md, LICENSE, and the phase 11 plan doc.

---

## What Phase 11 Does Not Do

- No entrance animation refinement — the spring drop from the notch on `.onAppear` is already in place from Phase 9.
- No README screenshots — those want asset work.
- No notarization or code-signing changes for distribution.
- No app icon (still SF Symbol `eject.circle`).
- No drive character art (still SF Symbol + emoji).
