import SwiftUI
#if DEBUG
    import AVFoundation
#endif

@main
struct SonarApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissions = PermissionsManager()
    @State private var didSeedUITestRecording = false
    @State private var queuedStartProfileID: String?
    @AppStorage("sonar.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    MainTabView()
                } else {
                    OnboardingView(permissions: permissions) {
                        onboarded = true
                        flushQueuedStartSession()
                    }
                }
            }
            .environmentObject(appState)
            .environmentObject(appState.peerStore)
            .environmentObject(appState.peerDirectory)
            .environmentObject(permissions)
            .preferredColorScheme(.dark)
            .task {
                // Pre-fix the IP only became visible at first session start —
                // scanning the QR before that left `tsIP` empty in the token
                // and Tailscale stayed permanently dark. Start the detector
                // at app launch so the QR-show screen always carries an IP
                // when one is reachable.
                TailscaleDetector.shared.startMonitoring()
                TailscaleDetector.shared.refresh()
            }
            .onAppear {
                #if DEBUG
                    guard !didSeedUITestRecording else { return }
                    didSeedUITestRecording = true
                    SonarApp.seedUITestRecordingIfRequested()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .sonarStartSessionRequested)) { note in
                let decision = StartSessionIntentRouter.decision(
                    onboarded: onboarded,
                    profileID: note.object as? String ?? ""
                )
                switch decision.action {
                case .dispatchToMountedSession:
                    dispatchStartSession(profileID: decision.profileID)
                case .queueUntilOnboarded:
                    queuedStartProfileID = decision.profileID
                }
            }
        }
    }

    private func flushQueuedStartSession() {
        guard let profileID = queuedStartProfileID else { return }
        queuedStartProfileID = nil
        dispatchStartSession(profileID: profileID)
    }

    private func dispatchStartSession(profileID: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .sonarStartSession,
                object: profileID
            )
        }
    }

    #if DEBUG
        @MainActor
        private static func seedUITestRecordingIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("-sonar.seedRecording") else { return }
            guard LocalRecorder.allSessions().isEmpty else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000) else { return }

            buffer.frameLength = 96000
            if let samples = buffer.floatChannelData?[0] {
                for index in 0 ..< Int(buffer.frameLength) {
                    let t = Float(index) / 48000
                    samples[index] = sinf(2 * .pi * 440 * t) * 0.08
                }
            }

            let recorder = LocalRecorder()
            do {
                try recorder.startSession(sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
                recorder.append(buffer)
                _ = recorder.stopSession()
            } catch {
                Log.app.error("UI test recording seed failed: \(error.localizedDescription)")
            }
        }
    #endif
}
