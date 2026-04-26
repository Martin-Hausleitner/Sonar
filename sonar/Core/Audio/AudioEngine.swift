import AVFoundation
import Combine
import Foundation

/// AVAudioEngine + VoiceProcessingIO. Plan §10/3, LATENCY.md.
///
/// Sets `AVAudioSession.preferredIOBufferDuration` to
/// `LatencyBudget.preferredIOBufferDurationSec` (5 ms) so the OS hands us
/// audio buffers as fast as the hardware allows.
@MainActor
final class AudioEngine {
    private let engine = AVAudioEngine()

    /// Each captured buffer is published with the frame ID it was assigned by
    /// `Metrics.openTrace()`. Subscribers must forward the ID through encode/
    /// transport/decode so glass-to-glass latency can be measured end-to-end.
    let captured = PassthroughSubject<(frameID: UInt64, buffer: AVAudioPCMBuffer), Never>()

    /// Attach a SpatialMixer before the engine starts so its nodes are part of the graph.
    func connect(spatialMixer: SpatialMixer) {
        spatialMixer.prepare(engine: engine)
    }

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .allowAirPlay]
        )
        try session.setPreferredIOBufferDuration(LatencyBudget.preferredIOBufferDurationSec)
        try session.setPreferredSampleRate(LatencyBudget.audioSampleRate)
        try session.setActive(true, options: [])

        // Voice processing must be enabled BEFORE prepare(). RESEARCH.md §6.
        try engine.inputNode.setVoiceProcessingEnabled(true)

        let format = engine.inputNode.inputFormat(forBus: 0)
        let bufSize = AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        engine.inputNode.installTap(onBus: 0, bufferSize: bufSize, format: format) { [weak self] buf, _ in
            guard let self else { return }
            let id = Metrics.shared.openTrace()
            Metrics.shared.mark(id, .captured)
            self.captured.send((frameID: id, buffer: buf))
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
