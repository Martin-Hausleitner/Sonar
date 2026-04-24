import AVFoundation
import Foundation

/// Mixes near, far, and AI streams into the output, applies gains and crossfades.
/// Plan §7.1.
@MainActor
final class AudioRouter {
    enum Layer { case voiceNear, voiceFar, ai, music, ambient }

    private var gains: [Layer: Float] = [
        .voiceNear: 1.0,
        .voiceFar: 0.0,
        .ai: 0.8,
        .music: 0.0,
        .ambient: 0.0
    ]

    func setRemoteVoiceGain(to target: Float, rampDuration: TimeInterval = 0.3) {
        // TODO §10/6: actually ramp via AVAudioMixerNode.volume on the relevant input bus.
        gains[.voiceNear] = target
    }

    func setLayerGain(_ layer: Layer, _ value: Float) {
        gains[layer] = value
    }
}
