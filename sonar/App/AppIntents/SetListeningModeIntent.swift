import AppIntents
import Foundation

// MARK: - Notification name

extension Notification.Name {
    /// Posted when a Siri / Shortcuts intent requests a listening-mode nudge.
    /// The `object` is the raw `String` mode value
    /// (one of "off", "transparency", "noiseCancellation", "adaptive").
    static let sonarSetListeningMode = Notification.Name("sonar.airpods.setListeningMode")
}

// MARK: - AppEnum

enum ListeningMode: String, AppEnum {
    case off, transparency, noiseCancellation, adaptive

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AirPods Hörpräferenz"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Aus anfragen",
        .transparency: "Transparenz anfragen",
        .noiseCancellation: "Geräuschunterdrückung anfragen",
        .adaptive: "Adaptiv anfragen"
    ]
}

// MARK: - Intent

struct SetListeningModeIntent: AppIntent {
    static let title: LocalizedStringResource = "AirPods Hörpräferenz anfragen"
    static let description = IntentDescription(
        "Fragt iOS best-effort an, Sonars bevorzugte AirPods-Hörpräferenz zu berücksichtigen. iOS und AirPods entscheiden, was tatsächlich aktiv wird."
    )

    @Parameter(title: "Gewünschte Hörpräferenz")
    var mode: ListeningMode

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AirPodsController().setListeningMode(mode.rawValue)
        return .result(
            dialog: "Ich frage diese AirPods-Hörpräferenz best-effort bei iOS an. iOS und AirPods entscheiden, was aktiv wird."
        )
    }
}
