import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter` for the `.notifyOnly` shake mode.
///
/// Responsibilities:
/// - Request notification authorization on demand (either proactively
///   when the user switches the mode picker, or lazily on first shake).
/// - Post a shake notification with a human-readable drive count when
///   the sensor fires and the user is in `.notifyOnly` mode.
///
/// The service deliberately does not retain any state about previous
/// authorization decisions — it re-reads the system's current status
/// every time so a user who toggled permission in System Settings
/// sees the correct behavior without restarting the app.
@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()

    /// Reads the current authorization status, and if it's
    /// `.notDetermined`, prompts the user. Returns whether the app is
    /// allowed to post notifications afterwards. Safe to call
    /// repeatedly — no-ops on the second call once resolved.
    func ensureAuthorization() async -> Bool {
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            NSLog("[notify] authorization denied — notifications will not appear")
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                NSLog("[notify] authorization prompt result: \(granted)")
                return granted
            } catch {
                NSLog("[notify] authorization request error: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Posts a one-shot banner summarizing how many non-excluded drives
    /// are currently connected. Returns `true` if the notification was
    /// successfully handed off to the system, `false` if authorization
    /// was denied or the add call errored — callers use the `false`
    /// return to fall back to the fullscreen warning flow.
    func postShakeNotification(driveCount: Int) async -> Bool {
        guard await ensureAuthorization() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "\(Bundle.main.displayName) — motion detected"
        content.body = Self.body(for: driveCount)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // fire immediately
        )

        do {
            try await center.add(request)
            NSLog("[notify] posted shake notification (\(driveCount) drive(s))")
            return true
        } catch {
            NSLog("[notify] post error: \(error.localizedDescription)")
            return false
        }
    }

    private static func body(for driveCount: Int) -> String {
        switch driveCount {
        case 0:
            return "Your laptop is moving, but no external drives are connected."
        case 1:
            return "Your laptop is moving — 1 external drive is still attached. Unmount it before walking away."
        default:
            return "Your laptop is moving — \(driveCount) external drives are still attached. Unmount them before walking away."
        }
    }
}
