import SwiftUI

struct DashboardView: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section("Detection") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(String(format: "%.2f g", settings.sensitivityThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.sensitivityThreshold },
                            set: { settings.sensitivityThreshold = $0 }
                        ),
                        in: SettingsStore.sensitivityRange
                    )
                    Text("Lower = detects gentler motion. Higher = only strong shakes trigger.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text(String(format: "%.1f s", settings.cooldownSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.cooldownSeconds },
                            set: { settings.cooldownSeconds = $0 }
                        ),
                        in: SettingsStore.cooldownRange,
                        step: 0.1
                    )
                    Text("Minimum time between detected shake events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Warning") {
                Stepper(
                    "Countdown: \(settings.countdownSeconds)s",
                    value: Binding(
                        get: { settings.countdownSeconds },
                        set: { settings.countdownSeconds = $0 }
                    ),
                    in: SettingsStore.countdownRange
                )
                Text("How long the warning overlay waits before ejecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Style",
                    selection: Binding(
                        get: { settings.warningStyle },
                        set: { settings.warningStyle = $0 }
                    )
                ) {
                    ForEach(WarningStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0 }
                    )
                )

                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.shortVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
