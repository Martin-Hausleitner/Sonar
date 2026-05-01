import simd
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = SessionCoordinator()

    /// Demo mode is OFF by default. Toggle in Settings → "Demo-Modus".
    /// When enabled, a synthetic peer (`Demo Peer · FAKE`) and animated
    /// distance/score values are shown so the UI can be screenshot/demoed
    /// without two real devices. In production this MUST stay false.
    @AppStorage("sonar.devmode.fakeDemo") private var fakeDemoEnabled: Bool = false

    @State private var showSettings = false
    @State private var showGuide    = false
    @State private var showPairing  = false
    @State private var sessionActive = false
    @State private var previewDistance: Double? = nil
    @State private var profileDetail: SessionProfile? = nil

    // Live stats
    @State private var sessionStart: Date?
    @State private var sessionElapsed: String = "0:00"
    @State private var latencyMs: Double?  = nil
    private let statsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, SonarTheme.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    heroSection
                        .padding(.horizontal, SonarTheme.horizontalPadding)

                    // In-session profile switcher — works pre- and during session.
                    // SessionCoordinator listens to appState.$profileID via dropFirst()
                    // and re-applies ANC / music / FEC live, so a tap here is enough.
                    profileSwitcher
                        .padding(.horizontal, SonarTheme.horizontalPadding)

                    if sessionActive {
                        liveConnectionCard
                            .padding(.horizontal, SonarTheme.horizontalPadding)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if !appState.peerOnline {
                        connectHint
                            .padding(.horizontal, SonarTheme.horizontalPadding)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 14)
            }

            mainButton
                .padding(.horizontal, SonarTheme.horizontalPadding)
                .padding(.top, 2)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundLayer.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showGuide)    { guideSheet    }
        .sheet(item: $profileDetail) { p in
            NavigationStack { ProfileDetailView(profile: p) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPairing)  { pairingSheet  }
        .onChange(of: sessionActive) { _, active in
            withAnimation(.easeInOut(duration: 0.3)) {
                if active {
                    coordinator.appState = appState
                    coordinator.start()
                    // Demo mode: only when explicitly opted-in via Settings AND
                    // we're not already on a real simulator-relay link.
                    if fakeDemoEnabled, !appState.testIdentity.isSimulatorRelayEnabled {
                        animateFakeDistance()
                    }
                    sessionStart = Date()
                } else {
                    coordinator.stop()
                    previewDistance = nil
                    sessionStart = nil
                    latencyMs = nil
                }
            }
        }
        .onAppear {
            guard appState.testIdentity.autoStartSession, !sessionActive else { return }
            sessionActive = true
        }
        .onReceive(statsTimer) { _ in
            guard sessionActive else { return }
            // Elapsed time
            if let start = sessionStart {
                let s = Int(Date().timeIntervalSince(start))
                sessionElapsed = s < 3600
                    ? String(format: "%d:%02d", s / 60, s % 60)
                    : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            }
            // Live latency
            if let snap = Metrics.shared.percentiles(.captured, .rendered) {
                latencyMs = snap.p50
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        SonarTheme.screenBackground
    }

    private var accentColor: Color {
        switch appState.signalScore {
        case 80...: return .cyan
        case 60..<80: return .green
        case 40..<60: return .yellow
        default: return .red
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        // No connection-status placeholder up here — only:
        //   title  ·  (peerBadge if peer online)  ·  Verbinden  ·  Gear
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SonarTheme.accent)
                Text("Sonar")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            // Peer online indicator (hidden when no peer — explicitly NO
            // no placeholder in this row).
            if appState.peerOnline {
                peerBadge
            }

            if sessionActive {
                compactMuteButton
            }

            // Connect / Pairing-Guide — always reachable, even mid-session.
            SonarIconButton(
                systemName: "link.badge.plus",
                accessibilityLabel: "Verbinden — Pairing-Guide öffnen",
                tint: SonarTheme.accent,
                isProminent: true
            ) { showGuide = true }

            // Settings
            SonarIconButton(
                systemName: "gearshape",
                accessibilityLabel: "Einstellungen öffnen",
                tint: .primary
            ) { showSettings = true }
        }
    }

    private var peerBadge: some View {
        HStack(spacing: 0) {
            SonarStatusDot(color: .green, size: 7)
        }
        .frame(width: 28, height: 28)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel("Peer verbunden")
    }

    private var heroSection: some View {
        VStack(spacing: 14) {
            DistanceRingView(
                distance: previewDistance,
                direction: previewDistance != nil ? simd_float3(0.4, 0, -0.9) : nil
            )
            .frame(width: 224, height: 224)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Abstandsradar")

            statusPill
        }
        .padding(.top, 2)
    }

    // MARK: - Profile Switcher (in-session, compact)

    /// Horizontal pill row of all built-in profiles. Tapping a pill writes
    /// the new id to `appState.profileID`; SessionCoordinator listens via
    /// `dropFirst()` and re-applies ANC / music / FEC settings live.
    private var profileSwitcher: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SessionProfile.builtIn) { profile in
                        profilePill(profile)
                    }
                }
                .padding(.vertical, 2)
            }

            // "i" — opens detail sheet for currently selected profile.
            Button {
                profileDetail = SessionProfile.builtIn.first(where: { $0.id == appState.profileID })
                    ?? SessionProfile.builtIn.first
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details zum aktiven Profil")
        }
    }

    @ViewBuilder
    private func profilePill(_ profile: SessionProfile) -> some View {
        let isSelected = appState.profileID == profile.id
        let tint = ProfileVisuals.color(profile.id)
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                appState.profileID = profile.id
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: ProfileVisuals.icon(profile.id))
                    .font(.system(size: 11, weight: .semibold))
                Text(profile.displayName)
                    .font(.caption.weight(.semibold))
            }
        .foregroundStyle(isSelected ? tint : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? tint.opacity(0.16) : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? tint.opacity(0.65) : SonarTheme.separator,
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profil \(profile.displayName)\(isSelected ? " (aktiv)" : "")")
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.caption.weight(.semibold))
            Text(statusText)
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SonarTheme.separator, lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
    }

    private var statusText: String {
        if appState.connectionType == .simulatorRelay, sessionActive {
            return appState.peerOnline ? "Simulator · verbunden" : "Simulator · wartet"
        }
        switch appState.phase {
        case .idle:              return sessionActive ? "Verbinde…" : "Bereit"
        case .connecting:        return "Verbinde…"
        case .near(let d):       return String(format: "Nah · %.1f m", d)
        case .far:               return "Fern · Internet"
        case .degrading:         return "Verbindung schwach"
        case .recovering:        return "Verbindung stellt sich wieder her"
        }
    }

    private var statusIcon: String {
        if appState.connectionType == .simulatorRelay, sessionActive {
            return "desktopcomputer"
        }
        switch appState.phase {
        case .idle:        return sessionActive ? "antenna.radiowaves.left.and.right" : "circle"
        case .connecting:  return "antenna.radiowaves.left.and.right"
        case .near:        return "dot.radiowaves.left.and.right"
        case .far:         return "globe"
        case .degrading:   return "exclamationmark.triangle"
        case .recovering:  return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch appState.phase {
        case .near:      return .cyan
        case .far:       return .white
        case .degrading: return .yellow
        default:         return .secondary
        }
    }

    // MARK: - Live Connection Card

    private var liveConnectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Live-Verbindung", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                    Text(appState.peerOnline ? (appState.peerName ?? "Peer verbunden") : "Suche nach deinem Gegenüber")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    SonarStatusDot(color: accentColor, size: 7)
                    Text("\(appState.signalScore)")
                        .font(.headline.weight(.semibold).monospacedDigit())
                    Text("/100")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(accentColor)
                .accessibilityLabel("Signal \(appState.signalScore) von 100")
            }

            qualityBar

            audioControlsRow

            activePathsRow

            Divider()

            metricsGrid

            if appState.batteryTier == .critical {
                Label("Kritischer Akku: Qualität stark reduziert", systemImage: "battery.0")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            liveTranscriptPreview
        }
        .sonarSurface(padding: 16, material: .regularMaterial)
    }

    private var qualityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                    .frame(height: 5)
                Capsule()
                    .fill(accentColor)
                    .frame(width: geo.size.width * CGFloat(appState.signalScore) / 100, height: 5)
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appState.signalScore)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var activePathsRow: some View {
        HStack(spacing: 6) {
            if appState.connectionType == .simulatorRelay {
                pathPill("desktopcomputer", "Simulator",
                         active: appState.activePathIDs.contains("simulatorRelay") || appState.peerOnline)
            } else {
                pathPill("dot.radiowaves.left.and.right", "AWDL",
                         active: appState.activePathIDs.contains("multipeer"))
                pathPill("wave.3.right.circle.fill", "Bluetooth",
                         active: appState.activePathIDs.contains("bluetooth"))
                pathPill("network.badge.shield.half.filled", "Tailscale",
                         active: appState.activePathIDs.contains("tailscale"))
                pathPill("globe", "Internet",
                         active: appState.activePathIDs.contains("mpquic"))
            }
            Spacer()
            if appState.isRecording {
                Label("REC", systemImage: "record.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var metricsGrid: some View {
        HStack(spacing: 0) {
            statCell(
                icon: "timer",
                label: "Session",
                value: sessionStart != nil ? sessionElapsed : "—",
                color: SonarTheme.accent
            )
            statCell(
                icon: "waveform.path.ecg",
                label: "Latenz",
                value: latencyMs != nil ? String(format: "%.0f ms", latencyMs!) : "—",
                color: latencyColor
            )
            statCell(
                icon: "location.fill",
                label: "Distanz",
                value: distanceLabel,
                color: .primary
            )
            statCell(
                icon: batteryIcon,
                label: "Akku",
                value: batteryLabel,
                color: batteryColor
            )
        }
    }

    @ViewBuilder
    private var liveTranscriptPreview: some View {
        let finalSegs = appState.transcriptSegments.filter(\.isFinal).suffix(2)
        if !finalSegs.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("Transkript", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(finalSegs) { seg in
                    Text(seg.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var compactMuteButton: some View {
        SonarIconButton(
            systemName: appState.isMuted ? "mic.slash.fill" : "mic.fill",
            accessibilityLabel: appState.isMuted ? "Mikrofon einschalten" : "Mikrofon stummschalten",
            tint: appState.isMuted ? .red : SonarTheme.accent,
            isProminent: true
        ) { toggleMute() }
    }

    private var audioControlsRow: some View {
        HStack(spacing: 12) {
            Button {
                toggleMute()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.callout.weight(.bold))
                    Text(appState.isMuted ? "Stumm" : "Mikro an")
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(appState.isMuted ? .red : SonarTheme.accent)
                .frame(minWidth: 116, minHeight: 42)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((appState.isMuted ? Color.red : SonarTheme.accent).opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((appState.isMuted ? Color.red : SonarTheme.accent).opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appState.isMuted ? "Mikrofon einschalten" : "Mikrofon stummschalten")

            AudioLevelMeter(rms: appState.inputLevelRMS)

            Spacer(minLength: 0)
        }
    }

    private func toggleMute() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            appState.isMuted.toggle()
        }
    }

    private func statCell(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color.opacity(0.7))
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var gradeLabel: String {
        switch appState.signalGrade {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .ok:        return "OK"
        case .poor:      return "Poor"
        case .unstable:  return "Unstable"
        }
    }

    private var distanceLabel: String {
        if let d = previewDistance { return String(format: "%.1f m", d) }
        if case .near(let d) = appState.phase { return String(format: "%.1f m", d) }
        return "—"
    }

    private var latencyColor: Color {
        guard let ms = latencyMs else { return .secondary }
        return ms < 40 ? .green : ms < 80 ? .yellow : .red
    }

    private var batteryLabel: String {
        switch appState.batteryTier {
        case .normal:   return "Normal"
        case .eco:      return "Eco"
        case .saver:    return "Sparen"
        case .critical: return "Kritisch"
        }
    }

    private var batteryIcon: String {
        switch appState.batteryTier {
        case .normal:   return "battery.100"
        case .eco:      return "battery.75"
        case .saver:    return "battery.25"
        case .critical: return "battery.0"
        }
    }

    private var batteryColor: Color {
        switch appState.batteryTier {
        case .normal: return .green
        case .eco:    return .yellow
        case .saver:  return .orange
        case .critical: return .red
        }
    }

    private func pathPill(_ icon: String, _ label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(active ? SonarTheme.accent : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(active ? SonarTheme.accent.opacity(0.12) : Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(active ? SonarTheme.accent.opacity(0.24) : SonarTheme.separator, lineWidth: 0.5))
    }

    // MARK: - Idle hint (before session)

    private var connectHint: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.line.dotted.person.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SonarTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(SonarTheme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Verbinden")
                        .font(.headline)
                    Text("QR-Code scannen oder beide Geräte mit Sonar öffnen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Button { showPairing = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.callout.weight(.semibold))
                    Text("QR-Pairing")
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SonarTheme.accent)
                )
            }
            .buttonStyle(.plain)

            Button { showGuide = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link.badge.plus")
                        .font(.callout.weight(.semibold))
                    Text("Verbindungsoptionen")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SonarTheme.separator, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label(appState.testIdentity.displayName, systemImage: "iphone")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if appState.testIdentity.isSimulatorRelayEnabled {
                    Label("Simulator Relay", systemImage: "desktopcomputer")
                        .foregroundStyle(SonarTheme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .sonarSurface(padding: 16, material: .regularMaterial)
    }

    // MARK: - Main Button

    private var mainButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                sessionActive.toggle()
            }
        } label: {
            Label(
                sessionActive ? "Session beenden" : "Session starten",
                systemImage: sessionActive ? "stop.fill" : "waveform"
            )
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(sessionActive ? Color.red : SonarTheme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(sessionActive ? "Session beenden" : "Session starten")
    }

    // MARK: - Sheets

    private var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .environmentObject(appState)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showSettings = false }
                    }
                }
        }
    }

    private var pairingSheet: some View {
        NavigationStack {
            PairingView()
                .environmentObject(appState)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showPairing = false }
                    }
                }
        }
    }

    private var guideSheet: some View {
        NavigationStack {
            ConnectionGuideView()
                .environmentObject(appState)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { showGuide = false }
                    }
                }
        }
    }

    // MARK: - Simulator demo animation

    private func animateFakeDistance() {
        let distances: [Double] = [8.0, 5.5, 3.2, 1.8, 1.0, 0.8, 1.2, 2.4, 4.0, 6.0]
        for (i, d) in distances.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) {
                guard self.sessionActive else { return }
                withAnimation(.easeInOut(duration: 1.0)) { self.previewDistance = d }
            }
        }
        let scores = [100, 94, 87, 78, 65, 82, 91, 96]
        for (i, s) in scores.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.0) {
                guard self.sessionActive else { return }
                self.appState.signalScore = s
                self.appState.activePathCount = s > 80 ? 3 : s > 60 ? 2 : 1
            }
        }
        // Simulate peer coming online
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard self.sessionActive else { return }
            withAnimation { self.appState.peerOnline = true; self.appState.peerName = "Demo Peer · FAKE" }
        }
    }
}

// MARK: - Preview

#Preview {
    SessionView()
        .environmentObject({
            let s = AppState()
            s.phase = .near(distance: 1.8)
            s.signalScore = 92
            s.activePathCount = 3
            s.isRecording = true
            s.peerOnline = true
            s.peerName = "Demo Peer · FAKE"
            return s
        }())
}
