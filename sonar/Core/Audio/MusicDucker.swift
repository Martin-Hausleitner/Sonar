import AVFoundation
import Combine
import Foundation
import MediaPlayer

#if canImport(MusicKit)
import MusicKit
#endif

/// Apple Music background mix-in for Club mode. Plan §7.2 / §10/13.
///
/// Uses `AVAudioSession` category options to duck other apps (including Music):
///  - When `duck()` is called → set `.duckOthers` option; the system lowers
///    Music automatically.
///  - When `unduck()` is called → remove `.duckOthers`; Music resumes full
///    volume on its own.
///
/// A software ramp timer drives the `@Published duckLevel` property so UI and
/// audio consumers can observe the current state without needing an
/// `AVAudioMixerNode` (which requires a running engine context).
@MainActor
final class MusicDucker {

    // MARK: - State

    /// Observable duck level in the range [0, 1].  1.0 = full (undducked).
    @Published private(set) var duckLevel: Float = 1.0

    /// Base music gain target (0…1). Set by `enable(targetGain:)`.
    private var targetGain: Float = 0.16
    /// Whether a further -6 dB voice-active duck is in effect.
    private var isVoiceDucked: Bool = false
    /// Whether the ducker has been enabled.
    private var isEnabled: Bool = false

    // Ramp timer drives the published duckLevel for UI observers.
    private var rampTimer: DispatchSourceTimer?
    private let stepInterval: TimeInterval = 0.020   // 20 ms steps

    // MARK: - Enable / Disable

    /// Request MusicKit authorisation and activate the audio session so
    /// subsequent `duck()` / `duckOnVoice(active:)` calls work.
    func enable(targetGain: Double = 0.16) async throws {
        self.targetGain = Float(targetGain)

#if canImport(MusicKit)
        _ = await MusicAuthorization.request()
#endif
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .voiceChat,
                                options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
        isEnabled = true

        // Reflect the initial target in the published level.
        rampTo(targetGain, duration: 0.3)
    }

    /// Release the audio session and restore normal music volume.
    func disable() {
        guard isEnabled else { return }
        isVoiceDucked = false
        isEnabled = false
        // Remove duck; the system will restore Music volume automatically.
        unduck()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Duck / Unduck

    /// Activate `.duckOthers` so the system lowers Music (and other apps).
    func duck() {
        rampTo(targetGain, duration: 0.3)
        applySessionDucking(enabled: true)
    }

    /// Deactivate `.duckOthers`; Music resumes full volume.
    func unduck() {
        rampTo(1.0, duration: 0.8)
        applySessionDucking(enabled: false)
    }

    // MARK: - Per-utterance ducking

    /// Drop another -6 dB while voice is active; restore when idle.
    func duckOnVoice(active: Bool) {
        isVoiceDucked = active
        if active {
            rampTo(targetGain * 0.5, duration: 0.3)   // 0.5 ≈ -6 dB
            applySessionDucking(enabled: true)
        } else {
            rampTo(targetGain, duration: 0.8)
            applySessionDucking(enabled: isEnabled)
        }
    }

    // MARK: - Private helpers

    /// Switch the AVAudioSession between `.duckOthers` and `.mixWithOthers`.
    private func applySessionDucking(enabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = enabled
            ? [.duckOthers, .allowBluetoothHFP]
            : [.mixWithOthers, .allowBluetoothHFP]
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setActive(true, options: [.notifyOthersOnDeactivation])
    }

    /// Linearly ramp the published `duckLevel` from its current value to
    /// `target` over `duration` seconds.  Pure UI / observer signal — does not
    /// apply hardware volume (that is handled by the session category).
    private func rampTo(_ target: Double, duration: TimeInterval) {
        rampTo(Float(target), duration: duration)
    }

    private func rampTo(_ target: Float, duration: TimeInterval) {
        rampTimer?.cancel()
        rampTimer = nil

        let start = duckLevel
        guard duration > 0.005 else {
            duckLevel = target
            return
        }

        let totalSteps = max(1, Int((duration / stepInterval).rounded()))
        let gainStep = (target - start) / Float(totalSteps)
        var stepsDone = 0

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + stepInterval,
                       repeating: stepInterval,
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            stepsDone += 1
            if stepsDone >= totalSteps {
                self.duckLevel = target
                self.rampTimer?.cancel()
                self.rampTimer = nil
            } else {
                self.duckLevel = start + gainStep * Float(stepsDone)
            }
        }
        rampTimer = timer
        timer.resume()
    }
}
