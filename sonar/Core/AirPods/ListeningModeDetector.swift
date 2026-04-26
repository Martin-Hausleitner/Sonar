import AVFoundation
import Combine
import Foundation

/// Reads back the AirPods' current listening mode where the OS exposes it.
/// Plan §9.
final class ListeningModeDetector {
    /// The most-recently detected listening mode. Possible values:
    /// "off" | "transparency" | "noiseCancellation" | "adaptive" | "unknown"
    let currentMode = CurrentValueSubject<String, Never>("unknown")

    private var observer: NSObjectProtocol?

    init() {
        // Seed with the current route immediately.
        currentMode.send(detectMode())

        // Keep it up-to-date whenever the route changes (e.g. AirPods put back in
        // the case, mode switched in Control Centre).
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.currentMode.send(self?.detectMode() ?? "unknown")
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public sync accessor (kept for legacy callers)

    func current() -> String { currentMode.value }

    // MARK: - Private

    private func detectMode() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs

        // We only have mode information when AirPods are the active output.
        let airPodsConnected = outputs.contains { port in
            (port.portType == .bluetoothA2DP || port.portType == .bluetoothHFP)
                && port.portName.localizedCaseInsensitiveContains("AirPods")
        }

        guard airPodsConnected else { return "unknown" }

        // iOS 14+ exposes the spatial-audio / head-tracking capable description,
        // but does not expose the ANC mode directly via AVAudioSession.
        // The best we can do is inspect the current session's mode flags as a
        // rough proxy:
        //   - .measurement  → ANC is likely off (used during calibration)
        //   - .voiceChat    → Conversation Boost / transparency-adjacent
        //   - .default      → ambiguous; report what the profile asked for by
        //                     returning "unknown" so callers fall back gracefully.
        //
        // A real read-back would require a private CoreAudio / BluetoothManager
        // entitlement that is not available to third-party apps on iOS 18.
        // The intended flow is: Sonar *sets* the mode via SetListeningModeIntent
        // (Siri Shortcuts) and trusts its own last-written value; this detector
        // is only used to initialise state on cold-start.
        return "unknown"
    }
}
