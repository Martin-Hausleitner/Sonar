import Foundation

// Cost/quality governance for the Soniox realtime engine (Soniox Beta).
//
// Soniox bills by streamed audio duration and caps a session at
// `max_session_duration_seconds`. Streaming an idle microphone therefore costs
// money and burns the session budget for nothing. `SonioxSessionGovernor`
// watches voice activity on the outgoing audio and decides — per chunk —
// whether the transcriber should send, hold, suspend or resume.
//
// Voice activity: RMS with hysteresis, computed here rather than through
// `sonar/Core/AI/VAD.swift`. Reasons, in order of weight:
//   1. That `VAD` instance is owned and mutated by `SessionCoordinator`
//      (`vad.feed(buffer)` in the capture chain); sharing its `isSpeaking`
//      state would couple two unrelated consumers to one hysteresis latch.
//   2. `VAD.feed` takes an `AVAudioPCMBuffer`, while the governor sits on the
//      already-extracted `[Float]` chunk the transcriber is about to convert —
//      so the decision is made on exactly the samples that would be billed.
//   3. `VAD` lives outside this module's file ownership and has hard-coded
//      thresholds, whereas the suspend policy must be configurable.
// The thresholds are deliberately identical to `VAD` (on 0.018 / off 0.010) so
// both detectors agree on what "speech" means.

/// Decides whether Soniox audio is streamed, withheld, or the session cycled.
final class SonioxSessionGovernor {
    enum State: String, Equatable {
        /// Session open, audio flowing.
        case streaming
        /// Session still open, but silence has begun; suspend is pending.
        case silentCountdown
        /// Session closed, nothing sent, pre-roll ring buffer filling.
        case suspended
        /// Resume ordered, socket not open yet; audio is buffered by the caller.
        case resuming
    }

    /// What the transcriber must do with the chunk it just handed over.
    enum Decision: Equatable {
        /// Forward these samples (identical to the input chunk).
        case send([Float])
        /// Drop these samples on the floor — the session is suspended.
        case hold
        /// Close the session with the terminator; the chunk is not sent.
        case suspend
        /// Open a new session and send these samples first (pre-roll + chunk).
        case resume([Float])
    }

    private(set) var state: State = .streaming
    private(set) var isSpeaking = false

    private let silenceStopSeconds: Double
    private let preRollSeconds: Double
    private let onThreshold: Float
    private let offThreshold: Float
    private let now: () -> TimeInterval

    private var silenceStartedAt: TimeInterval?
    private var preRoll: [Float] = []
    private var preRollCapacity = 0

    init(configuration: SonioxConfiguration, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        silenceStopSeconds = configuration.silenceStopSeconds
        preRollSeconds = configuration.preRollSeconds
        onThreshold = configuration.voiceOnThreshold
        offThreshold = configuration.voiceOffThreshold
        self.now = now
    }

    /// True when the configuration disabled suspension altogether.
    var isSuspensionEnabled: Bool {
        silenceStopSeconds > 0
    }

    /// Number of samples currently retained for the resume pre-roll.
    var preRollSampleCount: Int {
        preRoll.count
    }

    /// Feeds one capture chunk and returns the action the transcriber must take.
    func process(samples: [Float], sampleRate: Double) -> Decision {
        guard !samples.isEmpty, sampleRate > 0 else { return .hold }

        updateSpeaking(with: samples)
        rememberForPreRoll(samples, sampleRate: sampleRate)
        let timestamp = now()

        switch state {
        case .streaming:
            if isSpeaking || !isSuspensionEnabled {
                silenceStartedAt = nil
                return .send(samples)
            }
            state = .silentCountdown
            silenceStartedAt = timestamp
            return .send(samples)

        case .silentCountdown:
            if isSpeaking {
                state = .streaming
                silenceStartedAt = nil
                return .send(samples)
            }
            // Re-anchor if the countdown somehow lost its start time —
            // otherwise `since` would track `timestamp` forever and the
            // governor could never reach `.suspended`.
            let since = silenceStartedAt ?? timestamp
            if silenceStartedAt == nil { silenceStartedAt = timestamp }
            if timestamp - since >= silenceStopSeconds {
                state = .suspended
                silenceStartedAt = nil
                return .suspend
            }
            return .send(samples)

        case .suspended:
            guard isSpeaking else { return .hold }
            state = .resuming
            silenceStartedAt = nil
            let preRollSamples = preRoll
            preRoll.removeAll(keepingCapacity: true)
            return .resume(preRollSamples)

        case .resuming:
            // The socket is not up yet; the transcriber buffers these samples
            // and flushes them once the session is open.
            silenceStartedAt = nil
            return .send(samples)
        }
    }

    /// Called by the transcriber once the resumed socket is open.
    func markSessionOpened() {
        if state == .resuming || state == .suspended {
            state = .streaming
        }
        silenceStartedAt = nil
    }

    /// Called on abort/stop: forget audio and speech state.
    func reset() {
        state = .streaming
        isSpeaking = false
        silenceStartedAt = nil
        preRoll.removeAll(keepingCapacity: false)
        preRollCapacity = 0
    }

    /// Seconds of silence accumulated so far, for reporting.
    func silenceElapsed() -> Double {
        guard let silenceStartedAt else { return 0 }
        return max(0, now() - silenceStartedAt)
    }

    // MARK: - Private

    private func updateSpeaking(with samples: [Float]) {
        let rms = SonioxSessionGovernor.rms(samples)
        if rms > onThreshold { isSpeaking = true }
        if rms < offThreshold { isSpeaking = false }
    }

    private func rememberForPreRoll(_ samples: [Float], sampleRate: Double) {
        preRollCapacity = max(0, Int(sampleRate * preRollSeconds))
        guard preRollCapacity > 0 else {
            preRoll.removeAll(keepingCapacity: true)
            return
        }
        preRoll.append(contentsOf: samples)
        if preRoll.count > preRollCapacity {
            preRoll.removeFirst(preRoll.count - preRollCapacity)
        }
    }

    /// Root-mean-square level of a chunk, the same measure `VAD` uses.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Quality metrics

/// Everything needed to answer "how good — and how expensive — is Soniox?".
/// Maintained by `SonioxRealtimeTranscriber`, published by
/// `LiveTranscriptionEngine`.
struct SonioxQualityMetrics: Equatable {
    enum SessionEndCause: String, Equatable {
        case silence
        case error
        case user
    }

    var sessionsStarted = 0
    var sessionsEndedBySilence = 0
    var sessionsEndedByError = 0
    var sessionsEndedByUser = 0

    /// Audio actually shipped to Soniox — the billed quantity.
    var streamedAudioSeconds: Double = 0
    /// Audio withheld because the session was suspended — the saving.
    var suppressedSilenceSeconds: Double = 0

    /// Exponential moving average of the delay between sending audio and the
    /// first token of that session, in seconds. `nil` until the first token.
    var firstTokenLatencyEMA: Double?
    var lastFirstTokenLatency: Double?

    var totalTokens = 0
    var finalTokens = 0
    var reconnects = 0
    /// Last error, already redacted — never contains key-shaped substrings.
    var lastErrorMessage: String?
    /// Distinct diarization labels observed.
    var speakerIDs: Set<String> = []

    /// Smoothing factor of the latency EMA (weight of the newest sample).
    static let latencySmoothing: Double = 0.3

    var sessionsEnded: Int {
        sessionsEndedBySilence + sessionsEndedByError + sessionsEndedByUser
    }

    var speakerCount: Int {
        speakerIDs.count
    }

    var totalAudioSeconds: Double {
        streamedAudioSeconds + suppressedSilenceSeconds
    }

    /// Share of tokens Soniox committed as final — a stability indicator.
    var finalTokenRatio: Double {
        totalTokens > 0 ? Double(finalTokens) / Double(totalTokens) : 0
    }

    /// Share of captured audio that was never billed. The headline saving.
    var suppressionRatio: Double {
        totalAudioSeconds > 0 ? suppressedSilenceSeconds / totalAudioSeconds : 0
    }

    // MARK: Mutations

    mutating func recordSessionStarted() {
        sessionsStarted += 1
    }

    mutating func recordSessionEnded(cause: SessionEndCause) {
        switch cause {
        case .silence: sessionsEndedBySilence += 1
        case .error: sessionsEndedByError += 1
        case .user: sessionsEndedByUser += 1
        }
    }

    mutating func recordStreamedAudio(seconds: Double) {
        guard seconds > 0 else { return }
        streamedAudioSeconds += seconds
    }

    mutating func recordSuppressedSilence(seconds: Double) {
        guard seconds > 0 else { return }
        suppressedSilenceSeconds += seconds
    }

    mutating func recordFirstTokenLatency(_ seconds: Double) {
        guard seconds >= 0 else { return }
        lastFirstTokenLatency = seconds
        if let current = firstTokenLatencyEMA {
            firstTokenLatencyEMA = current * (1 - Self.latencySmoothing) + seconds * Self.latencySmoothing
        } else {
            firstTokenLatencyEMA = seconds
        }
    }

    mutating func recordTokens(_ tokens: [SonioxToken]) {
        for token in tokens where !token.isEndpoint {
            totalTokens += 1
            if token.isFinal { finalTokens += 1 }
            if let speaker = token.speakerID, !speaker.isEmpty {
                speakerIDs.insert(speaker)
            }
        }
    }

    mutating func recordReconnect() {
        reconnects += 1
    }

    mutating func recordError(_ message: String) {
        lastErrorMessage = SonioxServerMessage.redact(message)
    }
}
