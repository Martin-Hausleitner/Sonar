import Foundation

struct SessionProfile: Codable, Identifiable, Equatable, Sendable {
    enum BuiltIn: String, Codable, CaseIterable {
        case zimmer, roller, festival, club, zen
    }

    let id: String
    let displayName: String
    let duplicateThreshold: Double  // metres — below this, mute remote voice
    let nearFarThreshold: Double    // metres — above this, switch to LiveKit
    let listeningMode: String       // off | transparency | noiseCancellation | adaptive
    let gain: Double                // 0..1
    let musicMix: Double            // 0..1, 0 == no music
    let aiTrigger: AITrigger

    enum AITrigger: String, Codable {
        case wakeWordOnly, wakeWordAndPause, manualOnly, doubleTap, tapOnly
    }
}

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var profiles: [SessionProfile] = SessionProfile.builtIn
    @Published var selected: SessionProfile = SessionProfile.builtIn[0]

    func select(_ id: String) {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        selected = p
    }
}

extension SessionProfile {
    static let builtIn: [SessionProfile] = [
        .init(id: "zimmer",   displayName: "Zimmer",
              duplicateThreshold: 1.0, nearFarThreshold: 8,
              listeningMode: "transparency", gain: 0.4, musicMix: 0,
              aiTrigger: .wakeWordOnly),
        .init(id: "roller",   displayName: "Roller",
              duplicateThreshold: 0.5, nearFarThreshold: 15,
              listeningMode: "noiseCancellation", gain: 0.7, musicMix: 0,
              aiTrigger: .wakeWordAndPause),
        .init(id: "festival", displayName: "Festival",
              duplicateThreshold: 0.5, nearFarThreshold: 5,
              listeningMode: "noiseCancellation", gain: 0.9, musicMix: 0,
              aiTrigger: .manualOnly),
        .init(id: "club",     displayName: "Club",
              duplicateThreshold: 0.5, nearFarThreshold: 3,
              listeningMode: "noiseCancellation", gain: 0.95, musicMix: 0.3,
              aiTrigger: .doubleTap),
        .init(id: "zen",      displayName: "Zen",
              duplicateThreshold: 1.5, nearFarThreshold: 6,
              listeningMode: "transparency", gain: 0.2, musicMix: 0,
              aiTrigger: .tapOnly)
    ]
}
