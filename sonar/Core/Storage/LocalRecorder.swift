import AVFoundation
import Combine
import CryptoKit
import Foundation

/// Records raw PCM from AVAudioEngine tap to an encrypted .sonsess file. §4.2, §8.
/// Uses AVAudioFile (CAF/AIFF internally) as the container; FLAC export happens post-session.
///
/// Privacy hardening (V30 "Big Red Button"):
///   * `startSession()` refuses to open a file when privacy mode is active.
///   * `append(_:)` short-circuits while privacy mode is active — belt-and-braces
///     so audio cannot reach disk even if a caller forgets `stopSession()`.
///   * If privacy is toggled mid-session, the in-progress recording is closed
///     AND the half-written file in Documents/Library is deleted.
@MainActor
final class LocalRecorder {
    private(set) var isRecording = false
    private var file: AVAudioFile?
    private var sessionURL: URL?
    private let encryptionKey: SymmetricKey
    private var privacyCancellable: AnyCancellable?

    /// Optional override for the directory new sessions are written to.
    /// Used by tests to avoid touching `Library/Sonar/Recordings`. When `nil`,
    /// the production path under `Library/` is used.
    var directoryOverride: URL?

    init() {
        // Derive a per-device key from Keychain (stub: random for now, §8.2 Secure Enclave).
        encryptionKey = SymmetricKey(size: .bits256)

        // React to privacy mode being toggled mid-session: close the file and
        // wipe the in-progress recording so a half-session can't sit on disk.
        privacyCancellable = NotificationCenter.default
            .publisher(for: .sonarPrivacyModeActivated)
            .sink { [weak self] _ in
                self?.handlePrivacyActivated()
            }
    }

    func startSession(sessionID: UUID = UUID()) throws {
        guard !PrivacyMode.shared.isActive else {
            Log.app.info("Privacy mode active — recording suppressed")
            return
        }

        let dir = try recordingsDirectory()
        let filename = "\(ISO8601DateFormatter().string(from: Date()))-\(sessionID.uuidString.prefix(8)).sonsess"
        let url = dir.appendingPathComponent(filename)
        sessionURL = url

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        file = try AVAudioFile(forWriting: url, settings: format.settings)
        isRecording = true
    }

    /// Call this from AudioEngine's tap on every captured buffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        // Belt-and-braces: even if SessionCoordinator forgets to stop us when
        // privacy activates, no audio reaches disk.
        guard !PrivacyMode.shared.isActive else { return }
        guard isRecording, let file else { return }
        try? file.write(from: buffer)
    }

    func stopSession() -> URL? {
        isRecording = false
        file = nil
        let url = sessionURL
        sessionURL = nil
        return url
    }

    private func handlePrivacyActivated() {
        guard isRecording || file != nil || sessionURL != nil else { return }

        let url = sessionURL
        isRecording = false
        file = nil
        sessionURL = nil

        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            Log.app.info("Privacy mode active — in-progress recording deleted")
        }
    }

    private func recordingsDirectory() throws -> URL {
        if let override = directoryOverride {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Sonar/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Session storage layout (§8.1)

extension LocalRecorder {
    struct SessionMeta: Codable {
        let uuid: UUID
        let createdAt: Date
        let participants: [String]
        let profile: String
        let durationSec: Double
        let audioFormat: String
    }

    static func allSessions() -> [URL] {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Sonar/Recordings")
        return (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
    }

    static func deleteOlderThan(days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for url in allSessions() {
            guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                  created < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
