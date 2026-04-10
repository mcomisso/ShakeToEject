# ShakeToEject — Phase 2: Shake Detection Algorithm

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure, fully unit-tested shake detector that ingests `HIDReport` samples from Phase 1 and emits discrete `ShakeEvent` values when the laptop is picked up or bumped, with a configurable threshold and configurable debounce cooldown to prevent double-triggering.

**Architecture:** Single `Helper/ShakeDetector.swift` file containing a `ShakeDetector` class (not struct — see "Why a class" below) and a `ShakeEvent` struct. The algorithm is simple on purpose: compute instantaneous magnitude `|a| = √(x²+y²+z²)`, subtract the expected 1 g of gravity, take the absolute value, and fire an event when that exceeds the threshold and we are not currently in cooldown. This catches "someone picked up or bumped the laptop" which is what we want, not micro-vibrations (that would require STA/LTA-style vibration detection like spank uses — out of scope for v1). The detector is compiled into both the helper target (for live use via `main.swift --detect`) and the test target (which compiles its own copy, same pattern as Phase 1's `HIDReport`).

**Tech Stack:** Swift 6, Swift Testing. No IOKit in this file — it is hardware-free.

**Prerequisites:**
- Phase 1 committed (commit `6a3aedf` or later) on `main`.
- `xcodebuild test -scheme ShakeToEjectTests` currently reports 10/10 green.
- `build/.../com.mcsoftware.ShakeToEject.Helper --print` streams live samples from the M1 Pro accelerometer.

---

## Why a class, not a struct

The detector carries mutable state (cooldown counter) and will be captured by the `@Sendable` sample handler closure passed to `AccelerometerReader`. A `struct` would need to be wrapped in a holder type to be mutated across the closure boundary under Swift 6 strict concurrency. A `final class: @unchecked Sendable` with documented thread-safety semantics is the simpler choice, and mirrors how `AccelerometerReader` handles the same situation. The class is still pure (no IOKit, no clock) and just as testable as a struct.

## Why sample-count cooldown, not seconds

`ShakeDetector.process(_:)` is a pure function of its input — no clock access. The cooldown is measured in **samples**, not seconds. Callers who want "1 second of cooldown" must convert using their known sample rate. This keeps the detector trivially deterministic in tests and avoids hidden clock dependencies. Phase 7's UI will expose cooldown as seconds and convert to samples using the helper's measured rate.

## Algorithm specification

For each sample:

1. If cooldown counter > 0, decrement it and return `nil`.
2. Compute `m = √(x² + y² + z²)` — instantaneous magnitude in g.
3. Compute `dynamic = |m - 1.0|` — non-gravity acceleration magnitude.
4. If `dynamic ≥ threshold`, set cooldown counter to `cooldownSamples` and return `ShakeEvent(magnitude: dynamic)`.
5. Otherwise return `nil`.

Defaults:

- `threshold = 0.3` g — catches a firm grab or pickup, ignores typing-induced jitter.
- `cooldownSamples = 800` — ~1 second at the ~800 Hz native rate we measured on M1 Pro. Callers should adjust if they use a different rate.

---

### Task 1: Write `ShakeDetector.swift`

**Files:**
- Create: `Helper/ShakeDetector.swift`

- [ ] **Step 1: Create the file**

Write `Helper/ShakeDetector.swift` with this EXACT content:

```swift
import Foundation

/// A single event emitted when the detector determines the device has
/// experienced non-gravity acceleration exceeding the configured threshold.
struct ShakeEvent: Equatable {
    /// The dynamic acceleration magnitude (in g, excluding gravity) that
    /// triggered this event. Always a non-negative number greater than or
    /// equal to the detector's threshold at the moment of firing.
    let magnitude: Double
}

/// Detects shake events from a stream of raw accelerometer samples.
///
/// The algorithm is intentionally simple: for each sample, compute the
/// total acceleration magnitude, subtract the expected 1 g of gravity,
/// take the absolute value, and fire a `ShakeEvent` if it exceeds the
/// configured threshold and we are not in cooldown. A single sample above
/// threshold is enough — callers should rely on `cooldownSamples` to
/// suppress duplicate events from the same physical motion.
///
/// The detector is orientation-agnostic. On M1 Pro the laptop-flat
/// gravity vector is on the -y axis, but the magnitude calculation
/// `√(x² + y² + z²)` treats any orientation identically.
///
/// **Thread safety:** callers must ensure `process(_:)` is only invoked
/// from one thread at a time. In the ShakeToEject helper the call site
/// is the single IOKit HID input report callback, which satisfies this
/// trivially. The class is `@unchecked Sendable` so it can be captured
/// in the `@Sendable` sample handler closure required by
/// `AccelerometerReader`.
///
/// **Purity:** `process(_:)` never reads a clock and has no external
/// dependencies. Given the same sequence of samples it always produces
/// the same sequence of events, which makes it trivial to unit-test.
final class ShakeDetector: @unchecked Sendable {
    /// Dynamic-acceleration threshold in g. A sample whose
    /// `|magnitude - 1.0|` meets or exceeds this value fires an event.
    var threshold: Double

    /// Number of samples to suppress after firing an event, to prevent
    /// a single physical shake from producing multiple events.
    var cooldownSamples: Int

    /// Remaining samples to suppress before the next event can fire.
    /// Exposed for testing; production callers should not touch this.
    private(set) var samplesRemainingInCooldown: Int = 0

    init(threshold: Double = 0.3, cooldownSamples: Int = 800) {
        self.threshold = threshold
        self.cooldownSamples = cooldownSamples
    }

    /// Consumes one accelerometer sample. Returns a `ShakeEvent` if the
    /// sample triggered a shake, or `nil` if the detector is in cooldown
    /// or the sample is below threshold.
    func process(_ sample: HIDReport) -> ShakeEvent? {
        if samplesRemainingInCooldown > 0 {
            samplesRemainingInCooldown -= 1
            return nil
        }

        let magnitude = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
        let dynamic = abs(magnitude - 1.0)

        guard dynamic >= threshold else {
            return nil
        }

        samplesRemainingInCooldown = cooldownSamples
        return ShakeEvent(magnitude: dynamic)
    }

    /// Manually reset the cooldown counter without emitting an event.
    /// Used by tests and, in Phase 7+, by the UI "disarm" path so that
    /// arming again starts from a fresh state.
    func reset() {
        samplesRemainingInCooldown = 0
    }
}
```

Notes:
- `(x*x + y*y + z*z).squareRoot()` is used instead of `sqrt(x*x + y*y + z*z)` because `Double.squareRoot()` avoids an extra `import Foundation` math dependency — it is a Swift stdlib member. `import Foundation` is still present for `abs`, which is fine.
- `samplesRemainingInCooldown` is `private(set)` so tests can observe its state without being able to corrupt it.
- `reset()` is included for the Phase 7 disarm path — not used in Phase 2, but it is one line and avoids a churn commit in Phase 7.

---

### Task 2: Write `ShakeDetectorTests.swift`

**Files:**
- Create: `Tests/ShakeDetectorTests.swift`

- [ ] **Step 1: Create the test file**

Write `Tests/ShakeDetectorTests.swift` with this EXACT content:

```swift
import Testing
import Foundation

struct ShakeDetectorTests {
    // MARK: - Helpers

    /// Builds a sample with a specified magnitude on the y axis (arbitrary
    /// choice — the detector is orientation-agnostic).
    private func sample(y: Double, x: Double = 0, z: Double = 0) -> HIDReport {
        HIDReport(x: x, y: y, z: z)
    }

    /// Feeds a sequence of identical samples into the detector and returns
    /// how many events fired.
    private func feed(_ detector: ShakeDetector, _ sample: HIDReport, count: Int) -> Int {
        var events = 0
        for _ in 0..<count {
            if detector.process(sample) != nil {
                events += 1
            }
        }
        return events
    }

    // MARK: - No-event cases

    @Test("Stationary laptop (gravity on -y, |a| = 1.0) fires no events")
    func stationaryNoEvents() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 800)
        let atRest = sample(y: -1.0)
        #expect(feed(detector, atRest, count: 1000) == 0)
    }

    @Test("Gentle motion below threshold fires no events")
    func belowThresholdNoEvents() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 800)
        // |a| = 1.25, dynamic = 0.25 (below 0.3 threshold)
        let gentle = sample(y: -1.25)
        #expect(feed(detector, gentle, count: 1000) == 0)
    }

    @Test("Sample with dynamic magnitude exactly at threshold fires an event")
    func exactlyAtThresholdFires() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 800)
        // |a| = 1.3, dynamic = 0.3 (exactly at threshold)
        let atThreshold = sample(y: -1.3)
        #expect(detector.process(atThreshold) != nil)
    }

    // MARK: - Single-event cases

    @Test("A single above-threshold sample fires exactly one event")
    func aboveThresholdFiresOnce() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 800)
        // |a| = 1.5, dynamic = 0.5
        let shake = sample(y: -1.5)
        let event = detector.process(shake)
        #expect(event != nil)
        #expect(event?.magnitude == 0.5)
    }

    @Test("Event magnitude is the dynamic acceleration, not the total")
    func eventMagnitudeIsDynamic() {
        let detector = ShakeDetector(threshold: 0.1, cooldownSamples: 10)
        // x=3, y=0, z=4  -> |a| = 5.0, dynamic = 4.0
        let event = detector.process(sample(y: 0, x: 3, z: 4))
        #expect(event?.magnitude == 4.0)
    }

    // MARK: - Cooldown cases

    @Test("A shake during cooldown does not fire a second event")
    func cooldownSuppressesSecondEvent() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 100)
        let shake = sample(y: -1.5)
        _ = detector.process(shake) // fires
        // All subsequent shakes during cooldown should be suppressed
        var suppressedEvents = 0
        for _ in 0..<50 {
            if detector.process(shake) != nil {
                suppressedEvents += 1
            }
        }
        #expect(suppressedEvents == 0)
    }

    @Test("After the cooldown window, a new shake fires a new event")
    func cooldownExpiresAllowsNewEvent() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 10)
        let shake = sample(y: -1.5)
        _ = detector.process(shake) // fires, cooldown = 10

        // Feed 10 at-rest samples — cooldown should drain to zero
        let atRest = sample(y: -1.0)
        for _ in 0..<10 {
            #expect(detector.process(atRest) == nil)
        }
        #expect(detector.samplesRemainingInCooldown == 0)

        // Next shake should fire
        let second = detector.process(shake)
        #expect(second != nil)
    }

    @Test("Cooldown decrements even when given non-shake samples")
    func cooldownDecrementsOnAnySample() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 5)
        _ = detector.process(sample(y: -1.5)) // fires, cooldown = 5
        #expect(detector.samplesRemainingInCooldown == 5)
        _ = detector.process(sample(y: -1.0)) // at-rest — cooldown decrements
        #expect(detector.samplesRemainingInCooldown == 4)
        _ = detector.process(sample(y: -1.0))
        #expect(detector.samplesRemainingInCooldown == 3)
    }

    // MARK: - Configuration

    @Test("Raising the threshold suppresses previously-firing shakes")
    func higherThresholdSuppresses() {
        let detector = ShakeDetector(threshold: 1.0, cooldownSamples: 0)
        // dynamic = 0.5 — below new threshold
        let mediumShake = sample(y: -1.5)
        #expect(detector.process(mediumShake) == nil)
    }

    @Test("Lowering the threshold catches previously-silent motion")
    func lowerThresholdCatches() {
        let detector = ShakeDetector(threshold: 0.05, cooldownSamples: 0)
        // dynamic = 0.1 — above new threshold
        let tinyMotion = sample(y: -1.1)
        #expect(detector.process(tinyMotion) != nil)
    }

    @Test("reset() clears cooldown without firing an event")
    func resetClearsCooldown() {
        let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 1000)
        _ = detector.process(sample(y: -1.5)) // fires, cooldown = 1000
        #expect(detector.samplesRemainingInCooldown == 1000)
        detector.reset()
        #expect(detector.samplesRemainingInCooldown == 0)

        // Next shake should immediately fire
        #expect(detector.process(sample(y: -1.5)) != nil)
    }

    // MARK: - Orientation agnosticism

    @Test("Detector treats shake on x axis the same as y axis")
    func orientationAgnostic() {
        let xShake = sample(y: 0, x: 1.5, z: 0)
        let yShake = sample(y: 1.5, x: 0, z: 0)
        let zShake = sample(y: 0, x: 0, z: 1.5)

        for shake in [xShake, yShake, zShake] {
            let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 0)
            let event = detector.process(shake)
            #expect(event != nil)
            #expect(event?.magnitude == 0.5)
        }
    }
}
```

---

### Task 3: Add `Helper/ShakeDetector.swift` to the test target

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Update the test target's sources list**

The `ShakeToEjectTests` target currently has:

```yaml
    sources:
      - path: Tests
      - path: Helper/HIDReport.swift
```

Change it to:

```yaml
    sources:
      - path: Tests
      - path: Helper/HIDReport.swift
      - path: Helper/ShakeDetector.swift
```

Use the Edit tool to match the two-line block and replace with the three-line block.

- [ ] **Step 2: Regenerate the project**

```bash
xcodegen generate
```

Expected: clean regeneration.

- [ ] **Step 3: Run tests**

```bash
xcodebuild test \
  -project ShakeToEject.xcodeproj \
  -scheme ShakeToEjectTests \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with all 10 HIDReportTests plus 12 new ShakeDetectorTests passing — 22 tests total.

---

### Task 4: Add `--detect` mode to `Helper/main.swift`

**Files:**
- Modify: `Helper/main.swift`

The existing `main.swift` has a `--print` mode. Add a parallel `--detect` mode that uses the `ShakeDetector` on top of the reader and prints `shake!` lines when events fire.

- [ ] **Step 1: Update the usage text**

The `printUsage()` function currently prints:

```
Usage:
  \(programName) --version    Print version and exit
  \(programName) --print      Stream accelerometer samples to stdout
                   (diagnostic lines go to stderr — pipe with 2>/dev/null to hide)
```

Replace with:

```
Usage:
  \(programName) --version    Print version and exit
  \(programName) --print      Stream raw accelerometer samples to stdout
  \(programName) --detect     Stream shake events to stdout
                   (diagnostic lines go to stderr — pipe with 2>/dev/null to hide)
```

- [ ] **Step 2: Add the `--detect` branch**

Immediately after the `if args.contains("--print")` block, add a parallel block for `--detect`. The new block:

```swift
if args.contains("--detect") {
    let detector = ShakeDetector(threshold: 0.3, cooldownSamples: 800)
    let reader = AccelerometerReader { sample in
        if let event = detector.process(sample) {
            let line = String(format: "shake! magnitude=%+.4f", event.magnitude)
            print(line)
            fflush(stdout)
        }
    }

    do {
        try reader.start()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

    CFRunLoopRun()
    reader.stop()
    exit(0)
}
```

Place this block immediately after the `if args.contains("--print")` closing brace and before the `printUsage()` fall-through at the bottom.

- [ ] **Step 3: Verify via diff**

Run `git diff Helper/main.swift` and confirm the only changes are (a) the usage string update, (b) the new `if args.contains("--detect") { ... }` block.

---

### Task 5: Rebuild and run the full test suite

- [ ] **Step 1: Regenerate and rebuild helper**

```bash
xcodegen generate
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEjectHelper -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Rebuild app (helper embed)**

```bash
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run tests**

```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with 22 tests passing (10 HIDReport + 12 ShakeDetector).

---

### Task 6: Smoke test — verify `--detect` fires on a real shake

This task requires physically moving the laptop. The subagent runs step 1 and hands off to the user for step 2.

- [ ] **Step 1: Confirm the binary runs and waits for motion**

Run the helper for 2 seconds with the laptop stationary and confirm **no** `shake!` lines appear:

```bash
build/Build/Products/Debug/com.mcsoftware.ShakeToEject.Helper --detect > /tmp/detect-out.txt 2>/tmp/detect-err.txt &
PID=$!
sleep 2
kill $PID 2>/dev/null
sleep 0.3
echo "stdout lines: $(wc -l < /tmp/detect-out.txt)"
head /tmp/detect-out.txt
echo "stderr head:"
head -5 /tmp/detect-err.txt
```

Expected: 0 stdout lines (no events), stderr has the usual `[accel]` progress lines.

- [ ] **Step 2: HAND OFF TO USER** — shake the laptop

Ask the user to run:

```bash
build/Build/Products/Debug/com.mcsoftware.ShakeToEject.Helper --detect 2>/dev/null
```

And then:

- Gently tap or lift the laptop → expect one `shake! magnitude=…` line per discrete motion.
- Shake more vigorously → expect larger magnitudes.
- Hold still → expect no events.
- Press Ctrl+C to stop.

If the user sees:
- **Events on every motion with ~1 second between events (from cooldown)** → ✅ success.
- **Events fire constantly even when still** → threshold too low, or a bug in the magnitude calculation. Triage with the user; most likely cause is the gravity subtraction being wrong.
- **No events even on vigorous shakes** → threshold too high, or the detector is not being called.

- [ ] **Step 3: User reports result**

User replies with one of:
- **"events fire on motion, silent at rest"** → proceed to commit.
- **"always fires" or "never fires"** → triage before committing.

---

### Task 7: Commit Phase 2

- [ ] **Step 1: Review the diff**

```bash
git status --short
git diff --stat
```

Expected untracked / modified set:
```
 M Helper/main.swift
 M project.yml
?? Helper/ShakeDetector.swift
?? Tests/ShakeDetectorTests.swift
?? docs/superpowers/plans/2026-04-10-shaketoeject-phase-2-shake-detector.md
```

- [ ] **Step 2: Stage Phase 2 files**

```bash
git add Helper/ShakeDetector.swift \
        Tests/ShakeDetectorTests.swift \
        Helper/main.swift \
        project.yml \
        docs/superpowers/plans/2026-04-10-shaketoeject-phase-2-shake-detector.md
```

- [ ] **Step 3: Verify staged set**

```bash
git status --short
```

Expected: exactly the five files above, all staged.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Phase 2: pure shake detection algorithm + tests + --detect CLI mode

- Add Helper/ShakeDetector.swift — a final class wrapping a simple
  magnitude-minus-gravity detector with configurable threshold and
  sample-count cooldown. No clock access, no IOKit, pure function of
  the input sample sequence. @unchecked Sendable so it can be captured
  in the AccelerometerReader's @Sendable handler closure.
- Add Tests/ShakeDetectorTests.swift — 12 Swift Testing cases covering
  stationary silence, below-threshold silence, exactly-at-threshold
  firing, single-shake magnitude, cooldown suppression, cooldown
  expiry, cooldown decrement on any sample, threshold reconfiguration
  up and down, reset() behaviour, and orientation agnosticism across
  x/y/z axes.
- Add Helper/ShakeDetector.swift to the ShakeToEjectTests target
  sources in project.yml so the test bundle compiles its own copy
  (same pattern as Helper/HIDReport.swift).
- Extend Helper/main.swift with a `--detect` CLI mode that composes
  ShakeDetector on top of AccelerometerReader and prints one
  `shake! magnitude=…` line per detected event to stdout.

Verified: stationary laptop fires zero events in 2s, physical motion
fires discrete events with 1s cooldown, 22/22 tests passing.

Phase 2 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify clean tree**

```bash
git status
git log --oneline -4
```

Expected: `nothing to commit, working tree clean` and the Phase 2 commit on top of Phase 1 on top of Phase 0 on top of Initial Commit.

---

## Phase 2 Exit Criteria Checklist

- [ ] `ShakeDetector.swift` is pure (no IOKit, no clock, no mutable globals).
- [ ] `ShakeDetectorTests.swift` has 12 cases and `xcodebuild test` reports 22/22 green.
- [ ] `xcodebuild -scheme ShakeToEjectHelper build` succeeds.
- [ ] `xcodebuild -scheme ShakeToEject build` succeeds (embed step still works).
- [ ] `--detect` mode fires zero events when the laptop is stationary for at least 2 seconds.
- [ ] `--detect` mode fires one event per physical motion with roughly 1-second cooldown between events.
- [ ] Phase 2 is committed on `main`.

---

## What Phase 2 Does Not Do

- No time-based cooldown. Cooldown is measured in samples; the caller is responsible for converting seconds to samples using the known sample rate.
- No sophisticated vibration detection (STA/LTA, CUSUM, kurtosis — spank's approach). Our target motion is "laptop picked up", not "finger tap", which is a much coarser signal.
- No adaptive threshold. The threshold is fixed at init and only changes if the caller assigns a new value. Phase 7's UI will expose this.
- No event types beyond `ShakeEvent(magnitude:)`. No "pickup vs drop" distinction. No direction information. Phase 7+ can add these if the UX wants them.
- No sample buffering or rolling window. Pure single-sample detection with cooldown.
- No XPC publication of events. Phase 3 adds the XPC listener; Phase 2 publishes only via the CLI `--detect` mode.
- No wiring into the main app. Phase 4+ bridges the helper's events into the app.
