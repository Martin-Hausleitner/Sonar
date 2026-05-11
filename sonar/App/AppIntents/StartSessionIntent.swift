import AppIntents
import Foundation

// MARK: - Notification name

extension Notification.Name {
    /// Posted by the AppIntent entry point. `SonarApp` decides whether the
    /// request can be dispatched immediately or must wait for onboarding.
    static let sonarStartSessionRequested = Notification.Name("sonarStartSessionRequested")

    /// Posted when a Siri / Shortcuts intent requests a new Sonar session.
    /// Mounted session UI observes this and calls into `SessionCoordinator`.
    static let sonarStartSession = Notification.Name("sonarStartSession")
}

struct StartSessionIntentRoutingDecision: Equatable {
    enum Action: Equatable {
        case dispatchToMountedSession
        case queueUntilOnboarded
    }

    let action: Action
    let profileID: String
}

enum StartSessionIntentRouter {
    static func decision(onboarded: Bool, profileID: String) -> StartSessionIntentRoutingDecision {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return StartSessionIntentRoutingDecision(
            action: onboarded ? .dispatchToMountedSession : .queueUntilOnboarded,
            profileID: trimmed.isEmpty ? "zimmer" : trimmed
        )
    }
}

// MARK: - Intent

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Sonar starten"
    static let description = IntentDescription(
        "Startet eine Sonar-Session mit dem zuletzt verbundenen Partner."
    )
    static let openAppWhenRun: Bool = true

    /// Optional profile ID to activate before starting.
    /// Defaults to "zimmer" when omitted.
    @Parameter(title: "Profil", default: "zimmer")
    var profileID: String

    func perform() async throws -> some IntentResult {
        // The app root receives this first because SessionView is not mounted
        // until onboarding is complete. SonarApp queues or forwards it.
        NotificationCenter.default.post(
            name: .sonarStartSessionRequested,
            object: profileID
        )
        return .result()
    }
}
