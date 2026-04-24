import AVFoundation
import Foundation

/// Voice activity detection. Plan §8.2 trigger #2.
final class VAD {
    private(set) var isSpeaking = false

    func feed(_ buffer: AVAudioPCMBuffer) -> Bool {
        // TODO §10/12: WebRTC-VAD-style energy + zero-crossing classifier.
        return isSpeaking
    }
}
