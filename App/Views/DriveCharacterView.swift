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
