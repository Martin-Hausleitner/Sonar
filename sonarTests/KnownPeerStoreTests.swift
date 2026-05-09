@testable import Sonar
import XCTest

@MainActor
final class KnownPeerStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-peers-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> KnownPeerStore {
        KnownPeerStore(directoryOverride: tempDir)
    }

    private func makeToken(
        id: String = "peer-A",
        name: String = "Alice's iPhone",
        host: String = "alice.local",
        tsIP: String? = nil,
        ble: String? = nil,
        ageSeconds: TimeInterval = 0
    ) -> PairingToken {
        PairingToken(
            id: id,
            name: name,
            host: host,
            tsIP: tsIP,
            tsPort: tsIP != nil ? 49377 : nil,
            ble: ble,
            ts: Int64(Date().timeIntervalSince1970 - ageSeconds)
        )
    }

    // MARK: - Tests

    func testEmptyStoreStartsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.peers.isEmpty)
    }

    func testUpsertFromTokenAddsPeerAndPersistsAcrossInstances() {
        let token = makeToken(id: "peer-A", name: "Alice", tsIP: "100.10.0.1", ble: "BLE-1")

        let writer = makeStore()
        writer.upsert(from: token)
        XCTAssertEqual(writer.peers.count, 1)
        XCTAssertEqual(writer.peers.first?.name, "Alice")
        XCTAssertEqual(writer.peers.first?.tsIP, "100.10.0.1")
        XCTAssertEqual(writer.peers.first?.ble, "BLE-1")

        let reader = makeStore()
        XCTAssertEqual(reader.peers.count, 1, "store should hydrate from disk on init")
        XCTAssertEqual(reader.peers.first?.id, "peer-A")
    }

    func testUpsertOfSameIdMergesAndPreservesPairedAt() {
        let store = makeStore()
        store.upsert(from: makeToken(id: "peer-A", name: "Alice", host: "alice.local"))
        let originalPairedAt = store.peers[0].pairedAt

        // Wait a moment so the second upsert lands on a strictly later instant.
        let later = originalPairedAt.addingTimeInterval(1)
        store.upsert(from: makeToken(id: "peer-A", name: "Alice (Renamed)", host: "alice2.local"), now: later)

        XCTAssertEqual(store.peers.count, 1)
        XCTAssertEqual(store.peers[0].name, "Alice (Renamed)")
        XCTAssertEqual(store.peers[0].host, "alice2.local")
        XCTAssertEqual(store.peers[0].pairedAt, originalPairedAt, "pairedAt must survive merge")
        XCTAssertEqual(store.peers[0].lastSeenAt, later)
    }

    func testTouchUpdatesLastSeenAndResorts() {
        let store = makeStore()
        let now = Date()
        store.upsert(from: makeToken(id: "peer-A"), now: now.addingTimeInterval(-3600))
        store.upsert(from: makeToken(id: "peer-B"), now: now.addingTimeInterval(-1800))
        XCTAssertEqual(store.peers.first?.id, "peer-B", "B is more recent → top")

        store.touch(id: "peer-A", now: now)
        XCTAssertEqual(store.peers.first?.id, "peer-A", "touching A bumps it to top")
    }

    func testRemoveDeletesAndPersists() {
        let store = makeStore()
        store.upsert(from: makeToken(id: "peer-A"))
        store.upsert(from: makeToken(id: "peer-B"))
        store.remove(id: "peer-A")

        XCTAssertEqual(store.peers.map(\.id), ["peer-B"])
        let reader = makeStore()
        XCTAssertEqual(reader.peers.map(\.id), ["peer-B"])
    }

    func testClearWipesEverything() {
        let store = makeStore()
        store.upsert(from: makeToken(id: "peer-A"))
        store.upsert(from: makeToken(id: "peer-B"))
        store.clear()

        XCTAssertTrue(store.peers.isEmpty)
        XCTAssertTrue(makeStore().peers.isEmpty)
    }

    func testReplayTokenCarriesAllConnectionFields() {
        let token = makeToken(id: "peer-A", name: "Alice", host: "h.local", tsIP: "100.1.2.3", ble: "BLE-1")
        let store = makeStore()
        store.upsert(from: token)

        let replay = store.peers[0].asReplayToken()
        XCTAssertEqual(replay.id, "peer-A")
        XCTAssertEqual(replay.name, "Alice")
        XCTAssertEqual(replay.host, "h.local")
        XCTAssertEqual(replay.tsIP, "100.1.2.3")
        XCTAssertEqual(replay.ble, "BLE-1")
        XCTAssertGreaterThan(replay.ts, token.ts - 5, "replay token must use a fresh ts so TTL checks pass")
    }
}
