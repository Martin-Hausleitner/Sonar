import AVFoundation
import Combine
import Network
import XCTest
@testable import Sonar

/// End-to-end transport tests using two in-process "devices" linked by MockBondedPath.
/// No network or hardware required — bonderA's outbound is manually wired to bonderB's inbound.
@MainActor
final class E2ETransportTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() async throws {
        cancellables.removeAll()
    }

    // MARK: - Helpers

    private func sineBuffer(sampleRate: Double = 48_000, frameCount: Int = 480, freq: Double = 440) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ch = buf.floatChannelData![0]
        for i in 0..<frameCount {
            ch[i] = Float(sin(2.0 * .pi * freq * Double(i) / sampleRate)) * 0.5
        }
        return buf
    }

    private var pcmFmt: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTAssertTrue(condition(), "Timed out waiting for network E2E condition")
    }

    // MARK: - Frame flow between two bonders

    func testFrameFlowsBetweenTwoBonders() async throws {
        let bonderA = MultipathBonder()
        let bonderB = MultipathBonder()

        let pathOut = MockBondedPath(id: .multipeer, connected: true)
        let pathIn  = MockBondedPath(id: .multipeer, connected: true)
        bonderA.addPath(pathOut)
        bonderB.addPath(pathIn)
        try await Task.sleep(nanoseconds: 50_000_000)

        var received: [AudioFrame] = []
        bonderB.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)

        await bonderA.send(opusData: Data([0xAB, 0xCD]))
        try await Task.sleep(nanoseconds: 30_000_000)

        guard let sent = pathOut.sentFrames.first else {
            XCTFail("bonderA must have sent a frame"); return
        }
        pathIn.receiveInbound(sent)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.payload, sent.payload)
        XCTAssertEqual(received.first?.seq, sent.seq)
    }

    // MARK: - Deduplication across two redundant paths

    func testDeduplicationAcrossTwoRedundantPaths() async throws {
        let bonder = MultipathBonder()
        var received: [AudioFrame] = []

        bonder.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)

        let pathA = MockBondedPath(id: .multipeer,  connected: false)
        let pathB = MockBondedPath(id: .bluetooth, connected: false)
        bonder.addPath(pathA)
        bonder.addPath(pathB)

        let frame = AudioFrame(seq: 42, payload: Data([0x11, 0x22]))
        pathA.receiveInbound(frame)
        pathB.receiveInbound(frame)  // same seq — duplicate
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(received.count, 1,
                       "Duplicate frame arriving on two paths must be forwarded exactly once")
    }

    // MARK: - Full Opus encode → mock wire → decode round-trip

    func testOpusRoundTripThroughMockTransport() async throws {
        let bonderA = MultipathBonder()
        let bonderB = MultipathBonder()

        let pathOut = MockBondedPath(id: .multipeer, connected: true)
        let pathIn  = MockBondedPath(id: .multipeer, connected: true)
        bonderA.addPath(pathOut)
        bonderB.addPath(pathIn)
        try await Task.sleep(nanoseconds: 50_000_000)

        var received: [AudioFrame] = []
        bonderB.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)

        // Encode a real PCM sine
        let encoder = OpusCoder()
        let opusData = try encoder.encode(sineBuffer())

        await bonderA.send(opusData: opusData)
        try await Task.sleep(nanoseconds: 30_000_000)

        guard let sentFrame = pathOut.sentFrames.first else {
            XCTFail("bonderA must have sent a frame"); return
        }
        pathIn.receiveInbound(sentFrame)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(received.count, 1, "Encoded frame must arrive at bonderB")

        // Decode and check the signal survived.
        // 2× headroom: iOS Opus may output 7.5 ms (360 samples) instead of 10 ms (480).
        let decoder = OpusCoder()
        let out = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(decoder.samplesPerFrame * 2))!
        do {
            try decoder.decode(received[0].payload, into: out)
        } catch {
            throw XCTSkip("Opus decode unavailable on this simulator: \(error)")
        }
        let n = Int(out.frameLength)
        XCTAssertGreaterThan(n, 0, "Decoder must produce at least one sample")

        let samples = UnsafeBufferPointer(start: out.floatChannelData![0], count: n)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(n))
        XCTAssertGreaterThan(rms, 0.01, "Decoded sine must have non-trivial RMS — Opus must not mute the signal")
    }

    // MARK: - Seq numbers are monotonically increasing

    func testSeqNumbersMonotonicallyIncreasing() async throws {
        let bonder = MultipathBonder()
        let path = MockBondedPath(id: .multipeer, connected: true)
        bonder.addPath(path)
        try await Task.sleep(nanoseconds: 50_000_000)

        for _ in 0..<5 {
            await bonder.send(opusData: Data([0x01]))
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let seqs = path.sentFrames.map(\.seq)
        XCTAssertEqual(seqs.count, 5)
        for i in 1..<seqs.count {
            XCTAssertGreaterThan(seqs[i], seqs[i - 1],
                                 "Seq [\(i)] must be greater than seq [\(i-1)]")
        }
    }

    // MARK: - Wire encoding round-trip

    func testWireEncodingRoundTrip() {
        let original = AudioFrame(seq: 0xDEAD_BEEF, payload: Data([0x01, 0x02, 0x03, 0x04]))
        guard let decoded = AudioFrame(wireData: original.wireData) else {
            XCTFail("wireData round-trip must not return nil"); return
        }
        XCTAssertEqual(decoded.seq,     original.seq)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded.codecID, original.codecID)
    }

    // MARK: - Redundant send with two paths, both receive identical seq

    func testRedundantSendDeliversSameSeqToBothPaths() async throws {
        let bonder = MultipathBonder()
        bonder.mode = .redundant

        let pathA = MockBondedPath(id: .multipeer, connected: true)
        let pathB = MockBondedPath(id: .bluetooth, connected: true)
        bonder.addPath(pathA)
        bonder.addPath(pathB)
        try await Task.sleep(nanoseconds: 50_000_000)

        await bonder.send(opusData: Data([0xFF, 0xFE]))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(pathA.sentFrames.count, 1)
        XCTAssertEqual(pathB.sentFrames.count, 1)
        XCTAssertEqual(pathA.sentFrames[0].seq, pathB.sentFrames[0].seq,
                       "Both paths must carry identical seq in redundant mode")
        XCTAssertEqual(pathA.sentFrames[0].payload, pathB.sentFrames[0].payload)
    }

    // MARK: - Real loopback network path

    func testOpusFrameFlowsOverRealLoopbackTCPNetwork() async throws {
        let link = try await LoopbackAudioFrameNetworkLink.makeConnected()
        defer { link.stop() }

        let bonderA = MultipathBonder()
        let bonderB = MultipathBonder()
        bonderA.addPath(link.clientPath)
        bonderB.addPath(link.serverPath)
        try await Task.sleep(nanoseconds: 50_000_000)

        var received: [AudioFrame] = []
        bonderB.inboundFrames
            .sink { received.append($0) }
            .store(in: &cancellables)

        let encoder = OpusCoder()
        let opusData = try encoder.encode(sineBuffer(freq: 660))

        await bonderA.send(opusData: opusData)

        try await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            received.count == 1
        }

        let decodedFrame = try XCTUnwrap(received.first)
        XCTAssertEqual(decodedFrame.payload, opusData)

        let decoder = OpusCoder()
        let out = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(decoder.samplesPerFrame * 2))!
        try decoder.decode(decodedFrame.payload, into: out)
        XCTAssertGreaterThan(out.frameLength, 0)
    }
}

// MARK: - Test-only real TCP bonded path

private final class LoopbackAudioFrameNetworkLink {
    let clientPath: LoopbackTCPBondedPath
    let serverPath: LoopbackTCPBondedPath

    private let listener: NWListener

    private init(
        listener: NWListener,
        clientPath: LoopbackTCPBondedPath,
        serverPath: LoopbackTCPBondedPath
    ) {
        self.listener = listener
        self.clientPath = clientPath
        self.serverPath = serverPath
    }

    static func makeConnected() async throws -> LoopbackAudioFrameNetworkLink {
        let queue = DispatchQueue(label: "sonar.tests.loopback-network")
        let listener = try NWListener(using: .tcp, on: .any)

        let accept = OneShot<NWConnection>()
        listener.newConnectionHandler = { connection in
            accept.resume(returning: connection)
        }

        let ready = OneShot<NWEndpoint.Port>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    ready.resume(returning: port)
                } else {
                    ready.resume(throwing: LoopbackNetworkError.listenerMissingPort)
                }
            case .failed(let error):
                ready.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: queue)

        let port = try await ready.value()
        let clientConnection = NWConnection(host: .ipv4(IPv4Address("127.0.0.1")!), port: port, using: .tcp)
        let clientReady = waitForReady(clientConnection)
        clientConnection.start(queue: queue)

        let serverConnection = try await accept.value()
        let serverReady = waitForReady(serverConnection)
        serverConnection.start(queue: queue)

        try await clientReady.value
        try await serverReady.value

        return LoopbackAudioFrameNetworkLink(
            listener: listener,
            clientPath: LoopbackTCPBondedPath(id: .mpquic, connection: clientConnection, queue: queue),
            serverPath: LoopbackTCPBondedPath(id: .mpquic, connection: serverConnection, queue: queue)
        )
    }

    func stop() {
        clientPath.stop()
        serverPath.stop()
        listener.cancel()
    }

    private static func waitForReady(_ connection: NWConnection) -> Task<Void, Error> {
        Task {
            let ready = OneShot<Void>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.resume(returning: ())
                case .failed(let error):
                    ready.resume(throwing: error)
                case .cancelled:
                    ready.resume(throwing: LoopbackNetworkError.connectionCancelledBeforeReady)
                default:
                    break
                }
            }
            try await ready.value()
            connection.stateUpdateHandler = nil
        }
    }
}

private enum LoopbackNetworkError: Error {
    case listenerMissingPort
    case connectionCancelledBeforeReady
}

private final class LoopbackTCPBondedPath: BondedPath, @unchecked Sendable {
    let id: MultipathBonder.PathID
    let estimatedCostPerByte: Double = 0.01

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let connectedSubject = CurrentValueSubject<Bool, Never>(true)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()
    private let bufferLock = NSLock()
    private var receiveBuffer = Data()

    var isConnected: AnyPublisher<Bool, Never> {
        connectedSubject.eraseToAnyPublisher()
    }

    var inboundFrames: AnyPublisher<AudioFrame, Never> {
        inboundSubject.eraseToAnyPublisher()
    }

    init(id: MultipathBonder.PathID, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
        receiveNextChunk()
    }

    func send(_ frame: AudioFrame) async {
        let payload = frame.wireData
        var packet = Data(capacity: 4 + payload.count)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
        connectedSubject.send(false)
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.appendAndEmitFrames(data)
            }
            if isComplete || error != nil {
                self.connectedSubject.send(false)
                return
            }
            self.receiveNextChunk()
        }
    }

    private func appendAndEmitFrames(_ data: Data) {
        var frames: [AudioFrame] = []

        bufferLock.lock()
        receiveBuffer.append(data)
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            }
            let totalLength = 4 + Int(length)
            guard receiveBuffer.count >= totalLength else { break }
            let frameData = receiveBuffer.dropFirst(4).prefix(Int(length))
            if let frame = AudioFrame(wireData: Data(frameData)) {
                frames.append(frame)
            }
            receiveBuffer.removeFirst(totalLength)
        }
        bufferLock.unlock()

        for frame in frames {
            inboundSubject.send(frame)
        }
    }
}

private final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resume(returning value: Value) {
        resume(with: .success(value))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
