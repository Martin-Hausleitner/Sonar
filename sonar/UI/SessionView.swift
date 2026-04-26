import simd
import SwiftUI

/// Main session screen. Liquid Design — translucent glass cards over a deep
/// space background, animated glow that reacts to signal quality.
struct SessionView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = SessionCoordinator()

    // UI state
    @State private var showLiveData = false
    @State private var showProfiles = false
    @State private var showSettings = false
    @State private var sessionActive = false

    // Simulated waveform for simulator (replaced by real AudioEngine tap in production)
    @State private var waveformSamples: [Float] = Array(repeating: 0.05, count: 32)
    private let waveTimer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    // Simulated distance for simulator preview
    @State private var previewDistance: Double? = nil

    var body: some View {
        ZStack {
            // Full-screen background — explicitly ignores safe areas so
            // the dark gradient bleeds under the status bar and tab bar.
            backgroundGradient.ignoresSafeArea()
            glowLayer.ignoresSafeArea().allowsHitTesting(false)

            // Content — no ignoresSafeArea here, so it stays inside the
            // tab-bar safe-area inset automatically.
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                Spacer(minLength: 12)

                DistanceRingView(
                    distance: previewDistance,
                    direction: previewDistance != nil ? simd_float3(0.4, 0, -0.9) : nil
                )
                .frame(maxWidth: 300, maxHeight: 300)
                .padding(.horizontal, 24)

                Spacer(minLength: 12)

                phaseLabel

                waveformStrip
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                if !appState.transcriptSegments.isEmpty {
                    transcriptStrip
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                Spacer(minLength: 12)

                bottomControls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showLiveData) {
            LiveDataSheet()
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showProfiles) {
            profileSheet
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showSettings = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .onReceive(waveTimer) { _ in
            guard sessionActive else {
                waveformSamples = Array(repeating: 0.03, count: 32)
                return
            }
            withAnimation(.easeOut(duration: 0.08)) {
                waveformSamples = (0..<32).map { _ in Float.random(in: 0.05...0.85) }
            }
        }
        .onChange(of: sessionActive) { _, active in
            if active {
                coordinator.appState = appState
                coordinator.start()
                // Simulator: animate a fake distance for demo
                animateFakeDistance()
            } else {
                coordinator.stop()
                previewDistance = nil
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.03, green: 0.04, blue: 0.10), location: 0),
                .init(color: Color(red: 0.04, green: 0.06, blue: 0.14), location: 0.5),
                .init(color: Color(red: 0.02, green: 0.03, blue: 0.08), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var glowLayer: some View {
        ZStack {
            RadialGradient(
                colors: [glowColor.opacity(sessionActive ? 0.28 : 0.06), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .animation(.easeInOut(duration: 1.2), value: sessionActive)
            .animation(.easeInOut(duration: 0.8), value: appState.signalScore)

            RadialGradient(
                colors: [Color(red: 0.0, green: 0.4, blue: 0.6).opacity(0.08), .clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 280
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var glowColor: Color {
        guard sessionActive else { return .cyan }
        switch appState.signalScore {
        case 80...100: return .cyan
        case 60..<80:  return .green
        case 40..<60:  return .yellow
        default:       return .red
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Wordmark
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.89, blue: 1.0))
                Text("SONAR")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer()

            // Signal status (only when connected)
            if sessionActive {
                ConnectionStatusBadge(
                    score: appState.signalScore,
                    activePaths: appState.activePathCount,
                    phase: appState.phase
                )
            }

            // AI badge
            AIAvatarBadge(isActive: appState.aiActive)

            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.06), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Phase Label

    private var phaseLabel: some View {
        Text(phaseLabelText)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.white.opacity(0.05), in: Capsule())
            .animation(.easeInOut(duration: 0.3), value: appState.phase)
    }

    private var phaseLabelText: String {
        switch appState.phase {
        case .idle:              return sessionActive ? "Initialisiere…" : "Bereit"
        case .connecting:        return "Verbinde…"
        case .near(let d):       return String(format: "Near · %.1f m", d)
        case .far:               return "Far · Internet"
        case .degrading:         return "Verbindung schwach"
        case .recovering:        return "Verbindung stellt sich wieder her"
        }
    }

    // MARK: - Waveform

    private var waveformStrip: some View {
        VStack(spacing: 6) {
            WaveformView(samples: waveformSamples, color: sessionActive ? .cyan : .white.opacity(0.2))
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Text("Mein Mikro")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                if appState.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("REC")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appState.transcriptSegments.suffix(3)) { seg in
                    Text(seg.text)
                        .font(.system(size: 13))
                        .foregroundStyle(seg.isFinal ? .white.opacity(0.85) : .white.opacity(0.4))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.05), in: Capsule())
                }
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // Live data pull-up
                controlButton(
                    icon: "chart.bar.xaxis",
                    label: "Live",
                    active: showLiveData
                ) { showLiveData = true }

                // MAIN: Start/Stop
                mainButton

                // Profile picker
                controlButton(
                    icon: "slider.horizontal.3",
                    label: activeProfileName,
                    active: showProfiles
                ) { showProfiles = true }
            }

            // Privacy Mode button
            if appState.privacyModeActive {
                privacyBanner
            }
        }
    }

    private var mainButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                sessionActive.toggle()
            }
        } label: {
            ZStack {
                // Outer ring pulse when active
                if sessionActive {
                    Circle()
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 12)
                        .frame(width: 88, height: 88)
                }
                Circle()
                    .fill(
                        sessionActive
                        ? LinearGradient(colors: [.cyan, Color(red: 0.0, green: 0.6, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: sessionActive ? .cyan.opacity(0.5) : .clear, radius: 16)

                Image(systemName: sessionActive ? "waveform" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: sessionActive)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func controlButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(active ? .cyan : .white.opacity(0.5))
                    .frame(width: 52, height: 52)
                    .background(
                        active ? Color.cyan.opacity(0.12) : Color.white.opacity(0.06),
                        in: Circle()
                    )
                    .overlay(
                        Circle().strokeBorder(
                            active ? Color.cyan.opacity(0.4) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                    )
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var privacyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            Text("Privacy Mode aktiv · Keine Cloud-Verbindungen")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Spacer()
            Button {
                PrivacyMode.shared.deactivate()
                appState.privacyModeActive = false
            } label: {
                Text("Deaktivieren")
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Profile Sheet

    private var profileSheet: some View {
        NavigationStack {
            ProfilePickerView(
                selected: SessionProfile.builtIn.first { $0.id == appState.profileID },
                onSelect: { profile in
                    appState.profileID = profile.id
                    showProfiles = false
                }
            )
            .environmentObject(appState)
            .navigationTitle("Profil wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { showProfiles = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
        .preferredColorScheme(.dark)
    }

    private var activeProfileName: String {
        SessionProfile.builtIn.first { $0.id == appState.profileID }?.displayName ?? "Profil"
    }

    // MARK: - Simulator fake distance animation

    private func animateFakeDistance() {
        // Slowly animate a fake distance for simulator demo
        let distances: [Double] = [8.0, 5.5, 3.2, 1.8, 1.0, 0.8, 1.2, 2.4, 4.0, 6.0]
        for (i, d) in distances.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.5) {
                guard self.sessionActive else { return }
                withAnimation(.easeInOut(duration: 1.0)) {
                    self.previewDistance = d
                }
                if d < 1.0 {
                    // Simulate near phase
                    self.appState.phase = .near(distance: d)
                } else {
                    self.appState.phase = .far
                }
            }
        }
        // Simulate signal score changes
        let scores = [100, 94, 87, 78, 65, 82, 91, 96]
        for (i, s) in scores.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.0) {
                guard self.sessionActive else { return }
                self.appState.signalScore = s
                self.appState.activePathCount = s > 80 ? 4 : s > 60 ? 3 : 2
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SessionView()
        .environmentObject({ () -> AppState in
            let s = AppState()
            s.phase = .near(distance: 2.4)
            s.signalScore = 92
            s.activePathCount = 4
            s.isRecording = true
            return s
        }())
        .preferredColorScheme(.dark)
}
