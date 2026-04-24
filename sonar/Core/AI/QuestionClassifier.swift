import Foundation

/// Detects "question with rising intonation followed by silence" so the AI
/// can offer to chime in. Plan §8.2 trigger #2.
final class QuestionClassifier {
    func observed(utterance: String, endsWithRisingPitch: Bool, silenceAfter seconds: TimeInterval) -> Bool {
        endsWithRisingPitch && seconds >= 3.0
    }
}
