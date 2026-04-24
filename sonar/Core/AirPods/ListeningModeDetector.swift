import AVFoundation
import Foundation

/// Reads back the AirPods' current listening mode where the OS exposes it.
/// Plan §9.
final class ListeningModeDetector {
    func current() -> String {
        // TODO §10/10: derive from AVAudioSession.routeDescription / outputs.
        return "unknown"
    }
}
