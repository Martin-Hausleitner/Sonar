import Foundation

/// Rolling 2-minute transcript so the AI has recent context. Plan §2.1 L5.
@MainActor
final class ContextBuffer {
    struct Entry: Sendable {
        let speakerID: String
        let text: String
        let at: Date
    }

    private var entries: [Entry] = []
    private let window: TimeInterval = 120

    func append(_ entry: Entry) {
        entries.append(entry)
        let cutoff = Date().addingTimeInterval(-window)
        entries.removeAll { $0.at < cutoff }
    }

    func snapshot() -> [Entry] { entries }
}
