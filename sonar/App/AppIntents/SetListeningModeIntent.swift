import AppIntents

enum ListeningMode: String, AppEnum {
    case off, transparency, noiseCancellation, adaptive

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AirPods Listening Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .transparency: "Transparency",
        .noiseCancellation: "Noise Cancellation",
        .adaptive: "Adaptive"
    ]
}

struct SetListeningModeIntent: AppIntent {
    static let title: LocalizedStringResource = "AirPods Listening Mode setzen"

    @Parameter(title: "Mode")
    var mode: ListeningMode

    func perform() async throws -> some IntentResult {
        // TODO §10/10: bridge to system "Set Noise Control Mode" via AirPodsController.
        return .result()
    }
}
