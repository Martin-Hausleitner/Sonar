import XCTest
@testable import Sonar

@MainActor
final class AppStateTests: XCTestCase {
    func testDefaultsToIdle() {
        let s = AppState()
        XCTAssertEqual(s.phase, .idle)
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
    }

    func testStopReturnsToIdle() {
        let c = SessionCoordinator()
        c.start()
        c.stop()
        XCTAssertEqual(c.phase, .idle)
    }
}
