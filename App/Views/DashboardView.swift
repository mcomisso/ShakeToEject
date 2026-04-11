import SwiftUI

struct DashboardView: View {
    let settings: SettingsStore
    let drives: DriveMonitor

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

            Section("Drives") {
                let mounted = drives.drives
                let rememberedNotMounted = settings.excludedVolumeNames
                    .subtracting(Set(mounted.map(\.volumeName)))
                    .sorted()

                if mounted.isEmpty && rememberedNotMounted.isEmpty {
                    Text("No drives to configure")
                        .foregroundStyle(.secondary)
                } else {
                    if !mounted.isEmpty {
                        ForEach(mounted) { drive in
                            Toggle(
                                isOn: Binding(
                                    get: { !settings.excludedVolumeNames.contains(drive.volumeName) },
                                    set: { include in
                                        if include {
                                            settings.excludedVolumeNames.remove(drive.volumeName)
                                        } else {
                                            settings.excludedVolumeNames.insert(drive.volumeName)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(drive.volumeName)
                                    Text(drive.mountPoint.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !rememberedNotMounted.isEmpty {
                        Text("Remembered exclusions (not mounted)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)

                        ForEach(rememberedNotMounted, id: \.self) { name in
                            HStack {
                                Text("🔒 \(name)")
                                Spacer()
                                Button("Forget") {
                                    settings.excludedVolumeNames.remove(name)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    Text("Excluded drives are never auto-ejected, even on shake.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
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
        .frame(width: 520, height: 560)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}
