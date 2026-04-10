import AVFoundation
import AppKit
import Foundation

/// Thin wrapper around `AVAudioPlayer` that plays the warning and
/// ejected sounds for the `WarningCoordinator` flow.
///
/// The player looks for `warning.wav` and `ejected.wav` in the app
/// bundle's main resources. If the assets are missing (the
/// default — the user adds real files under `App/Resources/Sounds/`
/// later), it falls back to the macOS system sounds `Funk` (warning)
/// and `Glass` (eject confirmation) so the flow is still audible
/// during development.
///
/// `@MainActor` because AVAudioPlayer and NSSound are not Sendable
/// and the coordinator that drives us is main-actor-isolated.
@MainActor
final class SoundPlayer {
    private var currentPlayer: AVAudioPlayer?

    /// Plays the "shake detected, countdown starting" sound.
    func playWarning() {
        play(resourceName: "warning", fallbackSystemName: "Funk")
    }

    /// Plays the "drives ejected" confirmation sound.
    func playEjected() {
        play(resourceName: "ejected", fallbackSystemName: "Glass")
    }

    private func play(resourceName: String, fallbackSystemName: String) {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.prepareToPlay()
            player.play()
            currentPlayer = player
            return
        }
        NSSound(named: NSSound.Name(fallbackSystemName))?.play()
    }
}
