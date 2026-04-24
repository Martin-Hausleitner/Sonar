import AVFoundation
import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// Multipeer Connectivity transport. Plan §10/4.
/// Uses output streams (not `send(data:)`) for the audio path; see RESEARCH.md §1.
final class NearTransport: NSObject, Transport {
    let kind: TransportKind = .near

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundSubject.eraseToAnyPublisher() }
    var qualityScore: AnyPublisher<Double, Never> { qualitySubject.eraseToAnyPublisher() }

    private let serviceType = "sonar-mpc"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)

    private lazy var session: MCSession = {
        MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    }()
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: nil, serviceType: serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(
        peer: peerID, serviceType: serviceType
    )

    func start() async throws {
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() async {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedSubject.send(false)
    }

    func send(_ buffer: AVAudioPCMBuffer) async {
        // TODO §10/4: encode to Opus, write to MCSession output stream per peer.
    }
}

extension NearTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        connectedSubject.send(state == .connected)
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // TODO §10/4: read Opus frames from stream, decode into AVAudioPCMBuffer.
    }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension NearTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
