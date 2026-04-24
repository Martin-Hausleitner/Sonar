import AVFoundation
import Combine
import Foundation

// LiveKit SDK will be imported in §10/7 once we actually consume it.

/// LiveKit transport. Plan §10/7.
final class FarTransport: Transport {
    let kind: TransportKind = .far

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let qualitySubject = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundSubject.eraseToAnyPublisher() }
    var qualityScore: AnyPublisher<Double, Never> { qualitySubject.eraseToAnyPublisher() }

    func start() async throws {
        // TODO §10/7: request room token from sonar-server, connect Room,
        // publish a custom AudioTrack fed from AudioEngine, subscribe peers.
    }

    func stop() async {
        connectedSubject.send(false)
    }

    func send(_ buffer: AVAudioPCMBuffer) async {
        // TODO §10/7: push PCM into LiveKit's custom audio source.
    }
}
