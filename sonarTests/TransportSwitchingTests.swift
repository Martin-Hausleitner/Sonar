import XCTest
@testable import Sonar

final class TransportSwitchingTests: XCTestCase {
    @MainActor
    func testInitialActiveIsNear() async {
        let mux = TransportMultiplexer(near: NearTransport(), far: FarTransport(), audioRouter: AudioRouter())
        XCTAssertEqual(mux.active, .near)
    }

    @MainActor
    func testSwitchToFar() async {
        let mux = TransportMultiplexer(near: NearTransport(), far: FarTransport(), audioRouter: AudioRouter())
        mux.select(.far)
        XCTAssertEqual(mux.active, .far)
    }
}
