import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sonar braucht ein paar Berechtigungen")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 8)

            row("Mikrofon", state: permissions.microphone)
            row("Bluetooth", state: permissions.bluetooth)
            row("Lokales Netzwerk", state: permissions.localNetwork)
            row("Ultra-Wideband", state: permissions.nearbyInteraction)

            Spacer()

            Button {
                Task { await permissions.requestAll() }
            } label: {
                Text("Berechtigungen anfragen")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }

            Button(action: onContinue) {
                Text(permissions.allGranted ? "Weiter" : "Trotzdem weiter")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(false)
        }
        .padding(24)
    }

    @ViewBuilder
    private func row(_ label: String, state: PermissionsManager.State) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(state == .granted ? "✓" : state == .denied ? "✗" : "—")
                .foregroundStyle(state == .granted ? .green : state == .denied ? .red : .secondary)
                .monospaced()
        }
    }
}

#Preview {
    OnboardingView(permissions: PermissionsManager(), onContinue: {})
}
