import Combine
import Foundation
import Network
@testable import Sonar
import XCTest

@MainActor
final class TailscaleTransportTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() async throws {
        cancellables.removeAll()
    }

    func testPairingTokenConnectsAndCarriesAudioFramesOverLoopbackTCP() async throws {
        let port = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: port)
        let sender = try TailscaleTransport(listenPort: XCTUnwrap(freeTCPPort()))
        defer {
            receiver.stop()
            sender.stop()
        }

        try receiver.start()
        try sender.start()

        var received: [AudioFrame] = []
        receiver.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)
        var senderConnected = false
        sender.isConnected
            .sink { senderConnected = $0 }
            .store(in: &cancellables)

        let token = PairingToken(
            id: "receiver",
            name: "Receiver",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: port,
            ts: 1_750_000_000
        )
        sender.applyPairingToken(token)

        try await waitUntil { senderConnected }

        let frame = AudioFrame(seq: 42, payload: Data([0xCA, 0xFE]), codec: .opus)
        await sender.send(frame)

        try await waitUntil { received.count == 1 }
        XCTAssertEqual(received.first?.seq, 42)
        XCTAssertEqual(received.first?.payload, Data([0xCA, 0xFE]))
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_500_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTAssertTrue(condition(), "Timed out waiting for Tailscale transport condition")
    }

    private func freeTCPPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: bound.sin_port)
    }
}
