import Combine
import Foundation

/// Single source of truth for "how far is the partner". Plan §10/5.
@MainActor
final class DistancePublisher: ObservableObject {
    @Published private(set) var distance: Double? = nil
    @Published private(set) var source: Source = .none

    enum Source: String, Sendable { case uwb, rssi, none }

    private var bag = Set<AnyCancellable>()

    func bind(uwb: NIRangingEngine, rssi: RSSIFallback) {
        uwb.distance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self else { return }
                if let d {
                    self.distance = d
                    self.source = .uwb
                } else if self.source == .uwb {
                    self.distance = nil
                    self.source = .none
                }
            }
            .store(in: &bag)

        rssi.estimatedDistance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self, self.source != .uwb else { return }
                self.distance = d
                self.source = d == nil ? .none : .rssi
            }
            .store(in: &bag)
    }
}
