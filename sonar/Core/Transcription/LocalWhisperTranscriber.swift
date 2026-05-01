import AVFoundation
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

protocol LocalTranscribing: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

enum WhisperKitLocalTranscriber {
    @MainActor
    static func make(
        modelID: String,
        language: Locale,
        onSegment: @escaping (String) -> Void
    ) -> LocalTranscribing? {
        guard
            let model = LocalModelManager.availableModels.first(where: { $0.id == modelID }),
            let modelFolder = LocalModelManager.shared.localURL(for: model)
        else {
            return nil
        }

        #if canImport(WhisperKit)
        return WhisperKitBufferedTranscriber(
            modelName: model.whisperKitVariant,
            modelFolder: modelFolder,
            language: language,
            onSegment: onSegment
        )
        #else
        return nil
        #endif
    }
}

#if canImport(WhisperKit)
private final class WhisperKitBufferedTranscriber: LocalTranscribing {
    private let modelName: String
    private let modelFolder: URL
    private let language: Locale
    private let onSegment: (String) -> Void
    private let sampleRate: Double = 16_000
    private let chunkDuration: Double = 5.0
    private let queue = DispatchQueue(label: "sonar.local-whisper", qos: .userInitiated)

    private var samples: [Float] = []
    private var pipeline: WhisperKit?
    private var stopped = false

    init(modelName: String, modelFolder: URL, language: Locale, onSegment: @escaping (String) -> Void) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.language = language
        self.onSegment = onSegment
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let incoming = Array(UnsafeBufferPointer(start: channel, count: count))
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.samples.append(contentsOf: incoming)
            let chunkSize = Int(self.sampleRate * self.chunkDuration)
            while self.samples.count >= chunkSize {
                let chunk = Array(self.samples.prefix(chunkSize))
                self.samples.removeFirst(chunkSize)
                self.transcribe(chunk)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            if !self.samples.isEmpty {
                let chunk = self.samples
                self.samples = []
                self.transcribe(chunk)
            }
        }
    }

    private func transcribe(_ chunk: [Float]) {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let wavURL = try Self.writeTemporaryWAV(samples: chunk, sampleRate: self.sampleRate)
                defer { try? FileManager.default.removeItem(at: wavURL) }
                let pipe = try await self.pipeline()
                let results = try await pipe.transcribe(
                    audioPath: wavURL.path,
                    decodeOptions: DecodingOptions(language: Self.whisperLanguageCode(for: self.language))
                )
                let text = TranscriptionUtilities.mergeTranscriptionResults(results).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                DispatchQueue.main.async { self.onSegment(text) }
            } catch {
                Log.ai.error("Local Whisper transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func pipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path,
            load: true,
            download: false
        )
        let pipeline = try await WhisperKit(config)
        self.pipeline = pipeline
        return pipeline
    }

    private static func writeTemporaryWAV(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonar-whisper-\(UUID().uuidString).wav")
        try buildWAV(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        return url
    }

    private static func whisperLanguageCode(for locale: Locale) -> String {
        let identifier = locale.identifier
        if let separator = identifier.firstIndex(where: { $0 == "_" || $0 == "-" }) {
            return String(identifier[..<separator])
        }
        return identifier
    }

    private static func buildWAV(samples: [Float], sampleRate: Double) -> Data {
        let int16: [Int16] = samples.map {
            Int16(clamping: Int32(max(-1, min(1, $0)) * 32767))
        }
        let audioBytes = int16.withUnsafeBufferPointer { Data(buffer: $0) }
        let sr = UInt32(sampleRate)
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + audioBytes.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels)
        data.appendLE(sr)
        data.appendLE(sr * UInt32(channels) * UInt32(bitsPerSample) / 8)
        data.appendLE(channels * bitsPerSample / 8)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(audioBytes.count))
        data.append(audioBytes)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var remaining = value.littleEndian
        Swift.withUnsafeBytes(of: &remaining) { append(contentsOf: $0) }
    }
}
#endif
