import XCTest
@testable import Sonar

@MainActor
final class RecordingPlayerViewTests: XCTestCase {
    func testFormatZero() {
        XCTAssertEqual(RecordingPlayerView.format(seconds: 0), "00:00")
    }

    func testFormatSecondsAndMinutes() {
        XCTAssertEqual(RecordingPlayerView.format(seconds: 5), "00:05")
        XCTAssertEqual(RecordingPlayerView.format(seconds: 65), "01:05")
        XCTAssertEqual(RecordingPlayerView.format(seconds: 599), "09:59")
    }

    func testFormatHours() {
        XCTAssertEqual(RecordingPlayerView.format(seconds: 3600), "1:00:00")
        XCTAssertEqual(RecordingPlayerView.format(seconds: 3661), "1:01:01")
    }

    func testFormatHandlesInvalidValues() {
        XCTAssertEqual(RecordingPlayerView.format(seconds: -1), "--:--")
        XCTAssertEqual(RecordingPlayerView.format(seconds: .nan), "--:--")
        XCTAssertEqual(RecordingPlayerView.format(seconds: .infinity), "--:--")
    }

    func testFormatTruncatesFractional() {
        // 5.9 should still display as 00:05 (truncate, not round).
        XCTAssertEqual(RecordingPlayerView.format(seconds: 5.9), "00:05")
    }
}
