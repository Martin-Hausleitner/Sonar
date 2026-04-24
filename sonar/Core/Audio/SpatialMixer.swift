import AVFoundation
import Foundation
import simd

/// Renders the partner's voice at their actual UWB-tracked position. Plan §7.3 / §10/11.
@MainActor
final class SpatialMixer {
    private let environment = AVAudioEnvironmentNode()

    func attach(to engine: AVAudioEngine) {
        engine.attach(environment)
        // TODO §10/11: connect to mainMixer in HOA layout, plus a player node per remote.
    }

    func updateSpatialPosition(direction: simd_float3) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: atan2(direction.x, direction.z) * 180 / .pi,
            pitch: asin(max(-1, min(1, direction.y))) * 180 / .pi,
            roll: 0
        )
        // TODO §10/11: move the AVAudioPlayerNode for the remote source to direction * 2.
    }
}
