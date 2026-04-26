import SwiftUI

struct AIAvatarBadge: View {
    let isActive: Bool

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Outer pulse ring (only when active)
            if isActive {
                Circle()
                    .fill(Color.green.opacity(pulseOpacity * 0.35))
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulseScale)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: pulseScale
                    )
            }

            // Background circle
            Circle()
                .fill(isActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
                .frame(width: 32, height: 32)

            // Border
            Circle()
                .strokeBorder(
                    isActive ? Color.green : Color.gray.opacity(0.4),
                    lineWidth: 1.5
                )
                .frame(width: 32, height: 32)

            // Icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? .green : .gray.opacity(0.5))
                .shadow(color: isActive ? .green.opacity(0.8) : .clear, radius: 4)
        }
        .frame(width: 44, height: 44)
        .onAppear { startPulse() }
        .onChange(of: isActive) { _, _ in startPulse() }
    }

    private func startPulse() {
        if isActive {
            pulseScale = 1.35
            pulseOpacity = 0.0
        } else {
            pulseScale = 1.0
            pulseOpacity = 0.6
        }
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 24) {
        AIAvatarBadge(isActive: false)
        AIAvatarBadge(isActive: true)
    }
    .padding(32)
    .background(Color(red: 0.05, green: 0.05, blue: 0.12))
    .preferredColorScheme(.dark)
}
