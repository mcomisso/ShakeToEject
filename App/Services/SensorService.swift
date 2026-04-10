import Foundation
import Observation

/// Main-actor-isolated facade for the sensor pipeline. Views observe this
/// type via `@Observable`; the underlying `SensorWorker` does the blocking
/// IOKit work on a dedicated thread and hops back here for state updates.
///
/// The service is deliberately a thin shim — all meaningful work lives in
/// `SensorWorker`, `AccelerometerReader`, and `ShakeDetector`. This file's
/// only job is to expose observable state to SwiftUI and manage the
/// worker's lifecycle.
@MainActor
@Observable
final class SensorService {
    private(set) var isRunning: Bool = false
    private(set) var shakeCount: Int = 0
    private(set) var lastShakeMagnitude: Double = 0

    /// Called on the main actor once per detected shake, after the
    /// observable counters have been updated. Assign this from the
    /// owning `AppDelegate` to forward events to the warning flow.
    /// Assign before calling `start()` so the first shake after
    /// launch finds the handler in place.
    var onShake: ((ShakeEvent) -> Void)?

    private var worker: SensorWorker?

    /// Starts the sensor pipeline. No-op if already running.
    func start() {
        guard worker == nil else { return }

        let newWorker = SensorWorker { [weak self] event in
            // Called on the sensor worker thread. Hop to @MainActor for
            // observable state mutations so SwiftUI sees them safely.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.shakeCount += 1
                self.lastShakeMagnitude = event.magnitude
                self.onShake?(event)
            }
        }
        newWorker.start()
        worker = newWorker
        isRunning = true
    }

    /// Stops the sensor pipeline. No-op if already stopped.
    func stop() {
        worker?.stop()
        worker = nil
        isRunning = false
    }
}
