import AVFoundation
import Foundation

// Soniox realtime speech-to-text (model `stt-rt-v5`).
//
// Wire contract mirrored from the reverse-engineering lab in `soniox-route-lab`
// (`src/soniox-stream.mjs`, `web/app.js`, `docs/auth-flow.md`):
//
//   1. Open  wss://stt-rt.soniox.com/transcribe-websocket
//   2. Send  ONE JSON text frame with the session config
//            {api_key, model, audio_format:"pcm_s16le", sample_rate, num_channels,
//             enable_speaker_diarization, enable_endpoint_detection, language_hints}
//   3. Send  raw PCM16 little-endian mono binary frames (no envelope, no base64)
//   4. Recv  JSON frames {tokens:[{text,is_final,speaker,translation_status}], finished}
//   5. Send  an EMPTY text frame to terminate; the server replies with `finished:true`
//
// Credentials: never hardcoded. Either a short-lived key minted by a broker
// (`temporaryKeyURL`, the pattern from `docs/auth-flow.md` §"Drei nutzbare
// Schlüsselpfade") or a directly configured key. See `SonioxConfiguration`.

// MARK: - Configuration

/// Runtime configuration for the Soniox realtime engine.
///
/// Resolution order per value: process environment (`SONAR_SONIOX_*`) first,
/// then `UserDefaults` (`sonar.soniox.*`), then a built-in default.
/// This mirrors `SessionCoordinator.farConfiguration()`.
struct SonioxConfiguration: Equatable {
    /// A Soniox API key. Prefer `temporaryKeyURL` — a long-lived key on a device
    /// is the weaker of the two paths and is only meant for local testing.
    var apiKey: String
    /// URL of a broker that mints a SHORT-LIVED single-use streaming key.
    /// Accepts either the lab's loopback shape (`{"apiKey":…,"realtimeUrl":…}`)
    /// or Soniox' official shape (`{"api_key":…}`).
    var temporaryKeyURL: String
    var websocketURL: String
    var model: String
    var languageHints: [String]
    var enableSpeakerDiarization: Bool
    var enableEndpointDetection: Bool
    /// Silence (in seconds) after which the streaming session is suspended to
    /// stop paying for dead air. `<= 0` disables suspension entirely.
    var silenceStopSeconds: Double
    /// Audio retained while suspended and replayed on resume, so the first word
    /// after a pause is not clipped.
    var preRollSeconds: Double
    /// RMS thresholds with hysteresis, matching `sonar/Core/AI/VAD.swift`.
    var voiceOnThreshold: Float
    var voiceOffThreshold: Float

    static let defaultWebsocketURL = "wss://stt-rt.soniox.com/transcribe-websocket"
    static let defaultModel = "stt-rt-v5"
    static let defaultSilenceStopSeconds: Double = 120
    static let defaultPreRollSeconds: Double = 1.0
    static let defaultVoiceOnThreshold: Float = 0.018
    static let defaultVoiceOffThreshold: Float = 0.010

    /// Sample rate Soniox is configured with. Capture runs at 48 kHz
    /// (`LatencyBudget.audioSampleRate`) and is downsampled before sending.
    static let targetSampleRate: Double = 16000

    static let apiKeyDefaultsKey = "sonar.soniox.apiKey"
    static let temporaryKeyURLDefaultsKey = "sonar.soniox.tempKeyURL"
    static let websocketURLDefaultsKey = "sonar.soniox.wsURL"
    static let modelDefaultsKey = "sonar.soniox.model"
    static let languageHintsDefaultsKey = "sonar.soniox.languageHints"
    static let diarizationDefaultsKey = "sonar.soniox.diarization"
    static let silenceStopDefaultsKey = "sonar.soniox.silenceStopSec"
    static let preRollDefaultsKey = "sonar.soniox.preRollSec"
    static let voiceOnDefaultsKey = "sonar.soniox.vadOn"
    static let voiceOffDefaultsKey = "sonar.soniox.vadOff"

    /// True when the engine has something it can authenticate with.
    var isConfigured: Bool {
        !apiKey.isEmpty || !temporaryKeyURL.isEmpty
    }

    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> SonioxConfiguration {
        func string(_ env: String, _ key: String, default fallback: String) -> String {
            let value = environment[env] ?? defaults.string(forKey: key) ?? ""
            return value.isEmpty ? fallback : value
        }
        func flag(_ env: String, _ key: String, default fallback: Bool) -> Bool {
            if let raw = environment[env]?.lowercased(), !raw.isEmpty {
                return raw == "1" || raw == "true" || raw == "yes"
            }
            if defaults.object(forKey: key) != nil {
                return defaults.bool(forKey: key)
            }
            return fallback
        }

        func number(_ env: String, _ key: String, default fallback: Double) -> Double {
            if let raw = environment[env], let value = Double(raw) {
                return value
            }
            if defaults.object(forKey: key) != nil {
                return defaults.double(forKey: key)
            }
            return fallback
        }

        let hintsRaw = string("SONAR_SONIOX_LANGUAGE_HINTS", languageHintsDefaultsKey, default: "")
        let hints = hintsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return SonioxConfiguration(
            apiKey: string("SONAR_SONIOX_API_KEY", apiKeyDefaultsKey, default: ""),
            temporaryKeyURL: string("SONAR_SONIOX_TEMP_KEY_URL", temporaryKeyURLDefaultsKey, default: ""),
            websocketURL: string("SONAR_SONIOX_WS_URL", websocketURLDefaultsKey, default: defaultWebsocketURL),
            model: string("SONAR_SONIOX_MODEL", modelDefaultsKey, default: defaultModel),
            languageHints: hints,
            enableSpeakerDiarization: flag("SONAR_SONIOX_DIARIZATION", diarizationDefaultsKey, default: true),
            enableEndpointDetection: true,
            silenceStopSeconds: number(
                "SONAR_SONIOX_SILENCE_STOP_SEC",
                silenceStopDefaultsKey,
                default: defaultSilenceStopSeconds
            ),
            preRollSeconds: max(0, number("SONAR_SONIOX_PREROLL_SEC", preRollDefaultsKey, default: defaultPreRollSeconds)),
            voiceOnThreshold: Float(
                number("SONAR_SONIOX_VAD_ON", voiceOnDefaultsKey, default: Double(defaultVoiceOnThreshold))
            ),
            voiceOffThreshold: Float(
                number("SONAR_SONIOX_VAD_OFF", voiceOffDefaultsKey, default: Double(defaultVoiceOffThreshold))
            )
        )
    }

    /// `false` when suspension is switched off (non-positive threshold).
    var isSilenceSuspensionEnabled: Bool {
        silenceStopSeconds > 0
    }

    /// The single JSON text frame Soniox expects before any audio.
    func startMessage(apiKey resolvedKey: String, sampleRate: Double) -> [String: Any] {
        var message: [String: Any] = [
            "api_key": resolvedKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(sampleRate),
            "num_channels": 1,
            "enable_speaker_diarization": enableSpeakerDiarization,
            "enable_endpoint_detection": enableEndpointDetection
        ]
        if !languageHints.isEmpty {
            message["language_hints"] = languageHints
        }
        return message
    }
}

// MARK: - Wire model

/// One token as emitted by `stt-rt-v5`.
struct SonioxToken: Equatable {
    var text: String
    var isFinal: Bool
    /// Diarization label. Soniox sends it as a number or a string depending on
    /// the field (`speaker` / `speaker_id` / `speaker_label`); normalized here.
    var speakerID: String?
    /// `"translation"` for translated tokens, `"original"`/nil otherwise.
    var translationStatus: String?

    var isTranslation: Bool {
        translationStatus == "translation"
    }

    /// Endpoint marker emitted when `enable_endpoint_detection` is on.
    var isEndpoint: Bool {
        text == "<end>"
    }
}

/// One decoded server frame.
struct SonioxServerMessage: Equatable {
    var tokens: [SonioxToken] = []
    var finished: Bool = false
    var errorCode: Int?
    var errorType: String?
    var errorMessage: String?

    var isError: Bool {
        errorCode != nil || errorType != nil || errorMessage != nil
    }

    /// Human-readable error, already free of key-shaped substrings.
    var redactedErrorDescription: String? {
        guard isError else { return nil }
        let raw = errorMessage ?? errorType ?? "Soniox error \(errorCode.map(String.init) ?? "?")"
        return SonioxServerMessage.redact(raw)
    }

    static func redact(_ message: String) -> String {
        // Same guard as the lab client: never surface key-shaped strings in logs.
        let pattern = "[A-Za-z0-9_-]{24,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return message }
        let range = NSRange(message.startIndex ..< message.endIndex, in: message)
        return regex.stringByReplacingMatches(
            in: message,
            range: range,
            withTemplate: "[REDACTED]"
        )
    }

    /// Decodes a raw server frame. Tolerant on purpose: Soniox is an observed
    /// contract, so unknown fields and missing optionals must never throw.
    static func decode(_ data: Data) throws -> SonioxServerMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SonioxError.malformedResponse
        }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> SonioxServerMessage {
        var message = SonioxServerMessage()
        message.finished = object["finished"] as? Bool ?? false
        message.errorCode = object["error_code"] as? Int
        message.errorType = object["error_type"] as? String
        message.errorMessage = object["error_message"] as? String

        for raw in object["tokens"] as? [[String: Any]] ?? [] {
            message.tokens.append(
                SonioxToken(
                    text: raw["text"] as? String ?? "",
                    isFinal: raw["is_final"] as? Bool ?? false,
                    speakerID: speakerID(from: raw),
                    translationStatus: raw["translation_status"] as? String
                )
            )
        }
        return message
    }

    private static func speakerID(from raw: [String: Any]) -> String? {
        for key in ["speaker", "speaker_id", "speaker_label"] {
            guard let value = raw[key] else { continue }
            if let text = value as? String, !text.isEmpty { return text }
            if let number = value as? Int { return String(number) }
            if let number = value as? Double { return String(Int(number)) }
        }
        return nil
    }
}

enum SonioxError: LocalizedError, Equatable {
    case notConfigured
    case malformedResponse
    case temporaryKeyUnavailable(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Soniox is not configured (no API key and no temporary-key URL)"
        case .malformedResponse:
            "Soniox sent a response that is not a JSON object"
        case let .temporaryKeyUnavailable(reason):
            "Soniox temporary key unavailable: \(reason)"
        case let .server(reason):
            "Soniox error: \(reason)"
        }
    }
}

// MARK: - Transcript accumulation (pure, unit-testable)

/// Turns the Soniox token stream into `LiveTranscriptionEngine.Segment`-shaped
/// emissions.
///
/// Semantics taken from the lab web client (`web/app.js#updateTokenState`):
/// final tokens are **appended** to the transcript, non-final tokens are the
/// **replaceable tail** and are re-sent in full with every frame.
///
/// A committed segment is flushed as `isFinal` when
///   * an `<end>` endpoint token arrives, or
///   * the diarized speaker changes, or
///   * the stream finishes.
/// Until then the committed text plus the live tail is emitted as a non-final
/// segment, so the UI updates on every frame.
struct SonioxTranscriptAccumulator: Equatable {
    struct Emission: Equatable {
        var text: String
        var speakerID: String?
        var isFinal: Bool
    }

    /// Include translated tokens in the transcript. Off by default; translation
    /// is a separate channel and would otherwise interleave with the original.
    var includesTranslation: Bool = false

    private var committedText: String = ""
    private var committedSpeaker: String?

    mutating func ingest(_ message: SonioxServerMessage) -> [Emission] {
        var emissions: [Emission] = []
        var tailText = ""
        var tailSpeaker: String?

        for token in message.tokens {
            if token.isTranslation, !includesTranslation { continue }

            if token.isFinal {
                if token.isEndpoint {
                    emissions.append(contentsOf: flushCommitted())
                    continue
                }
                if let speaker = token.speakerID,
                   let current = committedSpeaker,
                   speaker != current,
                   !committedText.isEmpty
                {
                    emissions.append(contentsOf: flushCommitted())
                }
                if committedSpeaker == nil { committedSpeaker = token.speakerID }
                committedText += token.text
            } else {
                if token.isEndpoint { continue }
                if tailSpeaker == nil { tailSpeaker = token.speakerID }
                tailText += token.text
            }
        }

        // On a `finished` frame the committed text is flushed as final below;
        // emitting it here first as a non-final segment would duplicate it in
        // the transcript (partial "Ende" immediately followed by final "Ende").
        let liveText = committedText + tailText
        if !message.finished,
           !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            emissions.append(
                Emission(text: liveText, speakerID: committedSpeaker ?? tailSpeaker, isFinal: false)
            )
        }

        if message.finished {
            emissions.append(contentsOf: flushCommitted())
        }
        return emissions
    }

    /// Commits whatever finalized text is still buffered (used on `stop()`).
    mutating func flush() -> [Emission] {
        flushCommitted()
    }

    private mutating func flushCommitted() -> [Emission] {
        let text = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = committedSpeaker
        committedText = ""
        committedSpeaker = nil
        guard !text.isEmpty else { return [] }
        return [Emission(text: text, speakerID: speaker, isFinal: true)]
    }
}

// MARK: - Audio conversion (pure, unit-testable)

/// Converts the 48 kHz Float32 capture buffers into the 16 kHz mono PCM16LE
/// frames Soniox expects. Box-averaging (not naive decimation) matches the
/// lab web client and avoids aliasing on a 3:1 ratio.
enum SonioxAudioConverter {
    static func downsample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate > 0, outputRate > 0, !samples.isEmpty else { return [] }
        if inputRate == outputRate { return samples }
        if outputRate > inputRate { return samples } // never upsample; Soniox is told the real rate

        let ratio = inputRate / outputRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for index in 0 ..< outputCount {
            let start = Int(Double(index) * ratio)
            let end = min(Int(Double(index + 1) * ratio), samples.count)
            guard end > start else {
                output[index] = samples[min(start, samples.count - 1)]
                continue
            }
            var sum: Float = 0
            for position in start ..< end {
                sum += samples[position]
            }
            output[index] = sum / Float(end - start)
        }
        return output
    }

    static func pcm16LE(_ samples: [Float]) -> Data {
        let converted: [Int16] = samples.map { sample in
            let clamped = max(-1, min(1, sample))
            return clamped < 0
                ? Int16(clamping: Int32(clamped * 32768))
                : Int16(clamping: Int32(clamped * 32767))
        }
        return converted.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func convert(
        _ samples: [Float],
        from inputRate: Double,
        to outputRate: Double = SonioxConfiguration.targetSampleRate
    ) -> Data {
        pcm16LE(downsample(samples, from: inputRate, to: outputRate))
    }
}

// MARK: - Temporary key broker

/// Fetches a short-lived streaming key from a broker endpoint.
/// Mirrors the loopback broker in `soniox-route-lab/src/local-server.mjs`
/// (`POST /api/temporary-key`) and tolerates Soniox' official response shape.
struct SonioxTemporaryKey: Equatable {
    var apiKey: String
    var realtimeURL: String?

    static func decode(_ data: Data) throws -> SonioxTemporaryKey {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SonioxError.malformedResponse
        }
        let key = (object["apiKey"] as? String) ?? (object["api_key"] as? String) ?? ""
        guard !key.isEmpty else {
            let reason = (object["message"] as? String) ?? (object["error"] as? String) ?? "no key in response"
            throw SonioxError.temporaryKeyUnavailable(SonioxServerMessage.redact(reason))
        }
        let url = (object["realtimeUrl"] as? String) ?? (object["realtime_url"] as? String)
        return SonioxTemporaryKey(apiKey: key, realtimeURL: url?.isEmpty == false ? url : nil)
    }
}

// MARK: - Transcriber

protocol SonioxRealtimeTranscribing: CloudTranscribing {
    func connect()
    /// Current quality/cost record. Safe to read from any thread.
    var qualityMetrics: SonioxQualityMetrics { get }
    /// Called on the main queue whenever the metrics change.
    var onMetricsChange: ((SonioxQualityMetrics) -> Void)? { get set }
}

/// Streams live PCM to Soniox `stt-rt-v5` over a WebSocket and surfaces
/// partial/final segments (with diarized speaker labels) on the main queue.
///
/// Robustness: a dropped socket is retried with backoff and the session config
/// is re-sent; `finish()` terminates cleanly with the empty-frame terminator;
/// `abort()` (Privacy Mode) kills the socket immediately, drops all buffered
/// audio and silences every further callback.
///
/// Cost control (Soniox Beta): a `SonioxSessionGovernor` suspends the session
/// after sustained silence and resumes it — pre-roll first — on the next word.
final class SonioxRealtimeTranscriber: SonioxRealtimeTranscribing, @unchecked Sendable {
    /// (text, speakerID, isFinal) — always delivered on the main queue.
    typealias SegmentHandler = (String, String?, Bool) -> Void

    private let configuration: SonioxConfiguration
    private let onSegment: SegmentHandler
    private let session: URLSession
    private let maxReconnectAttempts: Int
    private let queue = DispatchQueue(label: "sonar.soniox", qos: .userInitiated)
    private let governor: SonioxSessionGovernor
    private let monotonicNow: () -> TimeInterval

    private var wsTask: URLSessionWebSocketTask?
    private var accumulator = SonioxTranscriptAccumulator()
    private var pendingSamples: [Float] = []
    private var captureSampleRate: Double = LatencyBudget.audioSampleRate
    private var reconnectAttempt = 0
    private var isConnecting = false
    private var isStreaming = false
    /// Set when audio was sent but no token has come back yet — the anchor of
    /// the first-token latency measurement.
    private var awaitingFirstTokenSince: TimeInterval?
    /// Guards against sending more than one terminator per suspend.
    private var terminatorSent = false

    private let lifecycleLock = NSLock()
    private var aborted = false
    private var finishing = false
    private var metrics = SonioxQualityMetrics()
    private var metricsObserver: ((SonioxQualityMetrics) -> Void)?
    /// Mirror of `wsTask` guarded by `lifecycleLock` so `abort()` can kill the
    /// socket immediately without hopping onto (and waiting for) `queue`.
    private var abortableSocket: URLSessionWebSocketTask?

    /// ~120 ms of audio per frame, matching the lab client's chunking.
    private static let chunkSeconds: Double = 0.12
    /// Hard cap on buffered capture audio while the socket is down (5 s).
    private static let maxBufferedSeconds: Double = 5

    init(
        configuration: SonioxConfiguration,
        session: URLSession = .shared,
        maxReconnectAttempts: Int = 3,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        governor: SonioxSessionGovernor? = nil,
        onSegment: @escaping SegmentHandler
    ) {
        self.configuration = configuration
        self.session = session
        self.maxReconnectAttempts = maxReconnectAttempts
        monotonicNow = now
        self.governor = governor ?? SonioxSessionGovernor(configuration: configuration, now: now)
        self.onSegment = onSegment
    }

    // MARK: Metrics

    var qualityMetrics: SonioxQualityMetrics {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return metrics
    }

    var onMetricsChange: ((SonioxQualityMetrics) -> Void)? {
        get {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return metricsObserver
        }
        set {
            lifecycleLock.lock()
            metricsObserver = newValue
            lifecycleLock.unlock()
        }
    }

    /// Current governor state, for diagnostics and the beta report.
    var sessionState: SonioxSessionGovernor.State {
        governor.state
    }

    /// Test hook: runs `block` once everything already queued on the private
    /// serial queue has finished, so tests observe settled state without sleeps.
    func performForTesting(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    private func mutateMetrics(_ body: (inout SonioxQualityMetrics) -> Void) {
        lifecycleLock.lock()
        body(&metrics)
        let snapshot = metrics
        let observer = metricsObserver
        let isAborted = aborted
        lifecycleLock.unlock()
        guard let observer, !isAborted else { return }
        DispatchQueue.main.async { observer(snapshot) }
    }

    // MARK: Lifecycle

    func connect() {
        guard configuration.isConfigured else {
            Log.ai.error("Soniox: no api key and no temporary-key URL configured")
            return
        }
        queue.async { [weak self] in self?.openSocket() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        let rate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : LatencyBudget.audioSampleRate

        queue.async { [weak self] in
            guard let self, !isAborted else { return }
            captureSampleRate = rate
            let seconds = Double(samples.count) / rate

            switch governor.process(samples: samples, sampleRate: rate) {
            case let .send(chunk):
                enqueue(chunk, seconds: seconds)

            case .hold:
                // Suspended: the samples live on only in the pre-roll ring buffer.
                mutateMetrics { $0.recordSuppressedSilence(seconds: seconds) }

            case .suspend:
                mutateMetrics { $0.recordSuppressedSilence(seconds: seconds) }
                suspendSession()

            case let .resume(preRoll):
                let preRollSeconds = Double(preRoll.count) / rate
                enqueue(preRoll, seconds: preRollSeconds)
                resumeSession()
            }
        }
    }

    private func enqueue(_ samples: [Float], seconds: Double) {
        guard !samples.isEmpty else { return }
        mutateMetrics { $0.recordStreamedAudio(seconds: seconds) }
        pendingSamples.append(contentsOf: samples)
        trimOverflowLocked()
        drainChunks()
    }

    /// Clean end of stream: flush the tail, send the empty-frame terminator and
    /// let the server answer with `finished: true`.
    func finish() {
        lifecycleLock.lock()
        finishing = true
        lifecycleLock.unlock()

        queue.async { [weak self] in
            guard let self, !isAborted else { return }
            terminateSession(cause: .user, flushTail: true)
        }
    }

    /// Privacy Mode kill switch: no terminator, no flush, no further callbacks.
    func abort() {
        lifecycleLock.lock()
        aborted = true
        let socket = abortableSocket
        abortableSocket = nil
        lifecycleLock.unlock()

        socket?.cancel(with: .goingAway, reason: nil)
        queue.async { [weak self] in
            guard let self else { return }
            wsTask = nil
            isStreaming = false
            isConnecting = false
            terminatorSent = true
            awaitingFirstTokenSince = nil
            pendingSamples.removeAll(keepingCapacity: false)
            accumulator = SonioxTranscriptAccumulator()
            governor.reset()
        }
    }

    // MARK: Session governing (suspend / resume)

    /// The one place that speaks Soniox' end-of-stream contract: flush, send the
    /// empty text frame exactly once, commit the transcript, then close after a
    /// short grace period so the server's `finished` frame can still arrive.
    /// Shared by the user stop and the silence suspend — no duplicated policy.
    private func terminateSession(cause: SonioxQualityMetrics.SessionEndCause, flushTail: Bool) {
        if flushTail { flushPendingChunk() }
        let closing = wsTask
        let wasOpen = isStreaming && closing != nil

        if wasOpen, !terminatorSent {
            terminatorSent = true
            closing?.send(.string("")) { _ in }
        }
        // Stop the send path immediately; the socket itself lingers briefly.
        isStreaming = false
        wsTask = nil
        awaitingFirstTokenSince = nil
        pendingSamples.removeAll(keepingCapacity: true)
        deliver(accumulator.flush())

        if wasOpen {
            mutateMetrics { $0.recordSessionEnded(cause: cause) }
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            closing?.cancel(with: .normalClosure, reason: nil)
            lifecycleLock.lock()
            if abortableSocket === closing { abortableSocket = nil }
            lifecycleLock.unlock()
        }
    }

    /// Silence threshold reached: stop paying for dead air.
    private func suspendSession() {
        guard isStreaming || wsTask != nil else { return }
        Log.ai.notice("Soniox: suspending session after sustained silence")
        terminateSession(cause: .silence, flushTail: false)
    }

    /// Speech is back: reuse the normal connect path (broker + backoff).
    private func resumeSession() {
        guard !isAborted, !isFinishing else { return }
        Log.ai.notice("Soniox: resuming session on speech onset")
        reconnectAttempt = 0
        openSocket()
    }

    // MARK: Connection

    private func openSocket() {
        guard !isAborted, !isFinishing, !isConnecting, !isStreaming else { return }
        isConnecting = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await resolveCredential()
                queue.async { [weak self] in
                    self?.startSocket(with: credential)
                }
            } catch {
                let reason = SonioxServerMessage.redact(error.localizedDescription)
                Log.ai.error("Soniox: key resolution failed — \(reason, privacy: .public)")
                queue.async { [weak self] in
                    self?.isConnecting = false
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func resolveCredential() async throws -> SonioxTemporaryKey {
        if !configuration.temporaryKeyURL.isEmpty,
           let url = URL(string: configuration.temporaryKeyURL)
        {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "provider": "auto",
                "enableSpeakerDiarization": configuration.enableSpeakerDiarization,
                "languageHints": configuration.languageHints
            ])
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw SonioxError.temporaryKeyUnavailable("broker status \(http.statusCode)")
            }
            return try SonioxTemporaryKey.decode(data)
        }
        guard !configuration.apiKey.isEmpty else { throw SonioxError.notConfigured }
        return SonioxTemporaryKey(apiKey: configuration.apiKey, realtimeURL: nil)
    }

    private func startSocket(with credential: SonioxTemporaryKey) {
        isConnecting = false
        guard !isAborted, !isFinishing else { return }
        let endpoint = credential.realtimeURL ?? configuration.websocketURL
        guard let url = URL(string: endpoint) else {
            Log.ai.error("Soniox: invalid websocket URL")
            return
        }

        let task = session.webSocketTask(with: url)
        wsTask = task
        lifecycleLock.lock()
        abortableSocket = task
        lifecycleLock.unlock()
        task.resume()
        isStreaming = true
        terminatorSent = false
        governor.markSessionOpened()
        mutateMetrics { $0.recordSessionStarted() }

        let start = configuration.startMessage(
            apiKey: credential.apiKey,
            sampleRate: SonioxConfiguration.targetSampleRate
        )
        if let data = try? JSONSerialization.data(withJSONObject: start),
           let json = String(data: data, encoding: .utf8)
        {
            task.send(.string(json)) { [weak self] error in
                guard let error else { return }
                self?.handleTransportFailure(error)
            }
        }

        receiveNext(on: task)
        drainChunks()
    }

    private func closeSocket(code: URLSessionWebSocketTask.CloseCode) {
        wsTask?.cancel(with: code, reason: nil)
        wsTask = nil
        lifecycleLock.lock()
        abortableSocket = nil
        lifecycleLock.unlock()
        isStreaming = false
    }

    private func scheduleReconnect() {
        guard !isAborted, !isFinishing else { return }
        let budget = maxReconnectAttempts
        guard reconnectAttempt < budget else {
            Log.ai.error("Soniox: giving up after \(budget, privacy: .public) reconnect attempts")
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = pow(2.0, Double(attempt - 1)) * 0.5 // 0.5 s, 1 s, 2 s
        Log.ai.notice("Soniox: reconnecting (attempt \(attempt, privacy: .public))")
        mutateMetrics { $0.recordReconnect() }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            isStreaming = false
            wsTask = nil
            openSocket()
        }
    }

    // MARK: Send path

    private var chunkFrameCount: Int {
        max(1, Int(captureSampleRate * Self.chunkSeconds))
    }

    private func trimOverflowLocked() {
        let cap = Int(captureSampleRate * Self.maxBufferedSeconds)
        if pendingSamples.count > cap {
            pendingSamples.removeFirst(pendingSamples.count - cap)
        }
    }

    private func drainChunks() {
        guard isStreaming, let task = wsTask, !isAborted else { return }
        let frames = chunkFrameCount
        while pendingSamples.count >= frames {
            let chunk = Array(pendingSamples.prefix(frames))
            pendingSamples.removeFirst(frames)
            send(chunk, on: task)
        }
    }

    private func flushPendingChunk() {
        guard isStreaming, let task = wsTask, !pendingSamples.isEmpty, !isAborted else { return }
        let chunk = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        send(chunk, on: task)
    }

    private func send(_ samples: [Float], on task: URLSessionWebSocketTask) {
        let data = SonioxAudioConverter.convert(samples, from: captureSampleRate)
        guard !data.isEmpty else { return }
        // Anchor for the first-token latency of this session.
        if awaitingFirstTokenSince == nil { awaitingFirstTokenSince = monotonicNow() }
        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            self?.handleTransportFailure(error)
        }
    }

    // MARK: Receive path

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, !isAborted else { return }
            switch result {
            case let .success(message):
                queue.async { [weak self] in
                    guard let self else { return }
                    handle(message)
                    if isStreaming, wsTask === task { receiveNext(on: task) }
                }
            case let .failure(error):
                handleTransportFailure(error)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data? = switch message {
        case let .string(text): text.data(using: .utf8)
        case let .data(payload): payload
        @unknown default: nil
        }
        guard let data, let decoded = try? SonioxServerMessage.decode(data) else { return }

        if let reason = decoded.redactedErrorDescription {
            // Application errors (auth, quota, bad config) are fatal — never retried.
            Log.ai.error("Soniox: \(reason, privacy: .public)")
            mutateMetrics {
                $0.recordError(reason)
                $0.recordSessionEnded(cause: .error)
            }
            closeSocket(code: .normalClosure)
            return
        }

        // A frame arrived, so the connection is healthy again.
        reconnectAttempt = 0
        recordTokenMetrics(for: decoded)
        deliver(accumulator.ingest(decoded))

        if decoded.finished {
            closeSocket(code: .normalClosure)
        }
    }

    private func recordTokenMetrics(for message: SonioxServerMessage) {
        guard !message.tokens.isEmpty else { return }
        let latency = awaitingFirstTokenSince.map { monotonicNow() - $0 }
        awaitingFirstTokenSince = nil
        let tokens = message.tokens
        mutateMetrics { metrics in
            metrics.recordTokens(tokens)
            if let latency { metrics.recordFirstTokenLatency(latency) }
        }
    }

    private func handleTransportFailure(_ error: Error) {
        guard !isAborted else { return }
        let reason = SonioxServerMessage.redact(error.localizedDescription)
        Log.ai.error("Soniox: websocket failure — \(reason, privacy: .public)")
        queue.async { [weak self] in
            guard let self, !isAborted else { return }
            // Committed text survives the drop; only the volatile tail is lost.
            deliver(accumulator.flush())
            let wasOpen = isStreaming
            awaitingFirstTokenSince = nil
            closeSocket(code: .abnormalClosure)
            mutateMetrics {
                $0.recordError(reason)
                if wasOpen { $0.recordSessionEnded(cause: .error) }
            }
            scheduleReconnect()
        }
    }

    private func deliver(_ emissions: [SonioxTranscriptAccumulator.Emission]) {
        guard !emissions.isEmpty, !isAborted else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !isAborted else { return }
            for emission in emissions {
                onSegment(emission.text, emission.speakerID, emission.isFinal)
            }
        }
    }

    // MARK: Lifecycle flags

    private var isAborted: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return aborted
    }

    private var isFinishing: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return finishing
    }
}
