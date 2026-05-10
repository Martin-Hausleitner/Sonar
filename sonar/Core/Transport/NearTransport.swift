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
    var estimatedCostPerByte: Double {
        0.001
    }

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)
    private let liveSubject = CurrentValueSubject<[LiveMPCPeer], Never>([])

    /// One MPC peer the browser currently sees. Surfaced so the app can show
    /// a live "Geräte in der Nähe" list without the user having to scan QR.
    struct LiveMPCPeer: Identifiable, Equatable {
        /// Stable id — prefers the remote peer's `SonarTestIdentity.deviceID`
        /// from `discoveryInfo["peerID"]`, falls back to MCPeerID's display
        /// name (which is also the user-visible device name).
        let id: String
        let displayName: String
        let host: String
        let lastSeen: Date
    }

    var livePeers: AnyPublisher<[LiveMPCPeer], Never> {
        liveSubject.eraseToAnyPublisher()
    }

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> {
        inboundPCMSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundFrameSubject.eraseToAnyPublisher()
    }

    var qualityScore: AnyPublisher<Double, Never> {
        qualitySubject.eraseToAnyPublisher()
    }

    // MARK: - UWB token exchange callback

    /// Called on main thread whenever a remote peer sends its NIDiscoveryToken.
    /// SessionCoordinator uses this to start NIRangingEngine with the peer token.
    var onReceivedNIToken: ((NIDiscoveryToken) -> Void)?

    /// The local NIDiscoveryToken to advertise when a peer connects.
    /// Set by SessionCoordinator once NIRangingEngine has started its session.
    var localNIToken: NIDiscoveryToken?

    struct PairingHint: Hashable {
        let peerID: String
        let displayName: String
        let host: String
        let bonjour: String

        init(token: PairingToken) {
            peerID = token.id
            displayName = token.name
            host = token.host
            bonjour = token.bonjour
        }

        func matches(displayName: String, discoveryInfo: [String: String]?) -> Bool {
            if discoveryInfo?["peerID"] == peerID { return true }
            if !self.displayName.isEmpty, displayName == self.displayName { return true }
            if !host.isEmpty, discoveryInfo?["host"] == host { return true }
            return false
        }
    }

    /// Set of allow-listed peers (from QR scan + replayed contact book). Empty
    /// means "auto-discover everything" — preserves the original first-launch
    /// behaviour of pre-pairing discovery before we had a contact book.
    private(set) var currentPairingHints: Set<PairingHint> = []

    /// Back-compat single-hint accessor (returns the most recently added hint).
    /// Used by legacy code paths and tests; new callers should read
    /// `currentPairingHints` directly.
    var currentPairingHint: PairingHint? {
        currentPairingHints.first
    }

    // MARK: - MPC internals

    private enum Msg: UInt8 { case audio = 0x01, niToken = 0x02 }

    private let serviceType = "sonar-mpc"
    private let identity: SonarTestIdentity
    private let localHost: () -> String
    private let peerID: MCPeerID
    private struct DiscoveredPeer {
        let peerID: MCPeerID
        let discoveryInfo: [String: String]?
    }

    /// Protects every read/write of `discoveredPeers`, `invitedPeerIDs`, and
    /// `currentPairingHints`. MPC delegate callbacks come on an arbitrary
    /// queue — without this serial queue they'd race against `addPairingToken`
    /// being called from the main thread by `PairingService`. Pre-fix, that
    /// race could corrupt the discovered-peers map mid-iteration.
    private let stateQueue = DispatchQueue(label: "app.sonar.near.state")

    private var discoveredPeers: [MCPeerID: DiscoveredPeer] = [:]
    private var invitedPeerIDs = Set<MCPeerID>()

    private lazy var session: MCSession = .init(peer: peerID, securityIdentity: nil, encryptionPreference: .required)

    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: advertisedDiscoveryInfo, serviceType: serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)

    init(
        identity: SonarTestIdentity = .current(),
        localHost: @escaping () -> String = PairingTokenGenerator.localHost
    ) {
        self.identity = identity
        self.localHost = localHost
        peerID = MCPeerID(displayName: identity.deviceName)
        super.init()
    }

    var advertisedDiscoveryInfo: [String: String] {
        var info = [
            "peerID": identity.deviceID,
            "peerName": identity.deviceName,
            "bonjour": serviceType
        ]
        let host = localHost()
        if !host.isEmpty { info["host"] = host }
        return info
    }

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
        stateQueue.sync {
            discoveredPeers.removeAll()
            invitedPeerIDs.removeAll()
        }
        publishLivePeers()
        emitConnectedIfChanged(false)
    }

    /// Add a peer to the allow-list. Replay path (contact book) and the live
    /// QR-scan path both go through this — accumulating instead of replacing
    /// is what makes "I scanned Alice yesterday and Bob today, both should
    /// auto-connect" work without re-scanning either of them.
    func addPairingToken(_ token: PairingToken) {
        let snapshotPeers: [DiscoveredPeer] = stateQueue.sync {
            currentPairingHints.insert(PairingHint(token: token))
            return Array(discoveredPeers.values)
        }
        for peer in snapshotPeers {
            inviteIfAllowed(peer.peerID, discoveryInfo: peer.discoveryInfo)
        }
    }

    /// Drop the entire allow-list (used by Settings → "Alle Kontakte
    /// vergessen"). Live MPC sessions are untouched; only future invitations
    /// will fall back to "accept everything" mode.
    func clearPairingTokens() {
        stateQueue.sync { currentPairingHints.removeAll() }
    }

    /// Forget a single peer's allow-list entry. Call this when the user
    /// removes a contact from the book mid-session — otherwise the deleted
    /// peer would silently re-connect because the hint stays cached until
    /// the next session restart.
    func removePairingToken(forPeerID peerID: String) {
        stateQueue.sync {
            currentPairingHints = currentPairingHints.filter { $0.peerID != peerID }
        }
    }

    /// Back-compat alias kept for callers that haven't migrated yet.
    func applyPairingToken(_ token: PairingToken) {
        addPairingToken(token)
    }

    // MARK: - Send

    func send(_ buffer: AVAudioPCMBuffer) async {} // legacy

    func send(_ frame: AudioFrame) async {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        var msg = Data([Msg.audio.rawValue])
        msg.append(frame.wireData)
        do {
            try session.send(msg, toPeers: peers, with: .unreliable)
        } catch {
            // Pre-fix, this was `try?` and silent. Real-device test on
            // v0.2.9 showed audio "abgehackt" came in part from invisible
            // send failures during AWDL flaps — log so we can see them.
            Log.app.error("NearTransport audio send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private helpers

    private func sendLocalNIToken(to peers: [MCPeerID]) {
        guard let token = localNIToken,
              let tokenData = try? NSKeyedArchiver.archivedData(
                  withRootObject: token, requiringSecureCoding: true
              ) else { return }
        var msg = Data([Msg.niToken.rawValue])
        msg.append(tokenData)
        do {
            try session.send(msg, toPeers: peers, with: .reliable)
        } catch {
            Log.app.error("NearTransport NI token send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Only push a new value into `connectedSubject` when the truth flips —
    /// raw MCSession state changes (`.connecting`, `.notConnected`, …) flap
    /// many times during AWDL handover and would generate connect/disconnect
    /// storms in the bonder otherwise.
    private func emitConnectedIfChanged(_ connected: Bool) {
        if connectedSubject.value != connected {
            connectedSubject.send(connected)
        }
    }

    static func shouldAcceptInvitation(
        currentPairingHints: Set<PairingHint>,
        displayName: String,
        discoveryInfo: [String: String]?
    ) -> Bool {
        guard !currentPairingHints.isEmpty else { return true }
        return currentPairingHints.contains { $0.matches(displayName: displayName, discoveryInfo: discoveryInfo) }
    }

    /// Back-compat single-hint helper kept for tests that pre-date the
    /// multi-peer refactor.
    static func shouldAcceptInvitation(
        currentPairingHint: PairingHint?,
        displayName: String,
        discoveryInfo: [String: String]?
    ) -> Bool {
        var set = Set<PairingHint>()
        if let hint = currentPairingHint { set.insert(hint) }
        return shouldAcceptInvitation(currentPairingHints: set, displayName: displayName, discoveryInfo: discoveryInfo)
    }
}

// MARK: - MCSessionDelegate

extension NearTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Truth = "any peer is connected", not "this individual state change
        // is .connected". Prevents the connect/disconnect storm on AWDL flap.
        emitConnectedIfChanged(!session.connectedPeers.isEmpty)
        // As soon as a peer connects, exchange NIDiscoveryTokens for UWB ranging.
        if state == .connected { sendLocalNIToken(to: [peerID]) }
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
        // Snapshot the relevant state under the lock so we don't race with
        // a concurrent foundPeer/addPairingToken mutating the dictionaries.
        let (discoveryInfo, hints): ([String: String]?, Set<PairingHint>) = stateQueue.sync {
            (discoveredPeers[peerID]?.discoveryInfo, currentPairingHints)
        }
        let accept = Self.shouldAcceptInvitation(
            currentPairingHints: hints,
            displayName: peerID.displayName,
            discoveryInfo: discoveryInfo
        )
        invitationHandler(accept, accept ? session : nil)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NearTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        stateQueue.sync {
            discoveredPeers[peerID] = DiscoveredPeer(peerID: peerID, discoveryInfo: info)
        }
        publishLivePeers()
        inviteIfAllowed(peerID, discoveryInfo: info)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        stateQueue.sync {
            discoveredPeers.removeValue(forKey: peerID)
            // Drop the invited mark too so a future re-discovery (after the
            // peer comes back into range) gets a fresh invite. Without this,
            // a peer that briefly disappears would never reconnect this
            // session.
            invitedPeerIDs.remove(peerID)
        }
        publishLivePeers()
    }

    private func publishLivePeers() {
        let snapshot = stateQueue.sync { Array(discoveredPeers.values) }
        let now = Date()
        let items = snapshot.map { peer -> LiveMPCPeer in
            let info = peer.discoveryInfo
            let stableID = info?["peerID"] ?? peer.peerID.displayName
            return LiveMPCPeer(
                id: stableID,
                displayName: info?["peerName"] ?? peer.peerID.displayName,
                host: info?["host"] ?? "",
                lastSeen: now
            )
        }
        liveSubject.send(items)
    }

    private func inviteIfAllowed(_ peerID: MCPeerID, discoveryInfo: [String: String]?) {
        let shouldInvite: Bool = stateQueue.sync {
            if !currentPairingHints.isEmpty,
               !currentPairingHints.contains(where: { $0.matches(displayName: peerID.displayName, discoveryInfo: discoveryInfo) })
            {
                return false
            }
            guard !invitedPeerIDs.contains(peerID) else { return false }
            invitedPeerIDs.insert(peerID)
            return true
        }
        guard shouldInvite else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }
}
