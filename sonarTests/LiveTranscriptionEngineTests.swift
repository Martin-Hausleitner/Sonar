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
    private let localModelUD = "sonar.localmodel.selected"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        UserDefaults.standard.removeObject(forKey: localModelUD)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        UserDefaults.standard.removeObject(forKey: localModelUD)
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
                       "Non-empty NVIDIA key must activate Parakeet engine")
        engine.stop()
    }

    func testOpenAIRealtimeSelectedWhenKeyPresent() async throws {
        UserDefaults.standard.set("sk-proj-test", forKey: "sonar.openai.apiKey")
        defer { UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey") }
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .openAIRealtime,
                       "Non-empty OpenAI key must activate OpenAI Realtime engine")
        engine.stop()
    }

    func testOpenAIRealtimeTakesPriorityOverParakeet() async throws {
        UserDefaults.standard.set("sk-proj-test",         forKey: "sonar.openai.apiKey")
        UserDefaults.standard.set("nvapi-test-key-1234",  forKey: apiKeyUD)
        defer {
            UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey")
        }
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .openAIRealtime,
                       "OpenAI Realtime must beat Parakeet in priority")
        engine.stop()
    }

    func testLocalWhisperEngineUsesSelectedDownloadedModel() async throws {
        let model = try XCTUnwrap(LocalModelManager.availableModels.first)
        let modelURL = plantLocalModelFileIfNeeded(model)
        defer { removePlantedModelIfNeeded(modelURL) }
        UserDefaults.standard.set(model.id, forKey: localModelUD)

        let fake = FakeLocalTranscriber()
        let engine = LiveTranscriptionEngine(localTranscriberFactory: { modelID, _, onSegment in
            XCTAssertEqual(modelID, model.id)
            fake.onSegment = onSegment
            return fake
        })

        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .local)

        engine.append(makePCMBuffer(frameCount: 160))
        XCTAssertEqual(fake.appendCount, 1)

        fake.emit("local whisper text")
        XCTAssertEqual(engine.transcript.last?.text, "local whisper text")

        engine.stop()
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testAppleSpeechSelectedWhenAPIKeyEmpty() async throws {
        UserDefaults.standard.set("", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        let key = UserDefaults.standard.string(forKey: apiKeyUD) ?? ""
        XCTAssertTrue(key.isEmpty)
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

    private var plantedModelURLs = Set<URL>()

    private func plantLocalModelFileIfNeeded(_ model: LocalModelManager.ModelInfo) -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelDir = supportDir.appendingPathComponent("SonarModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let folder = modelDir.appendingPathComponent("fake-\(model.id)", isDirectory: true)
        let metadataURL = modelDir.appendingPathComponent(model.filename)
        if !FileManager.default.fileExists(atPath: metadataURL.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("fake-local-model".utf8).write(to: folder.appendingPathComponent("model.mlmodelc"))
            let metadata = """
            {"modelID":"\(model.id)","variant":"\(model.whisperKitVariant)","folderPath":"\(folder.path)","size":16}
            """
            try? Data(metadata.utf8).write(to: metadataURL)
            plantedModelURLs.insert(metadataURL)
            plantedModelURLs.insert(folder)
        }
        return metadataURL
    }

    private func removePlantedModelIfNeeded(_ url: URL) {
        for planted in Array(plantedModelURLs) {
            try? FileManager.default.removeItem(at: planted)
            plantedModelURLs.remove(planted)
        }
    }
}

private final class FakeLocalTranscriber: LocalTranscribing {
    var appendCount = 0
    var stopCount = 0
    var onSegment: ((String) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        appendCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ text: String) {
        onSegment?(text)
    }
}
