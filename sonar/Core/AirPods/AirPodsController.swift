import AppIntents
import AVFoundation
import Foundation

/// Coordinates AirPods listening modes via the system "Set Noise Control Mode"
/// App Intent. Plan §9 / §10/10.
///
/// ## How ANC switching actually works on iOS 18
/// Apple does not expose a direct API to change the AirPods noise-control mode
/// from a third-party app. The canonical approach (used by Siri Shortcuts) is:
///
///   1. Donate a `SetListeningModeIntent` to the system.
///   2. The user runs the resulting shortcut once (one-time consent prompt).
///   3. Subsequent calls go through `AppIntents` / Shortcuts engine without UI.
///
/// As a *secondary* mechanism, switching `AVAudioSession.mode` to `.voiceChat`
/// nudges AirPods Pro into a transparency-like state on supported hardware, but
/// this is not guaranteed and cannot select specific modes.  We do it here as a
/// best-effort fallback only.
@MainActor
final class AirPodsController {

    // MARK: - Public interface

    /// Apply the listening mode specified in a profile.
    func apply(profile: SessionProfile) async {
        await setListeningMode(profile.listeningMode)
    }

    /// Set the AirPods listening mode by name.
    ///
    /// - Parameter mode: One of "off", "transparency", "noiseCancellation", "adaptive".
    func setListeningMode(_ mode: String) async {
        // 1. Post a notification so that any running AppIntents bridge
        //    (SetListeningModeIntent) or UI layer can react.
        NotificationCenter.default.post(name: .sonarSetListeningMode, object: mode)

        // 2. Best-effort AVAudioSession proxy.
        //    Switching to .voiceChat activates Conversation Boost / transparency
        //    on AirPods Pro; switching to .default is the closest to "off".
        //    There is no AVAudioSession mode that maps to noiseCancellation or
        //    adaptive — the real switch requires the Siri Shortcuts path above.
        let session = AVAudioSession.sharedInstance()
        do {
            switch mode {
            case "transparency", "adaptive":
                try session.setMode(.voiceChat)
            case "off":
                try session.setMode(.default)
            default:
                // "noiseCancellation" and unknown values: leave the session mode
                // unchanged; the Shortcuts intent is the authoritative channel.
                break
            }
        } catch {
            // Non-fatal — AirPods mode change via AVAudioSession is best-effort.
        }
    }
}
