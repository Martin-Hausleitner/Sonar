import AVFoundation
import Combine
import Foundation
import Speech

/// Drives transcription via the best available engine.
/// Priority: OpenAI Realtime → NVIDIA Parakeet → Local Whisper → Apple Speech.
@MainActor
final class LiveTranscriptionEngine: ObservableObject {
    enum Engine { case appleSpeech, parakeet, local, openAIRealtime }

    struct Segment: Sendable, Identifiable {
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
    private var parakeet: ParakeetTranscriber?
    private var openAIRealtime: OpenAIRealtimeTranscriber?

    func start(language: Locale = .current) async throws {
        currentEngine = pickEngine(language: language)
        switch currentEngine {
        case .appleSpeech, .local:
            // .local: model downloaded but WhisperKit inference not yet integrated.
            let authorized = await requestAuthorization()
            guard authorized else { return }
            currentEngine = .appleSpeech
            try startAppleSpeech(language: language)

        case .parakeet:
            let key = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
            parakeet = ParakeetTranscriber(apiKey: key) { [weak self] text in
                guard let self else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: true)
                self.transcript.append(seg)
            }

        case .openAIRealtime:
            let key      = UserDefaults.standard.string(forKey: "sonar.openai.apiKey")      ?? ""
            let endpoint = UserDefaults.standard.string(forKey: "sonar.openai.endpoint")    ?? ""
            openAIRealtime = OpenAIRealtimeTranscriber(
                apiKey: key, endpoint: endpoint
            ) { [weak self] text, isFinal in
                guard let self else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: isFinal)
                if isFinal {
                    self.transcript.append(seg)
                } else if let last = self.transcript.last, !last.isFinal {
                    self.transcript[self.transcript.count - 1] = seg
                } else {
                    self.transcript.append(seg)
                }
            }
            openAIRealtime?.connect()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        switch currentEngine {
        case .appleSpeech, .local: request?.append(buffer)
        case .parakeet:            parakeet?.append(buffer)
        case .openAIRealtime:      openAIRealtime?.append(buffer)
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        parakeet?.flush()
        parakeet = nil
        openAIRealtime?.disconnect()
        openAIRealtime = nil
    }

    // MARK: - Engine selection (priority order)

    private func pickEngine(language: Locale) -> Engine {
        let openAIKey = UserDefaults.standard.string(forKey: "sonar.openai.apiKey") ?? ""
        if !openAIKey.isEmpty { return .openAIRealtime }

        let parakeetKey = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
        if !parakeetKey.isEmpty { return .parakeet }

        let localID = UserDefaults.standard.string(forKey: "sonar.localmodel.selected") ?? ""
        if !localID.isEmpty,
           let model = LocalModelManager.availableModels.first(where: { $0.id == localID }),
           LocalModelManager.shared.localURL(for: model) != nil {
            return .local
        }

        return .appleSpeech
    }

    // MARK: - Apple SFSpeechRecognizer

    private func startAppleSpeech(language: Locale) throws {
        recognizer = SFSpeechRecognizer(locale: language)
        recognizer?.defaultTaskHint = .confirmation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        self.request = req
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

// MARK: - OpenAIRealtimeTranscriber

/// Streams PCM audio to the OpenAI Realtime API (wss) and returns incremental
/// transcription via the server-VAD turn-detection model (whisper-1).
/// Audio is resampled from the capture rate (16 kHz) to 24 kHz in-process.
private final class OpenAIRealtimeTranscriber {
    private let apiKey: String
    private let wsURL: URL
    private var wsTask: URLSessionWebSocketTask?
    private let onSegment: (String, Bool) -> Void   // (text, isFinal), called on main
    private var floatBuffer: [Float] = []
    private let queue = DispatchQueue(label: "sonar.openai-rt", qos: .userInteractive)

    private static let captureRate: Double = 16_000
    private static let targetRate:  Double = 24_000
    private static let chunkFrames: Int    = 1_600   // 100 ms @ 16 kHz

    init(apiKey: String, endpoint: String, onSegment: @escaping (String, Bool) -> Void) {
        let base = endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint
        let wsBase = base
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        self.wsURL = URL(string: "\(wsBase)/realtime?model=gpt-4o-realtime-preview-2024-12-17")!
        self.apiKey = apiKey
        self.onSegment = onSegment
    }

    func connect() {
        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1",       forHTTPHeaderField: "OpenAI-Beta")
        wsTask = URLSession.shared.webSocketTask(with: req)
        wsTask?.resume()
        sendSessionConfig()
        Task { [weak self] in await self?.receiveLoop() }
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch, count: count))
        queue.async { [weak self] in
            guard let self else { return }
            self.floatBuffer.append(contentsOf: samples)
            while self.floatBuffer.count >= Self.chunkFrames {
                let chunk = Array(self.floatBuffer.prefix(Self.chunkFrames))
                self.floatBuffer.removeFirst(Self.chunkFrames)
                self.sendAudio(chunk)
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
                    "type":                 "server_vad",
                    "threshold":            0.5,
                    "prefix_padding_ms":    300,
                    "silence_duration_ms":  600
                ]
            ]
        ]
        send(json: cfg)
    }

    private func sendAudio(_ pcm16k: [Float]) {
        let resampled = upsample(pcm16k,
                                 from: Self.captureRate,
                                 to:   Self.targetRate)
        let int16 = resampled.map { Int16(clamping: Int32($0 * 32767)) }
        let bytes = int16.withUnsafeBufferPointer { Data(buffer: $0) }
        send(json: ["type": "input_audio_buffer.append",
                    "audio": bytes.base64EncodedString()])
    }

    private func upsample(_ samples: [Float], from src: Double, to dst: Double) -> [Float] {
        let ratio    = dst / src
        let outCount = Int(Double(samples.count) * ratio)
        var out      = [Float](repeating: 0, count: outCount)
        let last     = samples.count - 1
        for i in 0..<outCount {
            let pos = Double(i) / ratio
            let lo  = min(Int(pos), last)
            let hi  = min(lo + 1, last)
            let t   = Float(pos - Double(lo))
            out[i]  = samples[lo] + t * (samples[hi] - samples[lo])
        }
        return out
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str  = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(str)) { _ in }
    }

    private func receiveLoop() async {
        while true {
            guard let task = wsTask else { break }
            do {
                let msg = try await task.receive()
                if case .string(let text) = msg { parseEvent(text) }
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
               let msg = err["message"] as? String {
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

/// Buffers PCM audio in 5-second chunks and streams them to the NVIDIA NIM
/// Parakeet endpoint (OpenAI-compatible audio/transcriptions API).
private final class ParakeetTranscriber {
    private let apiKey: String
    private let model     = "nvidia/parakeet-ctc-1.1b"
    private let endpoint  = URL(string: "https://integrate.api.nvidia.com/v1/audio/transcriptions")!
    private let sampleRate: Double = 16_000
    private let chunkDuration: Double = 5.0

    private var samples: [Float] = []
    private let queue = DispatchQueue(label: "sonar.parakeet", qos: .userInitiated)
    private let onSegment: (String) -> Void   // always called on main queue

    init(apiKey: String, onSegment: @escaping (String) -> Void) {
        self.apiKey = apiKey
        self.onSegment = onSegment
    }

    func append(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let ch = pcmBuffer.floatChannelData?[0] else { return }
        let count = Int(pcmBuffer.frameLength)
        let incoming = Array(UnsafeBufferPointer(start: ch, count: count))
        queue.async { [weak self] in
            guard let self else { return }
            self.samples.append(contentsOf: incoming)
            let chunkSize = Int(self.sampleRate * self.chunkDuration)
            while self.samples.count >= chunkSize {
                let chunk = Array(self.samples.prefix(chunkSize))
                self.samples.removeFirst(chunkSize)
                self.sendChunk(chunk)
            }
        }
    }

    func flush() {
        queue.async { [weak self] in
            guard let self, !self.samples.isEmpty else { return }
            let chunk = self.samples
            self.samples = []
            self.sendChunk(chunk)
        }
    }

    private func sendChunk(_ pcm: [Float]) {
        let wav = buildWAV(pcm: pcm)
        Task.detached { [weak self] in
            guard let self else { return }
            guard let text = await self.post(wav: wav) else { return }
            DispatchQueue.main.async { self.onSegment(text) }
        }
    }

    private func post(wav: Data) async -> String? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = buildBody(wav: wav, boundary: boundary)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode(ParakeetResponse.self, from: data).text
        } catch {
            return nil
        }
    }

    private func buildBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        body.mpAppend(boundary: boundary, name: "model", string: model)
        body.mpAppend(boundary: boundary, name: "file", filename: "audio.wav", mime: "audio/wav", data: wav)
        body += "--\(boundary)--\r\n"
        return body
    }

    // Encodes Float32 PCM as a 16-bit mono WAV blob.
    private func buildWAV(pcm: [Float]) -> Data {
        let int16: [Int16] = pcm.map { Int16(clamping: Int32($0 * 32767)) }
        let audioBytes = int16.withUnsafeBufferPointer { Data(buffer: $0) }
        let sr   = UInt32(sampleRate)
        let bps: UInt16 = 16
        let ch:  UInt16 = 1
        var h = Data()
        h += "RIFF"
        h.appendLE(UInt32(36 + audioBytes.count))
        h += "WAVEfmt "
        h.appendLE(UInt32(16)); h.appendLE(UInt16(1)); h.appendLE(ch); h.appendLE(sr)
        h.appendLE(sr * UInt32(ch) * UInt32(bps) / 8)
        h.appendLE(ch * bps / 8)
        h.appendLE(bps)
        h += "data"
        h.appendLE(UInt32(audioBytes.count))
        return h + audioBytes
    }
}

private struct ParakeetResponse: Decodable { let text: String }

// MARK: - Data helpers

private extension Data {
    static func += (lhs: inout Data, rhs: String) { lhs.append(contentsOf: rhs.utf8) }

    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var remaining = v.littleEndian
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    mutating func mpAppend(boundary: String, name: String, string: String) {
        self += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(string)\r\n"
    }

    mutating func mpAppend(boundary: String, name: String, filename: String, mime: String, data: Data) {
        self += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n"
        append(data)
        self += "\r\n"
    }
}
