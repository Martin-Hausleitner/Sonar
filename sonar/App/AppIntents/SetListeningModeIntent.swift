import AppIntents
import Foundation

// MARK: - Notification name

extension Notification.Name {
    /// Posted when a Siri / Shortcuts intent (or AirPodsController) requests a
    /// listening-mode change.  The `object` is the raw `String` mode value
    /// (one of "off", "transparency", "noiseCancellation", "adaptive").
    static let sonarSetListeningMode = Notification.Name("sonar.airpods.setListeningMode")
}

// MARK: - AppEnum

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

// MARK: - Intent

struct SetListeningModeIntent: AppIntent {
    static let title: LocalizedStringResource = "AirPods Listening Mode setzen"

    @Parameter(title: "Mode")
    var mode: ListeningMode

    func perform() async throws -> some IntentResult {
        // Bridge to AirPodsController via notification so that the intent can
        // run in the Shortcuts / Siri extension process without a direct
        // dependency on the app's object graph.
        NotificationCenter.default.post(
            name: .sonarSetListeningMode,
            object: mode.rawValue
        )
        return .result()
    }
}
