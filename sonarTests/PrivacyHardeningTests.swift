import AVFoundation
import XCTest
@testable import Sonar

/// Verifies the V30 privacy hardening: when PrivacyMode is active, audio must
/// not reach disk, and a mid-session activation must wipe any in-progress file.
@MainActor
final class PrivacyHardeningTests: XCTestCase {

    private var tempDir: URL!
    private var recorder: LocalRecorder!

    override func setUp() {
        super.setUp()
        // Always start tests with privacy mode OFF, regardless of state from
        // previous tests in the suite (PrivacyMode.shared is process-global).
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        recorder = LocalRecorder()
        recorder.directoryOverride = tempDir
    }

    override func tearDown() {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        recorder = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buf.frameLength = 480
        // Fill with a tiny sine so the file is non-trivial.
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(buf.frameLength) {
                ch[i] = 0.01 * sinf(Float(i) * 0.05)
            }
        }
        return buf
    }

    private func filesInTempDir() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
    }

    // MARK: - Tests

    /// LocalRecorder must not write when privacy is active before startSession().
    func testRecorderDoesNotWriteWhenPrivacyActiveBeforeStart() {
        PrivacyMode.shared.activate()

        // startSession should short-circuit. The implementation does not throw —
        // it logs and returns. Either way no file should land on disk.
        do { try recorder.startSession() } catch { /* fine — no-op expected */ }

        XCTAssertFalse(recorder.isRecording, "Recorder must not enter recording state when privacy is active")

        // Even if a buffer is fed, nothing must be written.
        recorder.append(makeBuffer())

        XCTAssertTrue(filesInTempDir().isEmpty,
                      "No file may exist in recordings dir when privacy was active before startSession")
    }

    /// Activating privacy mid-session must close the recorder and delete the
    /// in-progress file so a half-recording is never left in storage.
    func testActivatingPrivacyMidSessionDeletesInProgressFile() throws {
        // Start cleanly with privacy off.
        try recorder.startSession()
        XCTAssertTrue(recorder.isRecording)
        recorder.append(makeBuffer())

        XCTAssertEqual(filesInTempDir().count, 1, "Session file should exist before privacy activates")

        // Pull the kill switch.
        PrivacyMode.shared.activate()

        // Allow the Combine sink to run.
        let exp = expectation(description: "privacy sink ran")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(recorder.isRecording, "Recorder must stop when privacy activates mid-session")
        XCTAssertTrue(filesInTempDir().isEmpty,
                      "In-progress recording file must be deleted when privacy activates")
    }

    /// Deactivating privacy after a session has ended must not crash and must
    /// leave the recorder in a clean idle state.
    func testDeactivatingPrivacyAfterSessionEndedDoesNotCrash() throws {
        try recorder.startSession()
        recorder.append(makeBuffer())
        _ = recorder.stopSession()

        XCTAssertFalse(recorder.isRecording)

        // Toggle privacy through both edges with no active session.
        PrivacyMode.shared.activate()
        PrivacyMode.shared.deactivate()

        // Spin the runloop briefly so any sinks fire before assertions.
        let exp = expectation(description: "runloop tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(recorder.isRecording, "Recorder must remain idle after privacy toggles post-session")
        // No assertion on file presence — the file from the completed session may
        // remain. The contract here is "no crash, no spurious recording".
    }
}
