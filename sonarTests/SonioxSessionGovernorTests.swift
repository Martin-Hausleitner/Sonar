import AVFoundation
@testable import Sonar
import XCTest

/// Soniox Beta: the silence-suspend / speech-resume state machine and the
/// quality metrics. Fully deterministic — the clock is injected and no
/// network, no audio hardware and no real WebSocket is involved.
final class SonioxSessionGovernorTests: XCTestCase {
    private var clock: TestClock!
    private let sampleRate: Double = 48000

    override func setUp() {
        super.setUp()
        clock = TestClock()
    }

    // MARK: - Suspend on silence

    func testSilenceBeyondThresholdSuspends() {
        let governor = makeGovernor(silenceStopSeconds: 10)

        // Speech first, so the governor starts in a streaming state.
        XCTAssertEqual(governor.process(samples: speech(), sampleRate: sampleRate), .send(speech()))
        XCTAssertEqual(governor.state, .streaming)

        // Silence starts the countdown but keeps streaming.
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .silentCountdown)

        clock.advance(by: 9)
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .silentCountdown, "Below the threshold nothing is suspended")

        clock.advance(by: 2)
        XCTAssertEqual(governor.process(samples: silence(), sampleRate: sampleRate), .suspend)
        XCTAssertEqual(governor.state, .suspended)
    }

    func testSpeechDuringCountdownCancelsSuspend() {
        let governor = makeGovernor(silenceStopSeconds: 10)
        _ = governor.process(samples: speech(), sampleRate: sampleRate)

        clock.advance(by: 5)
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .silentCountdown)

        clock.advance(by: 3)
        _ = governor.process(samples: speech(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .streaming, "Speech must cancel the countdown")

        // The countdown restarts from scratch, so the old elapsed time is gone.
        clock.advance(by: 9)
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .silentCountdown)
        XCTAssertNotEqual(governor.process(samples: silence(), sampleRate: sampleRate), .suspend)
    }

    func testOngoingSpeechNeverSuspends() {
        let governor = makeGovernor(silenceStopSeconds: 1)

        for _ in 0 ..< 20 {
            clock.advance(by: 1)
            let decision = governor.process(samples: speech(), sampleRate: sampleRate)
            XCTAssertNotEqual(decision, .suspend)
            XCTAssertNotEqual(decision, .hold)
        }
        XCTAssertEqual(governor.state, .streaming)
    }

    func testNonPositiveThresholdDisablesSuspension() {
        let governor = makeGovernor(silenceStopSeconds: 0)
        XCTAssertFalse(governor.isSuspensionEnabled)

        _ = governor.process(samples: speech(), sampleRate: sampleRate)
        for _ in 0 ..< 10 {
            clock.advance(by: 60)
            XCTAssertEqual(governor.process(samples: silence(), sampleRate: sampleRate), .send(silence()))
        }
        XCTAssertEqual(governor.state, .streaming)
    }

    // MARK: - Suspended state

    func testSuspendedStateHoldsAudioAndSendsNothing() {
        let governor = suspendedGovernor()

        for _ in 0 ..< 5 {
            clock.advance(by: 1)
            XCTAssertEqual(governor.process(samples: silence(), sampleRate: sampleRate), .hold)
        }
        XCTAssertEqual(governor.state, .suspended)
    }

    func testPreRollBufferStaysBounded() {
        let governor = suspendedGovernor(preRollSeconds: 1.0)
        let capacity = Int(sampleRate * 1.0)

        for _ in 0 ..< 40 { // 40 × 0.1 s = 4 s of audio into a 1 s buffer
            clock.advance(by: 0.1)
            _ = governor.process(samples: silence(), sampleRate: sampleRate)
        }
        XCTAssertLessThanOrEqual(governor.preRollSampleCount, capacity)
        XCTAssertGreaterThan(governor.preRollSampleCount, 0)
    }

    // MARK: - Resume on speech

    func testSpeechWhileSuspendedResumesWithPreRollFirst() {
        let governor = suspendedGovernor(preRollSeconds: 1.0)

        // Fill the pre-roll with recognizable silence, then speak.
        for _ in 0 ..< 5 {
            clock.advance(by: 0.1)
            _ = governor.process(samples: silence(count: 4800), sampleRate: sampleRate)
        }
        let preRollBefore = governor.preRollSampleCount
        XCTAssertGreaterThan(preRollBefore, 0)

        clock.advance(by: 0.1)
        let onset = speech(count: 4800)
        let decision = governor.process(samples: onset, sampleRate: sampleRate)

        guard case let .resume(preRoll) = decision else {
            return XCTFail("Speech while suspended must resume, got \(decision)")
        }
        XCTAssertEqual(governor.state, .resuming)
        XCTAssertEqual(
            preRoll.count,
            preRollBefore + onset.count,
            "The resume payload is the buffered pre-roll plus the onset chunk"
        )
        XCTAssertEqual(
            Array(preRoll.suffix(onset.count)),
            onset,
            "The onset chunk must come last — pre-roll audio is replayed first"
        )
        XCTAssertEqual(governor.preRollSampleCount, 0, "The pre-roll is consumed by the resume")
    }

    func testResumingStateBuffersFurtherAudio() {
        let governor = suspendedGovernor()
        clock.advance(by: 0.1)
        _ = governor.process(samples: speech(), sampleRate: sampleRate)
        XCTAssertEqual(governor.state, .resuming)

        // While the socket is coming up the caller keeps the audio.
        XCTAssertEqual(governor.process(samples: speech(), sampleRate: sampleRate), .send(speech()))

        governor.markSessionOpened()
        XCTAssertEqual(governor.state, .streaming)
    }

    func testResetReturnsToStreamingAndDropsPreRoll() {
        let governor = suspendedGovernor()
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        XCTAssertGreaterThan(governor.preRollSampleCount, 0)

        governor.reset()

        XCTAssertEqual(governor.state, .streaming)
        XCTAssertEqual(governor.preRollSampleCount, 0)
        XCTAssertFalse(governor.isSpeaking)
    }

    // MARK: - Voice activity detection

    func testRMSHysteresisMatchesVADThresholds() {
        let governor = makeGovernor(silenceStopSeconds: 10)

        // Between the off (0.010) and on (0.018) threshold: no state change.
        _ = governor.process(samples: tone(amplitude: 0.014), sampleRate: sampleRate)
        XCTAssertFalse(governor.isSpeaking, "Sub-onset level must not latch speech on")

        _ = governor.process(samples: tone(amplitude: 0.05), sampleRate: sampleRate)
        XCTAssertTrue(governor.isSpeaking)

        // Still above the off threshold → hysteresis keeps it speaking.
        _ = governor.process(samples: tone(amplitude: 0.014), sampleRate: sampleRate)
        XCTAssertTrue(governor.isSpeaking, "Hysteresis must not drop out between the thresholds")

        _ = governor.process(samples: tone(amplitude: 0.001), sampleRate: sampleRate)
        XCTAssertFalse(governor.isSpeaking)
    }

    func testRMSOfKnownSignal() {
        XCTAssertEqual(SonioxSessionGovernor.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SonioxSessionGovernor.rms([]), 0)
    }

    func testEmptyChunkIsHeld() {
        let governor = makeGovernor(silenceStopSeconds: 10)
        XCTAssertEqual(governor.process(samples: [], sampleRate: sampleRate), .hold)
        XCTAssertEqual(governor.process(samples: speech(), sampleRate: 0), .hold)
    }

    // MARK: - Configuration

    func testSilenceThresholdIsConfigurableViaEnvironment() {
        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_SILENCE_STOP_SEC": "45"],
            defaults: isolatedDefaults()
        )
        XCTAssertEqual(configuration.silenceStopSeconds, 45)
        XCTAssertTrue(configuration.isSilenceSuspensionEnabled)
    }

    func testSilenceThresholdDefaultsTo120Seconds() {
        let configuration = SonioxConfiguration.resolved(environment: [:], defaults: isolatedDefaults())
        XCTAssertEqual(configuration.silenceStopSeconds, 120)
        XCTAssertEqual(configuration.preRollSeconds, 1.0)
        XCTAssertEqual(configuration.voiceOnThreshold, 0.018, accuracy: 0.0001)
        XCTAssertEqual(configuration.voiceOffThreshold, 0.010, accuracy: 0.0001)
    }

    func testSilenceThresholdReadsUserDefaultsKey() {
        let defaults = isolatedDefaults()
        defaults.set(30.0, forKey: SonioxConfiguration.silenceStopDefaultsKey)
        let configuration = SonioxConfiguration.resolved(environment: [:], defaults: defaults)
        XCTAssertEqual(configuration.silenceStopSeconds, 30)
    }

    func testZeroThresholdDisablesSuspensionInConfiguration() {
        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_SILENCE_STOP_SEC": "0"],
            defaults: isolatedDefaults()
        )
        XCTAssertFalse(configuration.isSilenceSuspensionEnabled)
    }

    // MARK: - Helpers

    private func makeGovernor(
        silenceStopSeconds: Double,
        preRollSeconds: Double = 1.0
    ) -> SonioxSessionGovernor {
        var configuration = SonioxConfiguration.resolved(environment: [:], defaults: isolatedDefaults())
        configuration.silenceStopSeconds = silenceStopSeconds
        configuration.preRollSeconds = preRollSeconds
        let capturedClock = clock!
        return SonioxSessionGovernor(configuration: configuration, now: { capturedClock.now })
    }

    /// A governor already driven into `.suspended`.
    private func suspendedGovernor(preRollSeconds: Double = 1.0) -> SonioxSessionGovernor {
        let governor = makeGovernor(silenceStopSeconds: 10, preRollSeconds: preRollSeconds)
        _ = governor.process(samples: speech(), sampleRate: sampleRate)
        _ = governor.process(samples: silence(), sampleRate: sampleRate)
        clock.advance(by: 11)
        XCTAssertEqual(governor.process(samples: silence(), sampleRate: sampleRate), .suspend)
        return governor
    }

    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "soniox.governor.tests")!
        defaults.removePersistentDomain(forName: "soniox.governor.tests")
        return defaults
    }

    private func speech(count: Int = 480) -> [Float] {
        tone(amplitude: 0.2, count: count)
    }

    private func silence(count: Int = 480) -> [Float] {
        tone(amplitude: 0.001, count: count)
    }

    /// A square wave, so RMS equals the amplitude exactly.
    private func tone(amplitude: Float, count: Int = 480) -> [Float] {
        (0 ..< count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }
}

// MARK: - Quality metrics

final class SonioxQualityMetricsTests: XCTestCase {
    func testStreamedAndSuppressedAudioAreCountedSeparately() {
        var metrics = SonioxQualityMetrics()
        metrics.recordStreamedAudio(seconds: 30)
        metrics.recordSuppressedSilence(seconds: 90)

        XCTAssertEqual(metrics.streamedAudioSeconds, 30)
        XCTAssertEqual(metrics.suppressedSilenceSeconds, 90)
        XCTAssertEqual(metrics.totalAudioSeconds, 120)
    }

    func testSuppressionRatioExpressesTheSaving() {
        var metrics = SonioxQualityMetrics()
        metrics.recordStreamedAudio(seconds: 30)
        metrics.recordSuppressedSilence(seconds: 90)

        XCTAssertEqual(metrics.suppressionRatio, 0.75, accuracy: 0.0001)
        XCTAssertEqual(SonioxQualityMetrics().suppressionRatio, 0, "No audio must not divide by zero")
    }

    func testNonPositiveDurationsAreIgnored() {
        var metrics = SonioxQualityMetrics()
        metrics.recordStreamedAudio(seconds: 0)
        metrics.recordStreamedAudio(seconds: -5)
        metrics.recordSuppressedSilence(seconds: -1)

        XCTAssertEqual(metrics.streamedAudioSeconds, 0)
        XCTAssertEqual(metrics.suppressedSilenceSeconds, 0)
    }

    func testFirstTokenLatencyUsesExponentialMovingAverage() {
        var metrics = SonioxQualityMetrics()
        XCTAssertNil(metrics.firstTokenLatencyEMA)

        metrics.recordFirstTokenLatency(1.0)
        XCTAssertEqual(metrics.firstTokenLatencyEMA ?? 0, 1.0, accuracy: 0.0001, "The first sample seeds the EMA")

        metrics.recordFirstTokenLatency(2.0)
        // 1.0 * 0.7 + 2.0 * 0.3
        XCTAssertEqual(metrics.firstTokenLatencyEMA ?? 0, 1.3, accuracy: 0.0001)
        XCTAssertEqual(metrics.lastFirstTokenLatency ?? 0, 2.0, accuracy: 0.0001)
    }

    func testNegativeLatencyDoesNotCorruptTheEMA() {
        var metrics = SonioxQualityMetrics()
        metrics.recordFirstTokenLatency(0.4)
        metrics.recordFirstTokenLatency(-3)

        XCTAssertEqual(metrics.firstTokenLatencyEMA ?? 0, 0.4, accuracy: 0.0001)
    }

    func testSessionEndCausesAreAttributedAndSumUp() {
        var metrics = SonioxQualityMetrics()
        metrics.recordSessionStarted()
        metrics.recordSessionStarted()
        metrics.recordSessionStarted()
        metrics.recordSessionEnded(cause: .silence)
        metrics.recordSessionEnded(cause: .error)
        metrics.recordSessionEnded(cause: .user)

        XCTAssertEqual(metrics.sessionsStarted, 3)
        XCTAssertEqual(metrics.sessionsEndedBySilence, 1)
        XCTAssertEqual(metrics.sessionsEndedByError, 1)
        XCTAssertEqual(metrics.sessionsEndedByUser, 1)
        XCTAssertEqual(metrics.sessionsEnded, 3)
    }

    func testTokenMetricsCountFinalsAndSpeakers() {
        var metrics = SonioxQualityMetrics()
        metrics.recordTokens([
            SonioxToken(text: "Hallo", isFinal: true, speakerID: "1"),
            SonioxToken(text: " Welt", isFinal: false, speakerID: "1"),
            SonioxToken(text: "Servus", isFinal: true, speakerID: "2"),
            SonioxToken(text: "<end>", isFinal: true, speakerID: "2")
        ])

        XCTAssertEqual(metrics.totalTokens, 3, "The endpoint marker is not a transcript token")
        XCTAssertEqual(metrics.finalTokens, 2)
        XCTAssertEqual(metrics.finalTokenRatio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.speakerCount, 2)
        XCTAssertEqual(metrics.speakerIDs, ["1", "2"])
    }

    func testFinalTokenRatioIsZeroWithoutTokens() {
        XCTAssertEqual(SonioxQualityMetrics().finalTokenRatio, 0)
        XCTAssertEqual(SonioxQualityMetrics().speakerCount, 0)
    }

    func testReconnectsAreCounted() {
        var metrics = SonioxQualityMetrics()
        metrics.recordReconnect()
        metrics.recordReconnect()
        XCTAssertEqual(metrics.reconnects, 2)
    }

    func testRecordedErrorsAreRedacted() {
        var metrics = SonioxQualityMetrics()
        let secret = String(repeating: "k", count: 40)
        metrics.recordError("auth failed for \(secret)")

        let stored = metrics.lastErrorMessage ?? ""
        XCTAssertFalse(stored.contains(secret))
        XCTAssertTrue(stored.contains("[REDACTED]"))
    }
}

// MARK: - Transcriber-level suspend/resume behaviour

/// Drives the real `SonioxRealtimeTranscriber` with an injected clock and a
/// `URLSession` that cannot reach the network, and asserts the observable
/// bookkeeping: audio accounting, terminator-once, and suspend attribution.
final class SonioxTranscriberSessionTests: XCTestCase {
    private let sampleRate: Double = 48000

    func testSuppressedAudioIsAccountedWhileSuspended() {
        let clock = TestClock()
        let governor = makeGovernor(silenceStopSeconds: 1, clock: clock)
        let transcriber = makeTranscriber(governor: governor, clock: clock)

        // Drive the governor into `.suspended` without a socket: every chunk is
        // silence, so nothing is ever streamed.
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800)) // 0.1 s
        // The append is processed asynchronously — drain before advancing the
        // clock so the silence countdown anchors at the pre-advance timestamp.
        drainQueue(transcriber)
        clock.advance(by: 5)
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber)

        let metrics = transcriber.qualityMetrics
        XCTAssertEqual(transcriber.sessionState, .suspended)
        XCTAssertGreaterThan(metrics.suppressedSilenceSeconds, 0)
        XCTAssertEqual(
            metrics.streamedAudioSeconds + metrics.suppressedSilenceSeconds,
            0.3,
            accuracy: 0.01,
            "Every captured second lands in exactly one bucket"
        )
    }

    func testSuspendWithoutAnOpenSocketEndsNoSessionAndSendsNoTerminator() {
        let clock = TestClock()
        let governor = makeGovernor(silenceStopSeconds: 1, clock: clock)
        let transcriber = makeTranscriber(governor: governor, clock: clock)

        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber) // anchor the silence countdown before advancing
        clock.advance(by: 5)
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber)

        // No session was ever open, so nothing may be attributed as an end.
        XCTAssertEqual(transcriber.qualityMetrics.sessionsStarted, 0)
        XCTAssertEqual(transcriber.qualityMetrics.sessionsEnded, 0)
    }

    func testSpeechAfterSuspendLeavesTheSuspendedState() {
        let clock = TestClock()
        let governor = makeGovernor(silenceStopSeconds: 1, clock: clock)
        let transcriber = makeTranscriber(governor: governor, clock: clock)

        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber) // anchor the silence countdown before advancing
        clock.advance(by: 5)
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber)
        XCTAssertEqual(transcriber.sessionState, .suspended)

        transcriber.append(makeBuffer(amplitude: 0.2, frameCount: 4800))
        drainQueue(transcriber)

        XCTAssertNotEqual(transcriber.sessionState, .suspended, "Speech must trigger a resume")
        XCTAssertGreaterThan(transcriber.qualityMetrics.streamedAudioSeconds, 0, "The pre-roll counts as streamed")
    }

    func testAbortResetsTheGovernor() {
        let clock = TestClock()
        let governor = makeGovernor(silenceStopSeconds: 1, clock: clock)
        let transcriber = makeTranscriber(governor: governor, clock: clock)

        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber) // anchor the silence countdown before advancing
        clock.advance(by: 5)
        transcriber.append(makeBuffer(amplitude: 0.001, frameCount: 4800))
        drainQueue(transcriber)
        XCTAssertEqual(transcriber.sessionState, .suspended)

        transcriber.abort()
        drainQueue(transcriber)

        XCTAssertEqual(transcriber.sessionState, .streaming)
        XCTAssertEqual(governor.preRollSampleCount, 0)
    }

    func testMetricsObserverIsNotified() {
        let clock = TestClock()
        let transcriber = makeTranscriber(governor: makeGovernor(silenceStopSeconds: 120, clock: clock), clock: clock)
        let expectation = expectation(description: "metrics observed")
        expectation.assertForOverFulfill = false

        transcriber.onMetricsChange = { metrics in
            if metrics.streamedAudioSeconds > 0 { expectation.fulfill() }
        }
        transcriber.append(makeBuffer(amplitude: 0.2, frameCount: 4800))

        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Helpers

    private func makeGovernor(silenceStopSeconds: Double, clock: TestClock) -> SonioxSessionGovernor {
        var configuration = makeConfiguration()
        configuration.silenceStopSeconds = silenceStopSeconds
        return SonioxSessionGovernor(configuration: configuration, now: { clock.now })
    }

    private func makeTranscriber(governor: SonioxSessionGovernor, clock: TestClock) -> SonioxRealtimeTranscriber {
        SonioxRealtimeTranscriber(
            configuration: makeConfiguration(),
            session: offlineSession(),
            maxReconnectAttempts: 1,
            now: { clock.now },
            governor: governor,
            onSegment: { _, _, _ in }
        )
    }

    private func makeConfiguration() -> SonioxConfiguration {
        let defaults = UserDefaults(suiteName: "soniox.transcriber.tests")!
        defaults.removePersistentDomain(forName: "soniox.transcriber.tests")
        // A loopback broker URL that nothing listens on: key resolution fails
        // fast and offline, so no session is ever established in tests.
        return SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_TEMP_KEY_URL": "http://127.0.0.1:1/api/temporary-key"],
            defaults: defaults
        )
    }

    private func offlineSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.25
        configuration.timeoutIntervalForResource = 0.25
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration)
    }

    /// The transcriber does its work on a private serial queue; appending a
    /// short barrier is enough to observe the result deterministically.
    private func drainQueue(_ transcriber: SonioxRealtimeTranscriber) {
        let expectation = expectation(description: "queue drained")
        transcriber.performForTesting { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func makeBuffer(amplitude: Float, frameCount: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0 ..< frameCount {
                channel[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
            }
        }
        return buffer
    }
}

/// Injected monotonic clock — no `sleep`, no wall-clock flakiness.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}
