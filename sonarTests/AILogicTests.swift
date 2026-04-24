import XCTest
@testable import Sonar

@MainActor
final class ContextBufferTests: XCTestCase {
    func testAppendKeepsRecentEntries() {
        let buf = ContextBuffer()
        buf.append(.init(speakerID: "a", text: "hi", at: Date()))
        XCTAssertEqual(buf.snapshot().count, 1)
    }

    func testEvictsEntriesOlderThanWindow() {
        let buf = ContextBuffer()
        let old = Date().addingTimeInterval(-300)
        buf.append(.init(speakerID: "a", text: "old", at: old))
        buf.append(.init(speakerID: "a", text: "new", at: Date()))
        XCTAssertEqual(buf.snapshot().count, 1)
        XCTAssertEqual(buf.snapshot().first?.text, "new")
    }
}

final class QuestionClassifierTests: XCTestCase {
    func testRisingPitchPlusLongSilenceTriggers() {
        let q = QuestionClassifier()
        XCTAssertTrue(q.observed(utterance: "Wann?", endsWithRisingPitch: true, silenceAfter: 3.5))
    }

    func testShortSilenceDoesNotTrigger() {
        let q = QuestionClassifier()
        XCTAssertFalse(q.observed(utterance: "Wann?", endsWithRisingPitch: true, silenceAfter: 2.0))
    }

    func testFallingPitchNeverTriggers() {
        let q = QuestionClassifier()
        XCTAssertFalse(q.observed(utterance: "OK.", endsWithRisingPitch: false, silenceAfter: 30))
    }
}
