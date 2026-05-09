@testable import Sonar
import XCTest

final class TransportSwitchingTests: XCTestCase {
    @MainActor
    func testInitialActiveIsNear() {
        let mux = TransportMultiplexer(near: NearTransport(), far: FarTransport(), audioRouter: AudioRouter())
        XCTAssertEqual(mux.active, .near)
    }

    @MainActor
    func testSwitchToFar() {
        let mux = TransportMultiplexer(near: NearTransport(), far: FarTransport(), audioRouter: AudioRouter())
        mux.select(.far)
        XCTAssertEqual(mux.active, .far)
    }
}
