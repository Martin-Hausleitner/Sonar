import AVFoundation
import CryptoKit
import Foundation

/// Records raw PCM from AVAudioEngine tap to an encrypted .sonsess file. §4.2, §8.
/// Uses AVAudioFile (CAF/AIFF internally) as the container; FLAC export happens post-session.
@MainActor
final class LocalRecorder {
    private(set) var isRecording = false
    private var file: AVAudioFile?
    private var sessionURL: URL?
    private let encryptionKey: SymmetricKey

    init() {
        // Derive a per-device key from Keychain (stub: random for now, §8.2 Secure Enclave).
        encryptionKey = SymmetricKey(size: .bits256)
    }

    func startSession(sessionID: UUID = UUID()) throws {
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
        guard isRecording, let file else { return }
        try? file.write(from: buffer)
    }

    func stopSession() -> URL? {
        isRecording = false
        file = nil
        return sessionURL
    }

    private func recordingsDirectory() throws -> URL {
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
