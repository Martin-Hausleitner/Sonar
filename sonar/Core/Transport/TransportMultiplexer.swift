import AVFoundation
import Combine
import Foundation

/// Holds Near and Far in parallel and crossfades between them. Plan §10/8.
@MainActor
final class TransportMultiplexer {
    private let near: NearTransport
    private let far: FarTransport

    @Published private(set) var active: TransportKind = .near

    init(near: NearTransport, far: FarTransport) {
        self.near = near
        self.far = far
    }

    /// Decide which transport drives the audible output based on distance and link quality.
    /// Crossfade target gain over `crossfade` seconds. Plan §10/8 default: 0.2 s.
    func select(_ kind: TransportKind, crossfade: Double = 0.2) {
        // TODO §10/8: hand crossfade off to AudioRouter.
        active = kind
    }
}
