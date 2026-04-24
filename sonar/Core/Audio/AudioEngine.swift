import AVFoundation
import Combine
import Foundation

/// AVAudioEngine + VoiceProcessingIO. Plan §10/3.
@MainActor
final class AudioEngine {
    private let engine = AVAudioEngine()

    let captured = PassthroughSubject<AVAudioPCMBuffer, Never>()

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowAirPlay]
        )
        try session.setActive(true, options: [])

        // Voice processing must be enabled BEFORE prepare(). RESEARCH.md §6.
        try engine.inputNode.setVoiceProcessingEnabled(true)

        let format = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buf, _ in
            self?.captured.send(buf)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
