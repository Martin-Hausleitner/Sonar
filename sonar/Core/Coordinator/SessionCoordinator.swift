import AVFoundation
import Combine
import Foundation
import NearbyInteraction
import simd

/// Central state machine. Wires the full audio pipeline:
///   mic → VoiceProcessing → OpusCoder → MultipathBonder → NearTransport / FarTransport
///   NearTransport / FarTransport → MultipathBonder → JitterBuffer → OpusCoder → SpatialMixer
///
/// Distance pipeline (§10/16):
///   NIRangingEngine (UWB) + RSSIFallback (BLE) → DistancePublisher
///   → AppState.phase + SpatialMixer.updateSpatialPosition()
///
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

    // Distance pipeline (§10/16)
    private let rangingEngine     = NIRangingEngine()
    private let rssiFallback      = RSSIFallback()
    private let distancePublisher = DistancePublisher()

    // Profile-driven subsystems
    private let airPods           = AirPodsController()
    private let musicDucker       = MusicDucker()
    private let vad               = VAD()

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
        rangingEngine.stop()
        rssiFallback.stop()
        musicDucker.disable()
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

        // MARK: Distance pipeline (§10/16)
        distancePublisher.bind(uwb: rangingEngine, rssi: rssiFallback)

        // When NearTransport gets a peer's NIDiscoveryToken, start UWB ranging.
        near.onReceivedNIToken = { [weak self] token in
            guard let self else { return }
            self.rangingEngine.start(with: token)
            // Publish our local token back so the peer can start ranging too.
            self.near.localNIToken = self.rangingEngine.localToken
        }

        // MARK: Distance → AppState.phase + SpatialMixer
        distancePublisher.$distance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] distance in
                self?.handleDistanceUpdate(distance)
            }
            .store(in: &cancellables)

        // Update spatial direction when UWB provides it.
        rangingEngine.direction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] direction in
                guard let direction else { return }
                self?.spatialMixer.updateSpatialPosition(direction: direction)
            }
            .store(in: &cancellables)

        // MARK: Transport setup
        try? await near.start()
        bonder.addPath(near)
        bonder.addPath(far)

        // MARK: Profile application — apply initial profile and react to changes.
        applyProfile(SessionProfile.builtIn.first { $0.id == (appState?.profileID ?? "zimmer") })

        if let appState {
            appState.$profileID
                .dropFirst()           // skip initial value, already applied above
                .receive(on: DispatchQueue.main)
                .sink { [weak self] id in
                    let profile = SessionProfile.builtIn.first { $0.id == id }
                    self?.applyProfile(profile)
                }
                .store(in: &cancellables)
        }

        // MARK: SEND CHAIN: mic → pre-processing → Opus encode → bonder → transports.
        audioEngine.captured
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] (_, buffer) in
                guard let self else { return }
                self.preCaptureBuffer.push(buffer)
                self.whisperDetector.process(buffer)
                self.smartMute.process(buffer)
                // VAD drives music ducking when voice is detected.
                let speaking = self.vad.feed(buffer)
                Task { @MainActor [weak self] in
                    self?.musicDucker.duckOnVoice(active: speaking)
                }
                self.transcription.append(buffer)
                self.recorder.append(buffer)
                if let data = try? self.encoder.encode(buffer) {
                    Task { await self.bonder.send(opusData: data) }
                }
            }
            .store(in: &cancellables)

        // MARK: RECEIVE CHAIN: transports → bonder (dedup) → jitter buffer.
        bonder.inboundFrames
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] frame in
                self?.jitterBuffer.enqueue(frame)
            }
            .store(in: &cancellables)

        // Drain the jitter buffer at the audio frame rate and schedule decoded PCM.
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: Double(LatencyBudget.audioFrameMs) / 1_000.0,
            repeats: true
        ) { [weak self] _ in
            self?.drainJitterBuffer()
        }

        // MARK: Battery tier → bonder mode + appState.
        battery.$tier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tier in
                guard let self else { return }
                self.applyBatteryTier(tier)
                self.appState?.batteryTier = tier
            }
            .store(in: &cancellables)

        // MARK: Active paths → appState.
        bonder.$activePaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                self?.appState?.activePathCount = paths.count
            }
            .store(in: &cancellables)

        // MARK: Signal score → appState.
        signalCalc.$score
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.appState?.signalScore = s }
            .store(in: &cancellables)

        signalCalc.$grade
            .receive(on: DispatchQueue.main)
            .sink { [weak self] g in self?.appState?.signalGrade = g }
            .store(in: &cancellables)

        // MARK: Privacy mode → remove cellular path immediately.
        NotificationCenter.default.publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in self?.bonder.removePath(.mpquic) }
            .store(in: &cancellables)

        try? recorder.startSession()
        appState?.isRecording = true
        Task { try? await transcription.start() }

        phase = .far
    }

    // MARK: - Distance → Phase

    private func handleDistanceUpdate(_ distance: Double?) {
        guard let distance else {
            // No reading — stay in current phase or fall back to far.
            if case .near = phase { phase = .far }
            return
        }

        let threshold = activeProfile?.nearFarThreshold ?? 8.0

        if distance <= threshold {
            phase = .near(distance: distance)
            appState?.phase = .near(distance: distance)
        } else {
            if case .near = phase { phase = .far }
            if case .near = appState?.phase ?? .idle { appState?.phase = .far }
        }
    }

    private var activeProfile: SessionProfile? {
        guard let id = appState?.profileID else { return nil }
        return SessionProfile.builtIn.first { $0.id == id }
    }

    // MARK: - Jitter buffer drain (runs on main thread via Timer)

    private func drainJitterBuffer() {
        if let frame = jitterBuffer.dequeue() {
            decodeAndSchedule(frame)
        } else if jitterBuffer.needsConcealment {
            jitterBuffer.advanceOnConceal()
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

    // MARK: - Profile application

    private func applyProfile(_ profile: SessionProfile?) {
        guard let profile else { return }

        // ANC / transparency mode for AirPods.
        Task { await airPods.apply(profile: profile) }

        // Music ducking: enable with the profile's mix level, or disable.
        if profile.musicMix > 0 {
            Task {
                try? await musicDucker.enable(targetGain: profile.musicMix)
                musicDucker.duck()
            }
        } else {
            musicDucker.disable()
        }

        // Encoder FEC: on for outdoor/noisy profiles, off for quiet ones.
        let fecProfiles: Set<String> = ["roller", "festival", "club"]
        encoder.fecEnabled = fecProfiles.contains(profile.id)
    }

    // MARK: - Battery adaptation

    private func applyBatteryTier(_ tier: BatteryManager.Tier) {
        switch tier {
        case .normal, .eco:     bonder.mode = .redundant
        case .saver, .critical: bonder.mode = .primaryStandby
        }
        if !tier.transcriptionEnabled { transcription.stop() }
        if !tier.recordingEnabled {
            _ = recorder.stopSession()
            appState?.isRecording = false
        }
    }
}
