import AVFoundation
import AppKit
import Foundation

/// Thin wrapper around `AVAudioPlayer` that plays the warning and
/// ejected sounds for the `WarningCoordinator` flow.
///
/// The player reads which named asset to play from the injected
/// `SettingsStore` each time `playWarning()` or `playEjected()`
/// fires, so user-picker changes in the dashboard take effect on
/// the next trigger with no restart.
///
/// Audio files live in `App/Resources/Sounds/` and are picked up
/// into the app bundle's main Resources directory automatically
/// by XcodeGen's recursive source discovery. Supported extensions:
/// `mp3`, `wav`, `m4a`, `aiff`, `caf`. The first extension that
/// matches a given base name is played.
///
/// An empty-string setting (`Settings.silentSoundName`) means
/// "play nothing for this slot"; the player then skips audio
/// entirely without falling back to a system sound, because the
/// user explicitly asked for silence.
///
/// If the configured name doesn't resolve to any file in the
/// bundle (e.g. a typo in UserDefaults from a previous build),
/// the player falls back to a macOS system sound (Funk / Glass)
/// so the flow stays audible.
///
/// `@MainActor` because AVAudioPlayer and NSSound are not Sendable
/// and the coordinator that drives us is main-actor-isolated.
@MainActor
final class SoundPlayer {
    /// Extensions tried in order for each candidate name.
    private static let audioExtensions: [String] = ["mp3", "wav", "m4a", "aiff", "caf"]

    private let settings: SettingsStore
    private var currentPlayer: AVAudioPlayer?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Plays the "shake detected, countdown starting" sound.
    func playWarning() {
        play(name: settings.warningSoundName, fallbackSystemName: "Funk")
    }

    /// Plays the "drives ejected" confirmation sound.
    func playEjected() {
        play(name: settings.ejectedSoundName, fallbackSystemName: "Glass")
    }

    /// Plays a specific named sound immediately, bypassing the
    /// SettingsStore. Used by the dashboard's preview button so
    /// the user can audition a sound before committing to it.
    /// If the name doesn't resolve, logs and stays silent — no
    /// system-sound fallback, because preview is explicit.
    func preview(name: String) {
        guard !name.isEmpty else { return }
        guard let player = loadPlayer(for: name) else {
            NSLog("[sound] preview failed: \"\(name)\" not found in bundle")
            return
        }
        player.prepareToPlay()
        player.play()
        currentPlayer = player
    }

    private func play(name: String, fallbackSystemName: String) {
        if name == SettingsStore.silentSoundName {
            return
        }
        if let player = loadPlayer(for: name) {
            player.prepareToPlay()
            player.play()
            currentPlayer = player
            return
        }
        NSSound(named: NSSound.Name(fallbackSystemName))?.play()
    }

    private func loadPlayer(for name: String) -> AVAudioPlayer? {
        for ext in Self.audioExtensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let player = try? AVAudioPlayer(contentsOf: url) {
                return player
            }
        }
        return nil
    }
}
