import SwiftUI

/// Pull-up sheet showing all live metrics — §10 Signal Score, paths, battery, latency.
struct LiveDataSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var latency: (p50: Double, p95: Double, p99: Double)? = nil

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.2))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text("Live Daten")
                .font(.title3.bold())
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 12) {
                    signalCard
                    pathsCard
                    batteryCard
                    latencyCard
                    sessionCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(.ultraThinMaterial)
        .onAppear { refreshLatency() }
        .onReceive(refreshTimer) { _ in refreshLatency() }
    }

    // MARK: - Cards

    private var signalCard: some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Signal", systemImage: "wifi")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(appState.signalScore)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(signalColor)
                        Text("/ 100")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                    Text(appState.signalGrade.label)
                        .font(.caption)
                        .foregroundStyle(signalColor)
                }
                Spacer()
                ZStack {
                    Circle()
                        .trim(from: 0, to: CGFloat(appState.signalScore) / 100)
                        .stroke(signalColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 6)
                        .frame(width: 60, height: 60)
                }
            }
        }
    }

    private var pathsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Multipath Bonding", systemImage: "arrow.triangle.branch")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    pathDot(label: "BT", id: 0)
                    pathDot(label: "WLAN", id: 1)
                    pathDot(label: "4G/5G", id: 2)
                    pathDot(label: "TS", id: 3)
                }
            }
        }
    }

    private func pathDot(label: String, id: Int) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(id < appState.activePathCount ? Color.green : Color.white.opacity(0.1))
                .frame(width: 10, height: 10)
                .shadow(color: id < appState.activePathCount ? .green.opacity(0.6) : .clear, radius: 4)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(id < appState.activePathCount ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var batteryCard: some View {
        GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Akku", systemImage: "battery.100")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(batteryTierLabel)
                        .font(.title2.bold())
                    Text(batteryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                batteryIcon
            }
        }
    }

    private var batteryIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .stroke(batteryColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: 40, height: 22)
            RoundedRectangle(cornerRadius: 2)
                .fill(batteryColor)
                .frame(width: 34 * batteryFill, height: 16)
                .frame(width: 34, height: 16, alignment: .leading)
        }
    }

    private var latencyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Glass-to-Glass Latenz", systemImage: "waveform.path")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let lat = latency {
                    HStack(spacing: 0) {
                        latencyValue("P50", ms: lat.p50, target: 80)
                        latencyValue("P95", ms: lat.p95, target: 150)
                        latencyValue("P99", ms: lat.p99, target: 300)
                    }
                } else {
                    Text("Keine Session aktiv")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func latencyValue(_ label: String, ms: Double, target: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f", ms))
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(ms < target ? .green : ms < target * 1.5 ? .yellow : .red)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionCard: some View {
        GlassCard {
            HStack(spacing: 16) {
                sessionStatus(icon: "circle.fill", label: "Aufnahme",
                              active: appState.isRecording, activeColor: .red)
                sessionStatus(icon: "captions.bubble", label: "Transkript",
                              active: !appState.transcriptSegments.isEmpty, activeColor: .blue)
                sessionStatus(icon: "lock.shield", label: "Privacy",
                              active: appState.privacyModeActive, activeColor: .orange)
            }
        }
    }

    private func sessionStatus(icon: String, label: String, active: Bool, activeColor: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(active ? activeColor : Color.white.opacity(0.2))
                .shadow(color: active ? activeColor.opacity(0.6) : .clear, radius: 4)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var signalColor: Color {
        switch appState.signalScore {
        case 80...100: .green
        case 60..<80:  .yellow
        case 40..<60:  .orange
        default:       .red
        }
    }

    private var batteryTierLabel: String {
        switch appState.batteryTier {
        case .normal:   "Normal"
        case .eco:      "Eco"
        case .saver:    "Saver"
        case .critical: "Kritisch"
        }
    }

    private var batteryDescription: String {
        switch appState.batteryTier {
        case .normal:   "~6 %/h · 4 Pfade aktiv"
        case .eco:      "~4 %/h · 2 Pfade aktiv"
        case .saver:    "~2.5 %/h · 1 Pfad aktiv"
        case .critical: "~1 %/h · PTT erzwungen"
        }
    }

    private var batteryColor: Color {
        switch appState.batteryTier {
        case .normal:   .green
        case .eco:      .yellow
        case .saver:    .orange
        case .critical: .red
        }
    }

    private var batteryFill: CGFloat {
        switch appState.batteryTier {
        case .normal:   0.95
        case .eco:      0.65
        case .saver:    0.3
        case .critical: 0.08
        }
    }

    private func refreshLatency() {
        latency = Metrics.shared.percentiles(.captured, .rendered)
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

#Preview {
    LiveDataSheet()
        .environmentObject(AppState())
        .background(Color(red: 0.05, green: 0.05, blue: 0.1))
        .preferredColorScheme(.dark)
}
