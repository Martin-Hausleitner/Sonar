import XCTest
@testable import Sonar

/// Tests for PrivacyMode.
/// We instantiate fresh instances via init() — we do NOT use .shared
/// to avoid cross-test state contamination.
@MainActor
final class PrivacyModeTests: XCTestCase {

    // PrivacyMode.init() is private, so we test via the shared singleton
    // but reset its state before each test.
    private var mode: PrivacyMode!

    override func setUp() {
        super.setUp()
        mode = PrivacyMode.shared
        // Reset to known state
        if mode.isActive { mode.deactivate() }
    }

    // MARK: - activate

    func testActivateSetsIsActiveTrue() {
        mode.activate()
        XCTAssertTrue(mode.isActive)
    }

    func testActivateIsIdempotent() {
        mode.activate()
        mode.activate()
        XCTAssertTrue(mode.isActive)
    }

    // MARK: - deactivate

    func testDeactivateSetsIsActiveFalse() {
        mode.activate()
        mode.deactivate()
        XCTAssertFalse(mode.isActive)
    }

    func testDeactivateWhenAlreadyInactiveRemainsInactive() {
        mode.deactivate()
        XCTAssertFalse(mode.isActive)
    }

    // MARK: - toggle

    func testToggleFromInactiveActivates() {
        XCTAssertFalse(mode.isActive)
        mode.toggle()
        XCTAssertTrue(mode.isActive)
    }

    func testToggleFromActiveDeactivates() {
        mode.activate()
        mode.toggle()
        XCTAssertFalse(mode.isActive)
    }

    func testDoubleToggleRestoresState() {
        let initial = mode.isActive
        mode.toggle()
        mode.toggle()
        XCTAssertEqual(mode.isActive, initial)
    }

    // MARK: - Notifications

    func testActivatePostsActivatedNotification() {
        let exp = expectation(description: "activated notification")
        let token = NotificationCenter.default.addObserver(
            forName: .sonarPrivacyModeActivated,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }

        mode.activate()

        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    func testDeactivatePostsDeactivatedNotification() {
        mode.activate()

        let exp = expectation(description: "deactivated notification")
        let token = NotificationCenter.default.addObserver(
            forName: .sonarPrivacyModeDeactivated,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }

        mode.deactivate()

        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    func testTogglePostsCorrectNotifications() {
        // From inactive → toggle → activated notification expected
        let exp = expectation(description: "activated via toggle")
        let token = NotificationCenter.default.addObserver(
            forName: .sonarPrivacyModeActivated,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }

        mode.toggle()

        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    func testActivateDoesNotPostDeactivatedNotification() {
        var gotDeactivated = false
        let token = NotificationCenter.default.addObserver(
            forName: .sonarPrivacyModeDeactivated,
            object: nil,
            queue: .main
        ) { _ in gotDeactivated = true }

        mode.activate()

        // Small spin to ensure any spurious notifications would have arrived
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(gotDeactivated, "activate() must not post the deactivated notification")
        NotificationCenter.default.removeObserver(token)
    }
}
