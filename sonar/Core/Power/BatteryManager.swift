import Combine
import Foundation
import UIKit

/// Monitors battery level and state, publishes the current power tier.
/// §6 — four tiers: Normal → Eco → Saver → Critical.
@MainActor
final class BatteryManager: ObservableObject {
    static let shared = BatteryManager()

    enum Tier: Int, Comparable, Sendable {
        case critical = 0   // <10 %: PTT only, Lyra 3.2 kbps, no recording
        case saver    = 1   // 10-20 %: 1 path, Lyra 6 kbps, no transcription
        case eco      = 2   // 20-40 %: 2 paths, Opus 24 kbps
        case normal   = 3   // >40 % or charging: all 4 paths, Opus 32 kbps

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published private(set) var tier: Tier = .normal
    @Published private(set) var level: Float = 1.0
    @Published private(set) var isCharging: Bool = false

    private var overrideTier: Tier?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateFromDevice()
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .sink { [weak self] _ in self?.updateFromDevice() }
            .store(in: &cancellables)
    }

    /// Pin a tier manually; pass nil to restore auto.
    func setOverride(_ tier: Tier?) {
        overrideTier = tier
        updateFromDevice()
    }

    private func updateFromDevice() {
        let device = UIDevice.current
        level = device.batteryLevel < 0 ? 1.0 : device.batteryLevel
        isCharging = device.batteryState == .charging || device.batteryState == .full

        if isCharging {
            tier = overrideTier ?? .normal
            return
        }
        tier = overrideTier ?? computeTier(level: level)
    }

    private func computeTier(level: Float) -> Tier {
        switch level {
        case ..<0.10: .critical
        case ..<0.20: .saver
        case ..<0.40: .eco
        default:      .normal
        }
    }
}

extension BatteryManager.Tier {
    var activePaths: Int {
        switch self {
        case .normal:   4
        case .eco:      2
        case .saver:    1
        case .critical: 1
        }
    }

    var opusBitrateKbps: Int {
        switch self {
        case .normal:   32
        case .eco:      24
        case .saver:    6   // Lyra v2
        case .critical: 0   // push-to-talk, Lyra 3.2
        }
    }

    var transcriptionEnabled: Bool {
        switch self {
        case .normal, .eco: true
        case .saver, .critical: false
        }
    }

    var recordingEnabled: Bool {
        self != .critical
    }
}
