import Combine
import Foundation

/// Single source of truth for "how far is the partner". Plan §10/5.
///
/// Priority: UWB (NIRangingEngine) > BLE RSSI (RSSIFallback).
/// When NIRangingEngine is invalidated (§14.1), RSSIFallback is automatically
/// started so the distance estimate degrades gracefully instead of going nil.
@MainActor
final class DistancePublisher: ObservableObject {
    @Published private(set) var distance: Double? = nil
    @Published private(set) var source: Source = .none

    enum Source: String, Sendable { case uwb, rssi, none }

    private var bag = Set<AnyCancellable>()

    func bind(uwb: NIRangingEngine, rssi: RSSIFallback) {
        // §14.1: start RSSI fallback when UWB session is invalidated.
        uwb.onInvalidated = { [weak rssi] in
            rssi?.start()
        }

        // UWB stream — highest priority.
        uwb.distance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self else { return }
                if let d {
                    self.distance = d
                    self.source = .uwb
                } else if self.source == .uwb {
                    // UWB went nil but wasn't invalidated (peer temporarily lost).
                    // Fall through to RSSI if it has a reading; otherwise nil.
                    self.distance = nil
                    self.source = .none
                }
            }
            .store(in: &bag)

        // RSSI stream — lower priority, only used when UWB is not active.
        rssi.distance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in
                guard let self, self.source != .uwb else { return }
                self.distance = d
                self.source = d == nil ? .none : .rssi
            }
            .store(in: &bag)
    }
}
