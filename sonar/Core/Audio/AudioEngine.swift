import Accelerate
import AVFoundation
import Combine
import Foundation
import os

/// AVAudioEngine + VoiceProcessingIO. Plan §10/3, LATENCY.md.
///
/// Sets `AVAudioSession.preferredIOBufferDuration` to
/// `LatencyBudget.preferredIOBufferDurationSec` (5 ms) so the OS hands us
/// audio buffers as fast as the hardware allows.
@MainActor
final class AudioEngine {
    /// Allowed range for the live mic-gain slider. Voice-processing AGC tends to
    /// pull real-world speech low; 0.5×–6× covers the practical span without
    /// distorting beyond reason.
    static let inputGainRange: ClosedRange<Float> = 0.5 ... 6.0

    private let engine = AVAudioEngine()

    /// Live mic gain, applied to every captured buffer in-place. Read on the
    /// audio thread inside the input tap, written from the main thread (UI),
    /// so the access has to be lock-protected.
    private let gainLock = OSAllocatedUnfairLock<Float>(initialState: 1.0)

    /// Multiplier applied to mic samples before they reach the encoder.
    /// `1.0` = pass-through; clamped into `inputGainRange`.
    nonisolated var inputGain: Float {
        get { gainLock.withLock { $0 } }
        set {
            let clamped = min(max(newValue, Self.inputGainRange.lowerBound), Self.inputGainRange.upperBound)
            gainLock.withLock { $0 = clamped }
        }
    }

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
            applyInputGain(to: buf)
            let id = Metrics.shared.openTrace()
            Metrics.shared.mark(id, .captured)
            captured.send((frameID: id, buffer: buf))
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Multiply each sample by the current `inputGain`, in-place, on the audio
    /// thread. Skipped for unity gain to keep the hot path branch-free.
    private nonisolated func applyInputGain(to buffer: AVAudioPCMBuffer) {
        var gain = inputGain
        guard gain != 1.0, let channels = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0 ..< channelCount {
            vDSP_vsmul(channels[ch], 1, &gain, channels[ch], 1, frames)
        }
    }
}
