import ActivityKit
import Foundation
import SwiftUI

// MARK: - Attributes (reserved for a future widget extension)

struct SonarActivityAttributes: ActivityAttributes {
    /// Dynamic state updated while the activity is live.
    struct ContentState: Codable, Hashable {
        var score: Int // 0-100
        var phaseName: String // "Near", "Far", "Verbindet…", etc.
        var activePaths: Int // 1-4
    }

    /// Static metadata set at launch.
    var peerName: String
}

// MARK: - Manager (main-app side)

@MainActor
final class SonarLiveActivityManager {
    static let shared = SonarLiveActivityManager()
    private var currentActivity: Activity<SonarActivityAttributes>?

    private init() {}

    func start(peerName: String, score: Int, phase: String, paths: Int) {
        // No-op until a WidgetKit extension supplies the visible presentation.
        _ = (peerName, score, phase, paths)
    }

    func update(score: Int, phase: String, paths: Int) async {
        _ = (score, phase, paths)
    }

    func stop() async {
        await currentActivity?.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
    }
}
