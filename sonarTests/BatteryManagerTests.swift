import XCTest
@testable import Sonar

/// Tests for BatteryManager.Tier only.
/// BatteryManager.shared is @MainActor and requires UIKit hardware,
/// so we only test the pure value-type enum extensions here.
final class BatteryManagerTests: XCTestCase {

    // MARK: - activePaths

    func testNormalTierHasFourActivePaths() {
        XCTAssertEqual(BatteryManager.Tier.normal.activePaths, 4)
    }

    func testEcoTierHasTwoActivePaths() {
        XCTAssertEqual(BatteryManager.Tier.eco.activePaths, 2)
    }

    func testSaverTierHasOneActivePath() {
        XCTAssertEqual(BatteryManager.Tier.saver.activePaths, 1)
    }

    func testCriticalTierHasOneActivePath() {
        XCTAssertEqual(BatteryManager.Tier.critical.activePaths, 1)
    }

    // MARK: - recordingEnabled

    func testCriticalTierDisablesRecording() {
        XCTAssertFalse(BatteryManager.Tier.critical.recordingEnabled)
    }

    func testNormalTierEnablesRecording() {
        XCTAssertTrue(BatteryManager.Tier.normal.recordingEnabled)
    }

    func testEcoTierEnablesRecording() {
        XCTAssertTrue(BatteryManager.Tier.eco.recordingEnabled)
    }

    func testSaverTierEnablesRecording() {
        XCTAssertTrue(BatteryManager.Tier.saver.recordingEnabled)
    }

    // MARK: - transcriptionEnabled

    func testNormalAndEcoHaveTranscriptionEnabled() {
        XCTAssertTrue(BatteryManager.Tier.normal.transcriptionEnabled)
        XCTAssertTrue(BatteryManager.Tier.eco.transcriptionEnabled)
    }

    func testSaverAndCriticalHaveTranscriptionDisabled() {
        XCTAssertFalse(BatteryManager.Tier.saver.transcriptionEnabled)
        XCTAssertFalse(BatteryManager.Tier.critical.transcriptionEnabled)
    }

    // MARK: - Comparable

    func testNormalIsGreaterThanCritical() {
        XCTAssertGreaterThan(BatteryManager.Tier.normal, BatteryManager.Tier.critical)
    }

    func testCriticalIsLessThanSaver() {
        XCTAssertLessThan(BatteryManager.Tier.critical, BatteryManager.Tier.saver)
    }

    func testTierOrder() {
        let ordered: [BatteryManager.Tier] = [.critical, .saver, .eco, .normal]
        XCTAssertEqual(ordered.sorted(), ordered)
    }

    // MARK: - opusBitrateKbps ordering

    func testOpusBitrateDecreasing() {
        let normal = BatteryManager.Tier.normal.opusBitrateKbps
        let eco    = BatteryManager.Tier.eco.opusBitrateKbps
        let saver  = BatteryManager.Tier.saver.opusBitrateKbps

        XCTAssertGreaterThan(normal, eco,   "normal bitrate should exceed eco")
        XCTAssertGreaterThan(eco,    saver, "eco bitrate should exceed saver")
        XCTAssertGreaterThan(saver,  0,     "saver bitrate should be positive")
    }

    func testNormalBitrateIs32kbps() {
        XCTAssertEqual(BatteryManager.Tier.normal.opusBitrateKbps, 32)
    }

    func testCriticalBitrateIsZero() {
        // Critical = PTT / Lyra 3.2 kbps — opusBitrateKbps is 0 in this tier
        XCTAssertEqual(BatteryManager.Tier.critical.opusBitrateKbps, 0)
    }
}
