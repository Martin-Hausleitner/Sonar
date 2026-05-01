import XCTest
@testable import Sonar

@MainActor
final class AppStateTests: XCTestCase {
    func testDefaultsToIdle() {
        let s = AppState()
        XCTAssertEqual(s.phase, .idle)
    }

    func testMicrophoneDefaultsToUnmutedWithNoInputLevel() {
        let s = AppState()
        XCTAssertFalse(s.isMuted)
        XCTAssertEqual(s.inputLevelRMS, 0, accuracy: 0.0001)
    }

    func testMicrophoneStateCanBeUpdated() {
        let s = AppState()
        s.isMuted = true
        s.inputLevelRMS = 0.42

        XCTAssertTrue(s.isMuted)
        XCTAssertEqual(s.inputLevelRMS, 0.42, accuracy: 0.0001)
    }

    func testPhaseEquality() {
        XCTAssertEqual(AppState.Phase.idle, .idle)
        XCTAssertEqual(AppState.Phase.connecting, .connecting)
        XCTAssertEqual(AppState.Phase.near(distance: 1.5), .near(distance: 1.5))
        XCTAssertNotEqual(AppState.Phase.near(distance: 1.5), .near(distance: 1.6))
        XCTAssertNotEqual(AppState.Phase.near(distance: 1.5), .far)
    }
}

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testStartsIdle() {
        let c = SessionCoordinator()
        XCTAssertEqual(c.phase, .idle)
    }

    func testStartLiftsToConnecting() {
        let c = SessionCoordinator()
        c.start()
        XCTAssertEqual(c.phase, .connecting)
        c.stop()   // cancel background task to avoid leaking transcription into later tests
    }

    func testStopReturnsToIdle() {
        let c = SessionCoordinator()
        c.start()
        c.stop()
        XCTAssertEqual(c.phase, .idle)
    }
}
