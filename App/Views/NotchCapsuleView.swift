import SwiftUI

/// SwiftUI content rendered inside a `NotchCapsuleWindow`.
///
/// Visually presents as a dark rounded capsule that appears to
/// drop out of the hardware notch — the initial state is a thin
/// rectangle covering just the notch area, and the content
/// expands downward into a full 480×92 capsule via SwiftUI spring
/// animation. The capsule itself carries a subtle camera shake.
struct NotchCapsuleView: View {
    let coordinator: WarningCoordinator

    @State private var hasExpanded: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.black.opacity(0.95))
            .overlay(alignment: .center) {
                if hasExpanded {
                    capsuleContent
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .overlay(alignment: .top) {
                // Cap the top edge flush with the notch, no rounding on top
                Rectangle()
                    .fill(.black.opacity(0.95))
                    .frame(height: 20)
                    .offset(y: -1)
            }
            .compositingGroup()
            .cameraShake(amplitude: ShakeAmplitude.subtle)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    hasExpanded = true
                }
            }
    }

    @ViewBuilder
    private var capsuleContent: some View {
        HStack(spacing: 14) {
            // Left: stack of panicked drive characters (up to 3 visible)
            HStack(spacing: -8) {
                ForEach(Array(coordinator.drivesSnapshot.prefix(3).enumerated()), id: \.element.id) { _, drive in
                    DriveCharacterView(drive: drive, panicLevel: panicLevel)
                        .scaleEffect(0.5)
                        .frame(width: 36, height: 36)
                }
            }

            // Middle: panic line + count
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.currentPanicLine)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: countdown digit + cancel X
            HStack(spacing: 10) {
                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: coordinator.secondsRemaining)
                    .monospacedDigit()

                Button {
                    coordinator.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var subtitleText: String {
        let count = coordinator.drivesSnapshot.count
        if count == 0 {
            return "dev simulation"
        }
        return "ejecting \(count) drive\(count == 1 ? "" : "s")"
    }

    private var panicLevel: Double {
        let total = max(coordinator.totalSeconds, 1)
        let elapsed = total - coordinator.secondsRemaining
        return min(1.0, max(0.0, Double(elapsed) / Double(total)))
    }
}
