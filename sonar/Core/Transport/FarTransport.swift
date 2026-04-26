import AVFoundation
import Combine
import Foundation

/// Cellular / internet transport via MPQUIC. Plan §2.2 Pfad 3.
/// Wraps MPQUICTransport and also satisfies the legacy Transport protocol
/// for TransportMultiplexer compatibility.
final class FarTransport: Transport, BondedPath {
    let kind: TransportKind = .far
    let id: MultipathBonder.PathID = .mpquic
    var estimatedCostPerByte: Double { 1.0 }

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundPCMSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundFrameSubject.eraseToAnyPublisher() }
    var qualityScore: AnyPublisher<Double, Never> { qualitySubject.eraseToAnyPublisher() }

    private var mpquic: MPQUICTransport?
    private var cancellables = Set<AnyCancellable>()

    func configure(host: String, port: UInt16) {
        let t = MPQUICTransport(host: host, port: port)
        mpquic = t
        t.isConnected.subscribe(connectedSubject).store(in: &cancellables)
        t.inboundFrames.subscribe(inboundFrameSubject).store(in: &cancellables)
    }

    func start() async throws {
        mpquic?.connect()
    }

    func stop() async {
        mpquic?.disconnect()
        connectedSubject.send(false)
    }

    func send(_ buffer: AVAudioPCMBuffer) async {}

    func send(_ frame: AudioFrame) async {
        await mpquic?.send(frame)
    }
}
