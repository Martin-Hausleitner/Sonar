import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case near(distance: Double)
        case far
        case degrading
        case recovering
    }

    @Published var phase: Phase = .idle
    @Published var profileID: String = "zimmer"
    @Published var aiActive: Bool = false
}
