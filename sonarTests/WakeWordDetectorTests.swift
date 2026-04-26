import AVFoundation
import XCTest

@testable import Sonar

final class WakeWordDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func makePCMBuffer(rms: Float, sampleRate: Double = 16_000, frameCount: Int = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buf.floatChannelData![0]
        // Fill with a constant amplitude that produces the requested RMS.
        let amp = rms
        for i in 0..<frameCount { ptr[i] = (i % 2 == 0) ? amp : -amp }
        return buf
    }

    private func silentBuffer() -> AVAudioPCMBuffer { makePCMBuffer(rms: 0.001) }
    private func loudBuffer()  -> AVAudioPCMBuffer { makePCMBuffer(rms: 0.10)  }

    // MARK: - Tests

    func testSilenceNeverTriggers() {
        let detector = WakeWordDetector()
        detector.start()

        var fired = false
        let sub = detector.triggered.sink { fired = true }

        for _ in 0..<20 { detector.feed(silentBuffer()) }

        XCTAssertFalse(fired)
        sub.cancel()
    }

    func testTwoSpikesWithinWindowTrigger() {
        let detector = WakeWordDetector()
        detector.start()

        var count = 0
        let sub = detector.triggered.sink { count += 1 }

        detector.feed(loudBuffer())   // first spike
        detector.feed(loudBuffer())   // second spike — within window

        XCTAssertEqual(count, 1)
        sub.cancel()
    }

    func testSingleSpikeDoesNotTrigger() {
        let detector = WakeWordDetector()
        detector.start()

        var fired = false
        let sub = detector.triggered.sink { fired = true }

        detector.feed(loudBuffer())   // only one spike

        XCTAssertFalse(fired)
        sub.cancel()
    }

    func testStopPreventsTriggering() {
        let detector = WakeWordDetector()
        detector.start()
        detector.stop()

        var fired = false
        let sub = detector.triggered.sink { fired = true }

        detector.feed(loudBuffer())
        detector.feed(loudBuffer())

        XCTAssertFalse(fired)
        sub.cancel()
    }

    func testRestartAfterStopWorks() {
        let detector = WakeWordDetector()
        detector.start()
        detector.stop()
        detector.start()

        var count = 0
        let sub = detector.triggered.sink { count += 1 }

        detector.feed(loudBuffer())
        detector.feed(loudBuffer())

        XCTAssertEqual(count, 1)
        sub.cancel()
    }

    func testTriggerResetsHitBuffer() {
        let detector = WakeWordDetector()
        detector.start()

        var count = 0
        let sub = detector.triggered.sink { count += 1 }

        // First trigger
        detector.feed(loudBuffer())
        detector.feed(loudBuffer())
        XCTAssertEqual(count, 1)

        // Feed one more spike — should NOT immediately trigger again (counter was reset)
        detector.feed(loudBuffer())
        XCTAssertEqual(count, 1)

        // Second spike completes a new two-spike sequence
        detector.feed(loudBuffer())
        XCTAssertEqual(count, 2)

        sub.cancel()
    }

    func testEmptyBufferIsIgnored() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        empty.frameLength = 0

        let detector = WakeWordDetector()
        detector.start()

        var fired = false
        let sub = detector.triggered.sink { fired = true }

        detector.feed(empty)

        XCTAssertFalse(fired)
        sub.cancel()
    }
}
