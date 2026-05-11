import AVFoundation
@testable import Sonar
import XCTest

/// Tests for LiveTranscriptionEngine engine selection and lifecycle.
/// Network calls are never made — the Parakeet path only sends audio once
/// a chunk is full (5 s × 16 kHz = 80 000 samples), so injecting a handful
/// of short buffers is safe and free of network side-effects.
@MainActor
final class LiveTranscriptionEngineTests: XCTestCase {
    private let apiKeyUD = "sonar.parakeet.apiKey"
    private let localModelUD = "sonar.localmodel.selected"

    override func setUp() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey")
        UserDefaults.standard.removeObject(forKey: localModelUD)
    }

    override func tearDown() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey")
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
        XCTAssertEqual(
            engine.currentEngine,
            .parakeet,
            "Non-empty NVIDIA key must activate Parakeet engine"
        )
        engine.stop()
    }

    func testOpenAIRealtimeSelectedWhenKeyPresent() async throws {
        UserDefaults.standard.set("sk-proj-test", forKey: "sonar.openai.apiKey")
        defer { UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey") }
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(
            engine.currentEngine,
            .openAIRealtime,
            "Non-empty OpenAI key must activate OpenAI Realtime engine"
        )
        engine.stop()
    }

    func testOpenAIRealtimeTakesPriorityOverParakeet() async throws {
        UserDefaults.standard.set("sk-proj-test", forKey: "sonar.openai.apiKey")
        UserDefaults.standard.set("nvapi-test-key-1234", forKey: apiKeyUD)
        defer {
            UserDefaults.standard.removeObject(forKey: "sonar.openai.apiKey")
        }
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(
            engine.currentEngine,
            .openAIRealtime,
            "OpenAI Realtime must beat Parakeet in priority"
        )
        engine.stop()
    }

    func testPrivacyModeBlocksCloudEnginesAtStartup() async throws {
        let model = try XCTUnwrap(LocalModelManager.availableModels.first)
        let modelURL = plantLocalModelFileIfNeeded(model)
        defer { removePlantedModelIfNeeded(modelURL) }
        UserDefaults.standard.set(model.id, forKey: localModelUD)
        UserDefaults.standard.set("sk-proj-test", forKey: "sonar.openai.apiKey")
        UserDefaults.standard.set("nvapi-test-key-1234", forKey: apiKeyUD)
        PrivacyMode.shared.activate()

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
        XCTAssertTrue(engine.transcript.isEmpty)
    }

    func testClearTranscriptRemovesExistingSegments() async throws {
        let model = try XCTUnwrap(LocalModelManager.availableModels.first)
        let modelURL = plantLocalModelFileIfNeeded(model)
        defer { removePlantedModelIfNeeded(modelURL) }
        UserDefaults.standard.set(model.id, forKey: localModelUD)

        let fake = FakeLocalTranscriber()
        let engine = LiveTranscriptionEngine(localTranscriberFactory: { _, _, onSegment in
            fake.onSegment = onSegment
            return fake
        })

        try await engine.start()
        fake.emit("sensitive text")
        XCTAssertFalse(engine.transcript.isEmpty)

        engine.clearTranscript()

        XCTAssertTrue(engine.transcript.isEmpty)
        engine.stop()
    }

    func testAppleSpeechSelectedWhenAPIKeyEmpty() {
        UserDefaults.standard.set("", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        let key = UserDefaults.standard.string(forKey: apiKeyUD) ?? ""
        XCTAssertTrue(key.isEmpty)
        XCTAssertEqual(engine.currentEngine, .appleSpeech)
    }

    func testAppleSpeechSelectedWhenAPIKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        XCTAssertEqual(
            engine.currentEngine,
            .appleSpeech,
            "Missing key must default to Apple Speech"
        )
    }

    // MARK: - Lifecycle: stop before start must not crash

    func testStopBeforeStartDoesNotCrash() {
        let engine = LiveTranscriptionEngine()
        engine.stop() // must be a no-op, not a crash
    }

    // MARK: - Parakeet path: append before chunk fills must not crash or send

    func testParakeetAppendShortBuffersDoesNotCrash() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet)

        // 160 frames × 10 = 1 600 samples ≪ 80 000 chunk threshold → no network call
        let buf = makePCMBuffer(frameCount: 160)
        for _ in 0 ..< 10 {
            engine.append(buf)
        }

        XCTAssertTrue(
            engine.transcript.isEmpty,
            "Sub-chunk audio must not produce transcript entries"
        )
        engine.stop()
    }

    func testParakeetStopAfterShortAppendDoesNotCrash() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let engine = LiveTranscriptionEngine()
        try await engine.start()
        engine.append(makePCMBuffer(frameCount: 160))
        engine.stop() // flush() called; buffer < chunk threshold → safe no-op
    }

    func testPrivacyActivationAbortsCloudTranscriberWithoutFinishing() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let fake = FakeCloudTranscriber()
        let engine = LiveTranscriptionEngine(
            parakeetFactory: { _, onSegment in
                fake.onSegment = onSegment
                return fake
            }
        )

        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet)

        PrivacyMode.shared.activate()
        await Task.yield()

        XCTAssertEqual(fake.abortCount, 1)
        XCTAssertEqual(fake.finishCount, 0)
        XCTAssertEqual(engine.currentEngine, .appleSpeech)
    }

    func testPrivacyActivationIgnoresLateParakeetSegmentCallback() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let fake = FakeCloudTranscriber()
        let engine = LiveTranscriptionEngine(
            parakeetFactory: { _, onSegment in
                fake.onSegment = onSegment
                return fake
            }
        )

        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet)

        PrivacyMode.shared.activate()
        await Task.yield()
        fake.emit("late cloud text")

        XCTAssertTrue(
            engine.transcript.isEmpty,
            "Late Parakeet callbacks after privacy activation must not repopulate transcript"
        )
    }

    func testQueuedParakeetAppendDoesNotUploadAfterPrivacyAbort() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let appendEntered = DispatchSemaphore(value: 0)
        let releaseAppend = DispatchSemaphore(value: 0)
        let sender = RecordingParakeetSender()
        let transcriber = ParakeetTranscriber(
            apiKey: "nvapi-fake",
            onSegment: { _ in },
            transcribeChunk: { _, _, _, _ in
                sender.recordCall()
                return "uploaded"
            },
            queueWorkGate: {
                appendEntered.signal()
                _ = releaseAppend.wait(timeout: .now() + 2)
            }
        )
        let engine = LiveTranscriptionEngine(
            parakeetFactory: { _, _ in transcriber }
        )

        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .parakeet)

        engine.append(makePCMBuffer(frameCount: 80000))
        XCTAssertEqual(appendEntered.wait(timeout: .now() + 2), .success)

        PrivacyMode.shared.activate()
        await Task.yield()
        releaseAppend.signal()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            sender.callCount,
            0,
            "A queued Parakeet append must not call the cloud sender after Privacy Mode abort"
        )
    }

    func testParakeetAbortCancelsInFlightChunkUploadAndSuppressesCallback() async throws {
        let sender = BlockingParakeetSender()
        let callback = CallbackRecorder()
        let transcriber = ParakeetTranscriber(
            apiKey: "nvapi-fake",
            onSegment: { text in
                callback.record(text)
            },
            transcribeChunk: { _, _, _, _ in
                try await sender.transcribe()
            }
        )

        transcriber.append(makePCMBuffer(frameCount: 80000))
        await sender.waitUntilStarted()

        transcriber.abort()
        let cancellationObserved = sender.waitUntilCancelled(timeout: .now() + 1)
        sender.release(returning: "should not surface")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sender.startedCount, 1)
        XCTAssertTrue(cancellationObserved)
        XCTAssertTrue(callback.segments.isEmpty)
    }

    func testNormalStopFinishesCloudTranscriber() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: apiKeyUD)
        let fake = FakeCloudTranscriber()
        let engine = LiveTranscriptionEngine(
            parakeetFactory: { _, _ in fake }
        )

        try await engine.start()
        engine.stop()

        XCTAssertEqual(fake.finishCount, 1)
        XCTAssertEqual(fake.abortCount, 0)
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
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
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

private final class RecordingParakeetSender: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

private final class BlockingParakeetSender: @unchecked Sendable {
    private let lock = NSLock()
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<String, Error>?
    private let cancellationSemaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var didCancel = false
    private var starts = 0

    var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func transcribe() async throws -> String {
        markStarted()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                releaseContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            markCancelled()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didStart {
                lock.unlock()
                continuation.resume()
            } else {
                startedContinuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitUntilCancelled(timeout: DispatchTime) -> Bool {
        lock.lock()
        let alreadyCancelled = didCancel
        lock.unlock()
        if alreadyCancelled { return true }
        return cancellationSemaphore.wait(timeout: timeout) == .success
    }

    func release(returning text: String) {
        lock.lock()
        let continuation = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: text)
    }

    private func markStarted() {
        lock.lock()
        didStart = true
        starts += 1
        let continuations = startedContinuations
        startedContinuations.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    private func markCancelled() {
        lock.lock()
        didCancel = true
        lock.unlock()
        cancellationSemaphore.signal()
    }
}

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSegments: [String] = []

    var segments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSegments
    }

    func record(_ text: String) {
        lock.lock()
        recordedSegments.append(text)
        lock.unlock()
    }
}

private final class FakeCloudTranscriber: CloudTranscribing {
    var appendCount = 0
    var finishCount = 0
    var abortCount = 0
    var onSegment: ((String) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        appendCount += 1
    }

    func finish() {
        finishCount += 1
    }

    func abort() {
        abortCount += 1
    }

    func emit(_ text: String) {
        onSegment?(text)
    }
}
