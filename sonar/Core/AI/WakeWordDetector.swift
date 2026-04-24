import AVFoundation
import Combine
import Foundation

/// On-device "Hey Sonar" detection. Plan §10/12.
final class WakeWordDetector {
    let triggered = PassthroughSubject<Void, Never>()

    func start() {
        // TODO §10/12: integrate Picovoice Porcupine with custom keyword.
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // TODO §10/12
    }

    func stop() {}
}
