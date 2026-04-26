import AVFoundation
import Foundation
import simd

/// Renders the partner's voice at their actual UWB-tracked position. Plan §7.3 / §10/11.
@MainActor
final class SpatialMixer {
    // MARK: - Nodes

    private let environment = AVAudioEnvironmentNode()

    /// Player node that feeds the remote-voice stream into the 3-D environment.
    private let remotePlayer = AVAudioPlayerNode()

    /// Tracks whether `prepare(engine:)` has been called.
    private var isPrepared = false

    // MARK: - Setup

    /// Attach the environment node and remote player to `engine` and wire them
    /// to `engine.mainMixerNode`.  Call once before starting the engine.
    func prepare(engine: AVAudioEngine) {
        guard !isPrepared else { return }
        isPrepared = true

        // Attach both nodes
        engine.attach(environment)
        engine.attach(remotePlayer)

        // Use fixed formats so prepare() is safe to call before the engine is started
        // (mainMixer.outputFormat(forBus:) returns a bad format on an unconfigured engine).
        let voiceFormat = AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 1
        )!
        // AVAudioEnvironmentNode outputs binaural stereo.
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 2
        )!

        // Remote player → environment (spatial input, mono)
        engine.connect(remotePlayer, to: environment, format: voiceFormat)

        // Environment → main mixer (binaural stereo output)
        engine.connect(environment, to: engine.mainMixerNode, format: stereoFormat)

        // Render the environment as binaural (works with or without AirPods).
        environment.renderingAlgorithm = .HRTFHQ

        // Place the listener at the origin, facing forward (+Z).
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        var orientation = AVAudio3DAngularOrientation()
        orientation.yaw = 0; orientation.pitch = 0; orientation.roll = 0
        environment.listenerAngularOrientation = orientation
    }

    // MARK: - Position update

    /// Move the remote-voice source to `direction * 2` metres from the listener.
    /// `direction` should be a unit vector obtained from the UWB ranging result.
    func updateSpatialPosition(direction: simd_float3) {
        // Rotate the listener orientation so the source sounds like it comes
        // from the right direction (original listener-orientation approach).
        let radToDeg: Float = 180 / .pi
        let clampedY = max(Float(-1), min(Float(1), direction.y))
        var orientation = AVAudio3DAngularOrientation()
        orientation.yaw   = atan2(direction.x, direction.z) * radToDeg
        orientation.pitch = asin(clampedY) * radToDeg
        orientation.roll  = 0
        environment.listenerAngularOrientation = orientation

        // Also move the remote player node to `direction * 2` metres.
        let scaled = direction * 2.0
        remotePlayer.position = AVAudio3DPoint(x: scaled.x, y: scaled.y, z: scaled.z)
    }

    // MARK: - Playback helpers

    /// Schedule decoded PCM audio on the remote player node.
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        remotePlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Start / stop the remote player.
    func startRemotePlayer() { remotePlayer.play() }
    func stopRemotePlayer()  { remotePlayer.stop() }

    /// Expose the underlying player so callers can query `isPlaying`.
    var remotePlayerNode: AVAudioPlayerNode { remotePlayer }
}
