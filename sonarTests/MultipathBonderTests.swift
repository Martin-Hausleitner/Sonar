import Combine
@testable import Sonar
import XCTest

// MARK: - Mock

final class MockBondedPath: BondedPath, @unchecked Sendable {
    let id: MultipathBonder.PathID
    private let connectedSubject: CurrentValueSubject<Bool, Never>
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()
    let estimatedCostPerByte: Double

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundSubject.eraseToAnyPublisher()
    }

    private(set) var sentFrames: [AudioFrame] = []

    init(id: MultipathBonder.PathID, connected: Bool = true, cost: Double = 1.0) {
        self.id = id
        connectedSubject = CurrentValueSubject(connected)
        estimatedCostPerByte = cost
    }

    func send(_ frame: AudioFrame) async {
        sentFrames.append(frame)
    }

    /// Simulate a connection state change.
    func setConnected(_ connected: Bool) {
        connectedSubject.send(connected)
    }

    /// Simulate receiving an inbound frame on this path.
    func receiveInbound(_ frame: AudioFrame) {
        inboundSubject.send(frame)
    }
}

// MARK: - Tests

@MainActor
final class MultipathBonderTests: XCTestCase {
    // MARK: - Initial state

    func testStartsWithEmptyActivePaths() {
        let bonder = MultipathBonder()
        XCTAssertTrue(bonder.activePaths.isEmpty)
    }

    // MARK: - addPath

    func testAddConnectedPathAppearsInActivePaths() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .multipeer, connected: true)
        bonder.addPath(path)

        // The Combine sink dispatches to DispatchQueue.main, so we give the
        // run loop one turn to process the initial value from the publisher.
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        XCTAssertTrue(bonder.activePaths.contains(.multipeer))
    }

    func testAddDisconnectedPathDoesNotAppearInActivePaths() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .bluetooth, connected: false)
        bonder.addPath(path)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(bonder.activePaths.contains(.bluetooth))
    }

    func testPathBecomesActiveAfterConnect() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .mpquic, connected: false)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(bonder.activePaths.contains(.mpquic))

        path.setConnected(true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(bonder.activePaths.contains(.mpquic))
    }

    func testPathRemovedAfterDisconnect() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .tailscale, connected: true)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(bonder.activePaths.contains(.tailscale))

        path.setConnected(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(bonder.activePaths.contains(.tailscale))
    }

    // MARK: - removePath

    func testRemovePathDropsFromActivePaths() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .multipeer, connected: true)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 50_000_000)

        bonder.removePath(.multipeer)
        XCTAssertFalse(bonder.activePaths.contains(.multipeer))
    }

    func testRemovedPathCannotReAddItselfAfterLaterConnectionEvent() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .mpquic, connected: false)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 50_000_000)

        bonder.removePath(.mpquic)
        path.setConnected(true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(
            bonder.activePaths.contains(.mpquic),
            "A removed path's old isConnected subscription must not re-add it."
        )
    }

    func testRemovedPathCannotDeliverInboundFrames() async throws {
        let bonder = MultipathBonder()
        var receivedFrames: [AudioFrame] = []
        var cancellables = Set<AnyCancellable>()

        bonder.inboundFrames
            .sink { receivedFrames.append($0) }
            .store(in: &cancellables)

        let path = MockBondedPath(id: .bluetooth, connected: true)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 50_000_000)

        bonder.removePath(.bluetooth)
        path.receiveInbound(AudioFrame(seq: 99, payload: Data([0x99])))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(
            receivedFrames.isEmpty,
            "A removed path's old inbound subscription must not deliver frames."
        )
    }

    func testRemoveAllPathsCancelsSubscriptionsAndClearsActivePaths() async throws {
        let bonder = MultipathBonder()
        let pathA = MockBondedPath(id: .multipeer, connected: true)
        let pathB = MockBondedPath(id: .mpquic, connected: false)
        bonder.addPath(pathA)
        bonder.addPath(pathB)
        try await Task.sleep(nanoseconds: 50_000_000)

        bonder.removeAllPaths()
        pathA.setConnected(false)
        pathB.setConnected(true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(bonder.activePaths.isEmpty)
    }

    // MARK: - Mode .redundant

    func testRedundantModeSendsOnAllConnectedPaths() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .redundant

        let pathA = MockBondedPath(id: .multipeer, connected: true)
        let pathB = MockBondedPath(id: .bluetooth, connected: true)
        bonder.addPath(pathA)
        bonder.addPath(pathB)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0x01, 0x02]))
        // Give the async sends a moment to complete
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(pathA.sentFrames.count, 1, "pathA should have received the frame")
        XCTAssertEqual(pathB.sentFrames.count, 1, "pathB should have received the frame")
    }

    func testRedundantModeFrameHasSameSeqOnAllPaths() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .redundant

        let pathA = MockBondedPath(id: .multipeer, connected: true)
        let pathB = MockBondedPath(id: .mpquic, connected: true)
        bonder.addPath(pathA)
        bonder.addPath(pathB)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xAB]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            pathA.sentFrames.first?.seq,
            pathB.sentFrames.first?.seq,
            "Both paths must carry the same seq number"
        )
    }

    // MARK: - Mode .primaryStandby

    func testPrimaryStandbyModeSendsOnlyOnHighestPriorityConnectedPath() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .primaryStandby

        let internet = MockBondedPath(id: .mpquic, connected: true)
        let tailscale = MockBondedPath(id: .tailscale, connected: true)
        let bluetooth = MockBondedPath(id: .bluetooth, connected: true)
        let multipeer = MockBondedPath(id: .multipeer, connected: true)
        bonder.addPath(internet)
        bonder.addPath(tailscale)
        bonder.addPath(bluetooth)
        bonder.addPath(multipeer)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xFF]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(multipeer.sentFrames.count, 1, "multipeer should be the deterministic primary")
        XCTAssertEqual(bluetooth.sentFrames.count, 0)
        XCTAssertEqual(tailscale.sentFrames.count, 0)
        XCTAssertEqual(internet.sentFrames.count, 0)

        // Total frames sent across all paths must be exactly 1
        let total = multipeer.sentFrames.count
            + bluetooth.sentFrames.count
            + tailscale.sentFrames.count
            + internet.sentFrames.count
        XCTAssertEqual(total, 1, "primaryStandby should only send on one path")
    }

    func testPrimaryStandbyModeFailsOverToNextPriorityPath() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .primaryStandby

        let internet = MockBondedPath(id: .mpquic, connected: true)
        let tailscale = MockBondedPath(id: .tailscale, connected: true)
        let bluetooth = MockBondedPath(id: .bluetooth, connected: true)
        let multipeer = MockBondedPath(id: .multipeer, connected: true)
        bonder.addPath(internet)
        bonder.addPath(tailscale)
        bonder.addPath(bluetooth)
        bonder.addPath(multipeer)
        try await Task.sleep(nanoseconds: 50_000_000)

        multipeer.setConnected(false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xFE]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(multipeer.sentFrames.count, 0)
        XCTAssertEqual(bluetooth.sentFrames.count, 1, "bluetooth should take over after multipeer disconnects")
        XCTAssertEqual(tailscale.sentFrames.count, 0)
        XCTAssertEqual(internet.sentFrames.count, 0)
    }

    func testPrimaryStandbyModeUsesSimulatorRelayWhenItIsTheOnlyConnectedPath() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .primaryStandby

        let simulatorRelay = MockBondedPath(id: .simulatorRelay, connected: true)
        bonder.addPath(simulatorRelay)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xFD]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(simulatorRelay.sentFrames.count, 1)
    }

    // MARK: - Mode .eco

    func testEcoModeSendsOnTwoCheapestConnectedPaths() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .eco

        let bluetooth = MockBondedPath(id: .bluetooth, connected: true, cost: 0.20)
        let multipeer = MockBondedPath(id: .multipeer, connected: true, cost: 0.10)
        let tailscale = MockBondedPath(id: .tailscale, connected: true, cost: 0.15)
        let internet = MockBondedPath(id: .mpquic, connected: true, cost: 0.80)
        bonder.addPath(bluetooth)
        bonder.addPath(multipeer)
        bonder.addPath(tailscale)
        bonder.addPath(internet)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xEC]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(multipeer.sentFrames.count, 1, "eco should use the cheapest connected path")
        XCTAssertEqual(tailscale.sentFrames.count, 1, "eco should keep a second connected path active")
        XCTAssertEqual(bluetooth.sentFrames.count, 0)
        XCTAssertEqual(internet.sentFrames.count, 0)
    }

    // MARK: - Deduplication of inbound frames

    func testInboundDuplicatesAreFiltered() async throws {
        let bonder = MultipathBonder()
        var receivedFrames: [AudioFrame] = []
        var cancellables = Set<AnyCancellable>()

        bonder.inboundFrames
            .sink { receivedFrames.append($0) }
            .store(in: &cancellables)

        let pathA = MockBondedPath(id: .multipeer, connected: false)
        let pathB = MockBondedPath(id: .bluetooth, connected: false)
        bonder.addPath(pathA)
        bonder.addPath(pathB)

        let frame = AudioFrame(seq: 1, payload: Data([0x11]))
        pathA.receiveInbound(frame)
        pathB.receiveInbound(frame) // duplicate

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            receivedFrames.count,
            1,
            "Duplicate inbound frame should be filtered by deduplicator"
        )
    }
}
