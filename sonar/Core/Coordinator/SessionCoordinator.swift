import Combine
import Foundation

/// Central state machine. Plan §2.3.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var phase: AppState.Phase = .idle

    func start() {
        // TODO §10/4 onwards: kick off NearTransport advertising/browsing,
        // then lift to .connecting and arbitrate Near vs Far.
        phase = .connecting
    }

    func stop() {
        phase = .idle
    }
}
