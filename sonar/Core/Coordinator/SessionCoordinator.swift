import AVFoundation
import Combine
import Foundation

/// Central state machine. Wires AudioEngine → MultipathBonder → BatteryManager →
/// SignalScoreCalculator → LocalRecorder → LiveTranscriptionEngine. §14 Phase 1-4.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var phase: AppState.Phase = .idle

    // MARK: - Sub-systems
    private let audioEngine      = AudioEngine()
    private let bonder           = MultipathBonder()
    private let battery          = BatteryManager.shared
    private let signalCalc       = SignalScoreCalculator()
    private let recorder         = LocalRecorder()
    private let transcription    = LiveTranscriptionEngine()
    private let privacy          = PrivacyMode.shared

    // Smart improvements
    private let preCaptureBuffer = PreCaptureBuffer()
    private let whisperDetector  = WhisperDetector()
    private let smartMute        = SmartMuteDetector()
    private let ambientSharing   = AmbientSharing()

    private var cancellables = Set<AnyCancellable>()
    private var audioTask: Task<Void, Never>?

    weak var appState: AppState?

    // MARK: - Lifecycle

    /// Synchronous entry point — sets phase = .connecting immediately so tests
    /// that call start() without await see the state change. Audio setup runs async.
    func start() {
        phase = .connecting
        audioTask = Task { [weak self] in
            await self?.startAudioPipeline()
        }
    }

    func stop() {
        audioTask?.cancel()
        audioTask = nil
        audioEngine.stop()
        transcription.stop()
        _ = recorder.stopSession()
        cancellables.removeAll()
        phase = .idle
        appState?.isRecording = false
    }

    // MARK: - Internal async setup

    private func startAudioPipeline() async {
        do {
            try audioEngine.prepare()
        } catch {
            phase = .idle
            return
        }

        // Wire AudioEngine output → full pipeline.
        audioEngine.captured
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] (_, buffer) in
                guard let self else { return }
                self.preCaptureBuffer.push(buffer)
                self.whisperDetector.process(buffer)
                self.smartMute.process(buffer)
                self.transcription.append(buffer)
                self.recorder.append(buffer)
                // Encode with OpusCoder then send on all paths.
                let coder = OpusCoder()
                if let data = try? coder.encode(buffer) {
                    Task { await self.bonder.send(opusData: data) }
                }
            }
            .store(in: &cancellables)

        // Battery tier → bonder mode + appState.
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
            .sink { [weak self] s in self?.appState?.signalScore = s }
            .store(in: &cancellables)

        signalCalc.$grade
            .receive(on: DispatchQueue.main)
            .sink { [weak self] g in self?.appState?.signalGrade = g }
            .store(in: &cancellables)

        // Privacy mode → remove cellular path.
        NotificationCenter.default.publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in self?.bonder.removePath(.mpquic) }
            .store(in: &cancellables)

        // Start recording.
        try? recorder.startSession()
        appState?.isRecording = true

        // Start transcription.
        Task { try? await transcription.start() }

        phase = .far
    }

    // MARK: - Battery adaptation

    private func applyBatteryTier(_ tier: BatteryManager.Tier) {
        switch tier {
        case .normal, .eco:
            bonder.mode = .redundant
        case .saver, .critical:
            bonder.mode = .primaryStandby
        }
        if !tier.transcriptionEnabled { transcription.stop() }
        if !tier.recordingEnabled {
            _ = recorder.stopSession()
            appState?.isRecording = false
        }
    }
}
