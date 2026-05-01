import XCTest
import UIKit
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

    func testSimulatorRelayLabel() {
        XCTAssertEqual(AppState.ConnectionType.simulatorRelay.label, "Simulator Relay")
    }

    // MARK: - Icon correctness (SF Symbol names must be non-empty)

    func testAllIconsNonEmpty() {
        for type in [AppState.ConnectionType.none, .awdl, .bluetooth, .wifi, .internet, .simulatorRelay] {
            XCTAssertFalse(type.icon.isEmpty, "\(type) must have a non-empty SF Symbol name")
        }
    }

    func testPrimaryInterfaceSymbolsResolve() {
        let symbols = Set([
            AppState.ConnectionType.none.icon,
            AppState.ConnectionType.awdl.icon,
            AppState.ConnectionType.bluetooth.icon,
            AppState.ConnectionType.wifi.icon,
            AppState.ConnectionType.tailscale.icon,
            AppState.ConnectionType.internet.icon,
            AppState.ConnectionType.simulatorRelay.icon,
            "antenna.radiowaves.left.and.right",
            "arrow.triangle.branch",
            "arrow.clockwise",
            "battery.0",
            "battery.100",
            "brain.head.profile",
            "captions.bubble",
            "checkmark",
            "checkmark.circle.fill",
            "checkmark.shield",
            "checkmark.shield.fill",
            "chevron.right",
            "circle",
            "desktopcomputer",
            "dot.radiowaves.left.and.right",
            "gearshape",
            "info.circle",
            "iphone",
            "key.fill",
            "link",
            "link.badge.plus",
            "list.number",
            "mic.fill",
            "mic.badge.xmark",
            "network",
            "network.badge.shield.half.filled",
            "person.line.dotted.person.fill",
            "qrcode.viewfinder",
            "record.circle.fill",
            "slider.horizontal.3",
            "speaker.fill",
            "speaker.wave.2.fill",
            "speaker.wave.3.fill",
            "text.bubble",
            "trash",
            "video.slash.fill",
            "wave.3.right.circle.fill",
            "waveform.and.mic",
            "waveform.circle",
            "waveform.circle.fill",
            "waveform.path",
            "wifi",
            "wrench.and.screwdriver",
            "xmark"
        ] + SessionProfile.builtIn.flatMap { profile in
            [
                ProfileVisuals.icon(profile.id),
                ProfileVisuals.listeningIcon(profile.listeningMode),
                ProfileVisuals.aiIcon(profile.aiTrigger)
            ]
        })

        for symbol in symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), "\(symbol) must be a valid SF Symbol")
        }
    }

    func testNoneIcon() {
        XCTAssertEqual(AppState.ConnectionType.none.icon,
                       "antenna.radiowaves.left.and.right.slash")
    }

    func testInternetIcon() {
        XCTAssertEqual(AppState.ConnectionType.internet.icon, "globe")
    }

    func testSimulatorRelayIcon() {
        XCTAssertEqual(AppState.ConnectionType.simulatorRelay.icon, "desktopcomputer")
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
        state.peerID = "alice-device"
        state.peerName   = "Alice's iPhone"
        XCTAssertTrue(state.peerOnline)
        XCTAssertEqual(state.peerID, "alice-device")
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
