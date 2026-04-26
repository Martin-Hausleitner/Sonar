import AVFoundation
import Combine
import Foundation
import Speech

/// Drives transcription via the best available engine.
/// Priority: NVIDIA Parakeet (when API key configured) → Apple SFSpeechRecognizer.
@MainActor
final class LiveTranscriptionEngine: ObservableObject {
    enum Engine { case appleSpeech, parakeet }

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

    func start(language: Locale = .current) async throws {
        currentEngine = pickEngine(language: language)
        switch currentEngine {
        case .appleSpeech:
            let authorized = await requestAuthorization()
            guard authorized else { return }
            try startAppleSpeech(language: language)
        case .parakeet:
            let key = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
            parakeet = ParakeetTranscriber(apiKey: key) { [weak self] text in
                guard let self else { return }
                let seg = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: true)
                self.transcript.append(seg)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        switch currentEngine {
        case .appleSpeech: request?.append(buffer)
        case .parakeet:    parakeet?.append(buffer)
        }
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        parakeet?.flush()
        parakeet = nil
    }

    // MARK: - Engine selection

    private func pickEngine(language: Locale) -> Engine {
        let key = UserDefaults.standard.string(forKey: "sonar.parakeet.apiKey") ?? ""
        if !key.isEmpty { return .parakeet }
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
