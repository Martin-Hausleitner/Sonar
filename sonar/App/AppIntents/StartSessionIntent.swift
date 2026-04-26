import AppIntents
import Foundation

// MARK: - Notification name

extension Notification.Name {
    /// Posted when a Siri / Shortcuts intent requests a new Sonar session.
    /// The SessionCoordinator observes this and calls `start()`.
    static let sonarStartSession = Notification.Name("sonarStartSession")
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
        // Post a notification carrying the requested profileID as the object.
        // SessionCoordinator (and/or AppState) observes .sonarStartSession and
        // routes to ProfileManager.select(_:) + SessionCoordinator.start().
        NotificationCenter.default.post(
            name: .sonarStartSession,
            object: profileID
        )
        return .result()
    }
}
