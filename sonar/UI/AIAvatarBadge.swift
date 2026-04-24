import SwiftUI

struct AIAvatarBadge: View {
    let active: Bool

    var body: some View {
        // TODO §10/12: animated avatar that lights up when AI is listening/speaking.
        Circle()
            .fill(active ? .green : .gray.opacity(0.3))
            .frame(width: 12, height: 12)
    }
}
