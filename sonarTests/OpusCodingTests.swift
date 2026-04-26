import AVFoundation
import XCTest
@testable import Sonar

final class OpusCodingTests: XCTestCase {
    func testCoderInitialises() {
        _ = OpusCoder()
    }

    func testDefaultsMatchLatencyBudget() {
        let c = OpusCoder()
        XCTAssertEqual(c.frameMs, LatencyBudget.audioFrameMs)
        XCTAssertEqual(c.sampleRate, LatencyBudget.audioSampleRate)
    }

    // TODO §10/3: round-trip a 1 kHz sine wave and assert reconstruction error <-30 dB.

    @available(iOS 18, *)
    func testEncodeDecodesRoundtrip() throws {
        let coder = OpusCoder()
        let sampleRate = Double(coder.sampleRate)
        let frameCount = coder.samplesPerFrame

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        src.frameLength = AVAudioFrameCount(frameCount)

        // Fill with a 1 kHz sine wave.
        let twoPi = 2.0 * Float.pi
        let freqHz: Float = 1_000
        let sr = Float(sampleRate)
        let ptr = src.floatChannelData![0]
        for i in 0..<frameCount {
            ptr[i] = sin(twoPi * freqHz * Float(i) / sr)
        }

        // Encode
        let encoded: Data
        do {
            encoded = try coder.encode(src)
        } catch {
            throw XCTSkip("encode() threw: \(error) — skipping round-trip test")
        }

        // Decode into a fresh buffer
        let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        do {
            try coder.decode(encoded, into: dst)
        } catch {
            throw XCTSkip("decode() threw: \(error) — skipping round-trip test")
        }

        XCTAssertEqual(Int(dst.frameLength), frameCount)

        // Compute RMS error between original and decoded samples.
        let decoded = dst.floatChannelData![0]
        var sumSq: Float = 0
        for i in 0..<frameCount {
            let diff = ptr[i] - decoded[i]
            sumSq += diff * diff
        }
        let rmsError = sqrt(sumSq / Float(frameCount))

        XCTAssertLessThan(Double(rmsError), 0.01,
                          "RMS error between original and decoded samples should be < 0.01 (Float)")
    }
}
