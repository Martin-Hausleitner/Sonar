import SwiftUI

struct SessionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Sonar")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
            Text("Hello Sonar")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(phaseLabel)
                .font(.footnote.monospaced())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(
            colors: [.black, Color(red: 0.05, green: 0.05, blue: 0.12)],
            startPoint: .top,
            endPoint: .bottom
        ))
        .foregroundStyle(.white)
        .ignoresSafeArea()
    }

    private var phaseLabel: String {
        switch appState.phase {
        case .idle: return "idle"
        case .connecting: return "connecting…"
        case .near(let d): return String(format: "near · %.2f m", d)
        case .far: return "far"
        case .degrading: return "degrading"
        case .recovering: return "recovering"
        }
    }
}

#Preview {
    SessionView()
        .environmentObject(AppState())
}
