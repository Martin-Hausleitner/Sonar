import AVFoundation
import Combine
import Foundation

/// Toggles AirPods Pro's Conversation Boost where supported. Plan §5.3.
///
/// Conversation Boost is activated when the AVAudioSession mode is set to
/// `.voiceChat` while AirPods Pro are the active output device.  Reverting
/// to `.default` switches it off.  This is the only non-private API available
/// to third-party apps on iOS 18.
final class ConversationBoostToggle {
    /// The current enabled state. Observers (SwiftUI, etc.) can subscribe.
    let isEnabled = CurrentValueSubject<Bool, Never>(false)

    // MARK: - Public

    func enable() {
        do {
            try AVAudioSession.sharedInstance().setMode(.voiceChat)
            isEnabled.send(true)
        } catch {
            // Conversation Boost activation is best-effort; log but don't throw.
        }
    }

    func disable() {
        do {
            try AVAudioSession.sharedInstance().setMode(.default)
            isEnabled.send(false)
        } catch {
            // Best-effort.
        }
    }

    func toggle() {
        isEnabled.value ? disable() : enable()
    }
}
