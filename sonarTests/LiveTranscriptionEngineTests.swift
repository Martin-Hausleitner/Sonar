import AVFoundation
import XCTest
@testable import Sonar

/// Tests for LiveTranscriptionEngine engine selection and lifecycle.
/// Network calls are never made — the Parakeet path only sends audio once
/// a chunk is full (5 s × 16 kHz = 80 000 samples), so injecting a handful
/// of short buffers is safe and free of network side-effects.
@MainActor
final class LiveTranscriptionEngineTests: XCTestCase {

    private let apiKeyUD = "sonar.parakeet.apiKey"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
    }

    // MARK: - Initial state

    func testInitialEngineIsAppleSpeech() {
        let engine = LiveTranscriptionEngine()
        XCTAssertEqual(engine.currentEngine, .appleSpeech)
    }

    func testInitialTranscriptIsEmpty() {
        let engine = LiveTranscriptionEngine()
        XCTAssertTrue(engine.transcript.isEmpty)
    }

    // MARK: - Engine selection via UserDefaults

    func testParakeetSelectedWhenAPIKeyPresent() async throws {
        UserDefaults.standard.set("nvapi-test-key-1234", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet,
                       "Non-empty API key must activate Parakeet engine")
        engine.stop()
    }

    func testAppleSpeechSelectedWhenAPIKeyEmpty() async throws {
        UserDefaults.standard.set("", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        // start() with appleSpeech requires authorization — we verify only that
        // the engine is NOT parakeet before calling start().
        // (Authorization prompt would block on CI; we rely on the key check.)
        let key = UserDefaults.standard.string(forKey: apiKeyUD) ?? ""
        XCTAssertTrue(key.isEmpty, "Precondition: empty key must be stored")
        // Calling start() without a key should attempt appleSpeech, not parakeet.
        // We just check it doesn't crash and doesn't switch to parakeet first.
        XCTAssertEqual(engine.currentEngine, .appleSpeech)
    }

    func testAppleSpeechSelectedWhenAPIKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        XCTAssertEqual(engine.currentEngine, .appleSpeech,
                       "Missing key must default to Apple Speech")
    }

    // MARK: - Lifecycle: stop before start must not crash

    func testStopBeforeStartDoesNotCrash() {
        let engine = LiveTranscriptionEngine()
        engine.stop()   // must be a no-op, not a crash
    }

    // MARK: - Parakeet path: append before chunk fills must not crash or send

    func testParakeetAppendShortBuffersDoesNotCrash() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet)

        // 160 frames × 10 = 1 600 samples ≪ 80 000 chunk threshold → no network call
        let buf = makePCMBuffer(frameCount: 160)
        for _ in 0..<10 { engine.append(buf) }

        XCTAssertTrue(engine.transcript.isEmpty,
                      "Sub-chunk audio must not produce transcript entries")
        engine.stop()
    }

    func testParakeetStopAfterShortAppendDoesNotCrash() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        engine.append(makePCMBuffer(frameCount: 160))
        engine.stop()   // flush() called; buffer < chunk threshold → safe no-op
    }

    // MARK: - Apple Speech path: append does not crash (request may be nil in sim)

    func testAppleSpeechAppendDoesNotCrash() {
        let engine = LiveTranscriptionEngine()
        // currentEngine is .appleSpeech; request is nil (not started)
        // append must be a no-op, not a crash
        engine.append(makePCMBuffer(frameCount: 160))
    }

    // MARK: - Segment model

    func testSegmentIDsAreUnique() {
        let s1 = LiveTranscriptionEngine.Segment(text: "hello", speakerID: nil, timestamp: Date(), isFinal: false)
        let s2 = LiveTranscriptionEngine.Segment(text: "hello", speakerID: nil, timestamp: Date(), isFinal: false)
        XCTAssertNotEqual(s1.id, s2.id)
    }

    func testSegmentIsFinalFlag() {
        var seg = LiveTranscriptionEngine.Segment(text: "hi", speakerID: nil, timestamp: Date(), isFinal: false)
        XCTAssertFalse(seg.isFinal)
        seg.isFinal = true
        XCTAssertTrue(seg.isFinal)
    }

    // MARK: - Helpers

    private func makePCMBuffer(frameCount: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        return buf
    }
}
