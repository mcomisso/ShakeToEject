# ShakeToEject — Phase 1: IOKit HID Accelerometer Reader

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the helper the ability to stream raw x/y/z accelerometer samples from the M1 Pro's BMI286 IMU via IOKit HID, with the report-byte parser fully unit-tested and independently verifiable on a standalone command-line run under `sudo`.

**Architecture:** Add a pure `HIDReport` byte parser (hardware-free, fully unit-tested) in `Helper/HIDReport.swift`. Add an `AccelerometerReader` wrapper around `IOHIDManager` that registers an input report callback, reconstructs `self` from the C context parameter via `Unmanaged`, and forwards parsed samples to a `@Sendable` handler closure. Update `Helper/main.swift` with a `--print` CLI mode that streams samples to stdout at ~100 Hz. Add a Swift Testing unit test target (`ShakeToEjectTests`) that compiles its own copy of `HIDReport.swift` — no test host, no library target, no `@testable import` shenanigans.

**Tech Stack:** Swift 6, Swift Testing, IOKit HID (`IOHIDManager`, `IOHIDDeviceRegisterInputReportCallback`), `CFRunLoopRun()` for the read loop, `Unmanaged` for the C callback bridge.

**Prerequisites:**
- Phase 0 committed on main (commit `fe1eb71` or later).
- `xcodegen generate && xcodebuild -scheme ShakeToEject build` currently succeeds.
- Working on an M1 Pro (or any M2+) with `docs/hardware-probe-m1pro.txt` confirming the `AppleSPUHIDDevice` with `PrimaryUsagePage=65280`, `PrimaryUsage=3`, `MaxInputReportSize=22`, `VendorID=1452`.
- Developer signing team selected in Xcode for both targets.

**Hardware facts baked into this phase (from `docs/hardware-probe-m1pro.txt`):**
- `VendorID` = `1452` (Apple)
- `ProductID` = `33028`
- Primary Usage Page = `0xFF00` (`65280`)
- Accelerometer `PrimaryUsage` = `3`
- Input report size = `22` bytes
- Data layout: signed int32 little-endian at byte offsets `6`, `10`, `14` for x/y/z; divide by `65536` to get g
- Callback rate ~100 Hz (decimated from ~800 Hz native)

---

### Task 1: Add `HIDReport.swift` with pure byte parser

**Files:**
- Create: `Helper/HIDReport.swift`

- [ ] **Step 1: Write the type**

Create `Helper/HIDReport.swift` with this exact content:

```swift
import Foundation

/// A single accelerometer sample decoded from a 22-byte HID input report
/// produced by the Apple SPU HID accelerometer (Bosch BMI286 IMU).
///
/// The report layout is undocumented by Apple. The format used here was
/// reverse-engineered by `olvvier/apple-silicon-accelerometer` and confirmed
/// against the M1 Pro report descriptor captured in
/// `docs/hardware-probe-m1pro.txt`.
///
/// Each axis is a signed Int32 in little-endian order. The raw integer is
/// divided by `0x10000` (65536) to yield a floating-point value in g.
struct HIDReport: Equatable {
    static let expectedSize = 22
    static let xOffset = 6
    static let yOffset = 10
    static let zOffset = 14
    static let rawScale: Double = 65536.0

    let x: Double
    let y: Double
    let z: Double

    /// Parses a raw HID input report into a sample. Returns `nil` if the
    /// buffer is shorter than `expectedSize`.
    ///
    /// The buffer may be longer than 22 bytes (callers should pass the
    /// entire buffer they received from the HID callback) — extra bytes
    /// after the z-axis are ignored.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> HIDReport? {
        guard bytes.count >= expectedSize, let base = bytes.baseAddress else {
            return nil
        }
        let xRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: xOffset, as: Int32.self))
        let yRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: yOffset, as: Int32.self))
        let zRaw = Int32(littleEndian: base.loadUnaligned(fromByteOffset: zOffset, as: Int32.self))
        return HIDReport(
            x: Double(xRaw) / rawScale,
            y: Double(yRaw) / rawScale,
            z: Double(zRaw) / rawScale
        )
    }
}
```

Notes:
- `loadUnaligned(fromByteOffset:as:)` is used because HID reports are packed without alignment guarantees. `loadUnaligned` is available on macOS 11+ and is the correct tool for this job.
- `Int32(littleEndian:)` is a no-op on Apple Silicon (which is already little-endian) but is explicit for future portability.
- The type is `internal` (Swift default). Both the Helper target and the test target compile their own copies, so no `public` is needed.
- `HIDReport: Equatable` gives us free equality for test assertions.

---

### Task 2: Write `HIDReportTests.swift` with concrete synthetic test vectors

**Files:**
- Create: `Tests/HIDReportTests.swift`

This task is pure TDD: the tests are written before any hardware-touching code runs. They verify that given specific byte sequences, the parser produces exactly the expected doubles.

- [ ] **Step 1: Write the test file**

Create `Tests/HIDReportTests.swift` with this exact content:

```swift
import Testing
import Foundation

struct HIDReportTests {
    // MARK: - Helpers

    /// Builds a 22-byte HID report with explicit int32 little-endian values at
    /// the documented offsets. Non-axis bytes are zero-filled.
    private func makeReport(x: Int32, y: Int32, z: Int32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: HIDReport.expectedSize)
        writeInt32LE(x, into: &bytes, at: HIDReport.xOffset)
        writeInt32LE(y, into: &bytes, at: HIDReport.yOffset)
        writeInt32LE(z, into: &bytes, at: HIDReport.zOffset)
        return bytes
    }

    private func writeInt32LE(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
        let unsigned = UInt32(bitPattern: value)
        bytes[offset]     = UInt8(unsigned & 0xFF)
        bytes[offset + 1] = UInt8((unsigned >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((unsigned >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((unsigned >> 24) & 0xFF)
    }

    private func parse(_ bytes: [UInt8]) -> HIDReport? {
        bytes.withUnsafeBytes { HIDReport.parse($0) }
    }

    // MARK: - Tests

    @Test("Parses an all-zero report to zero acceleration on every axis")
    func parsesZeros() throws {
        let report = try #require(parse(makeReport(x: 0, y: 0, z: 0)))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 0)
    }

    @Test("Parses a 1g value on the z axis (laptop sitting flat)")
    func parsesOneGOnZ() throws {
        // 1.0g == raw 65536
        let report = try #require(parse(makeReport(x: 0, y: 0, z: 65536)))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 1.0)
    }

    @Test("Parses a -1g value on the z axis (laptop lid face down)")
    func parsesNegativeOneGOnZ() throws {
        let report = try #require(parse(makeReport(x: 0, y: 0, z: -65536)))
        #expect(report.z == -1.0)
    }

    @Test("Parses fractional g values correctly")
    func parsesFractionalG() throws {
        // 0.5g == raw 32768
        let report = try #require(parse(makeReport(x: 32768, y: -32768, z: 16384)))
        #expect(report.x == 0.5)
        #expect(report.y == -0.5)
        #expect(report.z == 0.25)
    }

    @Test("Parses extreme int32 values without overflow")
    func parsesExtremes() throws {
        let report = try #require(parse(makeReport(x: .max, y: .min, z: 0)))
        #expect(report.x == Double(Int32.max) / HIDReport.rawScale)
        #expect(report.y == Double(Int32.min) / HIDReport.rawScale)
        #expect(report.z == 0)
    }

    @Test("Returns nil for a buffer shorter than expectedSize")
    func rejectsShortBuffer() {
        let tooShort = [UInt8](repeating: 0, count: HIDReport.expectedSize - 1)
        #expect(parse(tooShort) == nil)
    }

    @Test("Returns nil for an empty buffer")
    func rejectsEmptyBuffer() {
        #expect(parse([]) == nil)
    }

    @Test("Accepts a buffer longer than expectedSize and ignores trailing bytes")
    func acceptsLongBuffer() throws {
        var bytes = makeReport(x: 0, y: 0, z: 65536)
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        let report = try #require(parse(bytes))
        #expect(report.z == 1.0)
    }

    @Test("Zero-fills ignored bytes at offsets 0-5 and 18-21 without corrupting axes")
    func ignoresNonAxisBytes() throws {
        var bytes = makeReport(x: 0, y: 0, z: 65536)
        // Scribble on every byte that is NOT an axis slot
        for i in 0..<HIDReport.xOffset {
            bytes[i] = 0xAA
        }
        for i in (HIDReport.zOffset + 4)..<HIDReport.expectedSize {
            bytes[i] = 0x55
        }
        let report = try #require(parse(bytes))
        #expect(report.x == 0)
        #expect(report.y == 0)
        #expect(report.z == 1.0)
    }

    @Test("HIDReport.expectedSize matches the M1 Pro hardware report descriptor")
    func expectedSizeMatchesHardware() {
        // The probe in docs/hardware-probe-m1pro.txt shows
        // MaxInputReportSize = 22 for the accelerometer device.
        #expect(HIDReport.expectedSize == 22)
    }
}
```

Notes:
- Uses Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) per the plan's testing preferences.
- `try #require(parse(...))` unwraps the optional and fails cleanly if the parse returns nil.
- The `makeReport` helper synthesizes valid-layout byte arrays so tests are self-contained — no hardware capture files needed.
- The last test (`expectedSizeMatchesHardware`) is a documentation anchor: if a future contributor changes `expectedSize` away from 22, the test fails with a clear message pointing at the hardware probe.

---

### Task 3: Add `ShakeToEjectTests` target to `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the new target block**

Append this target to the existing `targets:` map in `project.yml`, immediately after the `ShakeToEjectHelper:` target:

```yaml
  ShakeToEjectTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
      - path: Helper/HIDReport.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mcsoftware.ShakeToEject.Tests
        PRODUCT_NAME: ShakeToEjectTests
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        SWIFT_EMIT_LOC_STRINGS: NO
```

Design notes:
- `type: bundle.unit-test` creates a standalone test bundle with no test host. It runs via `xcodebuild test` directly.
- `sources` includes `Tests/` (the tests themselves) plus the specific file under test (`Helper/HIDReport.swift`). The test bundle compiles its own copy of `HIDReport.swift` — this is the simplest way to make a helper-target-local type accessible to tests without introducing a shared library target.
- We are intentionally NOT including the whole `Helper/` directory in test sources. Pulling in `main.swift` would give us duplicate `@main` / top-level code; pulling in `AccelerometerReader.swift` would require linking IOKit from the test bundle. We want only the pure, hardware-free code under test.
- `PRODUCT_BUNDLE_IDENTIFIER` is distinct from the app and helper IDs so signing won't conflict.

- [ ] **Step 2: Remove the `Tests/.gitkeep` placeholder**

The `.gitkeep` file was added in Phase 0 so `Tests/` existed before any source files. Now that `Tests/HIDReportTests.swift` is present, the placeholder is no longer needed:

```bash
rm Tests/.gitkeep
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `Created project at ...`. A new `ShakeToEjectTests` scheme should appear in the generated project.

- [ ] **Step 4: Verify the test target exists**

```bash
grep -E "ShakeToEjectTests" ShakeToEject.xcodeproj/project.pbxproj | head -10
```

Expected: several matches including a PBXNativeTarget with productType `com.apple.product-type.bundle.unit-test`.

---

### Task 4: Run the HIDReport tests and watch them pass

- [ ] **Step 1: Run tests from the command line**

```bash
xcodebuild test \
  -project ShakeToEject.xcodeproj \
  -scheme ShakeToEjectTests \
  -destination 'platform=macOS' \
  2>&1 | tail -40
```

Expected: `** TEST SUCCEEDED **` near the bottom, with the 10 test cases from `HIDReportTests` reported as passed.

If any test fails, do NOT proceed. Fix the failure first. Possible failure causes and diagnostics:
- **"Cannot find type 'HIDReport'"** — the test target is not compiling `Helper/HIDReport.swift`. Check `sources` in `project.yml` task 3 and regenerate.
- **"Swift Testing not available"** — check Xcode version (Xcode 26 ships Swift Testing natively; no SPM dep needed).
- **Wrong values in the parse result** — check byte offsets in `HIDReport.swift` match the offsets used in `writeInt32LE` test helper.

---

### Task 5: Add `AccelerometerReader.swift` — the IOKit HID wrapper

**Files:**
- Create: `Helper/AccelerometerReader.swift`

- [ ] **Step 1: Write the reader**

Create `Helper/AccelerometerReader.swift` with this exact content:

```swift
import Foundation
import IOKit
import IOKit.hid

/// Reads raw accelerometer samples from the Apple SPU HID accelerometer
/// (Bosch BMI286 IMU) exposed via IOKit HID under `AppleSPUHIDDevice`.
///
/// Matching criteria (vendor ID, primary usage page, primary usage) were
/// derived from the M1 Pro probe in `docs/hardware-probe-m1pro.txt`.
///
/// **Thread safety:** The input report callback is invoked by the HID
/// subsystem on the thread that runs the CFRunLoop we schedule against.
/// The handler closure is declared `@Sendable`; the reader itself is
/// `@unchecked Sendable` because its only mutable state is the C callback
/// buffer, which is written only by the HID callback on a single thread.
///
/// **Privileges:** `IOHIDManagerOpen` will fail with `kIOReturnNotPrivileged`
/// unless the process runs as root. The SMAppService-registered helper in
/// Phase 4 satisfies this. For standalone testing, launch with `sudo`.
final class AccelerometerReader: @unchecked Sendable {
    typealias SampleHandler = @Sendable (HIDReport) -> Void

    /// Apple's USB vendor ID, used to narrow HID matching.
    static let vendorIDApple = 1452
    /// Primary usage page of the Apple SPU HID IMU devices.
    static let primaryUsagePage = 0xFF00
    /// Primary usage of the accelerometer sub-device.
    static let primaryUsageAccelerometer = 3
    /// Oversized input report buffer (the spec is 22 bytes; we allocate
    /// extra headroom in case the driver ever bumps the report size).
    static let inputBufferSize = 64

    private let manager: IOHIDManager
    private let handler: SampleHandler
    private let buffer: UnsafeMutablePointer<UInt8>

    init(handler: @escaping SampleHandler) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.handler = handler
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.inputBufferSize)
        self.buffer.initialize(repeating: 0, count: Self.inputBufferSize)
    }

    deinit {
        buffer.deinitialize(count: Self.inputBufferSize)
        buffer.deallocate()
    }

    /// Opens the IOKit HID manager, locates the accelerometer device, and
    /// registers an input report callback. The callback runs on the CFRunLoop
    /// of the calling thread — the caller is responsible for running that
    /// run loop (e.g. via `CFRunLoopRun()`).
    func start() throws {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorIDApple,
            kIOHIDPrimaryUsagePageKey as String: Self.primaryUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.primaryUsageAccelerometer,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AccelerometerReaderError.openFailed(ioReturn: openResult)
        }

        guard let devicesCF = IOHIDManagerCopyDevices(manager) else {
            throw AccelerometerReaderError.deviceNotFound
        }
        let devices = devicesCF as! Set<IOHIDDevice>
        guard let device = devices.first else {
            throw AccelerometerReaderError.deviceNotFound
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            CFIndex(Self.inputBufferSize),
            Self.inputReportCallback,
            selfPtr
        )

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    /// Unschedules from the run loop and closes the HID manager. Safe to
    /// call multiple times.
    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback bridge

    /// The @convention(c) callback invoked by IOKit HID when a new input
    /// report arrives. It reconstructs `self` from the context pointer and
    /// forwards parsed samples to the handler.
    private static let inputReportCallback: IOHIDReportCallback = {
        context, _, _, _, _, reportBytes, reportLength in
        guard let context else { return }
        let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
        let buffer = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(reportBytes),
            count: reportLength
        )
        if let sample = HIDReport.parse(buffer) {
            reader.handler(sample)
        }
    }
}

enum AccelerometerReaderError: Error, CustomStringConvertible {
    case openFailed(ioReturn: IOReturn)
    case deviceNotFound

    var description: String {
        switch self {
        case .openFailed(let ioReturn):
            let hex = String(ioReturn, radix: 16, uppercase: true)
            if ioReturn == kIOReturnNotPrivileged {
                return "IOHIDManagerOpen failed: kIOReturnNotPrivileged (0x\(hex)) — run with sudo."
            }
            return "IOHIDManagerOpen failed with IOReturn 0x\(hex)."
        case .deviceNotFound:
            return "Accelerometer device not found. Verify hardware with `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice`."
        }
    }
}
```

Key implementation decisions baked in:
- **Matching criteria** use all three keys (`VendorID`, `PrimaryUsagePage`, `PrimaryUsage`) for maximum specificity. If the match ever returns zero devices on a supported Mac, we know something changed in the driver rather than having a loose match picking up the wrong sensor.
- **Buffer oversizing** (`inputBufferSize = 64`) guards against future driver changes that might increase the report size. The parser ignores extra bytes, so this is safe.
- **`Unmanaged.passUnretained`** avoids a retain cycle. The caller owns the reader and is responsible for keeping it alive; the callback only borrows a reference.
- **No actor isolation.** Phase 1 exists solely to prove the reader works on the command line. Phase 3 will wrap the reader in an XPC service that handles cross-actor coordination.
- **Error messages cite `kIOReturnNotPrivileged` explicitly** because "forgot to sudo" is by far the most likely failure mode during Phase 1 testing.

---

### Task 6: Update `Helper/main.swift` with a `--print` streaming mode

**Files:**
- Modify: `Helper/main.swift`

- [ ] **Step 1: Replace the stub with the real main**

Replace the entire contents of `Helper/main.swift` with this:

```swift
import Foundation

// Phase 1: the helper can open the accelerometer and stream samples to
// stdout for interactive verification. Phase 2 adds shake detection.
// Phase 3 replaces the CLI with an XPC listener.

let version = "0.1.0"
let args = Array(CommandLine.arguments.dropFirst())
let programName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "helper"

func printUsage() {
    let usage = """
    ShakeToEject helper \(version)

    Usage:
      \(programName) --version    Print version and exit
      \(programName) --print      Stream accelerometer samples (requires sudo)

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

if args.contains("--version") {
    print(version)
    exit(0)
}

if args.contains("--print") {
    let reader = AccelerometerReader { sample in
        let line = String(
            format: "%+.4f\t%+.4f\t%+.4f",
            sample.x, sample.y, sample.z
        )
        print(line)
        fflush(stdout)
    }

    do {
        try reader.start()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }

    // Block until interrupted (Ctrl+C). The reader's callbacks fire on
    // this run loop.
    CFRunLoopRun()

    // CFRunLoopRun() only returns if the run loop is explicitly stopped,
    // which we do not do in --print mode. Unreachable in practice.
    reader.stop()
    exit(0)
}

printUsage()
exit(0)
```

Notes:
- `programName` uses `NSString.lastPathComponent` to strip the full path when the binary is invoked via an absolute path (which is typical when launched by launchd or by `sudo /path/to/helper`).
- `fflush(stdout)` after each `print` makes the stream observable in real time — without it, stdout line-buffering collides with piping and tail-like observation.
- Output format is `±0.0000\t±0.0000\t±0.0000` — fixed width, tab-separated, human-readable and machine-parseable. No header line (easier to pipe through `awk`, `cut`, etc.).

---

### Task 7: Regenerate, build both targets, run tests again

- [ ] **Step 1: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: clean regeneration, no errors.

- [ ] **Step 2: Build the helper target**

```bash
xcodebuild \
  -project ShakeToEject.xcodeproj \
  -scheme ShakeToEjectHelper \
  -configuration Debug \
  -derivedDataPath build \
  build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build the app target (which embeds the helper)**

```bash
xcodebuild \
  -project ShakeToEject.xcodeproj \
  -scheme ShakeToEject \
  -configuration Debug \
  -derivedDataPath build \
  build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. The post-build script should successfully embed and re-sign the helper (it now contains real IOKit code but the signing path is unchanged).

- [ ] **Step 4: Re-run tests**

```bash
xcodebuild test \
  -project ShakeToEject.xcodeproj \
  -scheme ShakeToEjectTests \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 10 tests passing.

---

### Task 8: Hardware smoke test — stream live samples

**This task requires root privileges and cannot be fully automated. The subagent executes steps 1-2 and then hands off to the user for step 3.**

- [ ] **Step 1: Locate the built helper binary**

```bash
HELPER="$(find build/Build/Products/Debug -type f -name 'com.mcsoftware.ShakeToEject.Helper' | head -1)"
echo "Helper binary: $HELPER"
file "$HELPER"
```

Expected: two paths exist — one loose in `Debug/` and one inside `ShakeToEject.app/Contents/MacOS/`. Either one will work for the smoke test; the loose one is slightly simpler.

- [ ] **Step 2: Verify the helper starts and prints usage without sudo**

```bash
"$HELPER" --version
```

Expected output: `0.1.0`.

```bash
"$HELPER"
```

Expected: usage block printed to stderr, process exits 0.

- [ ] **Step 3: HAND OFF TO USER** — run the helper under sudo and verify samples stream

The agent should stop here and ask the user to run:

```bash
sudo "$HELPER" --print
```

Expected output: continuous lines like

```
+0.0012	-0.0034	+0.9987
+0.0015	-0.0029	+0.9991
+0.0013	-0.0031	+0.9989
...
```

at roughly 100 lines per second. With the laptop sitting flat on a desk, `z` should be very close to `+1.0000` (gravity) and `x`/`y` should be near zero. Lift the laptop and the values should visibly change.

Press Ctrl+C to stop.

If the user sees:
- **"IOHIDManagerOpen failed: kIOReturnNotPrivileged"** → they forgot sudo.
- **"Accelerometer device not found"** → the match criteria did not return a device. Double-check `ioreg -l -w0 | grep -A5 AppleSPUHIDDevice` and compare against the hardcoded vendor/usage IDs in `AccelerometerReader.swift`. This would indicate a hardware compatibility regression.
- **Samples flowing but z ≈ 0** → the laptop is on its side; rotate it flat.
- **Samples flowing but all axes ≈ 0** → the sensor is reporting zero; verify the byte offsets in `HIDReport.swift` against the hardware probe.

- [ ] **Step 4: User reports success or failure**

User replies with one of:
- **"samples streaming, z ≈ 1"** → smoke test passed, proceed to Task 9 (commit).
- **"error: <message>"** → triage the error with the user before proceeding. Do NOT commit until the smoke test passes.

---

### Task 9: Commit Phase 1

- [ ] **Step 1: Review the diff**

```bash
git status --short
git diff --stat
```

Expected untracked / modified set:
```
 M Helper/main.swift
 M project.yml
?? Helper/AccelerometerReader.swift
?? Helper/HIDReport.swift
?? Tests/HIDReportTests.swift
 D Tests/.gitkeep
?? docs/superpowers/plans/2026-04-10-shaketoeject-phase-1-hid-reader.md
```

- [ ] **Step 2: Stage the Phase 1 changes explicitly**

```bash
git add Helper/main.swift \
        Helper/HIDReport.swift \
        Helper/AccelerometerReader.swift \
        Tests/HIDReportTests.swift \
        Tests/.gitkeep \
        project.yml \
        docs/superpowers/plans/2026-04-10-shaketoeject-phase-1-hid-reader.md
```

- [ ] **Step 3: Verify the staged set**

```bash
git status --short
```

Expected: exactly the files above, all staged, nothing unstaged or untracked that belongs to Phase 1.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Phase 1: IOKit HID accelerometer reader + HIDReport parser + tests

- Add Helper/HIDReport.swift — pure byte-parser for the 22-byte input
  report from the Apple SPU HID accelerometer, decoding int32 LE x/y/z
  values at offsets 6/10/14 divided by 65536 to produce g-force samples
- Add Tests/HIDReportTests.swift — 10 Swift Testing cases covering
  zero, 1g, -1g, fractional, extreme, short-buffer, empty-buffer,
  long-buffer, non-axis-byte-scribbling, and hardware-size cases
- Add ShakeToEjectTests bundle.unit-test target in project.yml; the
  bundle compiles its own copy of Helper/HIDReport.swift so no host
  app or shared library target is required
- Add Helper/AccelerometerReader.swift — IOHIDManager wrapper matching
  on VendorID=1452, UsagePage=0xFF00, Usage=3 (verified against the
  M1 Pro hardware probe in docs/hardware-probe-m1pro.txt). The C
  input-report callback bridges to Swift via Unmanaged.
- Update Helper/main.swift with a `--print` CLI mode that streams
  x/y/z samples to stdout at ~100 Hz via CFRunLoopRun()

Verified by: sudo ./com.mcsoftware.ShakeToEject.Helper --print on M1 Pro,
z ≈ +1.0 with laptop flat; 10/10 HIDReportTests passing.

Phase 1 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Verify clean working tree**

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

```bash
git log --oneline -3
```

Expected: the Phase 1 commit on top of the Phase 0 commit on top of `Initial Commit`.

---

## Phase 1 Exit Criteria Checklist

- [ ] `xcodegen generate` runs cleanly.
- [ ] `xcodebuild -scheme ShakeToEjectHelper build` succeeds.
- [ ] `xcodebuild -scheme ShakeToEject build` succeeds (helper still embeds correctly).
- [ ] `xcodebuild test -scheme ShakeToEjectTests` reports `** TEST SUCCEEDED **` with 10 passing tests.
- [ ] `sudo <helper> --print` streams live samples at ~100 Hz on the dev M1 Pro, with z ≈ 1.0 when the laptop is flat.
- [ ] The helper prints `IOHIDManagerOpen failed: kIOReturnNotPrivileged` (not a crash) when run WITHOUT sudo — verifies the error path is wired.
- [ ] Phase 1 is committed on `main`.

---

## Discoveries during execution

The plan as originally written was based on olvvier's blog post and the high-level spank/macimu description. During execution on M1 Pro / macOS 26, several facts surfaced that are not captured in the original "Task Text" sections above. Anyone re-executing this plan should expect to encounter these and adjust.

### The HID match criteria are not specific enough

`{VendorID: 1452, UsagePage: 0xFF00, Usage: 3}` also matches the **Apple Internal Keyboard / Trackpad**, which declares the same vendor + primary usage page + primary usage triple for its own purposes. Its `MaxInputReportSize` is 108, not 22.

Fix (applied during execution): after enumeration, filter the returned device set by `IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey)` and keep only devices whose report size equals `HIDReport.expectedSize` (22).

### The SPU driver must be woken up before any reports are delivered

Even with the correct accelerometer device opened and a callback registered on a running run loop, **zero sample callbacks fire** until you set three properties on each `AppleSPUHIDDriver` kernel service:

- `SensorPropertyReportingState` = `1`
- `SensorPropertyPowerState` = `1`
- `ReportInterval` = `1000` (μs — produces ~1 kHz native rate on BMI286)

Fix (applied during execution): added a `wakeSPUDrivers()` method that enumerates `AppleSPUHIDDriver` via `IOServiceMatching` + `IOServiceGetMatchingServices` and calls `IORegistryEntrySetCFProperty` for each of the three keys on every matched service. Call this as the **first** step in `start()`, before HID matching or opening.

Reference: olvvier/apple-silicon-accelerometer, `sensor_worker()` in `macimu/_spu.py`, the "# wake the SPU drivers" block.

### IOHIDDeviceOpen is needed in addition to IOHIDManagerOpen

`IOHIDManagerOpen` claims matched devices at the manager level, but on M1 Pro / macOS 26 the per-device report delivery pipeline is only active after an explicit `IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone)` plus `IOHIDDeviceScheduleWithRunLoop(device, ...)`. Without these extra calls, everything else succeeds silently.

Fix (applied during execution): after selecting the filtered accelerometer device, call `IOHIDDeviceOpen` on it, register the input report callback, then `IOHIDDeviceScheduleWithRunLoop` before returning from `start()`.

### sudo is NOT required on macOS 26

Olvvier documents the Python library as "requires root (sudo)". On macOS 26 / M1 Pro we observed that a **code-signed** unprivileged process can successfully:

- Enumerate `AppleSPUHIDDriver` services
- Call `IORegistryEntrySetCFProperty` on all 8 matched services
- Open the HID manager and devices
- Receive input report callbacks at full rate

This was verified with `build/Build/Products/Debug/com.mcsoftware.ShakeToEject.Helper --print` from an unprivileged shell — samples stream immediately. This has downstream implications for Phase 4 (SMAppService privileged helper may not be strictly necessary). **Do not remove the privilege-error diagnostics**: if Apple tightens this in a future macOS release we want a clear error path.

### The actual sample rate is ~800 Hz, not ~100 Hz

Olvvier decimates 8:1 in their Python code to produce a nominal ~100 Hz. With our current `ReportInterval=1000` (1 kHz requested) and no decimation, we see roughly 800 reports/second on M1 Pro. Phase 2 may choose to decimate in the shake detector or to operate at full rate — decide there.

### The gravity axis on M1 Pro is -y, not -z

When the MacBook Pro sits flat on a desk, the BMI286 on M1 Pro reports `y ≈ -1.0g` with `x ≈ 0`, `z ≈ 0`. The sensor's physical mount orientation inside the chassis places gravity on the y axis, not z as intuitively assumed. Phase 2's magnitude computation uses `sqrt(x² + y² + z²) - 1.0` which is orientation-agnostic, so this does not affect shake detection — but it matters for any future "which way is down?" UI.

### Diagnostic logging is kept in the committed code

All the `[accel]`-prefixed stderr lines (match criteria, open results, device count, filter result, selected product, callback registration, run loop scheduling) are intentionally left in the committed version. They are off the stdout sample stream (stderr only) and can be suppressed with `2>/dev/null`. They exist so that future regressions — which are very likely given we depend on undocumented Apple kernel APIs — produce actionable output instead of mysterious silence.

---

## What Phase 1 Does Not Do

Explicitly out of scope for Phase 1 — these arrive in later phases:

- No shake detection algorithm (Phase 2). The reader just publishes every sample.
- No gyroscope reading. The gyro is also on the SPU (PrimaryUsage=9) but we have no use for it yet.
- No XPC listener (Phase 3). The reader is invoked from `main.swift` directly.
- No arm/disarm control surface (Phase 3). The reader starts when `--print` is passed and runs until Ctrl+C.
- No `AsyncStream`-based publisher. Phase 1 uses a raw synchronous handler; async adaptation can wait.
- No privileged launchd registration. The Phase 1 smoke test is raw `sudo`. SMAppService arrives in Phase 4.
- No resource cleanup beyond `stop()`. No signal handler for graceful shutdown; Ctrl+C just kills the process.
