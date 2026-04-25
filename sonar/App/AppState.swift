import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case near(distance: Double)
        case far
        case degrading
        case recovering
    }

    @Published var phase: Phase = .idle
    @Published var profileID: String = "zimmer"
    @Published var aiActive: Bool = false

    // §6 — battery tier
    @Published var batteryTier: BatteryManager.Tier = .normal

    // §10 — signal quality
    @Published var signalScore: Int = 100
    @Published var signalGrade: SignalScoreCalculator.Grade = .excellent

    // §2.4 — active multipath count
    @Published var activePathCount: Int = 0

    // §9.2 — hardware tier
    let deviceCapabilities: DeviceCapabilities = DeviceCapabilities.detect()

    // §5 — live transcript
    @Published var transcriptSegments: [LiveTranscriptionEngine.Segment] = []

    // §4.2 — recording state
    @Published var isRecording: Bool = false

    // V30 — privacy mode
    @Published var privacyModeActive: Bool = false
}
