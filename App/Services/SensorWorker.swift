import Foundation

/// Owns the dedicated background thread that runs the IOKit HID run loop.
///
/// `SensorWorker` is the low-level lifecycle wrapper: it spins up a named
/// `Thread`, captures its `CFRunLoop` reference so callers can stop it
/// from another thread, runs `AccelerometerReader` on that run loop, and
/// invokes a handler closure whenever the `ShakeDetector` emits an event.
///
/// Callers that need to present state to the UI should wrap this in a
/// `@MainActor`-isolated `SensorService` and hop to the main actor from
/// the worker's handler. `SensorWorker` itself is non-main so it can
/// safely own the blocking `CFRunLoopRun()` call.
///
/// **Thread safety:** the public `start()`/`stop()` methods may be called
/// from any thread; they serialise via `runLoopReady` and the atomic
/// `runLoop` reference. The handler closure is always invoked on the
/// worker's private thread — never on the caller.
final class SensorWorker: @unchecked Sendable {
    typealias ShakeHandler = @Sendable (ShakeEvent) -> Void

    private let handler: ShakeHandler
    private let detector: ShakeDetector

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)

    init(
        threshold: Double,
        cooldownSamples: Int,
        handler: @escaping ShakeHandler
    ) {
        self.handler = handler
        self.detector = ShakeDetector(threshold: threshold, cooldownSamples: cooldownSamples)
    }

    /// Starts the dedicated thread and blocks the caller until the
    /// worker's `CFRunLoop` reference has been captured (so a follow-up
    /// `stop()` from the same thread is race-free).
    func start() {
        guard thread == nil else { return }
        let newThread = Thread { [weak self] in
            self?.runSensorLoop()
        }
        newThread.name = "com.mcsoftware.ShakeToEject.Sensor"
        newThread.qualityOfService = .userInitiated
        thread = newThread
        newThread.start()
        runLoopReady.wait()
    }

    /// Stops the worker's run loop. After this returns the worker thread
    /// will exit naturally.
    func stop() {
        if let loop = runLoop {
            CFRunLoopStop(loop)
        }
        thread = nil
        runLoop = nil
    }

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

    // MARK: - Worker thread body

    private func runSensorLoop() {
        runLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()

        let reader = AccelerometerReader { [weak self] sample in
            guard let self, let event = self.detector.process(sample) else { return }
            self.handler(event)
        }

        do {
            try reader.start()
        } catch {
            NSLog("[sensor] AccelerometerReader.start() failed: \(error)")
            return
        }

        // Blocks until `CFRunLoopStop` is called on this thread's run loop.
        CFRunLoopRun()
        reader.stop()
    }
}
