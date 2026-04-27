import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var appState: AppState

    private let profiles = SessionProfile.builtIn

    var selected: SessionProfile? = nil
    var onSelect: ((SessionProfile) -> Void)? = nil

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
            .padding()
        }
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
        VStack(spacing: 10) {
            // Top row: info button right-aligned
            HStack {
                Spacer()
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details zum Profil \(profile.displayName)")
            }
            .padding(.top, -6)

            Image(systemName: ProfileStyle.icon(profile.id))
                .font(.system(size: 32))
                .foregroundStyle(isSelected ? ProfileStyle.color(profile.id) : .secondary)

            Text(profile.displayName)
                .font(.headline)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(ProfileStyle.shortDescription(profile.id))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // Quick-glance setting chips so user sees what gets applied.
            HStack(spacing: 4) {
                miniChip(icon: ProfileStyle.listeningIcon(profile.listeningMode),
                         text: ProfileStyle.listeningShort(profile.listeningMode))
                miniChip(icon: "speaker.wave.2.fill",
                         text: "\(Int(profile.gain * 100))%")
                if profile.musicMix > 0 {
                    miniChip(icon: "music.note", text: "\(Int(profile.musicMix * 100))%")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? ProfileStyle.color(profile.id).opacity(0.12) : Color(.systemGray6).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? ProfileStyle.color(profile.id) : Color.white.opacity(0.07),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private func miniChip(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.06)))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Detail sheet

private struct ProfileDetailView: View {
    let profile: SessionProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(ProfileStyle.color(profile.id).opacity(0.15)).frame(width: 56, height: 56)
                        Image(systemName: ProfileStyle.icon(profile.id))
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(ProfileStyle.color(profile.id))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName).font(.title2.bold())
                        Text(ProfileStyle.shortDescription(profile.id))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                detailRow(
                    icon: ProfileStyle.listeningIcon(profile.listeningMode),
                    title: "AirPods-Modus",
                    value: ProfileStyle.listeningLabel(profile.listeningMode),
                    explain: ProfileStyle.listeningExplain(profile.listeningMode)
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
                    value: profile.musicMix > 0 ? "\(Int(profile.musicMix * 100)) % beibehalten" : "Aus",
                    explain: profile.musicMix > 0
                        ? "Apple Music läuft im Hintergrund weiter, gedimmt auf diesen Pegel. Beim Sprechen wird kurz weiter gedimmt."
                        : "Kein paralleler Musik-Mix — die App pausiert keine Musik, dimmt sie aber auch nicht aktiv."
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
                    explain: "Ab dieser Entfernung wechselt Sonar von lokaler Direktverbindung auf das Internet-Relay."
                )
                detailRow(
                    icon: ProfileStyle.aiIcon(profile.aiTrigger),
                    title: "KI-Auslöser",
                    value: ProfileStyle.aiLabel(profile.aiTrigger),
                    explain: ProfileStyle.aiExplain(profile.aiTrigger)
                )
            } header: {
                Text("Was dieses Profil einstellt")
            } footer: {
                Text("Werte werden beim Wechsel sofort angewendet — keine Session-Neustart nötig.")
            }
        }
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
                .foregroundStyle(ProfileStyle.color(profile.id))
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

// MARK: - Style helpers (shared by card + detail)

private enum ProfileStyle {
    static func color(_ id: String) -> Color {
        switch id {
        case "zimmer":   .blue
        case "roller":   .orange
        case "festival": .pink
        case "club":     .purple
        case "zen":      .teal
        default:         .green
        }
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "zimmer":   "house.fill"
        case "roller":   "scooter"
        case "festival": "tent.fill"
        case "club":     "headphones"
        case "zen":      "leaf.fill"
        default:         "waveform"
        }
    }

    static func shortDescription(_ id: String) -> String {
        switch id {
        case "zimmer":   "Drinnen, ruhig, transparentes Hören"
        case "roller":   "Unterwegs, Lärmunterdrückung"
        case "festival": "Outdoor-Crowd, maximale Stimme"
        case "club":     "Laut, Bass, Musik-Mix erlaubt"
        case "zen":      "Minimal-Setup, leiser Modus"
        default:         ""
        }
    }

    static func listeningIcon(_ mode: String) -> String {
        switch mode {
        case "transparency":      return "ear"
        case "noiseCancellation": return "ear.badge.waveform"
        case "adaptive":          return "wand.and.stars"
        default:                   return "ear.trianglebadge.exclamationmark"
        }
    }
    static func listeningShort(_ mode: String) -> String {
        switch mode {
        case "transparency":      return "Transp."
        case "noiseCancellation": return "ANC"
        case "adaptive":          return "Adapt."
        default:                   return "Aus"
        }
    }
    static func listeningLabel(_ mode: String) -> String {
        switch mode {
        case "transparency":      return "Transparenz"
        case "noiseCancellation": return "Aktive Lärmunterdrückung"
        case "adaptive":          return "Adaptiv"
        default:                   return "Aus"
        }
    }
    static func listeningExplain(_ mode: String) -> String {
        switch mode {
        case "transparency":
            return "AirPods lassen Umgebung durch — du hörst Realität + Peer gemischt."
        case "noiseCancellation":
            return "AirPods blocken Umgebungslärm — nur der Peer dringt klar durch."
        case "adaptive":
            return "AirPods entscheiden je nach Lärmpegel automatisch."
        default:
            return "AirPods-Modus bleibt unverändert."
        }
    }

    static func aiIcon(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly:      return "mic.circle"
        case .wakeWordAndPause:  return "ear.and.waveform"
        case .manualOnly:        return "hand.tap.fill"
        case .doubleTap:         return "hand.tap"
        case .tapOnly:           return "hand.point.up.left.fill"
        }
    }
    static func aiLabel(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly:      return "\"Hey Sonar\""
        case .wakeWordAndPause:  return "\"Hey Sonar\" + Frage-Pause"
        case .manualOnly:        return "Nur manuell"
        case .doubleTap:         return "AirPods-Doppeltipp"
        case .tapOnly:           return "Tipp im UI"
        }
    }
    static func aiExplain(_ trigger: SessionProfile.AITrigger) -> String {
        switch trigger {
        case .wakeWordOnly:
            return "KI antwortet nur, wenn du \"Hey Sonar\" sagst."
        case .wakeWordAndPause:
            return "Wake Word ODER eine offene Frage gefolgt von ~4 s Stille triggern die KI."
        case .manualOnly:
            return "Kein automatischer Trigger — KI muss aktiv aufgerufen werden."
        case .doubleTap:
            return "Doppeltipp auf den AirPods-Stem startet eine KI-Antwort."
        case .tapOnly:
            return "Nur ein Tipp im UI startet die KI."
        }
    }
}

// MARK: - Preview

#Preview {
    ProfilePickerView()
        .environmentObject({ () -> AppState in
            let s = AppState(); s.profileID = "festival"; return s
        }())
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
        .preferredColorScheme(.dark)
}
