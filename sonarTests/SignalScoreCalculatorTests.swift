import Combine
import XCTest
@testable import Sonar

final class SignalScoreCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private func metrics(
        rttMs: Double = 30,
        lossPercent: Double = 0,
        jitterMs: Double = 0,
        activePaths: Int = 4
    ) -> NetworkMetrics {
        NetworkMetrics(rttMs: rttMs, lossPercent: lossPercent,
                       jitterMs: jitterMs, activePaths: activePaths)
    }

    // MARK: - Near-perfect conditions → high score

    func testPerfectConditionsScoreNear100() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 30, lossPercent: 0, jitterMs: 0, activePaths: 4))
        // latencyScore = 100, lossScore = 100, jitterScore = 100, pathScore = 100
        // weighted = 100 * 0.3 + 100 * 0.4 + 100 * 0.2 + 100 * 0.1 = 100
        XCTAssertGreaterThanOrEqual(calc.score, 95)
    }

    // MARK: - Packet loss

    func testFivePercentLossReducesScore() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 30, lossPercent: 5, jitterMs: 0, activePaths: 4))
        // lossScore = max(0, 100 - 5*20) = 0
        // weighted = 100*0.3 + 0*0.4 + 100*0.2 + 100*0.1 = 30+0+20+10 = 60
        XCTAssertLessThan(calc.score, 90)
        XCTAssertGreaterThanOrEqual(calc.score, 55)
    }

    func testHundredPercentLossGivesVeryLowScore() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 30, lossPercent: 100, jitterMs: 0, activePaths: 4))
        // lossScore = 0, everything else max
        // weighted = 30 + 0 + 20 + 10 = 60
        XCTAssertLessThan(calc.score, 70)
    }

    // MARK: - High RTT

    func testHighRTTReducesScore() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 280, lossPercent: 0, jitterMs: 0, activePaths: 4))
        // latencyScore = max(0, 100 - (280-30)/5) = max(0, 100-50) = 50
        // weighted = 50*0.3 + 100*0.4 + 100*0.2 + 100*0.1 = 15+40+20+10 = 85
        XCTAssertLessThanOrEqual(calc.score, 90)
        XCTAssertGreaterThanOrEqual(calc.score, 80)
    }

    func testExtremeRTTClampsLatencyScoreToZero() {
        let calc = SignalScoreCalculator()
        // RTT so high that latencyScore would be negative → clamped to 0
        calc.update(metrics(rttMs: 5000, lossPercent: 0, jitterMs: 0, activePaths: 4))
        // latencyScore = 0, lossScore = 100, jitterScore = 100, pathScore = 100
        // weighted = 0 + 40 + 20 + 10 = 70
        XCTAssertLessThan(calc.score, 75)
    }

    // MARK: - Grades

    func testExcellentGradeForHighScore() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 30, lossPercent: 0, jitterMs: 0, activePaths: 4))
        XCTAssertEqual(calc.grade, .excellent)
    }

    func testUnstableGradeForLowScore() {
        let calc = SignalScoreCalculator()
        // Worst case: max loss + high RTT + max jitter + 1 path
        calc.update(metrics(rttMs: 5000, lossPercent: 100, jitterMs: 100, activePaths: 1))
        XCTAssertEqual(calc.grade, .unstable)
    }

    func testGoodGradeRange() {
        let calc = SignalScoreCalculator()
        // Aim for score in 80-94 range:
        // RTT 280 → latencyScore 50; no loss; no jitter; 4 paths
        // weighted = 15 + 40 + 20 + 10 = 85
        calc.update(metrics(rttMs: 280, lossPercent: 0, jitterMs: 0, activePaths: 4))
        XCTAssertEqual(calc.grade, .good)
    }

    func testPoorGradeRange() {
        let calc = SignalScoreCalculator()
        // Aim for score 40-59:
        // 5% loss → lossScore 0; RTT 280 → latencyScore 50; 1 path
        // weighted = 50*0.3 + 0*0.4 + 100*0.2 + 25*0.1 = 15+0+20+2.5 = 37.5 → 37
        // That's .unstable. Let's try 2% loss with 280 RTT:
        // lossScore = max(0,100-40) = 60
        // weighted = 15 + 24 + 20 + 10 = 69 → .ok
        // For poor (40-59): 5% loss, 2 paths, RTT=30
        // lossScore=0, latency=100, jitter=100, pathScore=50
        // weighted = 30+0+20+5 = 55 → .poor
        calc.update(metrics(rttMs: 30, lossPercent: 5, jitterMs: 0, activePaths: 2))
        XCTAssertEqual(calc.grade, .poor)
    }

    // MARK: - update() changes published score

    func testUpdateChangesPublishedScore() {
        let calc = SignalScoreCalculator()
        let initial = calc.score
        calc.update(metrics(rttMs: 5000, lossPercent: 50, jitterMs: 50, activePaths: 1))
        XCTAssertNotEqual(calc.score, initial,
                          "update() should change the published score")
    }

    func testUpdateChangesPublishedGrade() {
        let calc = SignalScoreCalculator()
        // Start with excellent
        calc.update(metrics(rttMs: 30, lossPercent: 0, jitterMs: 0, activePaths: 4))
        XCTAssertEqual(calc.grade, .excellent)

        // Then degrade hard
        calc.update(metrics(rttMs: 5000, lossPercent: 100, jitterMs: 100, activePaths: 1))
        XCTAssertNotEqual(calc.grade, .excellent)
    }

    func testScorePublishedViaPublisher() {
        let calc = SignalScoreCalculator()
        var scores: [Int] = []
        var cancellables = Set<AnyCancellable>()

        calc.$score
            .sink { scores.append($0) }
            .store(in: &cancellables)

        calc.update(metrics(rttMs: 30, lossPercent: 0, jitterMs: 0, activePaths: 4))
        calc.update(metrics(rttMs: 5000, lossPercent: 100, jitterMs: 100, activePaths: 1))

        XCTAssertGreaterThanOrEqual(scores.count, 2)
    }

    // MARK: - Score is clamped to 0-100

    func testScoreNeverExceeds100() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 0, lossPercent: 0, jitterMs: 0, activePaths: 4))
        XCTAssertLessThanOrEqual(calc.score, 100)
    }

    func testScoreNeverBelowZero() {
        let calc = SignalScoreCalculator()
        calc.update(metrics(rttMs: 100_000, lossPercent: 100, jitterMs: 100_000, activePaths: 0))
        XCTAssertGreaterThanOrEqual(calc.score, 0)
    }
}
