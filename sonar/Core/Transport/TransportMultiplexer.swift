import AVFoundation
import Combine
import Foundation

/// Holds Near and Far in parallel and crossfades between them.
/// Plan §10/8, LATENCY.md (`crossfadeMs = 100` — was 200).
@MainActor
final class TransportMultiplexer {
    private let near: NearTransport
    private let far: FarTransport
    private let audioRouter: AudioRouter

    @Published private(set) var active: TransportKind = .near

    init(near: NearTransport, far: FarTransport, audioRouter: AudioRouter) {
        self.near = near
        self.far = far
        self.audioRouter = audioRouter
    }

    /// Switch transports. Default crossfade pulled from LatencyBudget so the
    /// recovery-lag stays well below the 150 ms Near alarm threshold.
    ///
    /// Crossfade strategy:
    ///   - The outgoing transport is ramped from 1.0 → 0.0 over `crossfadeMs`.
    ///   - The incoming transport is ramped from 0.0 → 1.0 over the same window.
    ///   - Steps fire every 10 ms, matching the audio-frame cadence in LatencyBudget.
    func select(
        _ kind: TransportKind,
        crossfadeMs: Int = LatencyBudget.crossfadeMs
    ) {
        guard kind != active else { return }

        let previousKind = active
        active = kind

        // Determine which AudioRouter layers map to near vs far.
        let incomingLayer: AudioRouter.Layer = kind == .near ? .voiceNear : .voiceFar
        let outgoingLayer: AudioRouter.Layer = previousKind == .near ? .voiceNear : .voiceFar

        let stepMs: Int = 10
        let steps = max(1, crossfadeMs / stepMs)
        let stepInterval = Double(stepMs) / 1000.0

        for i in 0...steps {
            let delay = stepInterval * Double(i)
            let progress = Float(i) / Float(steps)   // 0.0 → 1.0

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // Incoming: fade in (0 → 1).
                self.audioRouter.setLayerGain(incomingLayer, progress)
                // Outgoing: fade out (1 → 0).
                self.audioRouter.setLayerGain(outgoingLayer, 1.0 - progress)
            }
        }
    }
}
