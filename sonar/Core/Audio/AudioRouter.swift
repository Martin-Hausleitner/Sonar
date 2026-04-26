import AVFoundation
import Combine
import Foundation

/// Mixes near, far, and AI streams into the output, applies gains and crossfades.
/// Plan §7.1.
@MainActor
final class AudioRouter {
    enum Layer: Hashable { case voiceNear, voiceFar, ai, music, ambient }

    // Observable per-layer gain state.
    @Published private(set) var currentGain: [Layer: Float] = [
        .voiceNear: 1.0,
        .voiceFar: 0.0,
        .ai: 0.8,
        .music: 0.0,
        .ambient: 0.0
    ]

    // Active ramp timer for the remote voice gain.
    private var rampTimer: DispatchSourceTimer?

    // MARK: - Public API

    /// Linearly ramp the remote-voice (`.voiceNear`) layer gain to `target`
    /// over `rampDuration` seconds.  Uses a DispatchSourceTimer that fires
    /// every ~10 ms and updates the published `currentGain[.voiceNear]`.
    func setRemoteVoiceGain(to target: Float, rampDuration: TimeInterval = 0.3) {
        // Cancel any in-progress ramp.
        rampTimer?.cancel()
        rampTimer = nil

        let layer = Layer.voiceNear
        let start = currentGain[layer] ?? 1.0

        // If duration is negligible, jump immediately.
        guard rampDuration > 0.005 else {
            currentGain[layer] = target
            return
        }

        let stepInterval: TimeInterval = 0.010          // 10 ms steps
        let totalSteps = max(1, Int((rampDuration / stepInterval).rounded()))
        let gainStep = (target - start) / Float(totalSteps)
        var stepsDone = 0

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(
            deadline: .now() + stepInterval,
            repeating: stepInterval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            stepsDone += 1
            if stepsDone >= totalSteps {
                self.currentGain[layer] = target
                self.rampTimer?.cancel()
                self.rampTimer = nil
            } else {
                self.currentGain[layer] = start + gainStep * Float(stepsDone)
            }
        }
        rampTimer = timer
        timer.resume()
    }

    func setLayerGain(_ layer: Layer, _ value: Float) {
        currentGain[layer] = value
    }
}
