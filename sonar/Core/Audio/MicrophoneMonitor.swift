import AVFoundation
import Foundation

enum MicrophoneMonitor {
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(frameCount))
    }

    static func shouldForwardCapturedAudio(isMuted: Bool) -> Bool {
        !isMuted
    }
}
