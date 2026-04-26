import AVFoundation
import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// Multipeer Connectivity transport (WLAN / AWDL Bonjour). Plan §10/4, §2.2 Pfad 2.
/// Uses output streams (not `send(data:)`) for the audio path; see RESEARCH.md §1.
/// Conforms to both the old Transport protocol and the new BondedPath protocol.
final class NearTransport: NSObject, Transport, BondedPath {
    let kind: TransportKind = .near
    let id: MultipathBonder.PathID = .multipeer
    var estimatedCostPerByte: Double { 0.001 }   // WLAN: cheap but not free

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundPCMSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundFrameSubject.eraseToAnyPublisher() }
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

    // Legacy AVAudioPCMBuffer send (kept for TransportMultiplexer compatibility).
    func send(_ buffer: AVAudioPCMBuffer) async {}

    // BondedPath send — writes wire-encoded AudioFrame to all connected peers.
    func send(_ frame: AudioFrame) async {
        let data = frame.wireData
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try? session.send(data, toPeers: peers, with: .unreliable)
    }
}

extension NearTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        connectedSubject.send(state == .connected)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let frame = AudioFrame(wireData: data) {
            inboundFrameSubject.send(frame)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
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
