import AVFoundation
import XCTest
@testable import Sonar

final class SmartMuteDetectorTests: XCTestCase {

    // MARK: - PCM buffer helpers

    /// Creates a 10ms 48kHz mono buffer filled with a constant value.
    private func makeSilentBuffer() -> AVAudioPCMBuffer {
        return makePCMBuffer(samples: Array(repeating: 0.0, count: 480))
    }

    /// Fills all samples with `value`.
    private func makeConstantBuffer(value: Float) -> AVAudioPCMBuffer {
        return makePCMBuffer(samples: Array(repeating: value, count: 480))
    }

    /// Creates a buffer with a large spike followed by low-level noise.
    /// This produces a very high crest factor (peak >> RMS).
    ///
    /// SmartMuteDetector triggers when: crestFactor > 8.0 && rms > 0.02
    ///   crestFactor = peak / rms
    ///
    /// Strategy: one large spike (peak ≈ 1.0) with the rest at a small
    /// non-zero value so rms > 0.02 but peak/rms >> 8.
    private func makeImpulseBuffer() -> AVAudioPCMBuffer {
        var samples = Array(repeating: Float(0.05), count: 480)
        samples[0] = 1.0   // single spike
        return makePCMBuffer(samples: samples)
    }

    private func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let data = buf.floatChannelData {
            for (i, v) in samples.enumerated() { data[0][i] = v }
        }
        return buf
    }

    // MARK: - Silence does not mute

    func testSilenceDoesNotTriggerMute() {
        let detector = SmartMuteDetector()
        detector.process(makeSilentBuffer())
        XCTAssertFalse(detector.shouldMute.value,
                       "All-zero buffer should not trigger mute")
    }

    func testRepeatedSilenceDoesNotTriggerMute() {
        let detector = SmartMuteDetector()
        for _ in 0..<20 { detector.process(makeSilentBuffer()) }
        XCTAssertFalse(detector.shouldMute.value)
    }

    // MARK: - Impulse triggers mute

    func testImpulseTriggersAutoMute() {
        let detector = SmartMuteDetector()
        detector.process(makeImpulseBuffer())
        XCTAssertTrue(detector.shouldMute.value,
                      "High crest factor + sufficient RMS should trigger mute")
    }

    func testMuteWindowRemainsActiveShortlyAfterImpulse() {
        let detector = SmartMuteDetector()
        detector.process(makeImpulseBuffer())
        // Immediately after the impulse the 500ms mute window should still be active
        detector.process(makeSilentBuffer())
        XCTAssertTrue(detector.shouldMute.value,
                      "Mute should remain active within the 500ms window")
    }

    // MARK: - Constant loud sound does NOT trigger mute (low crest factor)

    func testConstantLoudSoundDoesNotMute() {
        // A constant non-zero value has crestFactor = 1.0 (peak == rms), far below 8.
        let detector = SmartMuteDetector()
        detector.process(makeConstantBuffer(value: 0.5))
        XCTAssertFalse(detector.shouldMute.value,
                       "Constant loud sound has crestFactor ~1, should NOT mute")
    }

    // MARK: - shouldMute publisher emits changes

    func testShouldMutePublisherEmitsOnImpulse() {
        let detector = SmartMuteDetector()
        var emittedValues: [Bool] = []
        let cancellable = detector.shouldMute.sink { emittedValues.append($0) }

        detector.process(makeSilentBuffer())  // stays false
        detector.process(makeImpulseBuffer()) // goes true

        XCTAssertTrue(emittedValues.contains(true),
                      "Publisher should have emitted true after impulse")
        cancellable.cancel()
    }

    // MARK: - Crest factor boundary

    func testBelowCrestFactorThresholdDoesNotMute() {
        // crestFactor exactly at boundary: peak / rms = 8.0 (not > 8.0)
        // We use a constant buffer where peak == rms → crestFactor = 1
        let detector = SmartMuteDetector()

        // Construct buffer where crestFactor is just below 8:
        // peak = 0.16, all samples = 0.02 → rms ≈ 0.02, peak/rms = 8 exactly
        // 8.0 is NOT > 8.0, so should not trigger
        var samples = Array(repeating: Float(0.02), count: 480)
        samples[0] = 0.16   // peak/rms = 0.16/0.02 = 8.0 (not strictly greater)
        // Note: with 479 samples at 0.02 and 1 sample at 0.16,
        // rms = sqrt((479*0.02^2 + 0.16^2)/480) ≈ sqrt((0.1916+0.0256)/480) ≈ 0.02125
        // peak/rms ≈ 7.5 → below threshold
        let buf = makePCMBuffer(samples: samples)
        detector.process(buf)
        XCTAssertFalse(detector.shouldMute.value,
                       "crestFactor ≤ 8 should not trigger mute")
    }
}
