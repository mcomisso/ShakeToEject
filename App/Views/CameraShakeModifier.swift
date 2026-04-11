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
///     .cameraShake(amplitude: ShakeAmplitude.worried)
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
