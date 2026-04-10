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
