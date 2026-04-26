import simd
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = SessionCoordinator()

    @State private var showSettings = false
    @State private var showGuide    = false
    @State private var sessionActive = false
    @State private var previewDistance: Double? = nil

    // Live stats
    @State private var sessionStart: Date?
    @State private var sessionElapsed: String = "0:00"
    @State private var latencyMs: Double?  = nil
    private let statsTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Spacer(minLength: 0)

            // Hero: distance ring
            DistanceRingView(
                distance: previewDistance,
                direction: previewDistance != nil ? simd_float3(0.4, 0, -0.9) : nil
            )
            .frame(width: 260, height: 260)

            // Status pill
            statusPill
                .padding(.top, 14)

            Spacer(minLength: 0)

            // Live connection card — always visible when session is running
            if sessionActive {
                liveConnectionCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !appState.peerOnline {
                // Idle hint
                connectHint
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            // Primary action
            mainButton
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundLayer.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showGuide)    { guideSheet    }
        .onChange(of: sessionActive) { _, active in
            withAnimation(.easeInOut(duration: 0.3)) {
                if active {
                    coordinator.appState = appState
                    coordinator.start()
                    animateFakeDistance()
                    sessionStart = Date()
                } else {
                    coordinator.stop()
                    previewDistance = nil
                    sessionStart = nil
                    latencyMs = nil
                }
            }
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
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.10)
            if sessionActive {
                RadialGradient(
                    colors: [accentColor.opacity(0.18), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 400
                )
                .animation(.easeInOut(duration: 1.4), value: appState.signalScore)
            }
        }
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
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.cyan)
                Text("Sonar")
                    .font(.headline.bold())
            }

            Spacer()

            // Peer online indicator
            if appState.peerOnline {
                peerBadge
            }

            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var peerBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(.green.opacity(0.4), lineWidth: 3))
            Text(appState.peerName ?? "Peer")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
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
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
    }

    private var statusText: String {
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
        VStack(spacing: 12) {
            // Header: label + score
            HStack {
                Label("Verbindung", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(accentColor).frame(width: 6, height: 6)
                    Text("\(appState.signalScore)/100")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accentColor)
                    Text(gradeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Quality bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08)).frame(height: 5)
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, accentColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(appState.signalScore) / 100, height: 5)
                        .animation(.spring(response: 0.6), value: appState.signalScore)
                }
            }
            .frame(height: 5)

            // Active path pills + REC
            HStack(spacing: 6) {
                pathPill("dot.radiowaves.left.and.right", "AWDL",     active: appState.activePathCount > 0)
                pathPill("bluetooth",                     "Bluetooth", active: appState.activePathCount > 1)
                pathPill("globe",                         "Internet",  active: appState.activePathCount > 2)
                Spacer()
                if appState.isRecording {
                    Label("REC", systemImage: "record.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
            }

            Divider().background(.white.opacity(0.08))

            // 4-cell metrics grid
            HStack(spacing: 0) {
                statCell(
                    icon: "timer",
                    label: "Session",
                    value: sessionStart != nil ? sessionElapsed : "—",
                    color: .cyan
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
                    color: .white
                )
                statCell(
                    icon: batteryIcon,
                    label: "Akku",
                    value: batteryLabel,
                    color: batteryColor
                )
            }

            // Battery warning (only for critical states)
            if appState.batteryTier == .critical {
                Label("Kritischer Akkustand – Qualität stark reduziert", systemImage: "battery.0")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Live transcript (last 2 final segments)
            let finalSegs = appState.transcriptSegments.filter(\.isFinal).suffix(2)
            if !finalSegs.isEmpty {
                Divider().background(.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 4) {
                    Label("Transkript", systemImage: "text.bubble")
                        .font(.caption2.weight(.semibold))
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
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .foregroundStyle(active ? .cyan : .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(active ? Color.cyan.opacity(0.12) : Color.white.opacity(0.05), in: Capsule())
    }

    // MARK: - Idle hint (before session)

    private var connectHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.cyan)
            Text("Sonar auf beiden Geräten öffnen – die Verbindung startet automatisch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showGuide = true } label: {
                Text("Hilfe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(sessionActive ? .red.opacity(0.85) : .cyan)
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

    private var guideSheet: some View {
        NavigationStack {
            ConnectionGuideView()
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
            withAnimation { self.appState.peerOnline = true; self.appState.peerName = "Martin's iPhone" }
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
            s.peerName = "Martin's iPhone"
            return s
        }())
}
