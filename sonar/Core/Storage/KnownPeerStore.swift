import Combine
import Foundation

/// A persisted "contact book" of peers we've successfully paired with.
///
/// Real-device feedback on v0.2.7: re-scanning the QR code after every session
/// is the friction killing the product. We save every peer the moment a
/// scanned `PairingToken` is accepted, replay all of them into the transports
/// at session start, and surface them as a tap-to-reconnect list in the UI.
///
/// Storage layout mirrors `LocalRecorder` — JSON file under
/// `Library/Sonar/Peers/peers.json`. No `UserDefaults`: a list of structs
/// belongs in a file, and tests can swap `directoryOverride` to keep
/// production storage untouched.
@MainActor
final class KnownPeerStore: ObservableObject {
    @Published private(set) var peers: [KnownPeer] = []

    /// Optional override for the directory the store reads/writes. Tests set
    /// this to a temp directory; production leaves it `nil` and falls back to
    /// `Library/Sonar/Peers`.
    var directoryOverride: URL?

    private let storageFilename = "peers.json"

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
        peers = (try? load()) ?? []
    }

    /// Insert or update a peer derived from a freshly-accepted pairing token.
    /// Existing entries (matched by `id`) keep their `pairedAt` and any
    /// user-edited fields like `customName`; `lastSeenAt` is bumped to `now`.
    func upsert(from token: PairingToken, now: Date = Date()) {
        let incoming = KnownPeer(
            id: token.id,
            name: token.name,
            host: token.host,
            bonjour: token.bonjour,
            tsIP: token.tsIP,
            tsPort: token.tsPort,
            ble: token.ble,
            pairedAt: now,
            lastSeenAt: now,
            customName: nil
        )
        upsert(incoming)
    }

    /// Insert or update a peer directly. Existing `pairedAt` and `customName`
    /// are preserved; everything else is overwritten with the incoming row.
    func upsert(_ peer: KnownPeer, now: Date = Date()) {
        if let existing = peers.firstIndex(where: { $0.id == peer.id }) {
            var merged = peer
            merged.pairedAt = peers[existing].pairedAt
            merged.customName = peers[existing].customName ?? peer.customName
            merged.lastSeenAt = peer.lastSeenAt ?? peers[existing].lastSeenAt
            peers[existing] = merged
        } else {
            peers.append(peer)
        }
        peers.sort { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
        persistQuietly()
    }

    /// Mark a peer as just-seen — call this when a transport reports the
    /// connection actually came up, so the contact-book row sorts to top.
    func touch(id: String, now: Date = Date()) {
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[idx].lastSeenAt = now
        peers.sort { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
        persistQuietly()
    }

    /// Remove a peer from the contact book. Doesn't touch live transport state
    /// — the caller is responsible for tearing down active connections if any.
    func remove(id: String) {
        peers.removeAll { $0.id == id }
        persistQuietly()
    }

    /// Wipe everything. Used by Settings → "Alle Kontakte vergessen".
    func clear() {
        peers.removeAll()
        persistQuietly()
    }

    // MARK: - Disk I/O

    private func load() throws -> [KnownPeer] {
        let url = try storageURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.sonarPeers.decode([KnownPeer].self, from: data)
        return decoded.sorted { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
    }

    private func persistQuietly() {
        do {
            let url = try storageURL()
            let data = try JSONEncoder.sonarPeers.encode(peers)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("KnownPeerStore persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func storageURL() throws -> URL {
        let dir: URL
        if let override = directoryOverride {
            dir = override
        } else {
            let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            dir = lib.appendingPathComponent("Sonar/Peers", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(storageFilename)
    }
}

private extension JSONEncoder {
    static let sonarPeers: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let sonarPeers: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
