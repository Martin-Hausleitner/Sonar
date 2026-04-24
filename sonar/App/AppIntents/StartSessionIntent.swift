import AppIntents

struct StartSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Sonar starten"
    static var description = IntentDescription(
        "Startet eine Sonar-Session mit dem zuletzt verbundenen Partner."
    )
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // TODO §10/9: trigger SessionCoordinator.startSession()
        return .result()
    }
}
