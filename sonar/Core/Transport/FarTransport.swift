import AVFoundation
import Combine
import Foundation
import LiveKit
import UIKit

/// Internet/cellular transport via LiveKit WebRTC. Plan §2.2 Pfad 3, §10/14.
/// Sends and receives Opus-encoded AudioFrames over a LiveKit data channel
/// (topic "sonar.audio") rather than as MediaTracks, keeping the Opus pipeline
/// entirely under our control and matching the NearTransport wire format.
@MainActor
final class FarTransport: Transport, BondedPath {
    let kind: TransportKind = .far
    let id: MultipathBonder.PathID = .mpquic
    var estimatedCostPerByte: Double { 1.0 }

    private let connectedSubject   = CurrentValueSubject<Bool, Never>(false)
    private let inboundPCMSubject  = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let inboundFrameSubject = PassthroughSubject<AudioFrame, Never>()
    private let qualitySubject     = CurrentValueSubject<Double, Never>(0)

    var isConnected: AnyPublisher<Bool, Never>          { connectedSubject.eraseToAnyPublisher() }
    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> { inboundPCMSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never>  { inboundFrameSubject.eraseToAnyPublisher() }
    var qualityScore: AnyPublisher<Double, Never>       { qualitySubject.eraseToAnyPublisher() }

    private let room = Room()
    private var lkServerURL: String = ""
    private var tokenProvider: RoomTokenProviding?
    private var roomName: String = "sonar-main"

    func configure(
        serverURL: String,
        tokenProvider: RoomTokenProviding,
        roomName: String = "sonar-main"
    ) {
        lkServerURL = serverURL
        self.tokenProvider = tokenProvider
        self.roomName = roomName
    }

    func start() async throws {
        guard let provider = tokenProvider, !lkServerURL.isEmpty else { return }
        let identity = UIDevice.current.name
        let token = try await provider.fetchToken(roomName: roomName, participantIdentity: identity)
        room.add(delegate: self)
        try await room.connect(url: lkServerURL, token: token)
    }

    func stop() async {
        await room.disconnect()
        connectedSubject.send(false)
    }

    func send(_ buffer: AVAudioPCMBuffer) async {}

    func send(_ frame: AudioFrame) async {
        guard connectedSubject.value else { return }
        // lossy = unreliable UDP; audio frames are obsolete if they arrive late.
        try? await room.localParticipant.publish(
            data: frame.wireData,
            options: DataPublishOptions(topic: "sonar.audio", reliable: false)
        )
    }
}

extension FarTransport: RoomDelegate {
    nonisolated func roomDidConnect(_ room: Room) {
        Task { @MainActor in self.connectedSubject.send(true) }
    }

    nonisolated func roomDidDisconnect(_ room: Room, error: Error?) {
        Task { @MainActor in self.connectedSubject.send(false) }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        guard topic == "sonar.audio", let frame = AudioFrame(wireData: data) else { return }
        Task { @MainActor in self.inboundFrameSubject.send(frame) }
    }
}
