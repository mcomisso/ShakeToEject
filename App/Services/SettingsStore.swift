import Foundation
import Observation
import ServiceManagement

/// Enumeration of how the warning UI presents itself on screen.
/// Only `.fullscreen` is implemented in Phase 8; `.notch` and
/// `.auto` are placeholder cases that fall through to fullscreen
/// until Phase 9 implements the notch expansion window.
enum WarningStyle: String, CaseIterable, Identifiable, Sendable {
    case fullscreen
    case notch
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullscreen: return "Fullscreen"
        case .notch: return "Notch (compact)"
        case .auto: return "Auto"
        }
    }

    var detail: String? {
        switch self {
        case .fullscreen: return "Full-screen warning, visible on every display."
        case .notch: return "Compact capsule drops out of the MacBook notch. Non-notched screens fall back to fullscreen."
        case .auto: return "Notch capsule on notched Macs, fullscreen elsewhere."
        }
    }
}

/// Main-actor-isolated, @Observable facade over `UserDefaults`.
///
/// Every configurable parameter the user can touch lives here. The
/// store is instantiated once in `AppDelegate` and passed to every
/// consumer (sensor, warning coordinator, dashboard view).
///
/// Mutations trigger `didSet` handlers that forward values to the
/// running services:
/// - `sensitivityThreshold` and `cooldownSeconds` push live updates
///   into the already-running `SensorService` via `onSensorChange`
///   (set by AppDelegate at launch).
/// - `launchAtLogin` invokes `SMAppService.mainApp` register /
///   unregister synchronously.
/// - `countdownSeconds` and `warningStyle` don't push — consumers
///   read the current value on every `trigger()` call.
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Keys
    private enum Key {
        static let countdownSeconds = "settings.countdownSeconds"
        static let sensitivityThreshold = "settings.sensitivity"
        static let cooldownSeconds = "settings.cooldownSeconds"
        static let warningStyle = "settings.warningStyle"
        static let launchAtLogin = "settings.launchAtLogin"
        static let excludedVolumeNames = "settings.excludedVolumeNames"
    }

    // MARK: - Defaults
    static let defaultCountdownSeconds = 5
    static let defaultSensitivityThreshold = 0.3
    static let defaultCooldownSeconds = 1.0
    static let defaultWarningStyle: WarningStyle = .fullscreen
    static let defaultLaunchAtLogin = false

    // MARK: - Ranges
    static let countdownRange = 1...30
    static let sensitivityRange = 0.05...1.0
    static let cooldownRange = 0.5...5.0

    /// The assumed native HID sample rate of the BMI286 accelerometer
    /// on M1 Pro, measured in Phase 1. Cooldown seconds are converted
    /// to sample counts for the detector using this constant.
    static let assumedSampleRateHz: Double = 800.0

    // MARK: - Observable state

    var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Key.countdownSeconds) }
    }

    var sensitivityThreshold: Double {
        didSet {
            UserDefaults.standard.set(sensitivityThreshold, forKey: Key.sensitivityThreshold)
            onSensitivityChange?(sensitivityThreshold)
        }
    }

    var cooldownSeconds: Double {
        didSet {
            UserDefaults.standard.set(cooldownSeconds, forKey: Key.cooldownSeconds)
            onCooldownChange?(Int((cooldownSeconds * Self.assumedSampleRateHz).rounded()))
        }
    }

    var warningStyle: WarningStyle {
        didSet { UserDefaults.standard.set(warningStyle.rawValue, forKey: Key.warningStyle) }
    }

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Volume names the user has marked as "never auto-eject".
    /// Drives matching any of these names are skipped by both the
    /// manual Eject All action and the shake-triggered eject flow,
    /// and appear with a 🔒 prefix in the menu bar.
    var excludedVolumeNames: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedVolumeNames).sorted(), forKey: Key.excludedVolumeNames)
        }
    }

    // MARK: - Live-update hooks

    /// Called on every sensitivity mutation with the new value in g.
    /// AppDelegate wires this to `SensorService.setThreshold(_:)`.
    var onSensitivityChange: ((Double) -> Void)?

    /// Called on every cooldown mutation with the new value in samples
    /// (seconds × 800). AppDelegate wires this to
    /// `SensorService.setCooldownSamples(_:)`.
    var onCooldownChange: ((Int) -> Void)?

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let storedCountdown = defaults.integer(forKey: Key.countdownSeconds)
        self.countdownSeconds = storedCountdown > 0 ? storedCountdown : Self.defaultCountdownSeconds

        let storedSensitivity = defaults.double(forKey: Key.sensitivityThreshold)
        self.sensitivityThreshold = storedSensitivity > 0 ? storedSensitivity : Self.defaultSensitivityThreshold

        let storedCooldown = defaults.double(forKey: Key.cooldownSeconds)
        self.cooldownSeconds = storedCooldown > 0 ? storedCooldown : Self.defaultCooldownSeconds

        let storedStyle = defaults.string(forKey: Key.warningStyle) ?? Self.defaultWarningStyle.rawValue
        self.warningStyle = WarningStyle(rawValue: storedStyle) ?? Self.defaultWarningStyle

        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)

        let storedExcluded = defaults.array(forKey: Key.excludedVolumeNames) as? [String] ?? []
        self.excludedVolumeNames = Set(storedExcluded)
    }

    /// Reads the current cooldown value as a detector sample count.
    /// Used by `SensorService` at startup before any didSet has fired.
    var cooldownSamples: Int {
        Int((cooldownSeconds * Self.assumedSampleRateHz).rounded())
    }

    // MARK: - Launch at login

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                NSLog("[settings] launch at login: registered")
            } else {
                try service.unregister()
                NSLog("[settings] launch at login: unregistered")
            }
        } catch {
            NSLog("[settings] launch at login error: \(error.localizedDescription)")
        }
    }
}
