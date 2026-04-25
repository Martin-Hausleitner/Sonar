import AVFoundation
import Combine
import Foundation
import Speech

/// Selects and drives the best available on-device transcription engine. §5.
/// Priority: Apple SpeechAnalyzer → WhisperKit (via model availability check).
@MainActor
final class LiveTranscriptionEngine: ObservableObject {
    enum Engine { case appleSpeech, whisperKit }

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
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func start(language: Locale = .current) async throws {
        let authorized = await requestAuthorization()
        guard authorized else { return }

        currentEngine = pickEngine(language: language)
        switch currentEngine {
        case .appleSpeech: try startAppleSpeech(language: language)
        case .whisperKit:  break // WhisperKit integration via Swift package when added
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    // MARK: - Engine selection (§5.1)

    private func pickEngine(language: Locale) -> Engine {
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(language) { return .appleSpeech }
        return .whisperKit
    }

    // MARK: - Apple SpeechAnalyzer path

    private func startAppleSpeech(language: Locale) throws {
        recognizer = SFSpeechRecognizer(locale: language)
        recognizer?.defaultTaskHint = .confirmation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        self.request = req

        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            let segment = Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: result.isFinal)
            Task { @MainActor in
                if let last = self.transcript.last, !last.isFinal {
                    self.transcript[self.transcript.count - 1] = segment
                } else {
                    self.transcript.append(segment)
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
