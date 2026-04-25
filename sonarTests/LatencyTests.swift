import AVFoundation
import Darwin
import XCTest
@testable import Sonar

/// Headless tests for the latency budget contract. These verify that the
/// numbers in `LATENCY.md` are wired into code and that the per-stage timing
/// instrumentation works as advertised. They do NOT measure real audio
/// hardware — that's `E2E_TESTPLAN.md` TC-05.
final class LatencyBudgetTests: XCTestCase {
    func testFrameSizeIs10msAt48kHz() {
        XCTAssertEqual(LatencyBudget.audioFrameMs, 10)
        XCTAssertEqual(LatencyBudget.audioSampleRate, 48_000)
        XCTAssertEqual(LatencyBudget.samplesPerFrame, 480)
    }

    func testJitterBufferIsTighterForNear() {
        XCTAssertLessThan(
            LatencyBudget.jitterBufferMsNear,
            LatencyBudget.jitterBufferMsFar,
            "Near is in-WLAN, can afford a smaller jitter buffer"
        )
    }

    func testCrossfadeIsHalfOfOldDefault() {
        XCTAssertEqual(LatencyBudget.crossfadeMs, 100)
    }

    func testDuplicateSuppressorWindowMatchesAirPodsRoundTrip() {
        // ~80 ms typical AirPods round-trip + 20 ms slack = 100.
        XCTAssertEqual(LatencyBudget.duplicateSuppressorWindowMs, 100)
    }

    func testNearTargetUnderConversationThreshold() {
        // < 100 ms = humans don't notice in conversation.
        XCTAssertLessThanOrEqual(LatencyBudget.nearTargetGlassToGlassMs, 100)
    }

    func testFarTargetUnderTolerableThreshold() {
        XCTAssertLessThanOrEqual(LatencyBudget.farTargetGlassToGlassMs, 300)
    }

    func testOpusCoderHonoursLatencyBudget() {
        let c = OpusCoder()
        XCTAssertEqual(c.frameMs, LatencyBudget.audioFrameMs)
        XCTAssertEqual(c.sampleRate, LatencyBudget.audioSampleRate)
        XCTAssertEqual(c.bitrate, LatencyBudget.opusBitrateBps)
        XCTAssertEqual(c.samplesPerFrame, LatencyBudget.samplesPerFrame)
        XCTAssertEqual(c.theoreticalEncodeLatencyMs, 10)
    }
}

final class MetricsTests: XCTestCase {
    func testMachTimebaseConversion() {
        // 1 second worth of nanoseconds, converted via the Trace's helper.
        let oneSecondTicks = nanosToMachTicks(1_000_000_000)
        let ms = Metrics.Trace.ticksToMs(oneSecondTicks)
        XCTAssertEqual(ms, 1_000.0, accuracy: 0.5)
    }

    func testTraceIDsAreUnique() {
        let m = Metrics()
        var seen = Set<UInt64>()
        for _ in 0..<1000 {
            let id = m.openTrace()
            XCTAssertFalse(seen.contains(id), "duplicate trace id \(id)")
            seen.insert(id)
        }
    }

    func testTraceMarkAndElapsedRoundTrip() {
        let m = Metrics()
        let id = m.openTrace()
        m.mark(id, .captured)
        // Spin briefly so .rendered is measurably after .captured.
        let start = Date()
        while Date().timeIntervalSince(start) < 0.002 {}  // 2 ms
        m.mark(id, .rendered)

        let trace = m.snapshot().first { $0.frameID == id }!
        let total = trace.glassToGlassMs ?? 0
        XCTAssertGreaterThan(total, 1.5, "should be ≥ ~2 ms")
        XCTAssertLessThan(total, 50, "spin-loop should be well under 50 ms")
    }

    func testCapacityEvictsOldest() {
        let m = Metrics()
        for _ in 0..<700 {
            let id = m.openTrace()
            m.mark(id, .captured)
        }
        XCTAssertLessThanOrEqual(m.snapshot().count, 500)
    }

    func testPercentilesNeedSamples() {
        let m = Metrics()
        XCTAssertNil(m.percentiles(.captured, .rendered))
    }

    private func nanosToMachTicks(_ nanos: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return nanos &* UInt64(info.denom) / UInt64(info.numer)
    }
}

/// End-to-end pipeline tests: synthetic 1 kHz sine → AudioEngine-style
/// AVAudioPCMBuffer → DuplicateVoiceSuppressor + OpusCoder shape-checks.
/// No real audio hardware involved; runs on the iOS Simulator inside CI.
final class E2EAudioPipelineTests: XCTestCase {
    func testPCMBufferAt48kHzMonoMatchesFrameSize() throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate,
            channels: 1
        )!
        let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        )!
        buf.frameLength = AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        XCTAssertEqual(Int(buf.frameLength), LatencyBudget.samplesPerFrame)
        XCTAssertEqual(buf.format.sampleRate, 48_000)
        XCTAssertEqual(buf.format.channelCount, 1)
    }

    func testSineFillSurvivesRoundTripSetup() throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate,
            channels: 1
        )!
        let frames = AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames

        let ptr = buf.floatChannelData![0]
        let twoPi = 2 * Float.pi
        let freqHz: Float = 1_000
        let sr = Float(LatencyBudget.audioSampleRate)
        for i in 0..<Int(frames) {
            ptr[i] = sin(twoPi * freqHz * Float(i) / sr)
        }
        // First sample of a sine starting at phase 0 == 0.
        XCTAssertEqual(ptr[0], 0, accuracy: 1e-3)
        // Sample at quarter-period of 1 kHz @ 48 kHz = sample 12 ≈ peak.
        XCTAssertEqual(ptr[12], 1, accuracy: 0.05)
    }

    func testSuppressorAcceptsRealPCMBuffers() throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate,
            channels: 1
        )!
        let frames = AVAudioFrameCount(LatencyBudget.samplesPerFrame)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames

        let suppressor = DuplicateVoiceSuppressor()
        // No outgoing fingerprints yet → nothing to correlate against → full pass.
        let pass = suppressor.analyzeIncomingMic(buf)
        XCTAssertEqual(pass, 1.0, accuracy: 1e-6)
    }

    func testEndToEndStageInstrumentation() throws {
        let m = Metrics()
        let id = m.openTrace()
        m.mark(id, .captured)
        m.mark(id, .encoded)
        m.mark(id, .sentOnWire)
        m.mark(id, .receivedOnWire)
        m.mark(id, .decoded)
        m.mark(id, .rendered)

        let trace = m.snapshot().first { $0.frameID == id }!
        XCTAssertNotNil(trace.elapsedMs(.captured, .encoded))
        XCTAssertNotNil(trace.elapsedMs(.encoded, .sentOnWire))
        XCTAssertNotNil(trace.elapsedMs(.sentOnWire, .receivedOnWire))
        XCTAssertNotNil(trace.elapsedMs(.receivedOnWire, .decoded))
        XCTAssertNotNil(trace.elapsedMs(.decoded, .rendered))
        XCTAssertNotNil(trace.glassToGlassMs)
    }
}

