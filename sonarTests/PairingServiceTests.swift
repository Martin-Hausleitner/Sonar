import Combine
import XCTest
@testable import Sonar

@MainActor
final class PairingServiceTests: XCTestCase {

    // Pinned "now" so TTL behavior is deterministic regardless of when the
    // test runs.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeService() -> PairingService {
        PairingService(now: { self.now })
    }

    private func makeToken(
        id: String = "peer-A",
        name: String = "Alex iPhone",
        host: String = "alex.local",
        bonjour: String = "_sonar._tcp",
        ageSeconds: TimeInterval = 0
    ) -> PairingToken {
        PairingToken(
            id: id,
            name: name,
            bonjour: bonjour,
            host: host,
            ts: Int64(now.timeIntervalSince1970 - ageSeconds)
        )
    }

    /// PairingService hops onto `DispatchQueue.main` before reacting (so it can
    /// safely clear `pendingPairing` after `@Published.willSet` returns). Spin
    /// the run loop once so the deferred work lands before assertions.
    private func drainMain() {
        let exp = expectation(description: "main-tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Fresh, valid token

    func testFreshTokenSetsPeerOnlineAndName() {
        let appState = AppState()
        let service = makeService()
        service.bind(appState: appState)

        XCTAssertFalse(appState.peerOnline)
        XCTAssertNil(appState.peerName)

        let token = makeToken(id: "peer-A", name: "Alex iPhone", ageSeconds: 10)
        appState.pendingPairing = token
        drainMain()

        XCTAssertTrue(appState.peerOnline)
        XCTAssertEqual(appState.peerName, "Alex iPhone")
        XCTAssertEqual(appState.peerID, "peer-A")
        XCTAssertNotNil(appState.peerLastSeen)
        XCTAssertEqual(appState.peerLastSeen?.timeIntervalSince1970, now.timeIntervalSince1970)
    }

    // MARK: - Expired token (>5 min)

    func testExpiredTokenIsRejectedAndPeerOnlineStaysFalse() {
        let appState = AppState()
        let service = makeService()
        service.bind(appState: appState)

        // 6 minutes old → past the 5-minute TTL.
        let stale = makeToken(ageSeconds: 6 * 60)
        appState.pendingPairing = stale
        drainMain()

        XCTAssertFalse(appState.peerOnline)
        XCTAssertNil(appState.peerName)
        XCTAssertNil(appState.peerID)
        XCTAssertNil(appState.pendingPairing, "service should clear an expired token")
    }

    func testTokenAtTTLBoundaryIsAccepted() {
        let appState = AppState()
        let service = makeService()
        service.bind(appState: appState)

        // Exactly 5 minutes old — boundary is inclusive (`age > TTL` rejects).
        let onTheDot = makeToken(ageSeconds: 5 * 60)
        appState.pendingPairing = onTheDot
        drainMain()

        XCTAssertTrue(appState.peerOnline)
    }

    // MARK: - Nil pendingPairing must not crash

    func testNilPendingPairingDoesNotCrash() {
        let appState = AppState()
        let service = makeService()
        service.bind(appState: appState)

        // Initial nil from binding (the .removeDuplicates upstream emits the
        // current value); explicitly assigning nil again must not throw.
        appState.pendingPairing = nil
        drainMain()
        XCTAssertFalse(appState.peerOnline)

        // After a valid token, clearing back to nil also must not crash.
        appState.pendingPairing = makeToken(ageSeconds: 1)
        drainMain()
        XCTAssertTrue(appState.peerOnline)

        appState.pendingPairing = nil
        drainMain()
        // peerOnline stays true — disconnect is the transport layer's job, not
        // the pairing service's. We only verify "no crash".
        XCTAssertTrue(appState.peerOnline)
    }

    // MARK: - Bonjour hint notification

    func testBonjourHintNotificationCarriesHost() {
        let appState = AppState()
        let service = makeService()
        service.bind(appState: appState)

        let exp = expectation(forNotification: PairingService.bonjourHintNotification, object: nil) { note in
            (note.userInfo?["host"] as? String) == "alex.local"
                && (note.userInfo?["peerID"] as? String) == "peer-A"
        }

        appState.pendingPairing = makeToken(id: "peer-A", host: "alex.local", ageSeconds: 1)
        wait(for: [exp], timeout: 1.0)
    }
}
