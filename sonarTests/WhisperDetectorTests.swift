import AVFoundation
import XCTest
@testable import Sonar

final class WhisperDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a PCM buffer whose RMS maps to approximately `dbSPL` using
    /// the WhisperDetector's own formula: dbSPL = 20*log10(rms) + 94
    private func buffer(dbSPL: Float, frameCount: Int = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        let ptr = buf.floatChannelData![0]
        // rms = 10 ^ ((dbSPL - 94) / 20)
        let rms = pow(10.0, (dbSPL - 94.0) / 20.0)
        for i in 0..<frameCount { ptr[i] = (i % 2 == 0) ? rms : -rms }
        return buf
    }

    private func silentBuffer(frameCount: Int = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        return buf   // floatChannelData values default to 0
    }

    private func emptyBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        buf.frameLength = 0        // zero-length
        return buf
    }

    // MARK: - Silence (< 20 dBSPL) — excluded by "avg > 20" guard

    func testTotalSilenceIsNotWhisper() {
        let d = WhisperDetector()
        for _ in 0..<15 { d.process(silentBuffer()) }
        XCTAssertFalse(d.isWhispering.value, "Silence (0 dBSPL) must not trigger whisper")
    }

    // MARK: - Loud speech (> 40 dBSPL) — above threshold

    func testLoudSpeechIsNotWhisper() {
        let d = WhisperDetector()
        for _ in 0..<15 { d.process(buffer(dbSPL: 65)) }
        XCTAssertFalse(d.isWhispering.value, "Loud speech (65 dBSPL) must not trigger whisper")
    }

    func testVeryLoudBufferIsNotWhisper() {
        let d = WhisperDetector()
        for _ in 0..<15 { d.process(buffer(dbSPL: 90)) }
        XCTAssertFalse(d.isWhispering.value)
    }

    // MARK: - Whisper (20 – 40 dBSPL) — below threshold, above silence floor

    func testWhisperRangeIsDetected() {
        let d = WhisperDetector()
        // 30 dBSPL is squarely within the whisper zone (20 < 30 < 40)
        for _ in 0..<15 { d.process(buffer(dbSPL: 30)) }
        XCTAssertTrue(d.isWhispering.value, "30 dBSPL should be detected as whispering")
    }

    func testBoundaryJustBelowThreshold() {
        let d = WhisperDetector()
        // 39 dBSPL — just below the 40 dBSPL threshold
        for _ in 0..<15 { d.process(buffer(dbSPL: 39)) }
        XCTAssertTrue(d.isWhispering.value, "39 dBSPL should be detected as whispering")
    }

    // MARK: - Zero-length buffer safety

    func testEmptyBufferDoesNotCrash() {
        let d = WhisperDetector()
        // Must not crash or set isWhispering
        d.process(emptyBuffer())
        XCTAssertFalse(d.isWhispering.value)
    }

    func testEmptyBufferDoesNotPoisonHistory() {
        let d = WhisperDetector()
        // Fill history with whisper-level frames, then inject an empty buffer.
        // The rolling average should still register as whispering.
        for _ in 0..<9  { d.process(buffer(dbSPL: 30)) }
        d.process(emptyBuffer())                             // must not reset state
        d.process(buffer(dbSPL: 30))                        // 10th frame — window full
        XCTAssertTrue(d.isWhispering.value,
                      "Empty buffer must not corrupt rolling average")
    }

    // MARK: - Windowing: 10-frame rolling window

    func testWhisperClearsAfterWindowOfSilence() {
        let d = WhisperDetector()
        // Establish whisper
        for _ in 0..<10 { d.process(buffer(dbSPL: 30)) }
        XCTAssertTrue(d.isWhispering.value)

        // Push loud frames through the window (11 frames to fully evict whisper history)
        for _ in 0..<11 { d.process(buffer(dbSPL: 70)) }
        XCTAssertFalse(d.isWhispering.value, "Loud speech should clear whisper detection")
    }

    func testWindowSizeIsEffectivelyTenFrames() {
        let d = WhisperDetector()
        // 9 whisper frames followed by 9 loud frames: average still has whisper contamination
        for _ in 0..<9 { d.process(buffer(dbSPL: 30)) }
        for _ in 0..<9 { d.process(buffer(dbSPL: 70)) }
        // After 10 frame window, the last 10 are 1 whisper + 9 loud → avg loud → no whisper
        XCTAssertFalse(d.isWhispering.value)
    }
}
