import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var appState: AppState

    private let profiles = SessionProfile.builtIn

    var selected: SessionProfile?
    var onSelect: ((SessionProfile) -> Void)?

    @State private var infoProfile: SessionProfile? = nil

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(profiles) { profile in
                    ProfileCard(
                        profile: profile,
                        isSelected: isSelected(profile),
                        onInfo: { infoProfile = profile }
                    )
                    .onTapGesture { onSelect?(profile) }
                }
            }
            .padding(SonarTheme.horizontalPadding)
        }
        .background(SonarTheme.screenBackground.ignoresSafeArea())
        .sheet(item: $infoProfile) { p in
            NavigationStack { ProfileDetailView(profile: p) }
                .presentationDetents([.medium, .large])
        }
    }

    private func isSelected(_ profile: SessionProfile) -> Bool {
        if let sel = selected { return sel.id == profile.id }
        return appState.profileID == profile.id
    }
}

// MARK: - Card

private struct ProfileCard: View {
    let profile: SessionProfile
    let isSelected: Bool
    let onInfo: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Top row: info button right-aligned
            HStack {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ProfileVisuals.color(profile.id))
                        .accessibilityHidden(true)
                }
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.secondary.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details zum Profil \(profile.displayName)")
            }

            Image(systemName: ProfileVisuals.icon(profile.id))
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? ProfileVisuals.color(profile.id) : .secondary)

            Text(profile.displayName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(ProfileVisuals.shortDescription(profile.id))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // Quick-glance setting chips so user sees what gets applied.
            HStack(spacing: 4) {
                miniChip(
                    icon: ProfileVisuals.listeningIcon(profile.listeningMode),
                    text: ProfileVisuals.listeningShort(profile.listeningMode)
                )
                miniChip(
                    icon: "speaker.wave.2.fill",
                    text: "\(Int(profile.gain * 100))%"
                )
                if profile.musicMix > 0 {
                    miniChip(icon: "music.note", text: "\(Int(profile.musicMix * 100))%")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 164)
        .background(
            RoundedRectangle(cornerRadius: SonarTheme.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SonarTheme.cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? ProfileVisuals.color(profile.id).opacity(0.8) : SonarTheme.separator,
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private func miniChip(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Detail sheet

struct ProfileDetailView: View {
    let profile: SessionProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(ProfileVisuals.color(profile.id).opacity(0.15)).frame(width: 56, height: 56)
                        Image(systemName: ProfileVisuals.icon(profile.id))
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(ProfileVisuals.color(profile.id))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName).font(.title2.bold())
                        Text(ProfileVisuals.shortDescription(profile.id))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                detailRow(
                    icon: ProfileVisuals.listeningIcon(profile.listeningMode),
                    title: "AirPods-Modus",
                    value: ProfileVisuals.listeningLabel(profile.listeningMode),
                    explain: ProfileVisuals.listeningExplain(profile.listeningMode)
                )
                detailRow(
                    icon: "speaker.wave.2.fill",
                    title: "Stimmen-Verstärkung",
                    value: "\(Int(profile.gain * 100)) %",
                    explain: "Wie laut der Peer in deinen AirPods erklingt — vor der globalen Sonar-Lautstärke."
                )
                detailRow(
                    icon: "music.note",
                    title: "Musik-Mix",
                    value: profile.musicMix > 0 ? "System-Ducking angefragt" : "Aus",
                    explain: profile.musicMix > 0
                        ? "Sonar bittet iOS, andere Audio-Apps parallel laufen zu lassen und bei Sprache zu ducken. Die tatsächliche Absenkung steuert das System."
                        : "Kein paralleler Musik-Mix — die App pausiert keine Musik und fragt kein aktives Ducking an."
                )
                detailRow(
                    icon: "ruler",
                    title: "Doppelstimme ab",
                    value: String(format: "%.1f m", profile.duplicateThreshold),
                    explain: "Unterhalb dieser Distanz wird die digitale Stimme stumm geschaltet, weil ihr euch akustisch hört (Plan §6)."
                )
                detailRow(
                    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    title: "Near → Far ab",
                    value: String(format: "%.0f m", profile.nearFarThreshold),
                    explain: "Ab dieser Entfernung verlässt Sonar den Near-Pfad und nutzt den besten aktuell verfügbaren Verbindungspfad als Fallback."
                )
                detailRow(
                    icon: ProfileVisuals.aiIcon(profile.aiTrigger),
                    title: "KI-Auslöser",
                    value: ProfileVisuals.aiLabel(profile.aiTrigger),
                    explain: ProfileVisuals.aiExplain(profile.aiTrigger)
                )
            } header: {
                Text("Was dieses Profil einstellt")
            } footer: {
                Text("Werte werden beim Wechsel sofort angewendet — keine Session-Neustart nötig.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SonarTheme.screenBackground.ignoresSafeArea())
        .navigationTitle("Profil-Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fertig") { dismiss() }
            }
        }
    }

    private func detailRow(icon: String, title: String, value: String, explain: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
                .foregroundStyle(ProfileVisuals.color(profile.id))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(explain).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Style helpers (shared by card + detail + in-session switcher)

enum ProfileVisuals {
    static func color(_ id: String) -> Color {
        switch id {
        case "zimmer": .blue
        case "roller": .orange
        case "festival": .pink
        case "club": .purple
        case "zen": .teal
        default: .green
        }
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "zimmer": "house.fill"
        case "roller": "scooter"
        case "festival": "tent.fill"
        case "club": "headphones"
        case "zen": "leaf.fill"
        default: "waveform"
        }
    }

    static func shortDescription(_ id: String) -> String {
        switch id {
        case "zimmer": "Drinnen, ruhig, transparentes Hören"
        case "roller": "Unterwegs, Lärmunterdrückung"
        case "festival": "Outdoor-Crowd, maximale Stimme"
        case "club": "Laut, Bass, Musik-Mix erlaubt"
        case "zen": "Minimal-Setup, leiser Modus"
        default: ""
        }
    }

    static func listeningIcon(_ mode: String) -> String {
        switch mode {
        case "transparency": "ear"
        case "noiseCancellation": "ear.badge.waveform"
        case "adaptive": "wand.and.stars"
        default: "ear.trianglebadge.exclamationmark"
        }
    }

    static func listeningShort(_ mode: String) -> String {
        switch mode {
        case "transparency": "Transp."
        case "noiseCancellation": "ANC"
        case "adaptive": "Adapt."
        default: "Aus"
        }
    }

    static func listeningLabel(_ mode: String) -> String {
        switch mode {
        case "transparency": "Transparenz"
        case "noiseCancellation": "Aktive Lärmunterdrückung"
        case "adaptive": "Adaptiv"
        default: "Aus"
        }
    }

    static func listeningExplain(_ mode: String) -> String {
        switch mode {
        case "transparency":
            "Sonar fragt Transparenz best-effort als Hörpräferenz an; iOS bestätigt Drittanbieter-Apps den aktiven Modus nicht."
        case "noiseCancellation":
            "Sonar fragt Geräuschunterdrückung best-effort als Hörpräferenz an; die tatsächliche Wirkung liegt bei iOS und den AirPods."
        case "adaptive":
            "Sonar fragt Adaptiv best-effort als Hörpräferenz an; iOS und AirPods entscheiden, was tatsächlich aktiv wird."
        default:
            "AirPods-Modus bleibt unverändert."
        }
    }

    static func aiIcon(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly: "mic.circle"
        case .wakeWordAndPause: "ear.and.waveform"
        case .manualOnly: "hand.tap.fill"
        case .doubleTap: "hand.tap"
        case .tapOnly: "hand.point.up.left.fill"
        }
    }

    static func aiLabel(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly: "\"Hey Sonar\""
        case .wakeWordAndPause: "\"Hey Sonar\" + Frage-Pause"
        case .manualOnly: "Nur manuell"
        case .doubleTap: "AirPods-Doppeltipp"
        case .tapOnly: "Tipp im UI"
        }
    }

    static func aiExplain(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly:
            "KI antwortet nur, wenn du \"Hey Sonar\" sagst."
        case .wakeWordAndPause:
            "Wake Word ODER eine offene Frage gefolgt von ~4 s Stille triggern die KI."
        case .manualOnly:
            "Kein automatischer Trigger — KI muss aktiv aufgerufen werden."
        case .doubleTap:
            "Doppeltipp auf den AirPods-Stem startet eine KI-Antwort."
        case .tapOnly:
            "Nur ein Tipp im UI startet die KI."
        }
    }
}

// MARK: - Preview

#Preview {
    ProfilePickerView()
        .environmentObject({ () -> AppState in
            let s = AppState()
            s.profileID = "festival"
            return s
        }())
        .background(SonarTheme.screenBackground)
        .preferredColorScheme(.dark)
}
