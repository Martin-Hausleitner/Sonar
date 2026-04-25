import AVFoundation
import Combine
import Foundation

/// Holds Near and Far in parallel and crossfades between them.
/// Plan §10/8, LATENCY.md (`crossfadeMs = 100` — was 200).
@MainActor
final class TransportMultiplexer {
    private let near: NearTransport
    private let far: FarTransport

    @Published private(set) var active: TransportKind = .near

    init(near: NearTransport, far: FarTransport) {
        self.near = near
        self.far = far
    }

    /// Switch transports. Default crossfade pulled from LatencyBudget so the
    /// recovery-lag stays well below the 150 ms Near alarm threshold.
    func select(
        _ kind: TransportKind,
        crossfadeMs: Int = LatencyBudget.crossfadeMs
    ) {
        // TODO §10/8: hand crossfade off to AudioRouter using the supplied
        //            duration so both transports overlap exactly that long.
        active = kind
    }
}
