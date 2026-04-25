import AVFoundation
import Combine
import Foundation

/// Central state machine. Wires AudioEngine → MultipathBonder → BatteryManager →
/// SignalScoreCalculator → LocalRecorder → LiveTranscriptionEngine. §14 Phase 1-4.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var phase: AppState.Phase = .idle

    // MARK: - Sub-systems
    private let audioEngine     = AudioEngine()
    private let bonder          = MultipathBonder()
    private let battery         = BatteryManager.shared
    private let signalCalc      = SignalScoreCalculator()
    private let recorder        = LocalRecorder()
    private let transcription   = LiveTranscriptionEngine()
    private let privacy         = PrivacyMode.shared

    // Smart improvements
    private let preCaptureBuffer = PreCaptureBuffer()
    private let whisperDetector  = WhisperDetector()
    private let smartMute        = SmartMuteDetector()
    private let ambientSharing   = AmbientSharing()

    private var cancellables = Set<AnyCancellable>()

    weak var appState: AppState?

    // MARK: - Lifecycle

    func start() async {
        phase = .connecting
        do {
            try audioEngine.prepare()
        } catch {
            phase = .idle
            return
        }

        // Wire AudioEngine output to pipeline.
        audioEngine.captured
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] (_, buffer) in
                guard let self else { return }
                self.preCaptureBuffer.push(buffer)
                self.whisperDetector.process(buffer)
                self.smartMute.process(buffer)
                self.transcription.append(buffer)
                self.recorder.append(buffer)
                // TODO: encode with OpusCoder, then bonder.send()
            }
            .store(in: &cancellables)

        // Battery tier → bonder mode.
        battery.$tier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tier in
                guard let self else { return }
                self.applyBatteryTier(tier)
                self.appState?.batteryTier = tier
            }
            .store(in: &cancellables)

        // Active paths → appState.
        bonder.$activePaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                self?.appState?.activePathCount = paths.count
            }
            .store(in: &cancellables)

        // Signal score → appState.
        signalCalc.$score
            .receive(on: DispatchQueue.main)
            .assign(to: \.signalScore, on: appState ?? AppState())
            .store(in: &cancellables)

        // Privacy mode → bonder.
        NotificationCenter.default.publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in self?.bonder.removePath(.mpquic) }
            .store(in: &cancellables)

        // Start recording.
        try? recorder.startSession()
        appState?.isRecording = true

        // Start transcription.
        Task { try? await transcription.start() }

        phase = .far    // will be updated by distance/bonder events
    }

    func stop() {
        audioEngine.stop()
        transcription.stop()
        _ = recorder.stopSession()
        cancellables.removeAll()
        phase = .idle
        appState?.isRecording = false
    }

    // MARK: - Battery adaptation

    private func applyBatteryTier(_ tier: BatteryManager.Tier) {
        switch tier {
        case .normal:
            bonder.mode = .redundant
        case .eco:
            bonder.mode = .redundant   // still redundant but on 2 paths max
        case .saver, .critical:
            bonder.mode = .primaryStandby
        }
        if !tier.transcriptionEnabled { transcription.stop() }
        if !tier.recordingEnabled { _ = recorder.stopSession(); appState?.isRecording = false }
    }
}
