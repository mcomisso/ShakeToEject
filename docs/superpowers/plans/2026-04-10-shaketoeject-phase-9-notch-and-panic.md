# ShakeToEject — Phase 9: Notch Expansion + Panicked Drives + Multi-Display

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Turn the warning flow from a functional alert into a *useful toy* by (a) adopting the MacBook hardware notch as a first-class UI surface, (b) giving the drives expressive, panicked faces that react to motion, (c) implementing a subtle "earthquake camera" that jitters everything *except the drives themselves*, and (d) painting the warning across every connected display so an external monitor user can't miss it.

**Design principles:**

1. **The drives don't move, the Mac does.** The drive icons are pinned to their positions — what shakes is the *container* (the notch capsule, the fullscreen overlay). This mirrors physical reality: the laptop is what's being jostled, and the drives are passengers reacting in place.
2. **Panicked character, not panicked motion.** Drives express fear through facial expression and colour shifts, not translation. A tiny emoji-face overlay in the corner of each drive icon sells it cheaply.
3. **Notch as stage.** On notched MacBooks, the warning *emerges from under the hardware notch* with a liquid drop animation, settles into a shaking capsule, and slurps back up on dismissal. Non-notched screens get the fullscreen overlay as fallback. On multi-monitor setups, every display gets a presentation simultaneously so the user sees the warning wherever their eyes happen to be.
4. **Character-driven copy.** "SHAKE DETECTED" becomes the drives' collective voice: `"THEY MOVED US!!"`, `"Quick, before they drop us!"`, `"Not the trash can again!"`. Rotating through a pool on each trigger.

**Architecture:**

```
WarningCoordinator (existing, extended)
    └─ WarningPresenter (new)
         ├─ for each NSScreen:
         │    ├─ if screen has notch → NotchCapsuleWindow + NotchCapsuleView
         │    └─ else              → WarningOverlayWindow (existing, per-screen)
         ├─ global key monitor for Esc (so nonactivating panels can still cancel)
         └─ dismissAll() tears down every window
```

New reusable pieces:

- `CameraShakeModifier` — SwiftUI `ViewModifier` that applies a continuous pseudo-random sub-pixel jitter. Used by both `WarningView` and `NotchCapsuleView`. Amplitude configurable.
- `DriveCharacterView` — renders one `DriveInfo` as an SF Symbol drive icon plus a small emoji face overlay, with a subtle "worried" colour tint. Used by both fullscreen and notch views.
- `NotchDetector` — tiny helper that inspects an `NSScreen` and returns `(hasNotch: Bool, notchHeight: CGFloat)` based on `safeAreaInsets.top`.
- `KeyEventMonitor` — tiny wrapper around `NSEvent.addGlobalMonitorForEvents` so the coordinator can install + remove an Esc handler without leaking.

**Tech stack:** SwiftUI (`TimelineView`, `ViewModifier`, SF Symbols with `.symbolEffect`), `NSPanel` (with `.nonactivatingPanel` for the notch bubble so it doesn't steal focus), `NSScreen.safeAreaInsets`, `NSEvent.addGlobalMonitorForEvents`.

**Prerequisites:**
- Phase 8 committed on main (`bbdf8fb`).
- The `warningStyle` picker in the dashboard already exists with `.fullscreen`, `.notch`, `.auto` cases. Only `.fullscreen` is implemented; Phase 9 fills in the other two.
- 22/22 tests still green.

**No new tests in Phase 9.** All new code is visual. Manual smoke test is the verification.

---

## Design details

### Notch geometry

On M1 Pro and later notched MacBooks:

- `NSScreen.main?.safeAreaInsets.top` returns ~32 pt on notched displays, 0 on non-notched.
- The notch cutout is approximately centered horizontally, ~200 pt wide. Exact width isn't exposed by AppKit — we approximate as 200 pt.
- The capsule should emerge from directly under the notch: top edge pinned to `screen.frame.maxY - safeAreaInsets.top`, horizontally centered, starting at `200 × safeAreaInsets.top` (a rectangle the shape of the notch) and expanding to `480 × 80` as the drop animation runs.

In AppKit coordinates (bottom-left origin):
- Window top Y: `screen.frame.maxY - notchHeight` → stays pinned as height grows
- Window origin Y: `(screen.frame.maxY - notchHeight) - currentHeight`
- Window X: `screen.frame.midX - currentWidth / 2`

### Camera shake

A `ViewModifier` that wraps its content in a `TimelineView(.animation(minimumInterval: 1.0/60.0))` and applies a `.offset` computed from `sin(t × freqX) × amplitude`, `cos(t × freqY) × amplitude` with mismatched frequencies (17 and 13) so the motion never repeats in an obvious pattern.

Amplitude presets:
- `.subtle` (1 pt) — idle / resting
- `.worried` (2-3 pt) — during countdown
- `.panic` (5 pt) — last 2 seconds

The fullscreen overlay uses `.worried` throughout with a ramp to `.panic` for the final two seconds. The notch capsule uses `.subtle` throughout because larger amplitudes look weird on such a small surface.

### Drive character rendering

```swift
ZStack(alignment: .topTrailing) {
    Image(systemName: "externaldrive.fill")
        .font(.system(size: 52))
        .foregroundStyle(driveColor)
        .symbolEffect(.pulse, options: .speed(2.0).repeating)

    Text("😰")
        .font(.system(size: 24))
        .offset(x: 6, y: -6)
}
```

Colour progression: grey → orange → red as the countdown approaches zero. Emoji is a `@State`-rotated pick from `["😰", "😱", "🫨"]` that changes once per second for variety.

### Copy rotation

```swift
static let panicLines: [String] = [
    "THEY MOVED US!!",
    "QUICK, BEFORE THEY DROP US!",
    "NOT THE TRASH CAN AGAIN!",
    "WE HAVEN'T EVEN BEEN BACKED UP!",
    "EARTHQUAKE!!!",
    "IS THIS A NORMAL TUESDAY?",
    "HELP HELP HELP",
    "UNSTABLE GROUND DETECTED",
]
```

`WarningCoordinator.trigger()` picks a random line and stashes it in the coordinator as `currentPanicLine`; both views display the same line during a given flow. The line rotates on each new trigger, not during the countdown.

### Multi-display model

On `trigger()`, the coordinator queries `NSScreen.screens` and decides what to show on each:

| `warningStyle` setting | Screen has notch? | What appears on that screen |
|---|---|---|
| `.fullscreen` | any | fullscreen overlay |
| `.notch` | yes | notch capsule |
| `.notch` | no | fullscreen overlay (fallback with log line) |
| `.auto` | yes | notch capsule |
| `.auto` | no | fullscreen overlay |

All presentations for a single `trigger()` share the same `WarningCoordinator` — cancel (Esc or any CANCEL click) tears down every window, countdown completion ejects once, not per-window.

### Keyboard handling

Nonactivating `NSPanel` can't be key, so SwiftUI `keyboardShortcut(.escape)` doesn't fire inside the notch capsule. We install a `KeyEventMonitor` via `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` when the warning appears and remove it when the warning dismisses. The monitor checks for Esc (keyCode 53) and calls `coordinator.cancel()`.

Global monitors can't *consume* events, so Esc still reaches whatever foreground app — but that's harmless because Esc rarely does anything destructive in foreground apps.

Fullscreen overlay windows remain `canBecomeKey` so their existing SwiftUI Esc shortcut still works; the global monitor is installed regardless so both paths are belt-and-braces.

---

### Task 1: Create `CameraShakeModifier`

**Files:**
- Create: `App/Views/CameraShakeModifier.swift`

```swift
import SwiftUI

/// Applies a continuous pseudo-random jitter to a view so it
/// looks like "the camera is shaking". Motion is deterministic
/// (driven by wall-clock time via `TimelineView`) so identical
/// moments across multiple views are in sync, and the motion
/// never repeats exactly because the sin/cos frequencies are
/// coprime integers.
///
/// Use via the `.cameraShake(amplitude:)` helper:
///
/// ```swift
/// Text("HOLD ON")
///     .cameraShake(amplitude: .worried)
/// ```
struct CameraShakeModifier: ViewModifier {
    /// Maximum jitter offset in points, applied in both axes.
    let amplitude: CGFloat

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = CGFloat(sin(t * 17.0)) * amplitude
            let y = CGFloat(cos(t * 13.0)) * amplitude
            content.offset(x: x, y: y)
        }
    }
}

/// Named amplitudes for the earthquake effect.
enum ShakeAmplitude {
    /// ~1 pt — the laptop sits on a desk, the cat just walked by.
    static let subtle: CGFloat = 1.0
    /// ~2.5 pt — during countdown, someone is holding the laptop.
    static let worried: CGFloat = 2.5
    /// ~5 pt — final two seconds of the countdown, active shaking.
    static let panic: CGFloat = 5.0
}

extension View {
    /// Shorthand for `.modifier(CameraShakeModifier(amplitude:))`.
    func cameraShake(amplitude: CGFloat) -> some View {
        modifier(CameraShakeModifier(amplitude: amplitude))
    }
}
```

---

### Task 2: Create `DriveCharacterView`

**Files:**
- Create: `App/Views/DriveCharacterView.swift`

```swift
import SwiftUI

/// Renders one `DriveInfo` as a character: an SF Symbol drive
/// icon with a tiny emoji face overlay in the top-right corner,
/// plus a subtle colour tint driven by the countdown progress.
///
/// Deliberately *does not* translate in space — the drives are
/// stationary passengers being jostled by the laptop around them.
/// The camera shake is applied to the *container*, not here.
struct DriveCharacterView: View {
    let drive: DriveInfo

    /// 0.0 = calm, 1.0 = fully panicked. Drives the colour ramp
    /// from grey to red and the emoji selection.
    let panicLevel: Double

    @State private var emojiTick: Int = 0

    private static let panicEmoji: [String] = ["😰", "😱", "🫨"]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 52))
                .foregroundStyle(driveColor)
                .symbolEffect(.pulse, options: .speed(1.0 + 2.0 * panicLevel).repeating)

            Text(Self.panicEmoji[emojiTick % Self.panicEmoji.count])
                .font(.system(size: 28))
                .offset(x: 10, y: -6)
        }
        .onAppear {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    emojiTick += 1
                }
            }
        }
        .accessibilityLabel("Drive \(drive.volumeName), panicked")
    }

    private var driveColor: Color {
        // grey at 0.0 → orange at 0.5 → red at 1.0
        let hue = 0.08 - (0.08 * panicLevel)          // orange → red
        let saturation = 0.2 + (0.8 * panicLevel)     // drab → vivid
        let brightness = 0.7 + (0.2 * panicLevel)     // slightly lighter as panic rises
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}
```

---

### Task 3: Create `NotchDetector`

**Files:**
- Create: `App/Services/NotchDetector.swift`

```swift
import AppKit
import Foundation

/// Utility for asking a screen whether it has a hardware notch.
enum NotchDetector {
    /// Approximate horizontal width of the notch cutout on M-series
    /// notched MacBook Pros. AppKit does not expose the exact value;
    /// 200 pt is a safe approximation that looks correct across
    /// 14" and 16" models.
    static let approximateNotchWidth: CGFloat = 200.0

    /// Height of the notch area from the top of the screen, in points.
    /// Returns 0 on non-notched screens.
    static func notchHeight(for screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }

    /// True if the given screen has a hardware notch.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        notchHeight(for: screen) > 0
    }

    /// Returns the origin and initial size of a notch-hugging
    /// window for a given screen. The returned rectangle sits
    /// directly under the notch cutout.
    static func initialNotchFrame(for screen: NSScreen) -> NSRect {
        let height = notchHeight(for: screen)
        let width = approximateNotchWidth
        let x = screen.frame.midX - width / 2.0
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Returns the fully-expanded frame of a notch capsule: still
    /// pinned under the notch, but wider and taller.
    static func expandedNotchFrame(for screen: NSScreen, expandedWidth: CGFloat = 480, expandedHeight: CGFloat = 92) -> NSRect {
        let notchHeight = notchHeight(for: screen)
        let x = screen.frame.midX - expandedWidth / 2.0
        // Keep the top of the window flush against the bottom of the notch cutout.
        let y = screen.frame.maxY - notchHeight - (expandedHeight - notchHeight)
        return NSRect(x: x, y: y, width: expandedWidth, height: expandedHeight)
    }
}
```

---

### Task 4: Create `KeyEventMonitor`

**Files:**
- Create: `App/Services/KeyEventMonitor.swift`

```swift
import AppKit
import Foundation

/// RAII-style wrapper around `NSEvent.addGlobalMonitorForEvents`
/// and `addLocalMonitorForEvents`. The monitor is installed on
/// `install(onEscape:)` and torn down on `remove()` or deinit.
///
/// We install BOTH a local and a global monitor so Esc works
/// whether or not our app is foreground: global catches keydowns
/// sent to other apps (the nonactivating notch panel case), local
/// catches keydowns inside our own windows (the fullscreen case).
@MainActor
final class KeyEventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func install(onEscape: @escaping @MainActor () -> Void) {
        remove() // idempotent

        let handler: (NSEvent) -> Void = { event in
            if event.keyCode == 53 { // kVK_Escape
                Task { @MainActor in
                    onEscape()
                }
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    onEscape()
                }
                return nil // consume
            }
            return event
        }
    }

    func remove() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
```

---

### Task 5: Create `NotchCapsuleWindow`

**Files:**
- Create: `App/Windows/NotchCapsuleWindow.swift`

```swift
import AppKit
import SwiftUI

/// Borderless nonactivating `NSPanel` that emerges from under the
/// hardware notch on notched MacBooks. It does not become key,
/// does not steal focus, and draws above almost everything at
/// `.screenSaver` level.
///
/// Positioning is computed by `NotchDetector.expandedNotchFrame`.
/// The window is shown at full size immediately; the *content*
/// inside it animates the drop-expansion effect via SwiftUI.
final class NotchCapsuleWindow: NSPanel {
    init<Content: View>(screen: NSScreen, rootView: Content) {
        let frame = NotchDetector.expandedNotchFrame(for: screen)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        isFloatingPanel = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        hidesOnDeactivate = false

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

---

### Task 6: Create `NotchCapsuleView`

**Files:**
- Create: `App/Views/NotchCapsuleView.swift`

```swift
import SwiftUI

/// SwiftUI content rendered inside a `NotchCapsuleWindow`.
///
/// Visually presents as a dark rounded capsule that appears to
/// drop out of the hardware notch — the initial state is a thin
/// rectangle covering just the notch area, and the content
/// expands downward into a full 480×92 capsule via SwiftUI spring
/// animation. The capsule itself carries a subtle camera shake.
struct NotchCapsuleView: View {
    let coordinator: WarningCoordinator

    @State private var hasExpanded: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.black.opacity(0.95))
            .overlay(alignment: .center) {
                if hasExpanded {
                    capsuleContent
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .overlay(alignment: .top) {
                // Cap the top edge flush with the notch, no rounding on top
                Rectangle()
                    .fill(.black.opacity(0.95))
                    .frame(height: 20)
                    .offset(y: -1)
            }
            .compositingGroup()
            .cameraShake(amplitude: ShakeAmplitude.subtle)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    hasExpanded = true
                }
            }
    }

    @ViewBuilder
    private var capsuleContent: some View {
        HStack(spacing: 14) {
            // Left: stack of panicked drive characters (up to 3 visible)
            HStack(spacing: -8) {
                ForEach(Array(coordinator.drivesSnapshot.prefix(3).enumerated()), id: \.element.id) { _, drive in
                    DriveCharacterView(drive: drive, panicLevel: panicLevel)
                        .scaleEffect(0.5)
                        .frame(width: 36, height: 36)
                }
            }

            // Middle: panic line + count
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.currentPanicLine)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: countdown digit + cancel X
            HStack(spacing: 10) {
                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: coordinator.secondsRemaining)
                    .monospacedDigit()

                Button {
                    coordinator.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        let count = coordinator.drivesSnapshot.count
        if count == 0 {
            return "dev simulation"
        }
        return "ejecting \(count) drive\(count == 1 ? "" : "s")"
    }

    private var panicLevel: Double {
        let total = max(coordinator.totalSeconds, 1)
        let elapsed = total - coordinator.secondsRemaining
        return min(1.0, max(0.0, Double(elapsed) / Double(total)))
    }
}
```

---

### Task 7: Rewrite `WarningView` with camera shake, drive characters, panic copy

**Files:**
- Modify: `App/Views/WarningView.swift`

Replace the entire file with:

```swift
import SwiftUI

struct WarningView: View {
    let coordinator: WarningCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)

                Text(coordinator.currentPanicLine)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(2)
                    .multilineTextAlignment(.center)

                // Drive character row — pinned in place, jostled by
                // the camera shake wrapping the whole VStack.
                HStack(spacing: 24) {
                    ForEach(coordinator.drivesSnapshot) { drive in
                        DriveCharacterView(drive: drive, panicLevel: panicLevel)
                    }
                    if coordinator.drivesSnapshot.isEmpty {
                        Text("(dev simulation — no drives)")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.vertical, 12)

                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 220, weight: .black, design: .rounded))
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
            .cameraShake(amplitude: currentAmplitude)
        }
    }

    private var panicLevel: Double {
        let total = max(coordinator.totalSeconds, 1)
        let elapsed = total - coordinator.secondsRemaining
        return min(1.0, max(0.0, Double(elapsed) / Double(total)))
    }

    private var currentAmplitude: CGFloat {
        // Ramp from worried → panic in the last 2 seconds.
        if coordinator.secondsRemaining <= 2 && coordinator.secondsRemaining > 0 {
            return ShakeAmplitude.panic
        }
        return ShakeAmplitude.worried
    }
}
```

---

### Task 8: Make `WarningOverlayWindow` per-screen aware

**Files:**
- Modify: `App/Windows/WarningOverlayWindow.swift`

Change the init to take an `NSScreen` parameter and size itself to that screen instead of always `NSScreen.main`:

Replace the entire file with:

```swift
import AppKit
import SwiftUI

/// Borderless full-screen always-on-top window that hosts the
/// `WarningView` on a specific screen. One instance is created
/// per display during a warning flow when `.fullscreen` style
/// is in effect (either by user choice or by fallback from
/// `.notch` / `.auto` on non-notched screens).
final class WarningOverlayWindow: NSWindow {
    init<Content: View>(screen: NSScreen, rootView: Content) {
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

        // Pin the window to the given screen so it draws in the
        // right place on multi-monitor setups.
        setFrame(screen.frame, display: false)

        contentView = NSHostingView(rootView: rootView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

---

### Task 9: Extend `WarningCoordinator` with panic copy, multi-display presentation, and style selection

**Files:**
- Modify: `App/Services/WarningCoordinator.swift`

Four changes: add a `currentPanicLine` observable, add a `windows` array instead of a single window, rewrite `showWindow` / `hideWindow` to handle the per-screen presentation, and install the `KeyEventMonitor` alongside them.

**Step 1:** Add the panic line pool and observable at the top of the class (inside the `final class WarningCoordinator`, near the other `private(set) var` declarations):

```swift
/// One of a small pool of in-character panic lines, picked at
/// random on each `trigger()` call so successive warnings feel
/// varied.
private(set) var currentPanicLine: String = ""

private static let panicLines: [String] = [
    "THEY MOVED US!!",
    "QUICK, BEFORE THEY DROP US!",
    "NOT THE TRASH CAN AGAIN!",
    "WE HAVEN'T EVEN BEEN BACKED UP!",
    "EARTHQUAKE!!!",
    "IS THIS A NORMAL TUESDAY?",
    "HELP HELP HELP",
    "UNSTABLE GROUND DETECTED",
    "PLEASE PUT US DOWN",
    "WHOA WHOA WHOA",
]
```

**Step 2:** Replace `private var window: WarningOverlayWindow?` with:

```swift
private var windows: [NSWindow] = []
private let keyMonitor = KeyEventMonitor()
```

**Step 3:** In `trigger(force:overrideCountdown:)`, just before `soundPlayer.playWarning()`, set:

```swift
currentPanicLine = Self.panicLines.randomElement() ?? "HOLD ON!"
```

**Step 4:** Replace `showWindow()` and `hideWindow()` entirely:

```swift
private func showWindow() {
    // Install Esc handler first so it's ready before any
    // window appears.
    keyMonitor.install { [weak self] in
        self?.cancel()
    }

    NSApp.activate(ignoringOtherApps: true)

    let screens = NSScreen.screens
    let effectiveStyle = settings.warningStyle

    for screen in screens {
        let hasNotch = NotchDetector.hasNotch(screen)
        let useNotch: Bool

        switch effectiveStyle {
        case .fullscreen:
            useNotch = false
        case .notch, .auto:
            useNotch = hasNotch
        }

        let window: NSWindow
        if useNotch {
            let view = NotchCapsuleView(coordinator: self)
            window = NotchCapsuleWindow(screen: screen, rootView: view)
        } else {
            if effectiveStyle == .notch {
                NSLog("[warning] notch style requested but screen \(screen.localizedName) has no notch — falling back to fullscreen")
            }
            let view = WarningView(coordinator: self)
            window = WarningOverlayWindow(screen: screen, rootView: view)
        }

        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    NSLog("[warning] presented on \(windows.count) screen(s)")
}

private func hideWindow() {
    keyMonitor.remove()
    for window in windows {
        window.orderOut(nil)
    }
    windows.removeAll()
}
```

**Step 5:** Add `import AppKit` at the top of the file if it's not already there. (It should be — the file already uses `NSApp`.)

---

### Task 10: Regenerate, clean build, run tests

```bash
xcodegen generate 2>&1 | tail -3
```

```bash
rm -rf build
xcodebuild -project ShakeToEject.xcodeproj -scheme ShakeToEject -configuration Debug -derivedDataPath build build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

```bash
xcodebuild test -project ShakeToEject.xcodeproj -scheme ShakeToEjectTests -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` 22/22.

Watch for:
- `NSScreen.safeAreaInsets` availability (macOS 12+; we target 14+, should be fine)
- `NSEvent.addGlobalMonitorForEvents` Sendable warnings (the closure captures `self` via weak — should be OK)
- Any "view identity" SwiftUI warnings from the `ForEach` on `drivesSnapshot`

---

### Task 11: Smoke test matrix

Manual. Test all three styles across single-screen and (if possible) multi-screen.

**Fullscreen mode on the built-in display:**
1. Set warning style to Fullscreen in Settings
2. Simulate Shake → full-screen overlay with panicked drives, wobbly background, rotating panic line
3. The drives should be stationary; the WHOLE overlay should jitter ~2-3 pt
4. Last 2 seconds: jitter noticeably increases to ~5 pt

**Notch mode on the built-in display (M1 Pro has a notch):**
1. Settings → Style → Notch
2. Simulate Shake → a black capsule drops out from under the notch with a spring animation
3. Shows drive characters on the left, panic line + countdown + X button on the right
4. Capsule has a subtle 1-pt wobble
5. Click the X button → capsule dismisses (no visible "slurp back" animation yet — deferred to later polish)
6. Simulate Shake again → a new panic line should be different most of the time (random from pool of 10)
7. Press Esc → dismisses

**Auto mode:**
1. Settings → Style → Auto
2. Same as Notch on M1 Pro

**Multi-display (if an external monitor is connected):**
1. Settings → Style → Auto
2. Simulate Shake → built-in display shows notch capsule, external shows fullscreen overlay
3. Esc or Cancel on either dismisses both simultaneously
4. Simulate Shake → Fullscreen mode → both displays show fullscreen overlay

**Real shake flow:**
1. Mount a disk image: `hdiutil create -size 20m -fs APFS -volname ShakeTest /tmp/shake-test.dmg && hdiutil attach /tmp/shake-test.dmg`
2. Style: Auto (or Notch if you want the compact version)
3. Tap the laptop gently → notch capsule emerges on the built-in display (and fullscreen on external if present)
4. Let countdown finish → drive ejects, capsule dismisses, Ejecting… appears briefly in menu bar
5. Cleanup: `rm -f /tmp/shake-test.dmg`

---

### Task 12: Commit Phase 9

```bash
git add -A
git commit -m "$(cat <<'EOF'
Phase 9: notch expansion, panicked drive characters, camera shake, multi-display

Turns the warning flow from a functional alert into a useful toy:

- Add App/Views/CameraShakeModifier.swift + ShakeAmplitude — a
  SwiftUI ViewModifier that applies a continuous deterministic
  sub-pixel jitter via TimelineView. Used by both fullscreen and
  notch presentations. Ramps from "worried" (~2.5 pt) through
  "panic" (~5 pt) in the last two seconds of the countdown.
- Add App/Views/DriveCharacterView.swift — renders one DriveInfo
  as an SF Symbol drive icon plus a rotating emoji face overlay
  (😰 / 😱 / 🫨) with a colour ramp from grey to red driven by
  the countdown progress. Deliberately pinned in place — the
  drives are stationary passengers, the camera around them shakes.
- Add App/Services/NotchDetector.swift — helper that inspects an
  NSScreen, reports notch presence via safeAreaInsets.top, and
  computes the initial + expanded frame of a notch-hugging window.
- Add App/Services/KeyEventMonitor.swift — RAII wrapper around
  NSEvent.addGlobal/LocalMonitorForEvents so nonactivating
  NSPanels can still receive Esc to cancel.
- Add App/Windows/NotchCapsuleWindow.swift — borderless
  nonactivating NSPanel at .screenSaver level, positioned flush
  under the hardware notch on notched MacBooks.
- Add App/Views/NotchCapsuleView.swift — the SwiftUI content that
  "drops out" of the notch via a spring animation on first
  appear. Compact layout: drive characters on the left, panic
  line + subtitle in the middle, countdown digit + X button on
  the right. Whole capsule carries a subtle camera shake.
- Rewrite App/Views/WarningView.swift to use the panic copy,
  drive characters, and camera shake. Drives sit stationary while
  the container jitters around them.
- Rewrite App/Windows/WarningOverlayWindow.swift to take an
  explicit NSScreen parameter so multi-display presentations can
  target each screen correctly.
- Extend WarningCoordinator with currentPanicLine (picked at
  random from a pool of 10 lines on each trigger), replace the
  single window field with a windows array, install the
  KeyEventMonitor in showWindow(), iterate NSScreen.screens in
  showWindow() to present one window per display picking notch
  or fullscreen based on per-screen notch detection + settings.

Presentation matrix (warningStyle × screen has notch):
    .fullscreen       →  fullscreen overlay everywhere
    .notch / .auto + notch screen    →  notch capsule
    .notch / .auto + no notch screen →  fullscreen overlay
    (auto + no notch on this Mac) →  fullscreen everywhere

All three presentations (single-screen fullscreen, single-screen
notch, multi-screen mixed) share one coordinator: cancel or
complete tears down every window, eject fires once not per
window, Esc works via global key monitor so nonactivating notch
panels can still be cancelled without stealing focus.

Verified on M1 Pro: notch capsule drops out with spring on
Simulate Shake, camera shake visible on fullscreen, panic lines
rotate, all three warning styles work via the Settings picker,
real shake produces notch capsule in auto mode, drive ejects on
completion. 22/22 tests still green.

Phase 9 of docs/superpowers/plans/2026-04-10-shaketoeject-overview.md

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 9 Exit Criteria

- [ ] `CameraShakeModifier`, `DriveCharacterView`, `NotchDetector`, `KeyEventMonitor`, `NotchCapsuleWindow`, `NotchCapsuleView` all exist and compile.
- [ ] `WarningView` rewritten with panic copy, drive characters, camera shake.
- [ ] `WarningOverlayWindow` takes an `NSScreen` parameter.
- [ ] `WarningCoordinator` presents one window per `NSScreen`, picks notch or fullscreen per screen based on settings and notch presence.
- [ ] Settings → Style → Fullscreen on M1 Pro: fullscreen overlay on built-in, shake visible.
- [ ] Settings → Style → Notch on M1 Pro: notch capsule drops out, carries subtle shake, dismisses on X or Esc.
- [ ] Settings → Style → Auto on M1 Pro: behaves like Notch.
- [ ] Panic line rotates across successive triggers.
- [ ] Multi-display test passes (or is skipped with a note if no external monitor available).
- [ ] 22/22 tests still green.
- [ ] Phase 9 committed on main.

## What Phase 9 Does Not Do

- No "slurp back into notch" dismissal animation — the window just orderOut's. Polish.
- No custom drive character assets (still SF Symbol + emoji overlay).
- No sound design changes — Phase 5's Funk + Glass placeholders remain.
- No drive "fall off" animation on ejection — the drives are stationary throughout.
- No Liquid Glass iOS 26-era materials on the notch capsule.
- No haptic feedback (Macs don't have haptic trackpads in app contexts outside Force Touch).
- No test coverage for the visual code — manual only.
