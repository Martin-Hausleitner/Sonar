import SwiftUI

struct ConnectionStatusBadge: View {
    let score: Int
    let activePaths: Int
    let phase: AppState.Phase

    var body: some View {
        HStack(spacing: 6) {
            // Signal score circle
            ZStack {
                Circle()
                    .fill(scoreColor.opacity(0.2))
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(scoreColor, lineWidth: 2)
                    .frame(width: 22, height: 22)
                Text("\(score)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(scoreColor)
            }

            // Phase text
            Text(phaseLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)

            // Active path dots
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < activePaths ? scoreColor : Color.secondary.opacity(0.18))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }

    // MARK: - Derived

    private var scoreColor: Color {
        switch score {
        case 80...100: .green
        case 60..<80:  .yellow
        case 40..<60:  .orange
        default:       .red
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle:           "—"
        case .connecting:     "Verbindet…"
        case .near:           "Near"
        case .far:            "Far"
        case .degrading:      "Degrading"
        case .recovering:     "Recovering"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        ConnectionStatusBadge(score: 92, activePaths: 4, phase: .near(distance: 1.2))
        ConnectionStatusBadge(score: 65, activePaths: 2, phase: .far)
        ConnectionStatusBadge(score: 38, activePaths: 1, phase: .degrading)
        ConnectionStatusBadge(score: 0, activePaths: 0, phase: .connecting)
    }
    .padding()
    .background(.black)
}
