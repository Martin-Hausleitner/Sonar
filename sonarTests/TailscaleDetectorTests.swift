import XCTest
@testable import Sonar

/// Tests for `TailscaleDetector.isInCGNATRange(_:)` — pure CGNAT-membership
/// logic. We cannot deterministically test the live `getifaddrs(3)` walk
/// (it depends on whether the runner is actually attached to a tailnet),
/// so we focus on the membership predicate that gates which interfaces
/// count as Tailscale.
final class TailscaleDetectorTests: XCTestCase {

    // MARK: - Inside the 100.64.0.0/10 block (Tailscale CGNAT)

    func testCGNATLowBoundary() {
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.64.0.0"))
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.64.0.1"))
    }

    func testCGNATMidRange() {
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.100.42.17"))
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.96.1.1"))
    }

    func testCGNATHighBoundary() {
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.127.255.254"))
        XCTAssertTrue(TailscaleDetector.isInCGNATRange("100.127.255.255"))
    }

    // MARK: - Outside the CGNAT block

    func testRejects100_128_Boundary() {
        // 100.128.x.x is just above the /10 block; must be rejected.
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.128.0.1"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.128.0.0"))
    }

    func testRejects100_63_Boundary() {
        // 100.63.x.x is just below the /10 block; must be rejected.
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.63.255.255"))
    }

    func testRejectsPrivateRanges() {
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("192.168.1.1"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("10.0.0.1"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("172.16.0.1"))
    }

    func testRejectsPublicAddress() {
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("8.8.8.8"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("1.1.1.1"))
    }

    func testRejectsLoopback() {
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("127.0.0.1"))
    }

    // MARK: - Malformed inputs

    func testRejectsMalformed() {
        XCTAssertFalse(TailscaleDetector.isInCGNATRange(""))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.64"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.64.0"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.64.0.0.1"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("not-an-ip"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("256.64.0.1"))      // first octet overflow
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("100.999.0.1"))     // second octet overflow
    }

    // MARK: - IPv6 not supported (Tailscale's 4via6 still presents IPv4)

    func testRejectsIPv6() {
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("fd7a:115c:a1e0::1"))
        XCTAssertFalse(TailscaleDetector.isInCGNATRange("::1"))
    }
}
