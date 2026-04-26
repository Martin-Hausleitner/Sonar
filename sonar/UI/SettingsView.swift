import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("sonar.settings.audioFormat")    private var audioFormat: AudioFormat = .opus
    @AppStorage("sonar.settings.retentionDays")  private var retentionDays: Int = 30
    @AppStorage("sonar.settings.fecEnabled")     private var fecEnabled: Bool = false
    @AppStorage("sonar.settings.profileID")      private var profileID: String = "zimmer"

    @State private var privacyActive: Bool = PrivacyMode.shared.isActive
    @State private var latency: (p50: Double, p95: Double, p99: Double)? = nil

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    var body: some View {
        Form {
            connectionSection
            audioSection
            profileSection
            privacySection
            diagnosticsSection
            appInfoSection
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { latency = Metrics.shared.percentiles(.captured, .rendered) }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            NavigationLink {
                ConnectionGuideView()
            } label: {
                Label("Verbindung einrichten", systemImage: "network.badge.shield.half.filled")
            }

            HStack {
                Label("Aktive Pfade", systemImage: "arrow.triangle.branch")
                Spacer()
                pathIndicator
            }

            HStack {
                Label("Signal", systemImage: "antenna.radiowaves.left.and.right")
                Spacer()
                signalBadge
            }
        } header: {
            Text("Verbindung")
        } footer: {
            Text("Sonar wählt automatisch zwischen AWDL (lokal), Bluetooth und Internet. Die Verbindung startet, sobald beide Geräte die App öffnen.")
        }
    }

    private var pathIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < appState.activePathCount ? Color.cyan : Color.secondary.opacity(0.25))
                    .frame(width: 10, height: 14 + CGFloat(i) * 4)
            }
            Text(appState.activePathCount == 0 ? "Kein" : "\(appState.activePathCount) aktiv")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var signalBadge: some View {
        let color: Color = appState.signalScore >= 80 ? .green
                         : appState.signalScore >= 60 ? .yellow : .red
        return Text("\(appState.signalScore) / 100")
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(color)
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            Picker("Codec", selection: $audioFormat) {
                Text("Opus").tag(AudioFormat.opus)
                Text("FLAC").tag(AudioFormat.flac)
            }
            .pickerStyle(.segmented)

            Toggle("Vorwärtsfehlerkorrektur (FEC)", isOn: $fecEnabled)

            Picker("Aufbewahrung", selection: $retentionDays) {
                Text("7 Tage").tag(7)
                Text("30 Tage").tag(30)
                Text("90 Tage").tag(90)
                Text("Unbegrenzt").tag(Int.max)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("**Opus** ist für Sprache optimiert (niedrige Latenz, ~32 kBit/s). **FLAC** speichert verlustfrei, ist aber deutlich größer. **FEC** verbessert die Qualität bei Paketverlust, erhöht jedoch die Bandbreite um ca. 20 %. Empfohlen für Outdoor-Nutzung.")
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            NavigationLink {
                ProfilePickerView(
                    selected: SessionProfile.builtIn.first { $0.id == appState.profileID },
                    onSelect: { p in appState.profileID = p.id }
                )
                .environmentObject(appState)
                .navigationTitle("Umgebungsprofil")
            } label: {
                HStack {
                    Label("Umgebungsprofil", systemImage: "slider.horizontal.3")
                    Spacer()
                    Text(activeProfName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Profil")
        } footer: {
            Text("Das Profil passt Rauschunterdrückung, AirPods-Modus und Musiklautstärke automatisch an die Umgebung an. **Zimmer** ist der Standard für Innenräume.")
        }
    }

    private var activeProfName: String {
        SessionProfile.builtIn.first { $0.id == appState.profileID }?.displayName ?? "Standard"
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy Mode")
                    Text("Deaktiviert alle Cloud-Verbindungen sofort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $privacyActive)
                    .labelsHidden()
                    .onChange(of: privacyActive) { _, v in
                        if v { PrivacyMode.shared.activate() } else { PrivacyMode.shared.deactivate() }
                        appState.privacyModeActive = v
                    }
            }
        } header: {
            Text("Datenschutz")
        } footer: {
            Text("Im Privacy Mode werden ausschließlich lokale Pfade (AWDL, BT) genutzt. Internet-Pfade werden sofort getrennt und nicht neu aufgebaut, bis du den Modus deaktivierst.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            metricRow("Signal Score",    "\(appState.signalScore) / 100")
            metricRow("Aktive Pfade",    "\(appState.activePathCount)")
            metricRow("Akku-Modus",      batteryLabel)
            metricRow("Geräteprofil",    appState.deviceCapabilities.hasUWB ? "UWB · High-End" : "Standard")

            if let lat = latency {
                metricRow("Latenz P50",  fmtMs(lat.p50))
                metricRow("Latenz P95",  fmtMs(lat.p95))
                metricRow("Latenz P99",  fmtMs(lat.p99))
            } else {
                metricRow("Latenz",      "—")
            }

            Button("Aktualisieren") {
                latency = Metrics.shared.percentiles(.captured, .rendered)
            }
            .font(.footnote)
        } header: {
            Text("Diagnose")
        } footer: {
            Text("P50/P95/P99 sind statistische Latenzmessungen (50 %, 95 %, 99 % der Frames liegen unter diesem Wert). Das Budget beträgt 80 ms P95.")
        }
    }

    // MARK: - App Info

    private var appInfoSection: some View {
        Section("App") {
            metricRow("Version", appVersion)
            metricRow("Build",   buildNumber)
            NavigationLink("Open-Source-Lizenzen") {
                LicensesView()
            }
        }
    }

    // MARK: - Helpers

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var batteryLabel: String {
        switch appState.batteryTier {
        case .normal:   "Normal"
        case .eco:      "Eco"
        case .saver:    "Sparen"
        case .critical: "Kritisch"
        }
    }

    private func fmtMs(_ v: Double) -> String { String(format: "%.1f ms", v) }
}

// MARK: - Supporting types

private enum AudioFormat: String { case opus, flac }

// MARK: - Licenses

private struct LicensesView: View {
    var body: some View {
        List {
            Section("Verwendete Bibliotheken") {
                licRow("swift-opus",         "BSD-3-Clause")
                licRow("swift-nio",          "Apache 2.0")
                licRow("LiveKit SDK",        "Apache 2.0")
                licRow("Tailscale SDK",      "BSD-3-Clause")
                licRow("CoreHaptics",        "Apple (proprietary)")
            }
        }
        .navigationTitle("Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func licRow(_ name: String, _ lic: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(lic).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
