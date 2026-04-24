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
        let radToDeg: Float = 180 / .pi
        let clampedY = max(Float(-1), min(Float(1), direction.y))
        var orientation = AVAudio3DAngularOrientation()
        orientation.yaw = atan2(direction.x, direction.z) * radToDeg
        orientation.pitch = asin(clampedY) * radToDeg
        orientation.roll = 0
        environment.listenerAngularOrientation = orientation
        // TODO §10/11: move the AVAudioPlayerNode for the remote source to direction * 2.
    }
}
