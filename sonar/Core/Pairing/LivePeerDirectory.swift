import Combine
import Foundation

/// Unified, UI-friendly view of every Sonar peer the app could connect to:
/// the persisted contact book + everything the transports are currently
/// seeing on the local network and over Bluetooth.
///
/// Real-device feedback on v0.2.8: forcing the user through a QR pairing
/// dialog before they can even see who's around is "Blödsinn". This
/// directory powers a `DevicesView` where known contacts and live nearby
/// devices live side-by-side and a tap is enough to connect.
@MainActor
final class LivePeerDirectory: ObservableObject {
    enum Source: Equatable {
        case known
        case nearby
    }

    enum Transport: String, Hashable {
        case mpc
        case ble
        case tailscale
        case host
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let displayName: String
        let source: Source
        let isOnline: Bool
        let transports: Set<Transport>
        let lastSeenAt: Date?
        /// Convenience accessors for the connect path.
        let knownPeer: KnownPeer?
        let mpcDisplayName: String?
        let mpcHost: String?
        let bleIdentifier: String?
    }

    /// Set by SessionCoordinator from `NearTransport.livePeers`. UI doesn't
    /// touch this directly — it observes `entries`.
    @Published var mpcPeers: [NearTransport.LiveMPCPeer] = []
    /// Set by SessionCoordinator from `BluetoothMeshTransport.livePeers`.
    @Published var blePeers: [BluetoothMeshTransport.LiveBLEPeer] = []

    @Published private(set) var entries: [Entry] = []

    private let known: KnownPeerStore
    private var cancellables = Set<AnyCancellable>()

    init(known: KnownPeerStore) {
        self.known = known
        // Recompute whenever any source changes. We `prepend` once with the
        // current `peers` so the initial assign fires immediately even if
        // the live publishers haven't emitted yet.
        Publishers.CombineLatest3(
            known.$peers.prepend(known.peers),
            $mpcPeers,
            $blePeers
        )
        .map { knownPeers, mpc, ble -> [Entry] in
            LivePeerDirectory.merge(known: knownPeers, mpc: mpc, ble: ble)
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$entries)
    }

    static func merge(
        known knownPeers: [KnownPeer],
        mpc mpcPeers: [NearTransport.LiveMPCPeer],
        ble blePeers: [BluetoothMeshTransport.LiveBLEPeer]
    ) -> [Entry] {
        let mpcByID = Dictionary(uniqueKeysWithValues: mpcPeers.map { ($0.id, $0) })
        let bleByID = Dictionary(uniqueKeysWithValues: blePeers.map { ($0.id, $0) })

        // Known peers first — annotated with online status from live publishers.
        var knownEntries: [Entry] = knownPeers.map { peer in
            var transports: Set<Transport> = []
            var online = false
            if mpcByID[peer.id] != nil { transports.insert(.mpc)
                online = true
            }
            if let ble = peer.ble, bleByID[ble] != nil { transports.insert(.ble)
                online = true
            }
            // Static capabilities from the saved token — the user should see
            // these even when offline so the row carries context.
            if peer.tsIP != nil { transports.insert(.tailscale) }
            if !peer.host.isEmpty, !transports.contains(.mpc) { transports.insert(.host) }
            return Entry(
                id: peer.id,
                displayName: peer.displayName,
                source: .known,
                isOnline: online,
                transports: transports,
                lastSeenAt: peer.lastSeenAt,
                knownPeer: peer,
                mpcDisplayName: mpcByID[peer.id]?.displayName,
                mpcHost: mpcByID[peer.id]?.host,
                bleIdentifier: peer.ble
            )
        }
        // Online + most-recent first within the known list.
        knownEntries.sort {
            if $0.isOnline != $1.isOnline { return $0.isOnline && !$1.isOnline }
            return ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast)
        }

        // Anything visible live that *isn't* in the contact book becomes a
        // "nearby" candidate — the rows the user can tap to start a brand-new
        // connection without going through the QR sheet.
        let knownIDs = Set(knownPeers.map(\.id))
        let knownBLEIDs = Set(knownPeers.compactMap(\.ble))

        var nearbyByID: [String: Entry] = [:]
        for peer in mpcPeers where !knownIDs.contains(peer.id) {
            nearbyByID[peer.id] = Entry(
                id: peer.id,
                displayName: peer.displayName.isEmpty ? "Sonar-Gerät" : peer.displayName,
                source: .nearby,
                isOnline: true,
                transports: [.mpc],
                lastSeenAt: peer.lastSeen,
                knownPeer: nil,
                mpcDisplayName: peer.displayName,
                mpcHost: peer.host,
                bleIdentifier: nil
            )
        }
        for peer in blePeers where !knownBLEIDs.contains(peer.id) {
            if nearbyByID[peer.id] != nil { continue }
            nearbyByID[peer.id] = Entry(
                id: peer.id,
                displayName: peer.name,
                source: .nearby,
                isOnline: true,
                transports: [.ble],
                lastSeenAt: peer.lastSeen,
                knownPeer: nil,
                mpcDisplayName: nil,
                mpcHost: nil,
                bleIdentifier: peer.id
            )
        }

        var nearbyEntries = Array(nearbyByID.values)
        nearbyEntries.sort { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }

        return knownEntries + nearbyEntries
    }

    /// Build a `PairingToken` for an entry so the existing transport replay
    /// path (`addPairingToken`) can pick it up. For known entries we use the
    /// stored fields; for nearby entries we synthesize from whatever live
    /// data we have.
    static func makeToken(for entry: Entry, now: Date = Date()) -> PairingToken {
        if let known = entry.knownPeer {
            return known.asReplayToken(now: now)
        }
        return PairingToken(
            id: entry.id,
            name: entry.displayName,
            host: entry.mpcHost ?? "",
            tsIP: nil,
            tsPort: nil,
            ble: entry.bleIdentifier,
            ts: Int64(now.timeIntervalSince1970)
        )
    }
}
