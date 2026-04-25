import AVFoundation
import Combine
import Foundation

/// V22 — Double-tap AirPod triggers 5-second ambient sound share.
/// Taps the raw microphone input (no voice processing) and sends it as a one-shot stream.
@MainActor
final class AmbientSharing {
    private(set) var isSharing = false
    private var stopTimer: Timer?
    let ambientBuffer = PassthroughSubject<AVAudioPCMBuffer, Never>()

    private let shareDuration: TimeInterval = 5.0

    func start() {
        guard !isSharing else { return }
        isSharing = true
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: shareDuration, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        isSharing = false
        stopTimer?.invalidate()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard isSharing else { return }
        ambientBuffer.send(buffer)
    }
}
