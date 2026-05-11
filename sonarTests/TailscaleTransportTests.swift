import Combine
import Foundation
import Network
@testable import Sonar
import XCTest

@MainActor
final class TailscaleTransportTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        cancellables.removeAll()
    }

    func testPairingTokenConnectsAndCarriesAudioFramesOverLoopbackTCP() async throws {
        let port = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: port)
        let senderPort = try XCTUnwrap(freeTCPPort())
        let sender = TailscaleTransport(listenPort: senderPort)
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
        receiver.applyPairingToken(PairingToken(
            id: "sender",
            name: "Sender",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: senderPort,
            ts: 1_750_000_000
        ))
        sender.applyPairingToken(token)

        try await waitUntil { senderConnected }

        let frame = AudioFrame(seq: 42, payload: Data([0xCA, 0xFE]), codec: .opus)
        await sender.send(frame)

        try await waitUntil { received.contains { $0.seq == 42 } }
        let matchingFrame = try XCTUnwrap(received.first { $0.seq == 42 })
        XCTAssertEqual(matchingFrame.payload, Data([0xCA, 0xFE]))
    }

    func testInboundConnectionWithoutReceiverSidePairingTokenStaysDisconnected() async throws {
        let receiverPort = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: receiverPort)
        let sender = try TailscaleTransport(listenPort: XCTUnwrap(freeTCPPort()))
        defer {
            receiver.stop()
            sender.stop()
        }

        try receiver.start()
        try sender.start()

        var receiverConnected = false
        receiver.isConnected
            .sink { receiverConnected = $0 }
            .store(in: &cancellables)

        sender.applyPairingToken(PairingToken(
            id: "receiver",
            name: "Receiver",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: receiverPort,
            ts: 1_750_000_000
        ))

        try await assertStaysFalse { receiverConnected }
    }

    func testRemovePairingTokenDisconnectsOutboundConnection() async throws {
        let receiverPort = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: receiverPort)
        let senderPort = try XCTUnwrap(freeTCPPort())
        let sender = TailscaleTransport(listenPort: senderPort)
        defer {
            receiver.stop()
            sender.stop()
        }

        try receiver.start()
        try sender.start()

        var senderConnected = false
        sender.isConnected
            .sink { senderConnected = $0 }
            .store(in: &cancellables)

        receiver.applyPairingToken(PairingToken(
            id: "sender",
            name: "Sender",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: senderPort,
            ts: 1_750_000_000
        ))
        sender.applyPairingToken(PairingToken(
            id: "receiver",
            name: "Receiver",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: receiverPort,
            ts: 1_750_000_000
        ))

        try await waitUntil { senderConnected }

        sender.removePairingToken(forTSIP: "127.0.0.1", port: receiverPort)

        try await waitUntil { !senderConnected }
    }

    func testRemovePairingTokenDisconnectsInboundAcceptedConnectionByRemoteIP() async throws {
        let receiverPort = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: receiverPort)
        let senderPort = try XCTUnwrap(freeTCPPort())
        let sender = TailscaleTransport(listenPort: senderPort)
        defer {
            receiver.stop()
            sender.stop()
        }

        try receiver.start()
        try sender.start()

        var receiverConnected = false
        receiver.isConnected
            .sink { receiverConnected = $0 }
            .store(in: &cancellables)

        receiver.applyPairingToken(PairingToken(
            id: "sender",
            name: "Sender",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: senderPort,
            ts: 1_750_000_000
        ))
        sender.applyPairingToken(PairingToken(
            id: "receiver",
            name: "Receiver",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: receiverPort,
            ts: 1_750_000_000
        ))

        try await waitUntil { receiverConnected }

        receiver.removePairingToken(forTSIP: "127.0.0.1", port: receiverPort)

        try await waitUntil { !receiverConnected }
    }

    func testPrivacyModeBlocksPairingTokenOutboundDial() async throws {
        let receiverPort = try XCTUnwrap(freeTCPPort())
        let receiver = TailscaleTransport(listenPort: receiverPort)
        let sender = try TailscaleTransport(listenPort: XCTUnwrap(freeTCPPort()))
        defer {
            PrivacyMode.shared.deactivate()
            receiver.stop()
            sender.stop()
        }

        try receiver.start()
        try sender.start()

        var senderConnected = false
        sender.isConnected
            .sink { senderConnected = $0 }
            .store(in: &cancellables)

        PrivacyMode.shared.activate()
        sender.applyPairingToken(PairingToken(
            id: "receiver",
            name: "Receiver",
            host: "localhost",
            tsIP: "127.0.0.1",
            tsPort: receiverPort,
            ts: 1_750_000_000
        ))

        try await assertStaysFalse { senderConnected }
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

    private func assertStaysFalse(
        durationNanoseconds: UInt64 = 300_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + durationNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            XCTAssertFalse(condition(), "Condition became true before timeout elapsed")
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTAssertFalse(condition())
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
