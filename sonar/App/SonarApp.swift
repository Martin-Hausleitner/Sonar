import SwiftUI
#if DEBUG
import AVFoundation
#endif

@main
struct SonarApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permissions = PermissionsManager()
    @State private var didSeedUITestRecording = false
    @AppStorage("sonar.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded {
                    MainTabView()
                } else {
                    OnboardingView(permissions: permissions) {
                        onboarded = true
                    }
                }
            }
            .environmentObject(appState)
            .environmentObject(permissions)
            .preferredColorScheme(.dark)
            #if DEBUG
            .onAppear {
                guard !didSeedUITestRecording else { return }
                didSeedUITestRecording = true
                SonarApp.seedUITestRecordingIfRequested()
            }
            #endif
        }
    }

    #if DEBUG
    @MainActor
    private static func seedUITestRecordingIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-sonar.seedRecording") else { return }
        guard LocalRecorder.allSessions().isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000) else { return }

        buffer.frameLength = 96_000
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                let t = Float(index) / 48_000
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
