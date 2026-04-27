import Combine
import XCTest

@testable import Sonar

@MainActor
final class SimulatorRelayTransportTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() async throws {
        cancellables.removeAll()
    }

    func testStartRegistersAndPublishesConnectedPeer() async throws {
        let client = MockSimulatorRelayClient()
        let peer = SimulatorRelayPeer(id: "SIM-B-97D949", name: "SIM-B", lastSeen: 1_234)
        client.pollResponses = [
            SimulatorRelayPollResponse(serverSeq: 1, peers: [peer], frames: [])
        ]

        let transport = makeTransport(client: client)
        var connectedValues: [Bool] = []
        var peerUpdates: [SimulatorRelayPeer?] = []

        transport.isConnected
            .sink { connectedValues.append($0) }
            .store(in: &cancellables)
        transport.onPeerUpdate = { peerUpdates.append($0) }

        try await transport.start()
        try await waitUntil {
            connectedValues.contains(true) && peerUpdates.compactMap { $0?.id }.contains("SIM-B-97D949")
        }
        await transport.stop()

        XCTAssertEqual(client.registeredDeviceIDs, ["SIM-A-38D0B9"])
    }

    func testPollResponsePublishesInboundAudioFrame() async throws {
        let frame = AudioFrame(seq: 42, payload: Data([0xDE, 0xAD]))
        let client = MockSimulatorRelayClient()
        client.pollResponses = [
            SimulatorRelayPollResponse(
                serverSeq: 5,
                peers: [SimulatorRelayPeer(id: "SIM-B-97D949", name: "SIM-B", lastSeen: 1_234)],
                frames: [
                    SimulatorRelayFrame(from: "SIM-B-97D949", seq: 42, wireDataBase64: frame.wireData.base64EncodedString())
                ]
            )
        ]

        let transport = makeTransport(client: client)
        var received: [AudioFrame] = []
        transport.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)

        try await transport.start()
        try await waitUntil { received.count == 1 }
        await transport.stop()

        XCTAssertEqual(received.first?.seq, frame.seq)
        XCTAssertEqual(received.first?.payload, frame.payload)
    }

    func testSendPostsWireFrameToClient() async throws {
        let client = MockSimulatorRelayClient()
        let transport = makeTransport(client: client)
        let frame = AudioFrame(seq: 7, payload: Data([0xCA, 0xFE]))

        await transport.send(frame)

        XCTAssertEqual(client.sentFrames.count, 1)
        XCTAssertEqual(client.sentFrames.first?.from, "SIM-A-38D0B9")
        XCTAssertEqual(client.sentFrames.first?.frame.seq, frame.seq)
        XCTAssertEqual(client.sentFrames.first?.frame.wireDataBase64, frame.wireData.base64EncodedString())
    }

    private func makeTransport(client: MockSimulatorRelayClient) -> SimulatorRelayTransport {
        SimulatorRelayTransport(
            identity: SonarTestIdentity(
                environment: [
                    "SONAR_TEST_DEVICE_ID": "SIM-A-38D0B9",
                    "SONAR_TEST_DEVICE_NAME": "SIM-A",
                    "SONAR_SIM_RELAY_URL": "http://127.0.0.1:8787"
                ],
                arguments: [],
                vendorIdentifier: nil,
                fallbackDeviceName: "Fallback"
            ),
            relayURL: URL(string: "http://127.0.0.1:8787")!,
            client: client,
            pollIntervalNanoseconds: 10_000_000
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for simulator relay condition")
    }
}

private final class MockSimulatorRelayClient: SimulatorRelayClienting {
    var registeredDeviceIDs: [String] = []
    var unregisteredDeviceIDs: [String] = []
    var sentFrames: [(from: String, frame: SimulatorRelayFrame)] = []
    var pollResponses: [SimulatorRelayPollResponse] = []

    func register(identity: SonarTestIdentity, relayURL: URL) async throws {
        registeredDeviceIDs.append(identity.deviceID)
    }

    func unregister(deviceID: String, relayURL: URL) async throws {
        unregisteredDeviceIDs.append(deviceID)
    }

    func send(frame: SimulatorRelayFrame, from deviceID: String, relayURL: URL) async throws {
        sentFrames.append((deviceID, frame))
    }

    func poll(deviceID: String, after sequence: Int, relayURL: URL) async throws -> SimulatorRelayPollResponse {
        if pollResponses.isEmpty {
            return SimulatorRelayPollResponse(serverSeq: sequence, peers: [], frames: [])
        }
        return pollResponses.removeFirst()
    }
}
