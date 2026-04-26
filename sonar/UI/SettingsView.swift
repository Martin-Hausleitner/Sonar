import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Persisted settings
    @AppStorage("sonar.settings.audioFormat")    private var audioFormat: AudioFormat = .opus
    @AppStorage("sonar.settings.retentionDays")  private var retentionDays: Int = 30

    // Privacy mode is driven by PrivacyMode.shared; mirror into local state
    @State private var privacyActive: Bool = PrivacyMode.shared.isActive

    // Latency snapshot (P50/P95/P99) – refreshed on appear
    @State private var latencySnapshot: (p50: Double, p95: Double, p99: Double)? = nil

    // App info
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    var body: some View {
        NavigationStack {
            Form {
                audioSection
                privacySection
                debugSection
                appInfoSection
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { refreshLatency() }
        }
    }

    // MARK: - Sections

    private var audioSection: some View {
        Section("Audio") {
            Picker("Aufnahmeformat", selection: $audioFormat) {
                Text("Opus").tag(AudioFormat.opus)
                Text("FLAC").tag(AudioFormat.flac)
            }
            .pickerStyle(.segmented)

            Picker("Aufbewahrung", selection: $retentionDays) {
                Text("7 Tage").tag(7)
                Text("30 Tage").tag(30)
                Text("90 Tage").tag(90)
                Text("∞").tag(Int.max)
            }
            .pickerStyle(.menu)
        }
    }

    private var privacySection: some View {
        Section("Datenschutz") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy Mode")
                        .font(.body)
                    Text("Alle Cloud-Verbindungen sofort kappen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    PrivacyMode.shared.toggle()
                    privacyActive = PrivacyMode.shared.isActive
                } label: {
                    Text(privacyActive ? "Aktiv" : "Inaktiv")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(privacyActive ? Color.red : Color(.systemGray4))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.2), value: privacyActive)
            }
        }
    }

    private var debugSection: some View {
        Section("Debug Metrics") {
            metricRow(label: "Signal Score", value: "\(appState.signalScore) / 100")
            metricRow(label: "Aktive Pfade", value: "\(appState.activePathCount)")
            metricRow(label: "Battery Tier", value: batteryTierLabel)

            if let lat = latencySnapshot {
                metricRow(label: "Latenz P50", value: String(format: "%.1f ms", lat.p50))
                metricRow(label: "Latenz P95", value: String(format: "%.1f ms", lat.p95))
                metricRow(label: "Latenz P99", value: String(format: "%.1f ms", lat.p99))
            } else {
                metricRow(label: "Latenz", value: "— (keine Daten)")
            }

            Button("Aktualisieren") { refreshLatency() }
                .font(.footnote)
        }
    }

    private var appInfoSection: some View {
        Section("App Info") {
            metricRow(label: "Version", value: appVersion)
            metricRow(label: "Build", value: buildNumber)

            NavigationLink("Open-Source-Lizenzen") {
                LicensesView()
            }
        }
    }

    // MARK: - Helpers

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var batteryTierLabel: String {
        switch appState.batteryTier {
        case .normal:   "Normal"
        case .eco:      "Eco"
        case .saver:    "Saver"
        case .critical: "Critical"
        }
    }

    private func refreshLatency() {
        latencySnapshot = Metrics.shared.percentiles(.captured, .rendered)
    }
}

// MARK: - Supporting types

private enum AudioFormat: String {
    case opus, flac
}

// MARK: - Licenses placeholder

private struct LicensesView: View {
    var body: some View {
        List {
            Section("Verwendete Bibliotheken") {
                licenseRow(name: "swift-opus", license: "BSD-3-Clause")
                licenseRow(name: "swift-nio", license: "Apache 2.0")
                licenseRow(name: "CoreHaptics", license: "Apple (proprietary)")
            }
        }
        .navigationTitle("Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licenseRow(name: String, license: String) -> some View {
        HStack {
            Text(name).font(.body)
            Spacer()
            Text(license).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
