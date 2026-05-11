import AVFoundation
import Combine
import Foundation
import Speech

/// Drives transcription via the best available engine.
/// Priority: OpenAI Realtime -> NVIDIA Parakeet -> Local Whisper -> Apple Speech.
@MainActor
final class LiveTranscriptionEngine: ObservableObject {
    enum Engine { case appleSpeech, parakeet, local, openAIRealtime }

    struct Segment: Identifiable {
        let id = UUID()
        let text: String
        let speakerID: String?
        let timestamp: Date
        var isFinal: Bool
    }

    @Published private(set) var transcript: [Segment] = []
    @Published private(set) var currentEngine: Engine = .appleSpeech

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var parakeet: CloudTranscribing?
    private var openAIRealtime: OpenAIRealtimeTranscribing?
    private var localWhisper: LocalTranscribing?
    private var privacyCancellable: AnyCancellable?
    private var cloudCallbackGeneration = 0

    typealias LocalTranscriberFactory = @MainActor (
        _ modelID: String,
        _ language: Locale,
        _ onSegment: @escaping (String) -> Void
    ) -> LocalTranscribing?

    typealias ParakeetFactory = @MainActor (
        _ apiKey: String,
        _ onSegment: @escaping (String) -> Void
    ) -> CloudTranscribing

    typealias OpenAIRealtimeFactory = @MainActor (
        _ apiKey: String,
        _ endpoint: String,
        _ onSegment: @escaping (String, Bool) -> Void
    ) -> OpenAIRealtimeTranscribing

    typealias ParakeetChunkSender = @Sendable (
        _ apiKey: String,
        _ pcm16LE: Data,
        _ sampleRate: Int,
        _ languageCode: String
    ) async throws -> String

    private let localTranscriberFactory: LocalTranscriberFactory
    private let parakeetFactory: ParakeetFactory
    private let openAIRealtimeFactory: OpenAIRealtimeFactory

    init(
        localTranscriberFactory: @escaping LocalTranscriberFactory = LiveTranscriptionEngine.makeLocalTranscriber,
        parakeetChunkSender: @escaping ParakeetChunkSender = { apiKey, pcm16LE, sampleRate, languageCode in
            try await LiveTranscriptionEngine.transcribeParakeetChunk(
                apiKey: apiKey,
                pcm16LE: pcm16LE,
                sampleRate: sampleRate,
                languageCode: languageCode
            )
        },
        parakeetQueueWorkGate: (@Sendable () -> Void)? = nil,
        parakeetFactory: ParakeetFactory? = nil,
        openAIRealtimeFactory: @escaping OpenAIRealtimeFactory = { apiKey, endpoint, onSegment in
            OpenAIRealtimeTranscriber(apiKey: apiKey, endpoint: endpoint, onSegment: onSegment)
        }
    ) {
        self.localTranscriberFactory = localTranscriberFactory
        self.parakeetFactory = parakeetFactory ?? { apiKey, onSegment in
            ParakeetTranscriber(
                apiKey: apiKey,
                onSegment: onSegment,
                transcribeChunk: parakeetChunkSender,
                queueWorkGate: parakeetQueueWorkGate
            )
        }
        self.openAIRealtimeFactory = openAIRealtimeFactory
        privacyCancellable = NotificationCenter.default
            .publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.abortCloudTranscribers()
                }
            }
    }

    func start(language: Locale = .current) async throws {
        guard !SonarTestIdentity.current().isSimulatorRelayEnabled else { return }

        currentEngine = pickEngine(language: language, allowCloud: !PrivacyMode.shared.isActive)
        switch currentEngine {
        case .appleSpeech:
            let authorized = await requestAuthorization()
            guard authorized else { return }
            currentEngine = .appleSpeech
            try startAppleSpeech(language: language)

        case .local:
            let modelID = LocalModelManager.shared.selectedModelID
            guard let transcriber = localTranscriberFactory(modelID, language, { [weak self] text in
                guard let self else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: true)
                self.transcript.append(seg)
            }) else {
                let authorized = await requestAuthorization()
                guard authorized else { return }
                currentEngine = .appleSpeech
                try startAppleSpeech(language: language)
                return
            }
            localWhisper = transcriber

        case .parakeet:
            let key = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
            let generation = cloudCallbackGeneration
            parakeet = parakeetFactory(key) { [weak self] text in
                guard let self else { return }
                guard isCurrentCloudCallback(generation) else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: true)
                transcript.append(seg)
            }

        case .openAIRealtime:
            let key = UserDefaults.standard.string(forKey: "sonar.openai.apiKey") ?? ""
            let endpoint = UserDefaults.standard.string(forKey: "sonar.openai.endpoint") ?? ""
            let generation = cloudCallbackGeneration
            openAIRealtime = openAIRealtimeFactory(key, endpoint) { [weak self] text, isFinal in
                guard let self else { return }
                guard isCurrentCloudCallback(generation) else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: isFinal)
                if isFinal {
                    transcript.append(seg)
                } else if let last = transcript.last, !last.isFinal {
                    transcript[transcript.count - 1] = seg
                } else {
                    transcript.append(seg)
                }
            }
            openAIRealtime?.connect()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if PrivacyMode.shared.isActive,
           currentEngine == .parakeet || currentEngine == .openAIRealtime
        {
            abortCloudTranscribers()
            return
        }
        switch currentEngine {
        case .appleSpeech: request?.append(buffer)
        case .local: localWhisper?.append(buffer)
        case .parakeet: parakeet?.append(buffer)
        case .openAIRealtime: openAIRealtime?.append(buffer)
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        parakeet?.finish()
        parakeet = nil
        localWhisper?.stop()
        localWhisper = nil
        openAIRealtime?.finish()
        openAIRealtime = nil
        clearTranscript()
    }

    func clearTranscript() {
        transcript.removeAll()
    }

    func abortCloudTranscriptionForPrivacy() {
        abortCloudTranscribers()
    }

    // MARK: - Engine selection (priority order)

    private func pickEngine(language: Locale, allowCloud: Bool = true) -> Engine {
        if allowCloud {
            let openAIKey = UserDefaults.standard.string(forKey: "sonar.openai.apiKey") ?? ""
            if !openAIKey.isEmpty { return .openAIRealtime }

            let parakeetKey = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
            if !parakeetKey.isEmpty { return .parakeet }
        }

        let localID = LocalModelManager.shared.selectedModelID
        if !localID.isEmpty,
           let model = LocalModelManager.availableModels.first(where: { $0.id == localID }),
           LocalModelManager.shared.localURL(for: model) != nil
        {
            return .local
        }

        return .appleSpeech
    }

    private func abortCloudTranscribers() {
        cloudCallbackGeneration += 1
        parakeet?.abort()
        parakeet = nil
        openAIRealtime?.abort()
        openAIRealtime = nil
        if currentEngine == .parakeet || currentEngine == .openAIRealtime {
            currentEngine = .appleSpeech
        }
        clearTranscript()
    }

    private func isCurrentCloudCallback(_ generation: Int) -> Bool {
        generation == cloudCallbackGeneration && !PrivacyMode.shared.isActive
    }

    private static func transcribeParakeetChunk(
        apiKey: String,
        pcm16LE: Data,
        sampleRate: Int,
        languageCode: String
    ) async throws -> String {
        try await NvidiaRivaASRClient.transcribeHosted(
            apiKey: apiKey,
            pcm16LE: pcm16LE,
            sampleRate: sampleRate,
            languageCode: languageCode
        )
    }

    private static func makeLocalTranscriber(
        modelID: String,
        language: Locale,
        onSegment: @escaping (String) -> Void
    ) -> LocalTranscribing? {
        WhisperKitLocalTranscriber.make(modelID: modelID, language: language, onSegment: onSegment)
    }

    // MARK: - Apple SFSpeechRecognizer

    private func startAppleSpeech(language: Locale) throws {
        recognizer = SFSpeechRecognizer(locale: language)
        recognizer?.defaultTaskHint = .confirmation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: result.isFinal)
            Task { @MainActor in
                if let last = self.transcript.last, !last.isFinal {
                    self.transcript[self.transcript.count - 1] = seg
                } else {
                    self.transcript.append(seg)
                }
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}

protocol CloudTranscribing: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish()
    func abort()
}

protocol OpenAIRealtimeTranscribing: CloudTranscribing {
    func connect()
}

// MARK: - OpenAIRealtimeTranscriber

/// Streams PCM audio to the OpenAI Realtime API (wss) and returns incremental
/// transcription via the server-VAD turn-detection model (whisper-1).
/// Audio is resampled from the capture rate (16 kHz) to 24 kHz in-process.
private final class OpenAIRealtimeTranscriber: OpenAIRealtimeTranscribing {
    private let apiKey: String
    private let wsURL: URL
    private var wsTask: URLSessionWebSocketTask?
    private let onSegment: (String, Bool) -> Void // (text, isFinal), called on main
    private var floatBuffer: [Float] = []
    private let queue = DispatchQueue(label: "sonar.openai-rt", qos: .userInteractive)

    private static let captureRate: Double = 16000
    private static let targetRate: Double = 24000
    private static let chunkFrames: Int = 1600 // 100 ms @ 16 kHz

    init(apiKey: String, endpoint: String, onSegment: @escaping (String, Bool) -> Void) {
        let base = endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        wsURL = URL(string: "\(wsBase)/realtime?model=gpt-4o-realtime-preview-2024-12-17")
            ?? URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-12-17")!
        self.apiKey = apiKey
        self.onSegment = onSegment
    }

    func connect() {
        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        wsTask = URLSession.shared.webSocketTask(with: req)
        wsTask?.resume()
        sendSessionConfig()
        Task { [weak self] in await self?.receiveLoop() }
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    func finish() {
        disconnect()
    }

    func abort() {
        disconnect()
        queue.async { [weak self] in
            self?.floatBuffer.removeAll(keepingCapacity: false)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch, count: count))
        queue.async { [weak self] in
            guard let self else { return }
            floatBuffer.append(contentsOf: samples)
            while floatBuffer.count >= Self.chunkFrames {
                let chunk = Array(floatBuffer.prefix(Self.chunkFrames))
                floatBuffer.removeFirst(Self.chunkFrames)
                sendAudio(chunk)
            }
        }
    }

    // MARK: - Private

    private func sendSessionConfig() {
        let cfg: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 600
                ]
            ]
        ]
        send(json: cfg)
    }

    private func sendAudio(_ pcm16k: [Float]) {
        let resampled = upsample(
            pcm16k,
            from: Self.captureRate,
            to: Self.targetRate
        )
        let int16 = resampled.map { Int16(clamping: Int32($0 * 32767)) }
        let bytes = int16.withUnsafeBufferPointer { Data(buffer: $0) }
        send(json: [
            "type": "input_audio_buffer.append",
            "audio": bytes.base64EncodedString()
        ])
    }

    private func upsample(_ samples: [Float], from src: Double, to dst: Double) -> [Float] {
        let ratio = dst / src
        let outCount = Int(Double(samples.count) * ratio)
        var out = [Float](repeating: 0, count: outCount)
        let last = samples.count - 1
        for i in 0 ..< outCount {
            let pos = Double(i) / ratio
            let lo = min(Int(pos), last)
            let hi = min(lo + 1, last)
            let t = Float(pos - Double(lo))
            out[i] = samples[lo] + t * (samples[hi] - samples[lo])
        }
        return out
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(str)) { _ in }
    }

    private func receiveLoop() async {
        while true {
            guard let task = wsTask else { break }
            do {
                let msg = try await task.receive()
                if case let .string(text) = msg { parseEvent(text) }
            } catch { break }
        }
    }

    private func parseEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let text = json["transcript"] as? String ?? ""
            if !text.isEmpty { fireSegment(text, isFinal: true) }

        case "conversation.item.input_audio_transcription.delta":
            let delta = json["delta"] as? String ?? ""
            if !delta.isEmpty { fireSegment(delta, isFinal: false) }

        case "error":
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String
            {
                Log.ai.error("OpenAI Realtime: \(msg)")
            }

        default: break
        }
    }

    private func fireSegment(_ text: String, isFinal: Bool) {
        DispatchQueue.main.async { self.onSegment(text, isFinal) }
    }
}

// MARK: - ParakeetTranscriber

/// Buffers PCM audio in 5-second chunks and sends each chunk to NVIDIA's
/// hosted Riva/gRPC Parakeet endpoint.
final class ParakeetTranscriber: CloudTranscribing, @unchecked Sendable {
    private let apiKey: String
    private let sampleRate: Double = 16000
    private let chunkDuration: Double = 5.0

    private var samples: [Float] = []
    private let abortLock = NSLock()
    private var aborted = false
    private var inFlightChunkTasks: [UUID: Task<Void, Never>] = [:]
    private var completedChunkTaskIDs = Set<UUID>()
    private let queue = DispatchQueue(label: "sonar.parakeet", qos: .userInitiated)
    private let onSegment: (String) -> Void // always called on main queue
    private let transcribeChunk: LiveTranscriptionEngine.ParakeetChunkSender
    private let queueWorkGate: (@Sendable () -> Void)?

    init(
        apiKey: String,
        onSegment: @escaping (String) -> Void,
        transcribeChunk: @escaping LiveTranscriptionEngine.ParakeetChunkSender,
        queueWorkGate: (@Sendable () -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.onSegment = onSegment
        self.transcribeChunk = transcribeChunk
        self.queueWorkGate = queueWorkGate
    }

    func append(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let ch = pcmBuffer.floatChannelData?[0] else { return }
        let count = Int(pcmBuffer.frameLength)
        let incoming = Array(UnsafeBufferPointer(start: ch, count: count))
        queue.async { [weak self] in
            guard let self else { return }
            queueWorkGate?()
            guard !isAborted else { return }
            samples.append(contentsOf: incoming)
            let chunkSize = Int(sampleRate * chunkDuration)
            while samples.count >= chunkSize {
                guard !isAborted else {
                    samples.removeAll(keepingCapacity: false)
                    return
                }
                let chunk = Array(samples.prefix(chunkSize))
                samples.removeFirst(chunkSize)
                sendChunk(chunk)
            }
        }
    }

    func flush() {
        queue.async { [weak self] in
            guard let self, !self.samples.isEmpty else { return }
            guard !isAborted else {
                samples.removeAll(keepingCapacity: false)
                return
            }
            let chunk = samples
            samples = []
            sendChunk(chunk)
        }
    }

    func finish() {
        flush()
    }

    func abort() {
        let tasksToCancel = markAbortedAndCollectTasks()
        tasksToCancel.forEach { $0.cancel() }
        queue.async { [weak self] in
            self?.samples.removeAll(keepingCapacity: false)
        }
    }

    private func sendChunk(_ pcm: [Float]) {
        guard !isAborted else { return }
        let pcm16 = buildPCM16LE(pcm: pcm)
        let taskID = UUID()
        let task = Task.detached { [weak self] in
            guard let self else { return }
            defer { removeInFlightTask(id: taskID) }
            guard !Task.isCancelled, !isAborted else { return }
            guard let text = try? await transcribeChunk(apiKey, pcm16, Int(sampleRate), "en-US") else { return }
            guard !Task.isCancelled, !isAborted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !isAborted else { return }
                onSegment(text)
            }
        }
        trackInFlightTask(task, id: taskID)
        if isAborted {
            task.cancel()
            removeInFlightTask(id: taskID)
        }
    }

    private var isAborted: Bool {
        abortLock.lock()
        defer { abortLock.unlock() }
        return aborted
    }

    private func trackInFlightTask(_ task: Task<Void, Never>, id: UUID) {
        abortLock.lock()
        if completedChunkTaskIDs.remove(id) != nil {
            abortLock.unlock()
            return
        }
        inFlightChunkTasks[id] = task
        abortLock.unlock()
    }

    private func removeInFlightTask(id: UUID) {
        abortLock.lock()
        if inFlightChunkTasks.removeValue(forKey: id) == nil, !aborted {
            completedChunkTaskIDs.insert(id)
        }
        abortLock.unlock()
    }

    private func markAbortedAndCollectTasks() -> [Task<Void, Never>] {
        abortLock.lock()
        aborted = true
        let tasks = Array(inFlightChunkTasks.values)
        inFlightChunkTasks.removeAll()
        completedChunkTaskIDs.removeAll()
        abortLock.unlock()
        return tasks
    }

    /// Encodes Float32 PCM as raw little-endian LINEAR_PCM for Riva Recognize.
    private func buildPCM16LE(pcm: [Float]) -> Data {
        let int16: [Int16] = pcm.map { Int16(clamping: Int32($0 * 32767)) }
        return int16.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
