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
