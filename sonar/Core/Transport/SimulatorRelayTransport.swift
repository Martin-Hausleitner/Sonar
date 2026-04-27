import AVFoundation
import Combine
import Foundation

struct SimulatorRelayPeer: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let lastSeen: Double
}

struct SimulatorRelayFrame: Codable, Equatable, Sendable {
    let from: String
    let seq: UInt32
    let wireDataBase64: String
}

struct SimulatorRelayPollResponse: Codable, Equatable, Sendable {
    let serverSeq: Int
    let peers: [SimulatorRelayPeer]
    let frames: [SimulatorRelayFrame]
}

protocol SimulatorRelayClienting: AnyObject {
    func register(identity: SonarTestIdentity, relayURL: URL) async throws
    func unregister(deviceID: String, relayURL: URL) async throws
    func send(frame: SimulatorRelayFrame, from deviceID: String, relayURL: URL) async throws
    func poll(deviceID: String, after sequence: Int, relayURL: URL) async throws -> SimulatorRelayPollResponse
}

@MainActor
final class SimulatorRelayTransport: Transport, BondedPath {
    let kind: TransportKind = .simulator
    let id: MultipathBonder.PathID = .simulatorRelay
    let estimatedCostPerByte: Double = 0.0001

    var onPeerUpdate: ((SimulatorRelayPeer?) -> Void)?

    private let identity: SonarTestIdentity
    private let relayURL: URL
    private let client: SimulatorRelayClienting
    private let pollIntervalNanoseconds: UInt64

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)

    private var pollTask: Task<Void, Never>?
    private var lastServerSeq = 0

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> {
        inboundPCMSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundFrameSubject.eraseToAnyPublisher()
    }

    var qualityScore: AnyPublisher<Double, Never> {
        qualitySubject.eraseToAnyPublisher()
    }

    init(
        identity: SonarTestIdentity,
        relayURL: URL,
        client: SimulatorRelayClienting = URLSessionSimulatorRelayClient(),
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.identity = identity
        self.relayURL = relayURL
        self.client = client
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    static func makeFromIdentity(_ identity: SonarTestIdentity) -> SimulatorRelayTransport? {
        guard let relayURL = identity.relayURL else { return nil }
        return SimulatorRelayTransport(identity: identity, relayURL: relayURL)
    }

    func start() async throws {
        try await client.register(identity: identity, relayURL: relayURL)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        try? await client.unregister(deviceID: identity.deviceID, relayURL: relayURL)
        connectedSubject.send(false)
        qualitySubject.send(0)
        onPeerUpdate?(nil)
    }

    func send(_ buffer: AVAudioPCMBuffer) async {}

    func send(_ frame: AudioFrame) async {
        let relayFrame = SimulatorRelayFrame(
            from: identity.deviceID,
            seq: frame.seq,
            wireDataBase64: frame.wireData.base64EncodedString()
        )
        try? await client.send(frame: relayFrame, from: identity.deviceID, relayURL: relayURL)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func pollOnce() async {
        do {
            let response = try await client.poll(deviceID: identity.deviceID, after: lastServerSeq, relayURL: relayURL)
            process(response)
        } catch {
            connectedSubject.send(false)
            qualitySubject.send(0)
            onPeerUpdate?(nil)
        }
    }

    private func process(_ response: SimulatorRelayPollResponse) {
        lastServerSeq = max(lastServerSeq, response.serverSeq)

        let peer = response.peers.first { $0.id != identity.deviceID }
        connectedSubject.send(peer != nil)
        qualitySubject.send(peer == nil ? 0 : 1)
        onPeerUpdate?(peer)

        for relayFrame in response.frames where relayFrame.from != identity.deviceID {
            guard let data = Data(base64Encoded: relayFrame.wireDataBase64),
                  let frame = AudioFrame(wireData: data) else { continue }
            inboundFrameSubject.send(frame)
        }
    }
}

private final class URLSessionSimulatorRelayClient: SimulatorRelayClienting {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func register(identity: SonarTestIdentity, relayURL: URL) async throws {
        let request = SimulatorRelayRegisterRequest(id: identity.deviceID, name: identity.deviceName)
        try await post(path: "/api/register", body: request, relayURL: relayURL)
    }

    func unregister(deviceID: String, relayURL: URL) async throws {
        let request = SimulatorRelayUnregisterRequest(id: deviceID)
        try await post(path: "/api/unregister", body: request, relayURL: relayURL)
    }

    func send(frame: SimulatorRelayFrame, from deviceID: String, relayURL: URL) async throws {
        let request = SimulatorRelaySendRequest(from: deviceID, frame: frame)
        try await post(path: "/api/send", body: request, relayURL: relayURL)
    }

    func poll(deviceID: String, after sequence: Int, relayURL: URL) async throws -> SimulatorRelayPollResponse {
        var components = URLComponents(url: endpoint("api/poll", relayURL: relayURL), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "after", value: String(sequence))
        ]
        let url = components.url!
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(SimulatorRelayPollResponse.self, from: data)
    }

    private func post<T: Encodable>(path: String, body: T, relayURL: URL) async throws {
        var request = URLRequest(url: endpoint(path, relayURL: relayURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        _ = try await session.data(for: request)
    }

    private func endpoint(_ path: String, relayURL: URL) -> URL {
        var url = relayURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

private struct SimulatorRelayRegisterRequest: Encodable {
    let id: String
    let name: String
}

private struct SimulatorRelayUnregisterRequest: Encodable {
    let id: String
}

private struct SimulatorRelaySendRequest: Encodable {
    let from: String
    let frame: SimulatorRelayFrame
}
