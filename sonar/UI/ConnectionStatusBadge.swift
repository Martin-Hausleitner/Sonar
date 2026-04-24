import SwiftUI

struct ConnectionStatusBadge: View {
    let phase: AppState.Phase

    var body: some View {
        // TODO §10/8: live badge fed by SessionCoordinator state machine.
        Text(label)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }

    private var label: String {
        switch phase {
        case .idle: "—"
        case .connecting: "connecting"
        case .near: "near"
        case .far: "far"
        case .degrading: "degrading"
        case .recovering: "recovering"
        }
    }
}
