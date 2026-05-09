@testable import Sonar
import XCTest

@MainActor
final class NearTransportPairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAdvertisedDiscoveryInfoCarriesStablePeerIdentity() {
        let identity = SonarTestIdentity(
            environment: ["SONAR_TEST_DEVICE_ID": "local-device", "SONAR_TEST_DEVICE_NAME": "Martin iPhone"],
            arguments: [],
            vendorIdentifier: nil,
            fallbackDeviceName: "Fallback"
        )
        let near = NearTransport(identity: identity, localHost: { "martin.local" })

        XCTAssertEqual(near.advertisedDiscoveryInfo["peerID"], "local-device")
        XCTAssertEqual(near.advertisedDiscoveryInfo["peerName"], "Martin iPhone")
        XCTAssertEqual(near.advertisedDiscoveryInfo["host"], "martin.local")
    }

    func testPairingHintMatchesPeerIDFromDiscoveryInfo() {
        let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
        let hint = NearTransport.PairingHint(token: token)

        XCTAssertTrue(hint.matches(displayName: "Someone Else", discoveryInfo: ["peerID": "peer-A"]))
        XCTAssertFalse(hint.matches(displayName: "Someone Else", discoveryInfo: ["peerID": "peer-B"]))
    }

    func testPairingHintFallsBackToDisplayNameAndHost() {
        let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
        let hint = NearTransport.PairingHint(token: token)

        XCTAssertTrue(hint.matches(displayName: "Alex iPhone", discoveryInfo: nil))
        XCTAssertTrue(hint.matches(displayName: "Different", discoveryInfo: ["host": "alex.local"]))
    }

    func testInboundInvitationWithoutPairingHintIsAcceptedForAutoDiscovery() {
        XCTAssertTrue(NearTransport.shouldAcceptInvitation(
            currentPairingHint: nil,
            displayName: "Alex iPhone",
            discoveryInfo: nil
        ))
    }

    func testInboundInvitationWithMismatchedPairingHintIsRejected() {
        let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
        let hint = NearTransport.PairingHint(token: token)

        XCTAssertFalse(NearTransport.shouldAcceptInvitation(
            currentPairingHint: hint,
            displayName: "Mallory iPhone",
            discoveryInfo: ["peerID": "peer-B", "host": "mallory.local"]
        ))
    }

    func testInboundInvitationWithMatchingPairingHintIsAccepted() {
        let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
        let hint = NearTransport.PairingHint(token: token)

        XCTAssertTrue(NearTransport.shouldAcceptInvitation(
            currentPairingHint: hint,
            displayName: "Anything",
            discoveryInfo: ["peerID": "peer-A"]
        ))
    }

    func testPairingServiceAppliesAcceptedTokenToNearTransport() {
        let appState = AppState()
        let near = NearTransport()
        let service = PairingService(now: { self.now })
        service.bind(appState: appState, near: near)

        appState.pendingPairing = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
        drainMain()

        XCTAssertEqual(near.currentPairingHint?.peerID, "peer-A")
        XCTAssertEqual(near.currentPairingHint?.displayName, "Alex iPhone")
        XCTAssertEqual(near.currentPairingHint?.host, "alex.local")
    }

    private func makeToken(
        id: String,
        name: String,
        host: String,
        ageSeconds: TimeInterval = 1
    ) -> PairingToken {
        PairingToken(
            id: id,
            name: name,
            host: host,
            ts: Int64(now.timeIntervalSince1970 - ageSeconds)
        )
    }

    private func drainMain() {
        let exp = expectation(description: "main-tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }
}
