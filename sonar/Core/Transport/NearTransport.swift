import AVFoundation
import Combine
import Foundation
import MultipeerConnectivity
import NearbyInteraction
import UIKit

/// Multipeer Connectivity transport (WLAN / AWDL Bonjour). Plan §10/4, §2.2 Pfad 2.
///
/// Message framing: first byte is a MessageType tag so the same MPC data channel
/// carries both audio frames and control messages (NI token exchange).
///   0x01 — AudioFrame wire payload
///   0x02 — NIDiscoveryToken (NSKeyedArchiver, for UWB ranging)
final class NearTransport: NSObject, Transport, BondedPath {

    // MARK: - Protocol requirements

    let kind: TransportKind = .near
    let id: MultipathBonder.PathID = .multipeer
    var estimatedCostPerByte: Double { 0.001 }

    private let connectedSubject   = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject  = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject     = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never>       { connectedSubject.eraseToAnyPublisher() }
    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundPCMSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundFrameSubject.eraseToAnyPublisher() }
    var qualityScore: AnyPublisher<Double, Never>    { qualitySubject.eraseToAnyPublisher() }

    // MARK: - UWB token exchange callback

    /// Called on main thread whenever a remote peer sends its NIDiscoveryToken.
    /// SessionCoordinator uses this to start NIRangingEngine with the peer token.
    var onReceivedNIToken: ((NIDiscoveryToken) -> Void)?

    /// The local NIDiscoveryToken to advertise when a peer connects.
    /// Set by SessionCoordinator once NIRangingEngine has started its session.
    var localNIToken: NIDiscoveryToken?

    // MARK: - MPC internals

    private enum Msg: UInt8 { case audio = 0x01, niToken = 0x02 }

    private let serviceType = "sonar-mpc"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)

    private lazy var session: MCSession = {
        MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    }()
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: nil, serviceType: serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)

    // MARK: - Lifecycle

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

    // MARK: - Send

    func send(_ buffer: AVAudioPCMBuffer) async {}  // legacy

    func send(_ frame: AudioFrame) async {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        var msg = Data([Msg.audio.rawValue])
        msg.append(frame.wireData)
        try? session.send(msg, toPeers: peers, with: .unreliable)
    }

    // MARK: - Private helpers

    private func sendLocalNIToken(to peers: [MCPeerID]) {
        guard let token = localNIToken,
              let tokenData = try? NSKeyedArchiver.archivedData(
                  withRootObject: token, requiringSecureCoding: true
              ) else { return }
        var msg = Data([Msg.niToken.rawValue])
        msg.append(tokenData)
        try? session.send(msg, toPeers: peers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension NearTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let connected = state == .connected
        connectedSubject.send(connected)
        // As soon as a peer connects, exchange NIDiscoveryTokens for UWB ranging.
        if connected { sendLocalNIToken(to: [peerID]) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let typeRaw = data.first,
              let type = Msg(rawValue: typeRaw) else { return }
        let payload = data.dropFirst()

        switch type {
        case .audio:
            if let frame = AudioFrame(wireData: Data(payload)) {
                inboundFrameSubject.send(frame)
            }
        case .niToken:
            guard let token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self, from: Data(payload)
            ) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onReceivedNIToken?(token)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NearTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NearTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
