import Combine
import Foundation

/// Live signal quality score 0-100. §10.
/// Weights: loss 40 %, latency 30 %, jitter 20 %, path diversity 10 %.
struct NetworkMetrics: Sendable {
    var rttMs: Double       // round-trip time
    var lossPercent: Double // 0..100
    var jitterMs: Double
    var activePaths: Int    // 1..4
}

final class SignalScoreCalculator: @unchecked Sendable {
    @Published private(set) var score: Int = 100
    @Published private(set) var grade: Grade = .excellent

    enum Grade: Sendable {
        case excellent, good, ok, poor, unstable

        var label: String {
            switch self {
            case .excellent: "Excellent"
            case .good:      "Good"
            case .ok:        "OK"
            case .poor:      "Poor"
            case .unstable:  "Unstable"
            }
        }
    }

    func update(_ m: NetworkMetrics) {
        let latencyScore = max(0.0, 100.0 - (m.rttMs - 30.0) / 5.0)
        let lossScore    = max(0.0, 100.0 - m.lossPercent * 20.0)
        let jitterScore  = max(0.0, 100.0 - m.jitterMs * 5.0)
        let pathScore    = Double(m.activePaths) * 25.0

        let weighted = latencyScore * 0.3 + lossScore * 0.4 + jitterScore * 0.2 + pathScore * 0.1
        score = min(100, max(0, Int(weighted)))
        grade = gradeFor(score)
    }

    private func gradeFor(_ s: Int) -> Grade {
        switch s {
        case 95...100: .excellent
        case 80..<95:  .good
        case 60..<80:  .ok
        case 40..<60:  .poor
        default:       .unstable
        }
    }
}
