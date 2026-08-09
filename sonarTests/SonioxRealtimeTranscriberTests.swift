import AVFoundation
@testable import Sonar
import XCTest

/// Pure-logic tests for the Soniox realtime engine: JSON frame decoding,
/// token → segment accumulation (incl. diarization), 48 kHz → 16 kHz PCM16
/// conversion, and configuration resolution. No network is ever touched —
/// the transcriber is replaced by a fake in the engine-level tests.
final class SonioxRealtimeTranscriberTests: XCTestCase {
    // MARK: - Server message decoding

    func testDecodesTokensWithNumericSpeakerLabel() throws {
        let json = """
        {"tokens":[{"text":"Hallo","is_final":true,"speaker":1},
                   {"text":" Welt","is_final":false,"speaker":2}]}
        """
        let message = try SonioxServerMessage.decode(Data(json.utf8))

        XCTAssertEqual(message.tokens.count, 2)
        XCTAssertEqual(message.tokens[0].text, "Hallo")
        XCTAssertTrue(message.tokens[0].isFinal)
        XCTAssertEqual(message.tokens[0].speakerID, "1")
        XCTAssertFalse(message.tokens[1].isFinal)
        XCTAssertEqual(message.tokens[1].speakerID, "2")
        XCTAssertFalse(message.isError)
    }

    func testDecodesAlternativeSpeakerFieldNames() throws {
        let json = """
        {"tokens":[{"text":"a","is_final":true,"speaker_id":"7"},
                   {"text":"b","is_final":true,"speaker_label":"Guest"}]}
        """
        let message = try SonioxServerMessage.decode(Data(json.utf8))
        XCTAssertEqual(message.tokens[0].speakerID, "7")
        XCTAssertEqual(message.tokens[1].speakerID, "Guest")
    }

    func testDecodesFinishedAndErrorFrames() throws {
        let finished = try SonioxServerMessage.decode(Data(#"{"tokens":[],"finished":true}"#.utf8))
        XCTAssertTrue(finished.finished)
        XCTAssertFalse(finished.isError)

        let failed = try SonioxServerMessage.decode(
            Data(#"{"error_code":401,"error_type":"unauthorized","error_message":"bad key"}"#.utf8)
        )
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.redactedErrorDescription, "bad key")
    }

    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try SonioxServerMessage.decode(Data("[1,2,3]".utf8)))
    }

    func testErrorDescriptionRedactsKeyShapedStrings() throws {
        let secret = String(repeating: "a", count: 40)
        let message = try SonioxServerMessage.decode(
            Data(#"{"error_message":"rejected key \#(secret) here"}"#.utf8)
        )
        let description = try XCTUnwrap(message.redactedErrorDescription)
        XCTAssertFalse(description.contains(secret))
        XCTAssertTrue(description.contains("[REDACTED]"))
    }

    // MARK: - Transcript accumulation

    func testPartialTokensProduceReplaceableNonFinalSegment() {
        var accumulator = SonioxTranscriptAccumulator()

        let first = accumulator.ingest(message(tokens: [("Hallo", false, "1")]))
        XCTAssertEqual(first, [.init(text: "Hallo", speakerID: "1", isFinal: false)])

        // Soniox re-sends the whole non-final tail, so the previous tail is replaced,
        // never appended to.
        let second = accumulator.ingest(message(tokens: [("Hallo Welt", false, "1")]))
        XCTAssertEqual(second, [.init(text: "Hallo Welt", speakerID: "1", isFinal: false)])
    }

    func testEndpointTokenCommitsFinalSegment() {
        var accumulator = SonioxTranscriptAccumulator()
        _ = accumulator.ingest(message(tokens: [("Guten ", true, "1")]))
        let emissions = accumulator.ingest(message(tokens: [("Morgen", true, "1"), ("<end>", true, "1")]))

        XCTAssertEqual(emissions, [.init(text: "Guten Morgen", speakerID: "1", isFinal: true)])
        // Committed text is gone afterwards — no duplication on the next frame.
        XCTAssertEqual(accumulator.ingest(message(tokens: [])), [])
    }

    func testSpeakerChangeFlushesPreviousSpeakerAsFinalSegment() {
        var accumulator = SonioxTranscriptAccumulator()
        _ = accumulator.ingest(message(tokens: [("Hallo", true, "1")]))
        let emissions = accumulator.ingest(message(tokens: [("Servus", true, "2")]))

        XCTAssertEqual(emissions.first, .init(text: "Hallo", speakerID: "1", isFinal: true))
        XCTAssertEqual(emissions.last, .init(text: "Servus", speakerID: "2", isFinal: false))
    }

    func testFinishedFrameFlushesCommittedText() {
        var accumulator = SonioxTranscriptAccumulator()
        _ = accumulator.ingest(message(tokens: [("Ende", true, "1")]))
        let emissions = accumulator.ingest(SonioxServerMessage(tokens: [], finished: true))

        XCTAssertEqual(emissions, [.init(text: "Ende", speakerID: "1", isFinal: true)])
    }

    func testFlushCommitsPendingTextOnStop() {
        var accumulator = SonioxTranscriptAccumulator()
        _ = accumulator.ingest(message(tokens: [("halb fertig", true, "3")]))

        XCTAssertEqual(accumulator.flush(), [.init(text: "halb fertig", speakerID: "3", isFinal: true)])
        XCTAssertEqual(accumulator.flush(), [], "A second flush must not re-emit committed text")
    }

    func testTranslationTokensAreIgnoredByDefault() {
        var accumulator = SonioxTranscriptAccumulator()
        var translated = SonioxToken(text: "Hello", isFinal: true, speakerID: "1")
        translated.translationStatus = "translation"
        let original = SonioxToken(text: "Hallo", isFinal: true, speakerID: "1")

        let emissions = accumulator.ingest(SonioxServerMessage(tokens: [original, translated]))
        XCTAssertEqual(emissions, [.init(text: "Hallo", speakerID: "1", isFinal: false)])
    }

    func testEmptyFrameProducesNoEmission() {
        var accumulator = SonioxTranscriptAccumulator()
        XCTAssertEqual(accumulator.ingest(SonioxServerMessage()), [])
    }

    // MARK: - PCM conversion

    func testDownsamplesFortyEightToSixteenKilohertz() {
        let samples = [Float](repeating: 0.5, count: 4800) // 100 ms @ 48 kHz
        let converted = SonioxAudioConverter.downsample(samples, from: 48000, to: 16000)

        XCTAssertEqual(converted.count, 1600, "3:1 decimation must yield 100 ms @ 16 kHz")
        XCTAssertEqual(converted.first ?? 0, 0.5, accuracy: 0.0001)
    }

    func testDownsampleAveragesRatherThanDecimates() {
        // 6 samples @ 48 kHz → 2 samples @ 16 kHz, each the mean of 3 inputs.
        let samples: [Float] = [0, 0.3, 0.6, -0.3, -0.6, -0.9]
        let converted = SonioxAudioConverter.downsample(samples, from: 48000, to: 16000)

        XCTAssertEqual(converted.count, 2)
        XCTAssertEqual(converted[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(converted[1], -0.6, accuracy: 0.0001)
    }

    func testDownsampleIsIdentityWhenRatesMatch() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(SonioxAudioConverter.downsample(samples, from: 16000, to: 16000), samples)
    }

    func testPCM16IsLittleEndianAndClamped() {
        let data = SonioxAudioConverter.pcm16LE([0, 1.0, -1.0, 2.0, -2.0])
        XCTAssertEqual(data.count, 10, "5 samples × 2 bytes")

        let values: [Int16] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 32767)
        XCTAssertEqual(values[2], -32768)
        XCTAssertEqual(values[3], 32767, "Out-of-range positive input must clamp, not wrap")
        XCTAssertEqual(values[4], -32768, "Out-of-range negative input must clamp, not wrap")

        // Little-endian byte order for +1.0 → 0x7FFF
        XCTAssertEqual([UInt8](data)[2], 0xFF)
        XCTAssertEqual([UInt8](data)[3], 0x7F)
    }

    func testConvertProducesSixteenKilohertzPCM16Bytes() {
        let samples = [Float](repeating: 0, count: 4800)
        let data = SonioxAudioConverter.convert(samples, from: 48000)
        XCTAssertEqual(data.count, 3200, "1600 samples × 2 bytes")
    }

    // MARK: - Configuration

    func testConfigurationPrefersEnvironmentOverUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "soniox.config.tests"))
        defaults.removePersistentDomain(forName: "soniox.config.tests")
        defaults.set("from-defaults", forKey: SonioxConfiguration.apiKeyDefaultsKey)

        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_API_KEY": "from-env"],
            defaults: defaults
        )
        XCTAssertEqual(configuration.apiKey, "from-env")
        defaults.removePersistentDomain(forName: "soniox.config.tests")
    }

    func testConfigurationDefaultsMatchTheObservedSonioxContract() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "soniox.config.tests"))
        defaults.removePersistentDomain(forName: "soniox.config.tests")

        let configuration = SonioxConfiguration.resolved(environment: [:], defaults: defaults)
        XCTAssertEqual(configuration.websocketURL, "wss://stt-rt.soniox.com/transcribe-websocket")
        XCTAssertEqual(configuration.model, "stt-rt-v5")
        XCTAssertTrue(configuration.enableSpeakerDiarization)
        XCTAssertFalse(configuration.isConfigured, "No key and no broker URL must not activate Soniox")
    }

    func testConfigurationIsConfiguredWithBrokerURLAlone() {
        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_TEMP_KEY_URL": "http://127.0.0.1:3178/api/temporary-key"],
            defaults: isolatedDefaults()
        )
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertTrue(configuration.apiKey.isEmpty)
    }

    func testLanguageHintsAreParsedFromCommaSeparatedValue() {
        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_LANGUAGE_HINTS": " de , en ,"],
            defaults: isolatedDefaults()
        )
        XCTAssertEqual(configuration.languageHints, ["de", "en"])
    }

    func testStartMessageMatchesSonioxWireContract() {
        let configuration = SonioxConfiguration(
            apiKey: "ignored",
            temporaryKeyURL: "",
            websocketURL: SonioxConfiguration.defaultWebsocketURL,
            model: "stt-rt-v5",
            languageHints: ["de"],
            enableSpeakerDiarization: true,
            enableEndpointDetection: true
        )
        let message = configuration.startMessage(apiKey: "temp-key", sampleRate: 16000)

        XCTAssertEqual(message["api_key"] as? String, "temp-key")
        XCTAssertEqual(message["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(message["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(message["sample_rate"] as? Int, 16000)
        XCTAssertEqual(message["num_channels"] as? Int, 1)
        XCTAssertEqual(message["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(message["enable_endpoint_detection"] as? Bool, true)
        XCTAssertEqual(message["language_hints"] as? [String], ["de"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(message))
    }

    // MARK: - Temporary key broker payloads

    func testTemporaryKeyDecodesLoopbackBrokerShape() throws {
        let json = #"{"apiKey":"tmp-123","mode":"official-temporary-key","realtimeUrl":"wss://example/ws"}"#
        let key = try SonioxTemporaryKey.decode(Data(json.utf8))
        XCTAssertEqual(key.apiKey, "tmp-123")
        XCTAssertEqual(key.realtimeURL, "wss://example/ws")
    }

    func testTemporaryKeyDecodesOfficialSonioxShape() throws {
        let key = try SonioxTemporaryKey.decode(Data(#"{"api_key":"tmp-456"}"#.utf8))
        XCTAssertEqual(key.apiKey, "tmp-456")
        XCTAssertNil(key.realtimeURL)
    }

    func testTemporaryKeyRejectsResponseWithoutKey() {
        XCTAssertThrowsError(
            try SonioxTemporaryKey.decode(Data(#"{"error":"temporary_key_unavailable"}"#.utf8))
        )
    }

    // MARK: - Helpers

    private func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "soniox.config.tests")!
        defaults.removePersistentDomain(forName: "soniox.config.tests")
        return defaults
    }

    private func message(tokens: [(String, Bool, String?)]) -> SonioxServerMessage {
        SonioxServerMessage(
            tokens: tokens.map { SonioxToken(text: $0.0, isFinal: $0.1, speakerID: $0.2) }
        )
    }
}

// MARK: - Engine integration (fake transcriber, no network)

@MainActor
final class SonioxLiveTranscriptionEngineTests: XCTestCase {
    override func setUp() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
    }

    override func tearDown() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
    }

    func testSonioxSelectedWhenConfigured() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)

        try await engine.start()

        XCTAssertEqual(engine.currentEngine, .soniox)
        XCTAssertEqual(fake.connectCount, 1)
        engine.stop()
        XCTAssertEqual(fake.finishCount, 1)
    }

    func testSonioxNotSelectedWhenUnconfigured() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(
            configuration: SonioxConfiguration.resolved(environment: [:], defaults: emptyDefaults()),
            transcriber: fake
        )

        try await engine.start()

        XCTAssertNotEqual(engine.currentEngine, .soniox)
        XCTAssertEqual(fake.connectCount, 0)
    }

    func testFinalSegmentReplacesItsPartialTailAndKeepsSpeakerID() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)
        try await engine.start()

        fake.emit("Guten", speakerID: "1", isFinal: false)
        fake.emit("Guten Morgen", speakerID: "1", isFinal: false)
        XCTAssertEqual(engine.transcript.count, 1)
        XCTAssertEqual(engine.transcript[0].text, "Guten Morgen")
        XCTAssertFalse(engine.transcript[0].isFinal)

        fake.emit("Guten Morgen", speakerID: "1", isFinal: true)
        XCTAssertEqual(engine.transcript.count, 1, "The final segment replaces its own partial tail")
        XCTAssertTrue(engine.transcript[0].isFinal)
        XCTAssertEqual(engine.transcript[0].speakerID, "1")

        fake.emit("Servus", speakerID: "2", isFinal: true)
        XCTAssertEqual(engine.transcript.count, 2)
        XCTAssertEqual(engine.transcript[1].speakerID, "2")

        engine.stop()
    }

    func testAudioIsForwardedToSoniox() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)
        try await engine.start()

        engine.append(makePCMBuffer(frameCount: 480))
        XCTAssertEqual(fake.appendCount, 1)

        engine.stop()
    }

    func testPrivacyModeAbortsSonioxAndFallsBackToAppleSpeech() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .soniox)

        PrivacyMode.shared.activate()
        await Task.yield()

        XCTAssertEqual(fake.abortCount, 1)
        XCTAssertEqual(fake.finishCount, 0, "Privacy must kill, not gracefully finish")
        XCTAssertEqual(engine.currentEngine, .appleSpeech)
        XCTAssertTrue(engine.transcript.isEmpty)
    }

    func testLateSonioxCallbackAfterPrivacyAbortIsIgnored() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)
        try await engine.start()

        PrivacyMode.shared.activate()
        await Task.yield()
        fake.emit("late cloud text", speakerID: "1", isFinal: true)

        XCTAssertTrue(engine.transcript.isEmpty)
    }

    func testAppendAfterPrivacyActivationDoesNotReachSoniox() async throws {
        let fake = FakeSonioxTranscriber()
        let engine = makeEngine(configuration: configured(), transcriber: fake)
        try await engine.start()

        PrivacyMode.shared.activate()
        engine.append(makePCMBuffer(frameCount: 480))

        XCTAssertEqual(fake.appendCount, 0)
        XCTAssertEqual(fake.abortCount, 1)
    }

    func testSonioxIsClassifiedAsCloudEngine() {
        XCTAssertTrue(LiveTranscriptionEngine.isCloudEngine(.soniox))
        XCTAssertTrue(LiveTranscriptionEngine.isCloudEngine(.openAIRealtime))
        XCTAssertTrue(LiveTranscriptionEngine.isCloudEngine(.parakeet))
        XCTAssertFalse(LiveTranscriptionEngine.isCloudEngine(.local))
        XCTAssertFalse(LiveTranscriptionEngine.isCloudEngine(.appleSpeech))
    }

    // MARK: - Helpers

    private func makeEngine(
        configuration: SonioxConfiguration,
        transcriber: FakeSonioxTranscriber
    ) -> LiveTranscriptionEngine {
        LiveTranscriptionEngine(
            sonioxFactory: { _, onSegment in
                transcriber.onSegment = onSegment
                return transcriber
            },
            sonioxConfigurationProvider: { configuration },
            // Never touch the real speech-auth prompt: it never resolves in a
            // headless simulator, so the unconfigured-fallback case would hang.
            speechAuthorizer: { false }
        )
    }

    private func configured() -> SonioxConfiguration {
        SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_API_KEY": "soniox-test-key"],
            defaults: emptyDefaults()
        )
    }

    private func emptyDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "soniox.engine.tests")!
        defaults.removePersistentDomain(forName: "soniox.engine.tests")
        return defaults
    }

    private func makePCMBuffer(frameCount: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}

private final class FakeSonioxTranscriber: SonioxRealtimeTranscribing {
    var connectCount = 0
    var appendCount = 0
    var finishCount = 0
    var abortCount = 0
    var onSegment: ((String, String?, Bool) -> Void)?

    func connect() {
        connectCount += 1
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        appendCount += 1
    }

    func finish() {
        finishCount += 1
    }

    func abort() {
        abortCount += 1
    }

    func emit(_ text: String, speakerID: String?, isFinal: Bool) {
        onSegment?(text, speakerID, isFinal)
    }
}
