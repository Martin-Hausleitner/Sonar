import Foundation

/// Local metrics sink. Plan §11.
@MainActor
final class Metrics {
    static let shared = Metrics()

    struct Sample: Sendable {
        let key: String
        let value: Double
        let at: Date
    }

    private var samples: [Sample] = []

    func record(_ key: String, _ value: Double) {
        samples.append(Sample(key: key, value: value, at: Date()))
        // TODO §10/15: flush to local SQLite, expose in SettingsView debug pane.
    }

    func recent(_ key: String, count: Int = 50) -> [Sample] {
        samples.filter { $0.key == key }.suffix(count).map { $0 }
    }
}
