@testable import Sonar
import XCTest

@MainActor
final class LivePeerDirectoryTests: XCTestCase {
    // MARK: - Helpers

    private func makeKnown(
        id: String,
        name: String = "Alice",
        host: String = "alice.local",
        ble: String? = nil,
        tsIP: String? = nil,
        lastSeen: Date? = nil
    ) -> KnownPeer {
        KnownPeer(
            id: id,
            name: name,
            host: host,
            bonjour: "_sonar._tcp",
            tsIP: tsIP,
            tsPort: tsIP != nil ? 49377 : nil,
            ble: ble,
            pairedAt: Date().addingTimeInterval(-3600),
            lastSeenAt: lastSeen,
            customName: nil
        )
    }

    private func makeMPC(id: String, name: String = "Alice's iPhone", host: String = "h.local") -> NearTransport.LiveMPCPeer {
        NearTransport.LiveMPCPeer(id: id, displayName: name, host: host, lastSeen: Date())
    }

    private func makeBLE(id: String, name: String = "Sonar BLE", rssi: Int? = -60) -> BluetoothMeshTransport.LiveBLEPeer {
        BluetoothMeshTransport.LiveBLEPeer(id: id, name: name, rssi: rssi, lastSeen: Date())
    }

    // MARK: - merge

    func testEmptyInputsProduceEmptyDirectory() {
        let entries = LivePeerDirectory.merge(known: [], mpc: [], ble: [])
        XCTAssertTrue(entries.isEmpty)
    }

    func testKnownPeerWithoutLiveSightingsIsOffline() {
        let entries = LivePeerDirectory.merge(
            known: [makeKnown(id: "peer-A")],
            mpc: [],
            ble: []
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].source, .known)
        XCTAssertFalse(entries[0].isOnline)
        XCTAssertFalse(entries[0].transports.contains(.mpc))
    }

    func testKnownPeerSeenViaMPCIsMarkedOnline() {
        let entries = LivePeerDirectory.merge(
            known: [makeKnown(id: "peer-A")],
            mpc: [makeMPC(id: "peer-A")],
            ble: []
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isOnline)
        XCTAssertTrue(entries[0].transports.contains(.mpc))
    }

    func testKnownPeerWithStoredBLEMatchesLiveBLEAsOnline() {
        let entries = LivePeerDirectory.merge(
            known: [makeKnown(id: "peer-A", ble: "BLE-UUID-1")],
            mpc: [],
            ble: [makeBLE(id: "BLE-UUID-1")]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isOnline)
        XCTAssertTrue(entries[0].transports.contains(.ble))
    }

    func testUnknownLivePeerSurfacedAsNearby() {
        let entries = LivePeerDirectory.merge(
            known: [],
            mpc: [makeMPC(id: "peer-X", name: "Stranger")],
            ble: []
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].source, .nearby)
        XCTAssertEqual(entries[0].id, "peer-X")
        XCTAssertTrue(entries[0].isOnline)
    }

    func testKnownAndNearbyAreReturnedInThatOrder() {
        let entries = LivePeerDirectory.merge(
            known: [makeKnown(id: "peer-A", lastSeen: Date().addingTimeInterval(-60))],
            mpc: [
                makeMPC(id: "peer-A"),
                makeMPC(id: "peer-X", name: "Stranger")
            ],
            ble: []
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].source, .known)
        XCTAssertEqual(entries[0].id, "peer-A")
        XCTAssertEqual(entries[1].source, .nearby)
        XCTAssertEqual(entries[1].id, "peer-X")
    }

    func testOnlineKnownPeerSortsAboveOfflineKnownPeer() {
        let recentOffline = makeKnown(id: "peer-OLD", name: "Old Friend", lastSeen: Date().addingTimeInterval(-60))
        let oldOnline = makeKnown(id: "peer-LIVE", name: "Live", lastSeen: Date().addingTimeInterval(-3600))
        let entries = LivePeerDirectory.merge(
            known: [recentOffline, oldOnline],
            mpc: [makeMPC(id: "peer-LIVE")],
            ble: []
        )
        XCTAssertEqual(entries.first?.id, "peer-LIVE", "online > offline regardless of recency")
        XCTAssertEqual(entries.last?.id, "peer-OLD")
    }

    func testNearbyMPCAndBLEAreNamespacedSoCollisionCannotCrashList() {
        // Even if MPC peerID and BLE UUID happen to share the same string
        // (different ID-spaces, but a collision is theoretically possible
        // and would crash a SwiftUI ForEach on duplicate Identifiable.id),
        // the directory must produce TWO distinct entries with distinct ids.
        let id = "peer-X"
        let entries = LivePeerDirectory.merge(
            known: [],
            mpc: [makeMPC(id: id, name: "X via MPC")],
            ble: [makeBLE(id: id, name: "X via BLE")]
        )
        XCTAssertEqual(entries.count, 2)
        let ids = Set(entries.map(\.id))
        XCTAssertEqual(ids.count, 2, "Identifiable ids must be unique across transports")
        XCTAssertTrue(ids.contains("peer-X"))
        XCTAssertTrue(ids.contains("ble:peer-X"))
    }

    // MARK: - makeToken

    func testMakeTokenReusesKnownPeerFields() {
        let known = makeKnown(id: "peer-A", name: "Alice", ble: "BLE-1", tsIP: "100.10.0.1")
        let entry = LivePeerDirectory.merge(known: [known], mpc: [], ble: [])[0]
        let token = LivePeerDirectory.makeToken(for: entry)
        XCTAssertEqual(token.id, "peer-A")
        XCTAssertEqual(token.name, "Alice")
        XCTAssertEqual(token.ble, "BLE-1")
        XCTAssertEqual(token.tsIP, "100.10.0.1")
    }

    func testMakeTokenSynthesizesFromNearbyEntry() {
        let entry = LivePeerDirectory.merge(
            known: [],
            mpc: [makeMPC(id: "peer-X", name: "Stranger", host: "x.local")],
            ble: []
        )[0]
        let token = LivePeerDirectory.makeToken(for: entry)
        XCTAssertEqual(token.id, "peer-X")
        XCTAssertEqual(token.name, "Stranger")
        XCTAssertEqual(token.host, "x.local")
        XCTAssertNil(token.ble)
    }
}
