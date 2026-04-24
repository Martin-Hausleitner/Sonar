import AVFoundation
import Foundation

#if canImport(MusicKit)
import MusicKit
#endif

/// Apple Music background mix-in for Club mode. Plan §7.2 / §10/13.
@MainActor
final class MusicDucker {
    func enable(targetGain: Double = 0.16) async throws {
        // TODO §10/13: request MusicKit authorization, queue current track,
        // start a separate MPMusicPlayerController.applicationQueuePlayer with mixWithOthers.
    }

    func disable() {
        // TODO §10/13
    }

    func duckOnVoice(active: Bool) {
        // TODO §10/13: drop music gain another -6 dB while voice is active.
    }
}
