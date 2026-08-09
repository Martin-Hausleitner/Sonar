import AVFoundation
@testable import Sonar
import XCTest

/// Guards the two configuration bugs that made a connected session inaudible:
/// playback landing on the earpiece receiver, and the missing `_udp` Bonjour
/// entry that makes MultipeerConnectivity fail its handshake on iOS 14+.
final class AudioRoutePolicyTests: XCTestCase {
    // MARK: - Output route

    func testCategoryOptionsRouteToSpeakerByDefault() {
        let policy = AudioSessionPolicy()
        XCTAssertTrue(
            policy.categoryOptions.contains(.defaultToSpeaker),
            "Without .defaultToSpeaker, .playAndRecord routes the peer's voice to the earpiece receiver"
        )
    }

    func testCategoryOptionsKeepAirPlayBluetoothAndMixing() {
        let policy = AudioSessionPolicy()
        XCTAssertTrue(policy.categoryOptions.contains(.allowAirPlay))
        XCTAssertTrue(policy.categoryOptions.contains(.allowBluetooth))
        XCTAssertTrue(policy.categoryOptions.contains(.mixWithOthers))
    }

    func testSpeakerRoutingSurvivesDuckingAndModeNudges() {
        var policy = AudioSessionPolicy(rawAudioMode: false, listeningModeNudge: .voiceChat)
        policy.musicDuckingEnabled = true
        XCTAssertTrue(policy.categoryOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(policy.categoryOptions.contains(.duckOthers))
        XCTAssertEqual(policy.sessionMode, .voiceChat)
    }

    // MARK: - Bonjour declaration

    /// MultipeerConnectivity needs BOTH transport entries since iOS 14;
    /// with only `_tcp` the MCSession handshake fails silently.
    func testBonjourServicesDeclareTCPAndUDP() throws {
        let bundle = Bundle(for: OpusCoder.self)
        let services = (bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
            ?? (Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        guard let services else {
            throw XCTSkip("Test bundle has no host-app Info.plist to inspect")
        }
        XCTAssertTrue(services.contains("_sonar-mpc._tcp"), "declared: \(services)")
        XCTAssertTrue(services.contains("_sonar-mpc._udp"), "declared: \(services)")

        // The declared Bonjour names must match the service type NearTransport
        // actually advertises/browses with — a rename on either side silently
        // kills discovery.
        XCTAssertTrue(
            services.contains("_\(PairingToken.mpcServiceType)._tcp"),
            "Info.plist NSBonjourServices out of sync with NearTransport service type \(PairingToken.mpcServiceType)"
        )
        XCTAssertTrue(
            services.contains("_\(PairingToken.mpcServiceType)._udp"),
            "Info.plist NSBonjourServices out of sync with NearTransport service type \(PairingToken.mpcServiceType)"
        )
    }
}

/// Task 1.4: encode failures must hit an explicit metrics counter, not just a
/// throttled log line.
final class MetricsCounterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Metrics.shared.resetCounters()
    }

    override func tearDown() {
        Metrics.shared.resetCounters()
        super.tearDown()
    }

    func testCountersStartAtZero() {
        XCTAssertEqual(Metrics.shared.count(.opusEncodeFailure), 0)
        XCTAssertEqual(Metrics.shared.count(.opusEncodeSuccess), 0)
    }

    func testIncrementAndReset() {
        Metrics.shared.increment(.opusEncodeFailure)
        Metrics.shared.increment(.opusEncodeFailure, by: 2)
        Metrics.shared.increment(.opusEncodeSuccess)
        XCTAssertEqual(Metrics.shared.count(.opusEncodeFailure), 3)
        XCTAssertEqual(Metrics.shared.count(.opusEncodeSuccess), 1)

        Metrics.shared.resetCounters()
        XCTAssertEqual(Metrics.shared.count(.opusEncodeFailure), 0)
        XCTAssertEqual(Metrics.shared.count(.opusEncodeSuccess), 0)
    }
}
