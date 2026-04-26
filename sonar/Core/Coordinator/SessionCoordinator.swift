import AVFoundation
import Combine
import Foundation

/// Central state machine. Wires the full audio pipeline:
///   mic → VoiceProcessing → OpusCoder → MultipathBonder → NearTransport / FarTransport
///   NearTransport / FarTransport → MultipathBonder → JitterBuffer → OpusCoder → SpatialMixer
/// §14 Phase 1–4.
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
    private let spatialMixer     = SpatialMixer()
    private let near             = NearTransport()
    private let far              = FarTransport()
    private let jitterBuffer     = JitterBuffer()
    private let encoder          = OpusCoder()
    private let decoder          = OpusCoder()

    // Smart audio processing
    private let preCaptureBuffer = PreCaptureBuffer()
    private let whisperDetector  = WhisperDetector()
    private let smartMute        = SmartMuteDetector()
    private let ambientSharing   = AmbientSharing()

    private var cancellables = Set<AnyCancellable>()
    private var audioTask: Task<Void, Never>?
    private var playbackTimer: Timer?

    private lazy var pcmPlaybackFormat = AVAudioFormat(
        standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 1
    )!

    weak var appState: AppState?

    // MARK: - Lifecycle

    func start() {
        phase = .connecting
        audioTask = Task { [weak self] in
            await self?.startAudioPipeline()
        }
    }

    func stop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioTask?.cancel()
        audioTask = nil
        audioEngine.stop()
        transcription.stop()
        _ = recorder.stopSession()
        spatialMixer.stopRemotePlayer()
        Task {
            await near.stop()
            await far.stop()
        }
        jitterBuffer.reset()
        cancellables.removeAll()
        phase = .idle
        appState?.isRecording = false
    }

    // MARK: - Internal async setup

    private func startAudioPipeline() async {
        // Attach SpatialMixer nodes before the engine starts.
        audioEngine.connect(spatialMixer: spatialMixer)

        do {
            try audioEngine.prepare()
        } catch {
            phase = .idle
            return
        }

        spatialMixer.startRemotePlayer()

        // Register both transports with the bonder.
        // NearTransport auto-discovers via Multipeer; start it unconditionally.
        try? await near.start()
        bonder.addPath(near)
        // FarTransport connects only when configure(serverURL:tokenProvider:) has been called;
        // adding it now lets the bonder track it once the app wires in credentials.
        bonder.addPath(far)

        // SEND CHAIN: mic → pre-processing → Opus encode → bonder → transports.
        audioEngine.captured
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] (_, buffer) in
                guard let self else { return }
                self.preCaptureBuffer.push(buffer)
                self.whisperDetector.process(buffer)
                self.smartMute.process(buffer)
                self.transcription.append(buffer)
                self.recorder.append(buffer)
                if let data = try? self.encoder.encode(buffer) {
                    Task { await self.bonder.send(opusData: data) }
                }
            }
            .store(in: &cancellables)

        // RECEIVE CHAIN: transports → bonder (dedup) → jitter buffer.
        bonder.inboundFrames
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] frame in
                self?.jitterBuffer.enqueue(frame)
            }
            .store(in: &cancellables)

        // Drain the jitter buffer at the audio frame rate and schedule decoded PCM for playback.
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: Double(LatencyBudget.audioFrameMs) / 1_000.0,
            repeats: true
        ) { [weak self] _ in
            self?.drainJitterBuffer()
        }

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

        // Privacy mode → remove cellular path immediately.
        NotificationCenter.default.publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in self?.bonder.removePath(.mpquic) }
            .store(in: &cancellables)

        try? recorder.startSession()
        appState?.isRecording = true
        Task { try? await transcription.start() }

        phase = .far
    }

    // MARK: - Jitter buffer drain (runs on main thread via Timer)

    private func drainJitterBuffer() {
        if let frame = jitterBuffer.dequeue() {
            decodeAndSchedule(frame)
        } else if jitterBuffer.needsConcealment {
            jitterBuffer.advanceOnConceal()
            // PLC: skip — AVAudioPlayerNode produces silence for gaps automatically.
        }
    }

    private func decodeAndSchedule(_ frame: AudioFrame) {
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: pcmPlaybackFormat,
            frameCapacity: AVAudioFrameCount(decoder.samplesPerFrame)
        ) else { return }
        guard (try? decoder.decode(frame.payload, into: buf)) != nil else { return }
        spatialMixer.scheduleBuffer(buf)
    }

    // MARK: - Battery adaptation

    private func applyBatteryTier(_ tier: BatteryManager.Tier) {
        switch tier {
        case .normal, .eco:    bonder.mode = .redundant
        case .saver, .critical: bonder.mode = .primaryStandby
        }
        if !tier.transcriptionEnabled { transcription.stop() }
        if !tier.recordingEnabled {
            _ = recorder.stopSession()
            appState?.isRecording = false
        }
    }
}
