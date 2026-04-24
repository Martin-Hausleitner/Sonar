import CoreHaptics
import UIKit

@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    private var engine: CHHapticEngine?

    private init() {
        // TODO §10/15: bring up CHHapticEngine and expose pattern players.
    }

    func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
