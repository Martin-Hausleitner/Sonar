import AVFoundation
import Combine
import Foundation
import NearbyInteraction
import simd

@MainActor
protocol FarTransporting: BondedPath {
    func configure(_ configuration: FarTransport.Configuration)
    func start() async throws
    func stop() async
}

extension FarTransport: FarTransporting {}

/// Central state machine. Wires the full audio pipeline:
///   mic → VoiceProcessing → OpusCoder → MultipathBonder → NearTransport / FarTransport
///   NearTransport / FarTransport → MultipathBonder → JitterBuffer → OpusCoder → SpatialMixer
///
/// Distance pipeline (§10/16):
///   NIRangingEngine (UWB) + RSSIFallback (BLE) → DistancePublisher
///   → AppState.phase + AppState.peerDirection + SpatialMixer.updateSpatialPosition()
///
/// §14 Phase 1–4.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var phase: AppState.Phase = .idle

    // MARK: - Sub-systems

    private let audioEngine = AudioEngine()
    private let bonder = MultipathBonder()
    private let battery = BatteryManager.shared
    private let signalCalc = SignalScoreCalculator()
    private let recorder = LocalRecorder()
    private let transcription: LiveTranscriptionEngine
    private let privacy = PrivacyMode.shared
    private let spatialMixer = SpatialMixer()
    private let near = NearTransport()
    private let bluetooth = BluetoothMeshTransport()
    private let tailscalePath = TailscaleTransport()
    private let far: any FarTransporting
    private var simulatorRelay: SimulatorRelayTransport?
    private let jitterBuffer = JitterBuffer()
    private let encoder = OpusCoder()
    private let decoder = OpusCoder()

    // Smart audio processing
    private let preCaptureBuffer = PreCaptureBuffer()
    private let whisperDetector = WhisperDetector()
    private let smartMute = SmartMuteDetector()
    private let ambientSharing = AmbientSharing()

    // Distance pipeline (§10/16)
    private let rangingEngine = NIRangingEngine()
    private let rssiFallback = RSSIFallback()
    private let distancePublisher = DistancePublisher()

    // Profile-driven subsystems
    private let airPods = AirPodsController()
    private let musicDucker = MusicDucker()
    private let vad = VAD()
    private let wakeWord = WakeWordDetector()
    private let agentConnector = AgentConnector()

    /// Tailscale presence detector — drives `connectionType = .tailscale`
    /// when no peer-driven (simulator-relay) type is otherwise active.
    private let tailscale = TailscaleDetector.shared

    /// QR pairing — observes AppState.pendingPairing and reacts.
    private let pairingService = PairingService()

    private var cancellables = Set<AnyCancellable>()
    private var audioTask: Task<Void, Never>?
    private var farStartupTask: Task<Void, Never>?
    private var privacyModeCancellable: AnyCancellable?
    private var simulatorRelayFrameTask: Task<Void, Never>?
    private var playbackTimer: Timer?

    private lazy var pcmPlaybackFormat = AVAudioFormat(
        standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 1
    )!

    weak var appState: AppState?

    init() {
        far = FarTransport()
        transcription = LiveTranscriptionEngine()
    }

    init(
        far: any FarTransporting,
        transcription: LiveTranscriptionEngine? = nil
    ) {
        self.far = far
        if let transcription {
            self.transcription = transcription
        } else {
            self.transcription = LiveTranscriptionEngine()
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Pre-fix, calling start() twice in quick succession (e.g. user
        // double-taps "Session starten") spawned two parallel
        // startAudioPipeline tasks that fought over `bonder.addPath` and
        // could leave duplicate sinks behind on the next stop()/start().
        guard audioTask == nil else { return }
        registerPrivacyModeHandling()
        phase = .connecting
        appState?.phase = .connecting
        audioTask = Task { [weak self] in
            await self?.startAudioPipeline()
        }
    }

    func stop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        audioTask?.cancel()
        audioTask = nil
        farStartupTask?.cancel()
        farStartupTask = nil
        privacyModeCancellable?.cancel()
        privacyModeCancellable = nil
        simulatorRelayFrameTask?.cancel()
        simulatorRelayFrameTask = nil
        // Drop Combine subscriptions BEFORE stopping the engine — otherwise
        // an in-flight `audioEngine.captured` sink can still fire after
        // engine.stop() is called and try to encode/send on a torn-down
        // bonder, which would log spurious errors and leak frames.
        cancellables.removeAll()
        audioEngine.stop()
        transcription.stop()
        _ = recorder.stopSession()
        spatialMixer.stopRemotePlayer()
        distancePublisher.unbind()
        near.onReceivedNIToken = nil
        near.localNIToken = nil
        rangingEngine.stop()
        rssiFallback.stop()
        musicDucker.disable()
        wakeWord.stop()
        let relay = simulatorRelay
        bonder.removeAllPaths()
        tailscalePath.stop()
        Task {
            await near.stop()
            await far.stop()
            await relay?.stop()
        }
        simulatorRelay = nil
        jitterBuffer.reset()
        phase = .idle
        appState?.phase = .idle
        appState?.isRecording = false
        appState?.peerOnline = false
        appState?.peerID = nil
        appState?.peerName = nil
        appState?.peerLastSeen = nil
        appState?.connectionType = .none
        appState?.connectionIsSimulated = false
        appState?.activePathIDs = []
        appState?.activePathCount = 0
        appState?.inputLevelRMS = 0
        appState?.peerDirection = nil
    }

    // MARK: - Internal async setup

    private func startAudioPipeline() async {
        let simulatorRelayMode = appState?.testIdentity.isSimulatorRelayEnabled == true
        if simulatorRelayMode {
            await startSimulatorRelayPipeline()
            return
        }

        // Attach SpatialMixer nodes before the engine starts.
        audioEngine.connect(spatialMixer: spatialMixer)

        // Honor the user's "Ungefiltertes Audio" preference. Must be set
        // before prepare(): voice-processing-enabled can't be flipped on a
        // running engine without a full restart.
        audioEngine.rawAudioMode = appState?.rawAudioMode ?? true

        do {
            try audioEngine.prepare()
        } catch {
            phase = .idle
            return
        }

        spatialMixer.startRemotePlayer()

        // MARK: Distance pipeline (§10/16)

        let capabilities = DeviceCapabilities.detect()
        let localNIToken = capabilities.hasUWB ? rangingEngine.prepareLocalToken() : nil
        distancePublisher.bind(uwb: rangingEngine, rssi: rssiFallback, uwbAvailable: localNIToken != nil)

        // When NearTransport gets a peer's NIDiscoveryToken, start UWB ranging.
        near.localNIToken = localNIToken
        near.onReceivedNIToken = { [weak self] token in
            guard let self else { return }
            guard near.localNIToken != nil else { return }
            rangingEngine.start(with: token)
            // Publish our local token back so the peer can start ranging too.
            near.localNIToken = rangingEngine.localToken
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
                self?.handlePeerDirectionUpdate(direction)
            }
            .store(in: &cancellables)

        // MARK: Transport setup

        // Push the user's editable display name into MPC's advertiser before
        // starting — NearTransport rebuilds its MCPeerID stack if the name
        // changed since the last start so peers see the latest label.
        near.advertisedDisplayName = appState?.effectiveDisplayName
        bluetooth.advertisedDisplayName = appState?.effectiveDisplayName
        try? await near.start()
        if shouldStartTailscaleTransport() {
            try? tailscalePath.start()
        }
        // stop() may have run during the await above. Bail out instead of
        // re-arming subsystems the user has just torn down.
        guard !Task.isCancelled else { return }
        bonder.addPath(near)
        bonder.addPath(bluetooth)
        if shouldStartTailscaleTransport() {
            bonder.addPath(tailscalePath)
        }
        let farConfig = farConfiguration()
        if shouldStartFarTransport(configuration: farConfig) {
            startFarTransportIfAllowed(configuration: farConfig)
        }

        // Tailscale presence is advertised in the QR token. The UI only flips
        // to "Tailscale" after the TCP path itself is actually connected.
        tailscale.startMonitoring()
        tailscale.refresh()
        guard !Task.isCancelled else { return }

        // MARK: Replay contact book → all transports.

        replayContactBook(from: appState)

        // MARK: Live discovery → AppState.peerDirectory.

        wireLiveDiscovery(into: appState)

        // MARK: QR pairing — observe AppState.pendingPairing and translate

        // a successful scan into a targeted NearTransport invite and a new
        // contact-book entry via the KnownPeerStore. Transport state still
        // owns peerOnline.
        if let appState {
            pairingService.bind(
                appState: appState,
                near: near,
                bluetooth: bluetooth,
                tailscale: tailscalePath,
                peerStore: appState.peerStore
            )
        }

        // MARK: Contact-book "last seen" bookkeeping. When the bonder reports

        // any active path with a known peer ID set on AppState, bump the
        // peer's lastSeenAt so the contact book sorts most-recent-first.
        if let appState {
            appState.$peerOnline
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { online in
                    guard online, let id = appState.peerID else { return }
                    appState.peerStore.touch(id: id)
                }
                .store(in: &cancellables)
        }

        // MARK: Mic-gain slider → AudioEngine. Real-device testing on v0.2.6

        // showed Apple's voice-processing AGC pulls speech low, so users need a
        // live, persisted gain control on top of it.
        if let appState {
            audioEngine.inputGain = appState.inputGain
            appState.$inputGain
                .receive(on: DispatchQueue.main)
                .sink { [weak self] gain in
                    self?.audioEngine.inputGain = gain
                }
                .store(in: &cancellables)

            // Toggling "Ungefiltertes Audio" in Settings now restarts the
            // engine immediately so the user hears the difference without
            // having to manually stop+start the session.
            appState.$rawAudioMode
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newMode in
                    guard let self else { return }
                    audioEngine.rawAudioMode = newMode
                    do {
                        try audioEngine.reapplyConfig()
                        spatialMixer.startRemotePlayer()
                    } catch {
                        Log.app.error("AudioEngine reapplyConfig failed after rawAudioMode toggle: \(error.localizedDescription, privacy: .public)")
                    }
                }
                .store(in: &cancellables)
        }

        // MARK: Wake word → AI agent

        wakeWord.start()
        wakeWord.triggered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { [weak self] in
                    try? await self?.agentConnector.ensureAgentInRoom()
                    self?.appState?.aiActive = true
                }
            }
            .store(in: &cancellables)

        // MARK: Profile application — apply initial profile and react to changes.

        applyProfile(SessionProfile.builtIn.first { $0.id == (appState?.profileID ?? "zimmer") })

        if let appState {
            appState.$profileID
                .dropFirst() // skip initial value, already applied above
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
            .sink { [weak self] _, buffer in
                guard let self else { return }
                let rms = MicrophoneMonitor.rms(buffer)
                Task { @MainActor [weak self] in
                    self?.appState?.inputLevelRMS = rms
                }
                preCaptureBuffer.push(buffer)
                whisperDetector.process(buffer)
                smartMute.process(buffer)
                // VAD drives music ducking when voice is detected.
                let speaking = vad.feed(buffer)
                Task { @MainActor [weak self] in
                    self?.musicDucker.duckOnVoice(active: speaking)
                }
                guard MicrophoneMonitor.shouldForwardCapturedAudio(
                    isMuted: appState?.isMuted ?? false
                ) else {
                    return
                }
                if !simulatorRelayMode {
                    transcription.append(buffer)
                }
                recorder.append(buffer)
                wakeWord.feed(buffer)
                if let data = try? encoder.encode(buffer) {
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
            withTimeInterval: Double(LatencyBudget.audioFrameMs) / 1000.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainJitterBuffer()
            }
        }

        // MARK: Battery tier → bonder mode + appState.

        battery.$tier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tier in
                guard let self else { return }
                applyBatteryTier(tier)
                appState?.batteryTier = tier
            }
            .store(in: &cancellables)

        // MARK: Active paths → appState (count + per-path Set for the live icon row).

        bonder.$activePaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                self?.handleActivePathUpdate(paths)
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

        LocalRecorder.applyStoredRetentionPolicy()
        appState?.isRecording = (try? recorder.startSession()) ?? false

        // Live transcript → AppState (drives UI)
        transcription.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segs in self?.appState?.transcriptSegments = segs }
            .store(in: &cancellables)

        if simulatorRelayMode {
            appState?.transcriptSegments = []
        } else {
            Task { try? await transcription.start() }
        }

        // If stop() interleaved during one of the awaits above, don't flip the
        // phase back over the .idle that stop() just set.
        guard !Task.isCancelled else { return }
        setFallbackPhaseForCurrentConnection()
    }

    private func startSimulatorRelayPipeline() async {
        guard let appState, let relay = SimulatorRelayTransport.makeFromIdentity(appState.testIdentity) else {
            phase = .idle
            appState?.phase = .idle
            return
        }

        simulatorRelay = relay
        relay.onPeerUpdate = { [weak self] peer in
            self?.handleSimulatorRelayPeerUpdate(peer)
        }

        bonder.addPath(relay)
        do {
            try await relay.start()
        } catch {
            phase = .idle
            appState.phase = .idle
            appState.connectionType = .none
            appState.connectionIsSimulated = false
            return
        }

        guard !Task.isCancelled else { return }

        appState.connectionType = .simulatorRelay
        appState.connectionIsSimulated = true
        appState.isRecording = false
        appState.transcriptSegments = []

        bonder.$activePaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                self?.appState?.activePathCount = paths.count
                self?.appState?.activePathIDs = Set(paths.map(\.rawValue))
            }
            .store(in: &cancellables)

        signalCalc.$score
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.appState?.signalScore = s }
            .store(in: &cancellables)

        signalCalc.$grade
            .receive(on: DispatchQueue.main)
            .sink { [weak self] g in self?.appState?.signalGrade = g }
            .store(in: &cancellables)

        simulatorRelayFrameTask?.cancel()
        simulatorRelayFrameTask = Task { [weak self] in
            let payload = Data("sonar-simulator-relay-frame".utf8)
            while !Task.isCancelled {
                await self?.bonder.send(opusData: payload)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        phase = .far
        appState.phase = .far
    }

    // MARK: - Distance → Phase

    func handleDistanceUpdate(_ distance: Double?) {
        guard let distance else {
            // No reading — leave near mode so the UI stops showing stale metres.
            if case .near = phase { setFallbackPhaseForCurrentConnection() }
            if case .near = appState?.phase ?? .idle { setFallbackPhaseForCurrentConnection() }
            return
        }

        let threshold = activeProfile?.nearFarThreshold ?? 8.0

        if distance <= threshold {
            phase = .near(distance: distance)
            appState?.phase = .near(distance: distance)
        } else {
            if case .near = phase { setFallbackPhaseForCurrentConnection() }
            if case .near = appState?.phase ?? .idle { setFallbackPhaseForCurrentConnection() }
        }
    }

    func handlePeerDirectionUpdate(_ direction: simd_float3?) {
        appState?.peerDirection = direction
        guard let direction else { return }
        spatialMixer.updateSpatialPosition(direction: direction)
    }

    private func registerPrivacyModeHandling() {
        guard privacyModeCancellable == nil else { return }
        // Privacy has to be observed before async startup reaches cloud paths,
        // otherwise a token fetch/connect already in flight can survive the kill switch.
        privacyModeCancellable = NotificationCenter.default.publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handlePrivacyModeActivated()
                }
            }
    }

    private func farConfiguration() -> FarTransport.Configuration {
        let env = ProcessInfo.processInfo.environment
        let liveKitURL = env["SONAR_LIVEKIT_URL"]
            ?? UserDefaults.standard.string(forKey: "sonar.livekit.url")
            ?? ""
        let tokenServerURL = env["SONAR_TOKEN_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: "sonar.tokenServer.url")
            ?? ""
        let roomName = env["SONAR_LIVEKIT_ROOM"]
            ?? UserDefaults.standard.string(forKey: "sonar.livekit.room")
            ?? "sonar-main"
        return FarTransport.Configuration(
            liveKitURL: liveKitURL,
            tokenServerURL: tokenServerURL,
            roomName: roomName
        )
    }

    func startFarTransportIfAllowed(configuration: FarTransport.Configuration) {
        guard shouldStartFarTransport(configuration: configuration) else { return }

        farStartupTask?.cancel()
        far.configure(configuration)
        farStartupTask = Task { [weak self] in
            guard let self else { return }
            guard shouldStartFarTransport(configuration: configuration), !Task.isCancelled else { return }

            do {
                try await far.start()
            } catch {
                return
            }

            guard Self.shouldKeepStartedFarTransport(
                privacyActive: privacy.isActive,
                startupTaskCancelled: Task.isCancelled,
                configuration: configuration
            ) else {
                await far.stop()
                return
            }

            bonder.addPath(far)
            farStartupTask = nil
        }
    }

    func handlePrivacyModeActivated() async {
        farStartupTask?.cancel()
        farStartupTask = nil
        bonder.removePath(.tailscale)
        bonder.removePath(.mpquic)
        tailscalePath.stop()
        await far.stop()
        switch transcription.currentEngine {
        case .openAIRealtime, .parakeet:
            transcription.abortCloudTranscriptionForPrivacy()
        case .appleSpeech, .local:
            break
        }
        // Clear any cloud-sourced live transcript so stale text doesn't
        // linger in the UI after the user pulls the kill switch.
        transcription.clearTranscript()
        appState?.transcriptSegments = []
        appState?.isRecording = false
    }

    static func shouldStartFarTransport(
        privacyActive: Bool,
        configuration: FarTransport.Configuration
    ) -> Bool {
        !privacyActive && configuration.isStartable
    }

    static func shouldKeepStartedFarTransport(
        privacyActive: Bool,
        startupTaskCancelled: Bool,
        configuration: FarTransport.Configuration
    ) -> Bool {
        shouldStartFarTransport(privacyActive: privacyActive, configuration: configuration) && !startupTaskCancelled
    }

    private func shouldStartFarTransport(configuration: FarTransport.Configuration) -> Bool {
        Self.shouldStartFarTransport(privacyActive: privacy.isActive, configuration: configuration)
    }

    static func shouldStartTailscaleTransport(privacyActive: Bool) -> Bool {
        !privacyActive
    }

    private func shouldStartTailscaleTransport() -> Bool {
        Self.shouldStartTailscaleTransport(privacyActive: privacy.isActive)
    }

    private func handleActivePathUpdate(_ paths: [MultipathBonder.PathID]) {
        appState?.applyActiveTransportPaths(paths)
        guard phase != .idle else { return }
        guard !paths.isEmpty else {
            phase = .connecting
            appState?.phase = .connecting
            return
        }
        if case .near = phase { return }
        phase = .far
        appState?.phase = .far
    }

    private func setFallbackPhaseForCurrentConnection() {
        let nextPhase: AppState.Phase = bonder.activePaths.isEmpty ? .connecting : .far
        phase = nextPhase
        appState?.phase = nextPhase
    }

    private var activeProfile: SessionProfile? {
        guard let id = appState?.profileID else { return nil }
        return SessionProfile.builtIn.first { $0.id == id }
    }

    /// Push every persisted contact into the transports' allow-lists so
    /// MPC/BLE/Tailscale auto-reconnect without the user needing to re-scan
    /// the QR. Extracted from `startAudioPipeline` to keep that function under
    /// the cyclomatic-complexity ceiling.
    private func replayContactBook(from appState: AppState?) {
        guard let appState else { return }
        for peer in appState.peerStore.peers {
            let token = peer.asReplayToken()
            near.addPairingToken(token)
            bluetooth.addPairingToken(token)
            if shouldStartTailscaleTransport() {
                tailscalePath.addPairingToken(token)
            }
        }
    }

    /// Pipe NearTransport + BluetoothMeshTransport live-peer publishers into
    /// `AppState.peerDirectory` so `DevicesView` reflects MPC/BLE sightings
    /// within seconds of session start. Extracted from `startAudioPipeline`
    /// to keep that function under the cyclomatic-complexity ceiling.
    private func wireLiveDiscovery(into appState: AppState?) {
        guard let appState else { return }
        near.livePeers
            .receive(on: DispatchQueue.main)
            .sink { peers in
                appState.peerDirectory.mpcPeers = peers
            }
            .store(in: &cancellables)
        bluetooth.livePeers
            .receive(on: DispatchQueue.main)
            .sink { peers in
                appState.peerDirectory.blePeers = peers
            }
            .store(in: &cancellables)

        // Mirror "Vergessen"-gestures into the transport allow-lists. Pre-fix,
        // removing a contact in the UI left the transport hint in place so
        // the deleted peer would silently re-connect on next discovery.
        var previousPeerIDs = Set(appState.peerStore.peers.map(\.id))
        var previousByID = Dictionary(uniqueKeysWithValues: appState.peerStore.peers.map { ($0.id, $0) })
        appState.peerStore.$peers
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                guard let self else { return }
                let currentIDs = Set(current.map(\.id))
                let removedIDs = previousPeerIDs.subtracting(currentIDs)
                for id in removedIDs {
                    near.removePairingToken(forPeerID: id)
                    let removed = previousByID[id]
                    if let ble = removed?.ble, !ble.isEmpty {
                        bluetooth.removePairingToken(forBLEIdentifier: ble)
                    }
                    if let ip = removed?.tsIP, !ip.isEmpty {
                        tailscalePath.removePairingToken(forTSIP: ip, port: removed?.tsPort ?? TailscaleTransport.defaultPort)
                    }
                }
                previousPeerIDs = currentIDs
                previousByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            }
            .store(in: &cancellables)
    }

    private func handleSimulatorRelayPeerUpdate(_ peer: SimulatorRelayPeer?) {
        guard let appState else { return }
        guard let peer else {
            appState.peerOnline = false
            appState.peerID = nil
            appState.peerName = nil
            appState.peerLastSeen = nil
            return
        }

        appState.peerOnline = true
        appState.peerID = peer.id
        appState.peerName = "\(peer.name) · \(shortPeerID(peer.id))"
        appState.peerLastSeen = Date(timeIntervalSince1970: peer.lastSeen)
        appState.connectionType = .simulatorRelay
        appState.connectionIsSimulated = true
    }

    private func shortPeerID(_ id: String) -> String {
        let cleaned = id.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty else { return "PEER" }
        return String(cleaned.suffix(6)).uppercased()
    }

    // MARK: - Jitter buffer drain (runs on main thread via Timer)

    private func drainJitterBuffer() {
        if let frame = jitterBuffer.dequeue() {
            decodeAndSchedule(frame)
        } else if jitterBuffer.needsConcealment {
            jitterBuffer.advanceOnConceal()
            // Pre-fix, missing frames just advanced the seq counter and
            // scheduled nothing — audible hard gap. Schedule a frame of
            // silence to keep the audio graph continuous so packet loss
            // sounds like a brief muffle instead of a click.
            scheduleSilenceFrame()
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

    private func scheduleSilenceFrame() {
        let frames = AVAudioFrameCount(decoder.samplesPerFrame)
        guard let buf = AVAudioPCMBuffer(pcmFormat: pcmPlaybackFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        if let channels = buf.floatChannelData {
            let count = Int(buf.format.channelCount)
            for ch in 0 ..< count {
                memset(channels[ch], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        spatialMixer.scheduleBuffer(buf)
    }

    // MARK: - Profile application

    private func applyProfile(_ profile: SessionProfile?) {
        guard let profile else { return }

        // AirPods listening preferences and Music ducking are AVAudioSession
        // best-effort requests. Merge them into AudioEngine's policy so a later
        // raw-audio reassert/restart preserves the requested mode/options.
        audioEngine.updateSessionPolicy { policy in
            policy.listeningModeNudge = airPods.listeningModeNudge(for: profile.listeningMode)
            policy.musicDuckingEnabled = profile.musicMix > 0
        }

        // Music ducking: request system mixing/ducking. iOS decides the actual
        // attenuation applied to other audio.
        if profile.musicMix > 0 {
            Task { [weak self] in
                guard let self else { return }
                try? await musicDucker.enable(targetGain: profile.musicMix)
                musicDucker.duck()
            }
        } else {
            musicDucker.disable()
        }

        // Remote voice gain from the profile, multiplied by the global Sonar
        // output volume inside SpatialMixer.
        spatialMixer.applyProfileVoiceGain(Float(profile.gain))
    }

    // MARK: - Battery adaptation

    private func applyBatteryTier(_ tier: BatteryManager.Tier) {
        switch tier {
        case .normal: bonder.mode = .redundant
        case .eco: bonder.mode = .eco
        case .saver, .critical: bonder.mode = .primaryStandby
        }
        if !tier.transcriptionEnabled { transcription.stop() }
        if !tier.recordingEnabled {
            _ = recorder.stopSession()
            appState?.isRecording = false
        }
    }
}
