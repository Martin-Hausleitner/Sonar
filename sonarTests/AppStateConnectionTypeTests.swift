import XCTest
@testable import Sonar

/// Tests for AppState.ConnectionType — labels, icons, and AppState integration.
final class AppStateConnectionTypeTests: XCTestCase {

    // MARK: - Label correctness

    func testNoneLabel() {
        XCTAssertEqual(AppState.ConnectionType.none.label, "Kein Signal")
    }

    func testAWDLLabel() {
        XCTAssertEqual(AppState.ConnectionType.awdl.label, "AWDL · Lokal")
    }

    func testBluetoothLabel() {
        XCTAssertEqual(AppState.ConnectionType.bluetooth.label, "Bluetooth")
    }

    func testWifiLabel() {
        XCTAssertEqual(AppState.ConnectionType.wifi.label, "WLAN · Lokal")
    }

    func testInternetLabel() {
        XCTAssertEqual(AppState.ConnectionType.internet.label, "Internet")
    }

    // MARK: - Icon correctness (SF Symbol names must be non-empty)

    func testAllIconsNonEmpty() {
        for type in [AppState.ConnectionType.none, .awdl, .bluetooth, .wifi, .internet] {
            XCTAssertFalse(type.icon.isEmpty, "\(type) must have a non-empty SF Symbol name")
        }
    }

    func testNoneIcon() {
        XCTAssertEqual(AppState.ConnectionType.none.icon,
                       "antenna.radiowaves.left.and.right.slash")
    }

    func testInternetIcon() {
        XCTAssertEqual(AppState.ConnectionType.internet.icon, "globe")
    }

    // MARK: - AppState default state

    @MainActor
    func testAppStateDefaultConnectionType() {
        let state = AppState()
        // Default must be .none (no connection established yet)
        if case .none = state.connectionType { } else {
            XCTFail("Default connectionType must be .none, got \(state.connectionType)")
        }
    }

    @MainActor
    func testAppStateDefaultPeerOnline() {
        let state = AppState()
        XCTAssertFalse(state.peerOnline, "No peer should be online at initialisation")
        XCTAssertNil(state.peerName,     "peerName must be nil at initialisation")
    }

    @MainActor
    func testAppStatePeerCanBeSet() {
        let state = AppState()
        state.peerOnline = true
        state.peerName   = "Alice's iPhone"
        XCTAssertTrue(state.peerOnline)
        XCTAssertEqual(state.peerName, "Alice's iPhone")
    }

    @MainActor
    func testAppStateConnectionTypeCanChange() {
        let state = AppState()
        state.connectionType = .awdl
        if case .awdl = state.connectionType { } else {
            XCTFail("connectionType should be .awdl after assignment")
        }
    }
}
