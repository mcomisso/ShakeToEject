import SwiftUI

/// The SwiftUI content of the full-screen warning overlay.
///
/// Binds to `WarningCoordinator` for state (`secondsRemaining`,
/// `drivesSnapshot`) and invokes `coordinator.cancel()` when the
/// user presses Escape or clicks the Cancel button.
struct WarningView: View {
    let coordinator: WarningCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 36) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.yellow)
                    .symbolEffect(.pulse, options: .repeating)

                Text("SHAKE DETECTED")
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(4)

                Text(ejectingSubtitle)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))

                Text("\(coordinator.secondsRemaining)")
                    .font(.system(size: 240, weight: .black, design: .rounded))
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
        }
    }

    private var ejectingSubtitle: String {
        let count = coordinator.drivesSnapshot.count
        if count == 0 {
            return "(dev simulation — no drives to eject)"
        }
        return "Ejecting \(count) drive\(count == 1 ? "" : "s") in"
    }
}
