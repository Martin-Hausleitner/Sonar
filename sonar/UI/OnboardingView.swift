import SwiftUI

// MARK: - OnboardingView

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    let onContinue: () -> Void

    @State private var radarPulse: CGFloat = 0.7
    @State private var appeared = false
    @State private var requesting = false

    private let accentCyan = Color(red: 0.00, green: 0.89, blue: 1.00)
    private let accentBlue = Color(red: 0.10, green: 0.55, blue: 1.00)

    var body: some View {
        ZStack {
            // MARK: Background
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.02, green: 0.03, blue: 0.08), location: 0.0),
                    .init(color: Color(red: 0.04, green: 0.06, blue: 0.13), location: 0.5),
                    .init(color: Color(red: 0.03, green: 0.04, blue: 0.10), location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Top ambient glow
            RadialGradient(
                colors: [accentCyan.opacity(0.14), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: Scrollable content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 28) {
                        heroSection
                            .padding(.top, 24)

                        permissionsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                // MARK: Pinned bottom CTA (never scrolls away)
                Divider()
                    .background(.white.opacity(0.06))

                VStack(spacing: 10) {
                    requestButton
                    continueButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 36)
                .background(
                    Color(red: 0.03, green: 0.04, blue: 0.10)
                        .opacity(0.95)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.easeOut(duration: 0.65).delay(0.08)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                radarPulse = 1.0
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 18) {
            // Animated radar
            ZStack {
                // Pulsing rings
                ForEach([0, 1, 2], id: \.self) { i in
                    let base = CGFloat(60 + i * 22)
                    Circle()
                        .strokeBorder(accentCyan.opacity(0.14 - Double(i) * 0.04), lineWidth: 1)
                        .frame(width: base, height: base)
                        .scaleEffect(radarPulse + CGFloat(i) * 0.07)
                        .animation(
                            .easeInOut(duration: 2.6 + Double(i) * 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.35),
                            value: radarPulse
                        )
                }

                // Center icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [accentCyan.opacity(0.30), accentBlue.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)

                    Circle()
                        .strokeBorder(accentCyan.opacity(0.55), lineWidth: 1)
                        .frame(width: 56, height: 56)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accentCyan)
                        .shadow(color: accentCyan.opacity(0.7), radius: 8)
                }
            }
            .frame(height: 110)

            // Wordmark + subtitle
            VStack(spacing: 6) {
                Text("SONAR")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .tracking(7)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, accentCyan.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("Für den vollen Funktionsumfang benötigt\nSonar die folgenden Berechtigungen.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
    }

    // MARK: - Permission cards

    private var permissionsSection: some View {
        VStack(spacing: 9) {
            permissionCard(
                icon: "mic.fill",
                iconColor: accentCyan,
                title: "Mikrofon",
                description: "Stimme aufnehmen und in Echtzeit übertragen",
                state: permissions.microphone,
                delay: 0.15
            )
            permissionCard(
                icon: "waveform",
                iconColor: Color(red: 0.45, green: 0.55, blue: 1.00),
                title: "Spracherkennung",
                description: "Live-Transkription während des Gesprächs",
                state: permissions.speechRecognition,
                delay: 0.22
            )
            permissionCard(
                icon: "antenna.radiowaves.left.and.right",
                iconColor: Color(red: 0.20, green: 0.78, blue: 0.65),
                title: "Bluetooth",
                description: "AirPods und nahe Geräte finden",
                state: permissions.bluetooth,
                delay: 0.29
            )
            permissionCard(
                icon: "network",
                iconColor: Color(red: 0.58, green: 0.45, blue: 1.00),
                title: "Lokales Netzwerk",
                description: "Direktverbindung ohne Umweg über das Internet",
                state: permissions.localNetwork,
                delay: 0.36
            )
            permissionCard(
                icon: "dot.radiowaves.left.and.right",
                iconColor: Color(red: 1.00, green: 0.65, blue: 0.22),
                title: "Ultra-Wideband",
                description: "Entfernung zentimetergenau messen",
                state: permissions.nearbyInteraction,
                delay: 0.43
            )
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 24)
    }

    @ViewBuilder
    private func permissionCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        state: PermissionsManager.State,
        delay: Double
    ) -> some View {
        HStack(spacing: 13) {
            // Icon pill
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 42, height: 42)
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(iconColor.opacity(0.22), lineWidth: 1)
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(description)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // State indicator
            stateBadge(state)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(
                    state == .granted ? accentCyan.opacity(0.32) : .white.opacity(0.07),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.35), value: state)
    }

    @ViewBuilder
    private func stateBadge(_ state: PermissionsManager.State) -> some View {
        switch state {
        case .granted:
            ZStack {
                Circle()
                    .fill(accentCyan.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accentCyan)
            }
            .transition(.scale(scale: 0.5).combined(with: .opacity))

        case .denied:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 24, height: 24)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
            .transition(.scale(scale: 0.5).combined(with: .opacity))

        case .unknown:
            Circle()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1.5)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - Buttons

    private var requestButton: some View {
        Button {
            requesting = true
            Task {
                await permissions.requestAll()
                requesting = false
            }
        } label: {
            ZStack {
                if requesting {
                    ProgressView().tint(.white)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Alle freigeben")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [accentCyan, accentBlue],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: accentCyan.opacity(0.30), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(requesting)
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text(permissions.allGranted ? "Weiter →" : "Überspringen")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(permissions.allGranted ? 0.7 : 0.30))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(
        permissions: {
            let m = PermissionsManager()
            m.microphone = .granted
            m.speechRecognition = .unknown
            m.bluetooth = .unknown
            m.localNetwork = .unknown
            m.nearbyInteraction = .granted
            return m
        }(),
        onContinue: {}
    )
}
