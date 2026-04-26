import CoreHaptics
import UIKit

@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var engine: CHHapticEngine?
    private let supportsHaptics: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
        } catch {
            // Device supports haptics but engine failed to start; fall back to UIKit.
        }
    }

    // MARK: - Public API

    /// Short "bump" — connection established.
    func playConnectionSuccess() {
        guard supportsHaptics, let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        let events: [CHHapticEvent] = [
            makeEvent(intensity: 0.9, sharpness: 0.6, relativeTime: 0)
        ]
        play(events: events, engine: engine)
    }

    /// Two quick taps — disconnected.
    func playDisconnect() {
        guard supportsHaptics, let engine else {
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                gen.impactOccurred()
            }
            return
        }
        let events: [CHHapticEvent] = [
            makeEvent(intensity: 0.7, sharpness: 0.8, relativeTime: 0),
            makeEvent(intensity: 0.7, sharpness: 0.8, relativeTime: 0.15)
        ]
        play(events: events, engine: engine)
    }

    /// Longer rumble — warning / degraded signal.
    func playWarning() {
        guard supportsHaptics, let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        var events: [CHHapticEvent] = []
        // Three increasing-intensity pulses
        let timings: [(Double, Float)] = [(0.0, 0.4), (0.15, 0.65), (0.30, 0.85)]
        for (time, intensity) in timings {
            events.append(makeEvent(intensity: intensity, sharpness: 0.3,
                                    relativeTime: time, duration: 0.1))
        }
        play(events: events, engine: engine)
    }

    // MARK: - Convenience (original API kept for existing call sites)

    func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Private helpers

    private func makeEvent(
        intensity: Float,
        sharpness: Float,
        relativeTime: TimeInterval,
        duration: TimeInterval = 0.08
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: relativeTime,
            duration: duration
        )
    }

    private func play(events: [CHHapticEvent], engine: CHHapticEngine) {
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently fall back – haptic failure is non-critical.
        }
    }
}
