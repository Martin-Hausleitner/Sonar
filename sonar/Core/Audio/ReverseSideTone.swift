import AVFoundation
import Foundation

/// V13 — Feeds own voice back at -30 dB so the user doesn't shout in wind/noise.
/// Taps the pre-encoded PCM and routes it to the output mixer at low gain.
@MainActor
final class ReverseSideTone {
    private weak var router: AudioRouter?
    private let gainDB: Float = -30.0
    var isEnabled: Bool = true

    init(router: AudioRouter) {
        self.router = router
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled else { return }
        // In a full implementation this would write `buffer` at `gainDB` into
        // a dedicated AVAudioMixerNode input bus. Stub sets layer gain token.
        let linear = pow(10.0, gainDB / 20.0)
        router?.setLayerGain(.ambient, linear)
    }
}
