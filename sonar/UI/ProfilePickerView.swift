import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var appState: AppState

    // The list of profiles is static; ProfileManager owns the selection.
    private let profiles = SessionProfile.builtIn

    // Callback-based variant (can also be used standalone).
    var selected: SessionProfile? = nil
    var onSelect: ((SessionProfile) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(profiles) { profile in
                    ProfileCard(
                        profile: profile,
                        isSelected: isSelected(profile)
                    )
                    .onTapGesture {
                        onSelect?(profile)
                    }
                }
            }
            .padding()
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

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundStyle(isSelected ? accentColor : .secondary)

            Text(profile.displayName)
                .font(.headline)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? accentColor.opacity(0.12) : Color(.systemGray6).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? accentColor : Color.white.opacity(0.07),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private var accentColor: Color {
        switch profile.id {
        case "zimmer":   .blue
        case "roller":   .orange
        case "festival": .pink
        case "club":     .purple
        case "zen":      .teal
        default:         .green
        }
    }

    private var iconName: String {
        switch profile.id {
        case "zimmer":   "house.fill"
        case "roller":   "scooter"
        case "festival": "tent.fill"
        case "club":     "headphones"
        case "zen":      "leaf.fill"
        default:         "waveform"
        }
    }

    private var description: String {
        switch profile.id {
        case "zimmer":   "Ruhige Umgebung, transparentes Hören"
        case "roller":   "Unterwegs, Lärmunterdrückung aktiv"
        case "festival": "Outdoor-Event, maximale Verstärkung"
        case "club":     "Laut, Bass, Musik-Mix"
        case "zen":      "Minimale Stimulation, leiser Modus"
        default:         ""
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
