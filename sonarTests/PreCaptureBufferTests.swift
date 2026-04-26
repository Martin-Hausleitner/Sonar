import AVFoundation
import XCTest
@testable import Sonar

final class PreCaptureBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeBuffer(value: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buf.frameLength = 480
        if let data = buf.floatChannelData {
            for i in 0..<480 { data[0][i] = value }
        }
        return buf
    }

    // MARK: - push + drain

    func testPushAndDrainReturnsAllFrames() {
        let pcb = PreCaptureBuffer(durationMs: 100, frameMs: 10) // capacity = 10
        let buffers = (0..<5).map { _ in makeBuffer() }
        buffers.forEach { pcb.push($0) }

        let drained = pcb.drain()
        XCTAssertEqual(drained.count, 5)
    }

    func testDrainReturnsFramesOldestFirst() {
        let pcb = PreCaptureBuffer(durationMs: 30, frameMs: 10) // capacity = 3
        let b0 = makeBuffer(value: 0.0)
        let b1 = makeBuffer(value: 0.1)
        let b2 = makeBuffer(value: 0.2)
        pcb.push(b0)
        pcb.push(b1)
        pcb.push(b2)

        let drained = pcb.drain()
        XCTAssertEqual(drained.count, 3)
        // Verify order by checking the float values we stamped
        XCTAssertEqual(drained[0].floatChannelData![0][0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(drained[1].floatChannelData![0][0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(drained[2].floatChannelData![0][0], 0.2, accuracy: 1e-6)
    }

    // MARK: - Over-capacity eviction

    func testPushOverCapacityEvictsOldest() {
        let pcb = PreCaptureBuffer(durationMs: 30, frameMs: 10) // capacity = 3
        // Push 4 frames; the first one should be evicted
        let b0 = makeBuffer(value: 0.0) // will be evicted
        let b1 = makeBuffer(value: 0.1)
        let b2 = makeBuffer(value: 0.2)
        let b3 = makeBuffer(value: 0.3)
        pcb.push(b0)
        pcb.push(b1)
        pcb.push(b2)
        pcb.push(b3)

        let drained = pcb.drain()
        XCTAssertEqual(drained.count, 3, "Only 3 frames (capacity) should remain")
        XCTAssertEqual(drained[0].floatChannelData![0][0], 0.1, accuracy: 1e-6,
                       "b0 should have been evicted; b1 is now oldest")
    }

    func testPushFarOverCapacityRetainsOnlyMostRecent() {
        let pcb = PreCaptureBuffer(durationMs: 20, frameMs: 10) // capacity = 2
        for i in 0..<10 {
            pcb.push(makeBuffer(value: Float(i) * 0.1))
        }
        let drained = pcb.drain()
        XCTAssertEqual(drained.count, 2)
        // The last two pushed (0.8 and 0.9) should be present
        XCTAssertEqual(drained[0].floatChannelData![0][0], 0.8, accuracy: 1e-6)
        XCTAssertEqual(drained[1].floatChannelData![0][0], 0.9, accuracy: 1e-6)
    }

    // MARK: - Drain empties the buffer

    func testDrainAfterDrainReturnsEmpty() {
        let pcb = PreCaptureBuffer(durationMs: 100, frameMs: 10)
        pcb.push(makeBuffer())
        _ = pcb.drain()

        let second = pcb.drain()
        XCTAssertTrue(second.isEmpty, "Second drain should return an empty array")
    }

    func testEmptyBufferDrainReturnsEmpty() {
        let pcb = PreCaptureBuffer()
        XCTAssertTrue(pcb.drain().isEmpty)
    }

    // MARK: - Default capacity

    func testDefaultCapacity200ms() {
        // durationMs=200, frameMs=10 → capacity = 20
        let pcb = PreCaptureBuffer()
        for _ in 0..<25 { pcb.push(makeBuffer()) }
        let drained = pcb.drain()
        XCTAssertEqual(drained.count, 20, "Default 200ms / 10ms = 20 frames capacity")
    }
}
