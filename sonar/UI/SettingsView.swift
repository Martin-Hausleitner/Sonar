import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var modelManager = LocalModelManager.shared
    @StateObject private var tailscale    = TailscaleDetector.shared

    @AppStorage("sonar.settings.audioFormat")    private var audioFormat: AudioFormat = .opus
    @AppStorage("sonar.settings.retentionDays")  private var retentionDays: Int = 30
    @AppStorage("sonar.settings.fecEnabled")     private var fecEnabled: Bool = false
    @AppStorage("sonar.settings.profileID")      private var profileID: String = "zimmer"
    @AppStorage("sonar.parakeet.apiKey")         private var parakeetAPIKey: String = ""
    @AppStorage("sonar.openai.apiKey")           private var openAIKey: String = ""
    @AppStorage("sonar.openai.endpoint")         private var openAIEndpoint: String = ""
    @AppStorage("sonar.devmode.fakeDemo")         private var fakeDemoEnabled: Bool = false
    /// Output volume of Sonar's voice mix (0.0–1.0). Independent from system volume so
    /// the user can keep music loud and turn the peer's voice down (or vice-versa).
    @AppStorage("sonar.audio.outputVolume")       private var outputVolume: Double = 1.0

    @State private var privacyActive: Bool = PrivacyMode.shared.isActive
    @State private var latency: (p50: Double, p95: Double, p99: Double)? = nil

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    /// Section ordering: connection setup first (most important for new users),
    /// then audio + transcription configuration, then per-session profile,
    /// privacy, live diagnostics, and finally developer/app metadata at the bottom.
    var body: some View {
        Form {
            connectionSection
            audioSection
            transcriptionMasterSection
            profileSection
            privacySection
            diagnosticsSection
            developerSection
            appInfoSection
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            latency = Metrics.shared.percentiles(.captured, .rendered)
            tailscale.refresh()
        }
    }

    // MARK: - Connection (top of the screen — first thing the user sees)

    private var connectionSection: some View {
        Section {
            // "Verbindung einrichten" link is the primary call-to-action for
            // new users — keeping it as the first row of the first section.
            NavigationLink {
                PairingView()
                    .environmentObject(appState)
            } label: {
                Label("QR-Pairing", systemImage: "qrcode.viewfinder")
            }

            NavigationLink {
                ConnectionGuideView()
                    .environmentObject(appState)
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

            tailscaleRow
        } header: {
            Text("Verbindung")
        } footer: {
            Text("Sonar wählt automatisch zwischen AWDL (lokal), Bluetooth, Tailscale und Internet. Die Verbindung startet, sobald beide Geräte die App öffnen. Tailscale wird automatisch erkannt, wenn dein Gerät eine 100.x-Adresse aus dem CGNAT-Bereich hat.")
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

    @ViewBuilder
    private var tailscaleRow: some View {
        HStack {
            Label("Tailscale", systemImage: "network.badge.shield.half.filled")
            Spacer()
            if tailscale.isAvailable, let ip = tailscale.localTailscaleIP {
                Text(ip)
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(.green)
            } else {
                Text("Nicht erkannt")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            Picker("Codec", selection: $audioFormat) {
                Text("Opus").tag(AudioFormat.opus)
                Text("FLAC").tag(AudioFormat.flac)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Sonar-Lautstärke", systemImage: "speaker.wave.2.fill")
                    Spacer()
                    Text("\(Int(outputVolume * 100)) %")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $outputVolume, in: 0.0...1.0, step: 0.01)
                        .onChange(of: outputVolume) { _, v in
                            // Live-apply to the active mix node so the user
                            // hears the change instantly without restarting.
                            SpatialMixer.applyOutputVolume(Float(v))
                        }
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

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

    // MARK: - Transcription (merged: Realtime API + Cloud + Local model)

    /// Combined section containing all transcription-engine config:
    /// OpenAI Realtime, NVIDIA Parakeet, and on-device Whisper models.
    /// Previously these lived in three separate sections that asked
    /// repetitive questions ("Engine", "Active engine", "API key…"); merging
    /// them removes that redundancy while keeping every individual control.
    private var transcriptionMasterSection: some View {
        Section {
            // Active engine indicator — single source of truth.
            HStack {
                Label("Aktive Engine", systemImage: "waveform.and.mic")
                Spacer()
                Text(activeEngineLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(activeEngineColor)
            }

            // OpenAI Realtime — highest priority.
            HStack {
                Label("OpenAI API Key", systemImage: "key.fill")
                Spacer()
                SecureField("sk-proj-…", text: $openAIKey)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 180)
            }
            HStack {
                Label("OpenAI Endpoint", systemImage: "link")
                Spacer()
                TextField("https://api.openai.com/v1", text: $openAIEndpoint)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 200)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            // NVIDIA Parakeet — secondary cloud option.
            HStack {
                Label("NVIDIA API Key", systemImage: "key.fill")
                Spacer()
                SecureField("nvapi-…", text: $parakeetAPIKey)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 180)
            }

            // On-device Whisper models.
            ForEach(LocalModelManager.availableModels) { model in
                localModelRow(model)
            }
        } header: {
            Text("Transkription")
        } footer: {
            Text("Sonar wählt die Engine automatisch nach Priorität: **OpenAI Realtime → Parakeet → Lokales Whisper-Modell → Apple Speech**. Lokale Whisper-Modelle (~75–466 MB) laufen vollständig auf dem Gerät — kein API Key nötig. Cloud-Engines sind präziser, brauchen aber Internet.")
        }
    }

    private var activeEngineLabel: String {
        if !openAIKey.isEmpty           { return "OpenAI Realtime" }
        if !parakeetAPIKey.isEmpty      { return "Parakeet (NVIDIA)" }
        let lid = UserDefaults.standard.string(forKey: "sonar.localmodel.selected") ?? ""
        if !lid.isEmpty,
           let m = LocalModelManager.availableModels.first(where: { $0.id == lid }),
           LocalModelManager.shared.localURL(for: m) != nil { return "Lokal · \(m.displayName)" }
        return "Apple Speech"
    }

    private var activeEngineColor: Color {
        if !openAIKey.isEmpty      { return .green }
        if !parakeetAPIKey.isEmpty { return .cyan }
        let lid = UserDefaults.standard.string(forKey: "sonar.localmodel.selected") ?? ""
        if !lid.isEmpty { return .yellow }
        return Color.secondary
    }

    private func localModelRow(_ model: LocalModelManager.ModelInfo) -> some View {
        let state = modelManager.states[model.id] ?? .notDownloaded
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.body)
                Group {
                    switch state {
                    case .notDownloaded:
                        Text("~\(model.approxMB) MB")
                            .foregroundStyle(.secondary)
                    case .downloading(let p):
                        ProgressView(value: p)
                            .tint(.cyan)
                            .frame(maxWidth: 140)
                    case .ready(let bytes):
                        Text(formatBytes(bytes))
                            .foregroundStyle(.secondary)
                    case .failed(let msg):
                        Text(msg)
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
            Spacer()
            modelRowAction(model, state: state)
        }
    }

    @ViewBuilder
    private func modelRowAction(_ model: LocalModelManager.ModelInfo,
                                state: LocalModelManager.DownloadState) -> some View {
        switch state {
        case .notDownloaded, .failed:
            Button(state == .notDownloaded ? "Laden" : "Erneut") {
                modelManager.download(model)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .downloading:
            ProgressView().controlSize(.small)

        case .ready:
            HStack(spacing: 8) {
                if modelManager.selectedModelID == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cyan)
                } else {
                    Button("Nutzen") { modelManager.selectedModelID = model.id }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button { modelManager.delete(model) } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes > 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1_000_000) }
        if bytes > 1_000     { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
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
    //
    // Every value below is read DIRECTLY from `appState` (an
    // `@EnvironmentObject`) so SwiftUI re-evaluates this body whenever any of
    // the underlying `@Published` props fire `objectWillChange`. The previous
    // implementation already did this — there is no stale-state copy. To make
    // the live-update behaviour explicit we (a) read each metric inline in
    // the row builder and (b) tag the latency rows as the only manual-refresh
    // metrics in the footer.

    private var diagnosticsSection: some View {
        Section {
            // Each row reads `appState.<prop>` inline — value re-computes on
            // every body invocation, which SwiftUI triggers when the
            // ObservableObject publishes.
            metricRow("Signal Score",  "\(appState.signalScore) / 100")
            metricRow("Aktive Pfade",  "\(appState.activePathCount)")
            metricRow("Dieses Gerät",  appState.testIdentity.displayName)
            metricRow("Peer",          appState.peerName ?? "—")
            metricRow("Verbindung",    appState.connectionType.label)
            metricRow("Quelle",        appState.connectionIsSimulated ? "Simuliert" : "Echt")
            metricRow("Akku-Modus",    batteryLabel)
            metricRow("Geräteprofil",  appState.deviceCapabilities.hasUWB ? "UWB · High-End" : "Standard")
            metricRow("Tailscale",     tailscale.isAvailable ? (tailscale.localTailscaleIP ?? "ja") : "Nein")

            if let lat = latency {
                metricRow("Latenz P50",  fmtMs(lat.p50))
                metricRow("Latenz P95",  fmtMs(lat.p95))
                metricRow("Latenz P99",  fmtMs(lat.p99))
            } else {
                metricRow("Latenz",      "—")
            }

            Button("Aktualisieren") {
                latency = Metrics.shared.percentiles(.captured, .rendered)
                tailscale.refresh()
            }
            .font(.footnote)
        } header: {
            Text("Diagnose")
        } footer: {
            Text("Signal, Pfade, Peer und Verbindung aktualisieren sich live. **Latenz P50/P95/P99** (50 %, 95 %, 99 % der Frames liegen unter diesem Wert; Budget: 80 ms P95) wird nur beim Tippen auf *Aktualisieren* neu berechnet, um Akku zu sparen.")
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        Section {
            Toggle(isOn: $fakeDemoEnabled) {
                Label("Demo-Modus", systemImage: "theatermasks")
            }
            if fakeDemoEnabled {
                Text("⚠️ Demo aktiv — Distanz, Signal-Score und Peer-Name (\"Demo Peer · FAKE\") sind synthetisch animiert. Echte Verbindungen laufen parallel weiter.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Entwickler")
        } footer: {
            Text("Im Demo-Modus simuliert die App einen Peer ohne dass ein zweites Gerät verbunden ist — nur für Screenshots / Marketing. Standard: aus.")
        }
    }

    // MARK: - App Info (always last)

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
