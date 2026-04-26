import Combine
import Foundation
import NearbyInteraction
import simd

/// UWB ranging via Nearby Interaction. Plan §10/5.
final class NIRangingEngine: NSObject {
    let distance = CurrentValueSubject<Double?, Never>(nil)
    let direction = CurrentValueSubject<simd_float3?, Never>(nil)

    /// Called on the main queue when the NISession is invalidated (e.g. hardware
    /// unavailable, peer disconnected).  DistancePublisher uses this to start
    /// RSSIFallback.  Plan §14.1.
    var onInvalidated: (() -> Void)?

    private var session: NISession?

    func start(with token: NIDiscoveryToken) {
        let session = NISession()
        session.delegate = self
        let config = NINearbyPeerConfiguration(peerToken: token)
        session.run(config)
        self.session = session
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    var localToken: NIDiscoveryToken? { session?.discoveryToken }
}

extension NIRangingEngine: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peer = nearbyObjects.first else { return }
        if let d = peer.distance { distance.send(Double(d)) }
        if let v = peer.direction { direction.send(v) }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        distance.send(nil)
        direction.send(nil)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        // Clear published values so downstream knows UWB is gone.
        distance.send(nil)
        direction.send(nil)
        // §14.1: notify DistancePublisher to activate RSSIFallback.
        DispatchQueue.main.async { [weak self] in
            self?.onInvalidated?()
        }
    }
}
