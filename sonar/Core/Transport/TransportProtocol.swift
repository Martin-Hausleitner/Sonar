import AVFoundation
import Combine
import Foundation

enum TransportKind: Sendable { case near, far, simulator }

protocol Transport: AnyObject {
    var kind: TransportKind { get }
    var isConnected: AnyPublisher<Bool, Never> { get }
    var inboundPCMFrames: AnyPublisher<AVAudioPCMBuffer, Never> { get }
    var qualityScore: AnyPublisher<Double, Never> { get }   // 0..1, higher is better

    func start() async throws
    func stop() async
    func send(_ buffer: AVAudioPCMBuffer) async
}
