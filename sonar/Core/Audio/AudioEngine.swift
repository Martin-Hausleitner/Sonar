import Accelerate
import AVFoundation
import Combine
import Foundation
import os

/// Single source of truth for Sonar's AVAudioSession category/mode/options.
///
/// Profile helpers such as MusicDucker and AirPodsController express desired
/// state here; AudioEngine is the only component that applies the merged
/// session configuration during prepare/reassert/restart.
struct AudioSessionPolicy: Equatable {
    enum ListeningModeNudge: Equatable {
        case none
        case `default`
        case voiceChat

        var sessionMode: AVAudioSession.Mode? {
            switch self {
            case .none: nil
            case .default: .default
            case .voiceChat: .voiceChat
            }
        }
    }

    var rawAudioMode: Bool = true
    var listeningModeNudge: ListeningModeNudge = .none
    var musicDuckingEnabled: Bool = false

    init(
        rawAudioMode: Bool = true,
        listeningModeNudge: ListeningModeNudge = .none,
        musicDuckingEnabled: Bool = false
    ) {
        self.rawAudioMode = rawAudioMode
        self.listeningModeNudge = listeningModeNudge
        self.musicDuckingEnabled = musicDuckingEnabled
    }

    var sessionMode: AVAudioSession.Mode {
        if let nudgedMode = listeningModeNudge.sessionMode {
            return nudgedMode
        }
        return rawAudioMode ? .default : .voiceChat
    }

    var voiceProcessingEnabled: Bool {
        !rawAudioMode
    }

    var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [
            .allowAirPlay,
            .allowBluetoothHFP,
            .mixWithOthers
        ]
        if musicDuckingEnabled {
            options.insert(.duckOthers)
        }
        return options
    }
}

/// AVAudioEngine + VoiceProcessingIO. Plan §10/3, LATENCY.md.
///
/// Sets `AVAudioSession.preferredIOBufferDuration` to
/// `LatencyBudget.preferredIOBufferDurationSec` (5 ms) so the OS hands us
/// audio buffers as fast as the hardware allows.
@MainActor
final class AudioEngine {
    /// Allowed range for the live mic-gain slider. Voice-processing AGC tends to
    /// pull real-world speech low; 0.5×–6× covers the practical span without
    /// distorting beyond reason.
    static let inputGainRange: ClosedRange<Float> = 0.5 ... 6.0

    private let engine = AVAudioEngine()

    /// Live mic gain, applied to every captured buffer in-place. Read on the
    /// audio thread inside the input tap, written from the main thread (UI),
    /// so the access has to be lock-protected.
    private let gainLock = OSAllocatedUnfairLock<Float>(initialState: 1.0)

    /// Multiplier applied to mic samples before they reach the encoder.
    /// `1.0` = pass-through; clamped into `inputGainRange`.
    nonisolated var inputGain: Float {
        get { gainLock.withLock { $0 } }
        set {
            let clamped = min(max(newValue, Self.inputGainRange.lowerBound), Self.inputGainRange.upperBound)
            gainLock.withLock { $0 = clamped }
        }
    }

    private var sessionPolicy = AudioSessionPolicy()

    /// When true, `prepare()` keeps Apple's VoiceProcessingIO chain disabled.
    /// The AVAudioSession mode itself is resolved through `AudioSessionPolicy`
    /// so best-effort AirPods nudges and ducking options survive reasserts.
    var rawAudioMode: Bool {
        get { sessionPolicy.rawAudioMode }
        set { sessionPolicy.rawAudioMode = newValue }
    }

    /// Each captured buffer is published with the frame ID it was assigned by
    /// `Metrics.openTrace()`. Subscribers must forward the ID through encode/
    /// transport/decode so glass-to-glass latency can be measured end-to-end.
    let captured = PassthroughSubject<(frameID: UInt64, buffer: AVAudioPCMBuffer), Never>()

    /// Attach a SpatialMixer before the engine starts so its nodes are part of the graph.
    func connect(spatialMixer: SpatialMixer) {
        spatialMixer.prepare(engine: engine)
    }

    func prepare() throws {
        try applySessionConfiguration(activate: true, updateVoiceProcessing: true)

        let format = engine.inputNode.inputFormat(forBus: 0)
        let bufSize = AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        engine.inputNode.installTap(onBus: 0, bufferSize: bufSize, format: format) { [weak self] buf, _ in
            guard let self else { return }
            applyInputGain(to: buf)
            let id = Metrics.shared.openTrace()
            Metrics.shared.mark(id, .captured)
            captured.send((frameID: id, buffer: buf))
        }

        engine.prepare()
        try engine.start()
        observeInterruptions()
    }

    func stop() {
        stopObservingInterruptions()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Tear down + re-prepare in one shot. Used by SessionCoordinator when
    /// the user toggles "Ungefiltertes Audio" mid-session — Apple requires
    /// the AVAudioSession to be inactive to flip voice processing, so a
    /// full restart is the only way the change can take effect.
    var isRunning: Bool {
        engine.isRunning
    }

    func reapplyConfig() throws {
        guard isRunning else {
            try prepare()
            return
        }
        stop()
        try prepare()
    }

    /// Reassert category/mode after profile helpers that also touch the shared
    /// AVAudioSession. This preserves raw/non-raw mode without rebuilding the
    /// whole graph; voice processing itself is changed only by `reapplyConfig()`.
    func reassertSessionConfiguration() {
        try? applySessionConfiguration(activate: true, updateVoiceProcessing: false)
    }

    func updateSessionPolicy(_ update: (inout AudioSessionPolicy) -> Void) {
        update(&sessionPolicy)
        reassertSessionConfiguration()
    }

    deinit {
        // Defensive: if the owner forgets to call stop(), the NotificationCenter
        // observers would keep this instance alive via their token closures.
        let center = NotificationCenter.default
        if let token = interruptionObserver { center.removeObserver(token) }
        if let token = routeChangeObserver { center.removeObserver(token) }
    }

    // MARK: - Interruption handling

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// Real-device test on v0.2.9: a phone call / Siri / AirPods drop would
    /// silently kill the input — the engine kept "running" but produced no
    /// frames. Subscribe to the system interruption + route-change
    /// notifications and restart the engine on `.ended` / valid route.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    private func stopObservingInterruptions() {
        let center = NotificationCenter.default
        if let token = interruptionObserver { center.removeObserver(token) }
        if let token = routeChangeObserver { center.removeObserver(token) }
        interruptionObserver = nil
        routeChangeObserver = nil
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            // The system stops our engine for us; nothing to do here. Holding
            // the tap installed is fine — `.ended` will reactivate.
            break
        case .ended:
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard opts.contains(.shouldResume) else { return }
            reassertSessionConfiguration()
            if !engine.isRunning { try? engine.start() }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        // Old device unavailable (AirPods unplugged, headphones disconnect)
        // pauses the engine on iOS — kick it back on so the live session
        // keeps streaming through the new route (built-in mic/speaker).
        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            reassertSessionConfiguration()
            if !engine.isRunning { try? engine.start() }
        }
    }

    private func applySessionConfiguration(activate: Bool, updateVoiceProcessing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: sessionPolicy.sessionMode,
            options: sessionPolicy.categoryOptions
        )
        try session.setPreferredIOBufferDuration(LatencyBudget.preferredIOBufferDurationSec)
        try session.setPreferredSampleRate(LatencyBudget.audioSampleRate)

        if updateVoiceProcessing {
            // Voice processing must be configured BEFORE setActive(true). Calling
            // setVoiceProcessingEnabled after the session is active is silently
            // ignored — that was the v0.2.9 bug where flipping "Ungefiltertes
            // Audio" had no audible effect.
            try engine.inputNode.setVoiceProcessingEnabled(sessionPolicy.voiceProcessingEnabled)
        }

        if activate {
            try session.setActive(true, options: [])
        }
    }

    /// Multiply each sample by the current `inputGain`, in-place, on the audio
    /// thread. Skipped for unity gain to keep the hot path branch-free.
    private nonisolated func applyInputGain(to buffer: AVAudioPCMBuffer) {
        var gain = inputGain
        guard gain != 1.0, let channels = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0 ..< channelCount {
            vDSP_vsmul(channels[ch], 1, &gain, channels[ch], 1, frames)
        }
    }
}
