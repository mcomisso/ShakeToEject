import SwiftUI

struct WarningView: View {
    let coordinator: WarningCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 30) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)

                Text(coordinator.currentPanicLine)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(2)
                    .multilineTextAlignment(.center)

                // Drive character row — pinned in place, jostled by
                // the camera shake wrapping the whole VStack.
                HStack(spacing: 24) {
                    ForEach(coordinator.drivesSnapshot) { drive in
                        DriveCharacterView(drive: drive, panicLevel: panicLevel)
                    }
                    if coordinator.drivesSnapshot.isEmpty {
                        Text("(dev simulation — no drives)")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.vertical, 12)

                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 220, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: coordinator.secondsRemaining)
                    .monospacedDigit()

                Button(action: { coordinator.cancel() }) {
                    Text("CANCEL")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .tracking(2)
                        .padding(.horizontal, 80)
                        .padding(.vertical, 22)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Text("or press Esc")
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(80)
            .cameraShake(amplitude: currentAmplitude)
        }
        .opacity(coordinator.isDismissing ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: coordinator.isDismissing)
    }

    private var panicLevel: Double {
        let total = max(coordinator.totalSeconds, 1)
        let elapsed = total - coordinator.secondsRemaining
        return min(1.0, max(0.0, Double(elapsed) / Double(total)))
    }

    private var currentAmplitude: CGFloat {
        // Ramp from worried → panic in the last 2 seconds.
        if coordinator.secondsRemaining <= 2 && coordinator.secondsRemaining > 0 {
            return ShakeAmplitude.panic
        }
        return ShakeAmplitude.worried
    }
}
