import AppIntents
import AVFoundation
import Foundation

/// Coordinates AirPods listening modes via the system "Set Noise Control Mode"
/// App Intent. Plan §9 / §10/10.
@MainActor
final class AirPodsController {
    func apply(profile: SessionProfile) async {
        // TODO §10/10: invoke SetListeningModeIntent with mapped value.
    }
}
