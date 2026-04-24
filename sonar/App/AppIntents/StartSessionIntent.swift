import AppIntents

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Sonar starten"
    static let description = IntentDescription(
        "Startet eine Sonar-Session mit dem zuletzt verbundenen Partner."
    )
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // TODO §10/9: trigger SessionCoordinator.startSession()
        return .result()
    }
}
