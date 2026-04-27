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

    let testIdentity: SonarTestIdentity

    @Published var phase: Phase = .idle
    @Published var profileID: String = "zimmer"
    @Published var aiActive: Bool = false

    // §6 — battery tier
    @Published var batteryTier: BatteryManager.Tier = .normal

    // §10 — signal quality
    @Published var signalScore: Int = 100
    @Published var signalGrade: SignalScoreCalculator.Grade = .excellent

    // §2.4 — active multipath count + which specific paths are live
    @Published var activePathCount: Int = 0
    /// Set of currently-connected transports (raw values: "multipeer", "bluetooth",
    /// "mpquic", "tailscale", "simulatorRelay"). Drives the per-path icon row on
    /// the main screen so the user sees *which* transports are up, not just how many.
    @Published var activePathIDs: Set<String> = []

    // §9.2 — hardware tier
    let deviceCapabilities: DeviceCapabilities = DeviceCapabilities.detect()

    // §5 — live transcript
    @Published var transcriptSegments: [LiveTranscriptionEngine.Segment] = []

    // §4.2 — recording state
    @Published var isRecording: Bool = false

    // V30 — privacy mode
    @Published var privacyModeActive: Bool = false

    // Peer discovery (passive — updated by SessionCoordinator even before session starts)
    @Published var localPeerName: String
    @Published var localPeerID: String
    @Published var peerOnline: Bool = false
    @Published var peerID: String? = nil
    @Published var peerName: String? = nil
    @Published var peerLastSeen: Date? = nil
    @Published var connectionIsSimulated: Bool

    // Connection type shown in status
    @Published var connectionType: ConnectionType = .none

    // QR-code pairing — populated by `PairingView`'s scan tab. SessionCoordinator
    // (or a future PairingService) can react to this to attempt a connection
    // using the token's `host`/`tsIP`/`ble` hints. For MVP the UI layer also
    // mirrors `name`/`id` into `peerName`/`peerID` and flips `peerOnline = true`
    // so the existing connection chrome shows the pairing.
    @Published var pendingPairing: PairingToken? = nil

    enum ConnectionType {
        case none, awdl, bluetooth, wifi, tailscale, internet, simulatorRelay
        var label: String {
            switch self {
            case .none:      return "Kein Signal"
            case .awdl:      return "AWDL · Lokal"
            case .bluetooth: return "Bluetooth"
            case .wifi:      return "WLAN · Lokal"
            case .tailscale: return "Tailscale"
            case .internet:  return "Internet"
            case .simulatorRelay: return "Simulator Relay"
            }
        }
        var icon: String {
            switch self {
            case .none:      return "antenna.radiowaves.left.and.right.slash"
            case .awdl:      return "dot.radiowaves.left.and.right"
            case .bluetooth: return "wave.3.right.circle.fill"
            case .wifi:      return "wifi"
            case .tailscale: return "network.badge.shield.half.filled"
            case .internet:  return "globe"
            case .simulatorRelay: return "desktopcomputer.and.iphone"
            }
        }
    }

    init(testIdentity: SonarTestIdentity = .current()) {
        self.testIdentity = testIdentity
        self.localPeerName = testIdentity.deviceName
        self.localPeerID = testIdentity.deviceID
        self.connectionIsSimulated = testIdentity.isSimulatorRelayEnabled
    }
}
