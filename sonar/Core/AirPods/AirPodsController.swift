import AppIntents
import AVFoundation
import Foundation

/// Applies best-effort AirPods listening preferences through AVAudioSession.
/// Plan §9 / §10/10.
///
/// ## How ANC switching actually works on iOS 18
/// Apple does not expose a direct API to change the AirPods noise-control mode
/// from a third-party app, and it does not expose readback for the active mode.
/// Switching `AVAudioSession.mode` can only nudge the system toward a voice
/// chat profile on supported hardware. It cannot guarantee ANC, transparency,
/// adaptive mode, or Conversation Boost.
@MainActor
final class AirPodsController {
    // MARK: - Public interface

    /// Apply the listening mode specified in a profile.
    func apply(profile: SessionProfile) async -> AudioSessionPolicy.ListeningModeNudge {
        listeningModeNudge(for: profile.listeningMode)
    }

    /// Set the AirPods listening mode by name.
    ///
    /// - Parameter mode: One of "off", "transparency", "noiseCancellation", "adaptive".
    func setListeningMode(_ mode: String) async {
        // Best-effort AVAudioSession proxy. There is no AVAudioSession mode
        // that maps to ANC, transparency, or adaptive mode directly.
        let nudge = listeningModeNudge(for: mode)
        let session = AVAudioSession.sharedInstance()
        do {
            if let sessionMode = nudge.sessionMode {
                try session.setMode(sessionMode)
            }
        } catch {
            // Non-fatal because the request is advisory.
        }
    }

    func listeningModeNudge(for mode: String) -> AudioSessionPolicy.ListeningModeNudge {
        switch mode {
        case "transparency", "adaptive":
            // Voice chat is the closest supported request for speech use.
            .voiceChat
        case "off":
            .default
        default:
            // "noiseCancellation" and unknown values: leave the session mode
            // unchanged because iOS offers no direct third-party API.
            .none
        }
    }
}
